#!/usr/bin/env bash
# vault-auto-unseal.sh — keep the self-hosted (minikube) Vault unsealed automatically.
#
# WHY: Vault uses Shamir seal with NO auto-unseal (no cloud KMS in this homelab), so after
# any cluster restart it comes up SEALED → every vault-agent-init hangs → postgres/web/jobs
# stall, and the 01:00 postgres-backup silently skips (incident N-0006 / N-0009). This loop
# unseals it within ~10s of Vault becoming reachable, with NO manual step.
#
# DESIGN (host-side on purpose): the unseal key stays in ~/.vault/cluster-keys.json on the
# host — exactly where it already lives — and is NEVER written into the cluster/etcd or git.
# The key is sent only in the HTTP request BODY (via stdin, never argv), so it can't leak via
# `ps`. Talks to Vault over the NodePort; resolves the minikube IP each pass so it adapts.
#
# RUN: started by cron (@reboot + */5 watchdog, see docs/RESTART-RECOVERY.md). flock keeps a single
# instance. Logs ONLY on seal/unseal events (so the log stays tiny). Run by hand to start now:
#   setsid ~/Ideaprojects/STEP0/vault-auto-unseal.sh >> ~/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1 </dev/null &
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

KEYFILE="$HOME/.vault/cluster-keys.json"
INTERVAL="${VAULT_UNSEAL_INTERVAL:-10}"     # seconds between checks
NODEPORT="${VAULT_NODEPORT:-30200}"          # vault svc NodePort (http; tls_disable=1)
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$SELFDIR/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/vault-auto-unseal.log"
LOCK="$LOGDIR/.vault-unseal.lock"

log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$LOG"; }

# Single instance — a duplicate (e.g. the */5 watchdog while we're alive) exits immediately.
exec 9>"$LOCK"
if ! flock -n 9; then exit 0; fi

if [ ! -f "$KEYFILE" ]; then log "FATAL: unseal keyfile $KEYFILE not found — cannot run"; exit 1; fi

log "started (interval=${INTERVAL}s, nodeport=${NODEPORT})"
DOWN_LOGGED=0
while true; do
  MIP="$(minikube ip 2>/dev/null)"
  if [ -z "$MIP" ]; then
    [ "$DOWN_LOGGED" = 0 ] && { log "cluster unreachable (minikube ip empty) — waiting"; DOWN_LOGGED=1; }
    sleep "$INTERVAL"; continue
  fi
  DOWN_LOGGED=0
  ADDR="http://$MIP:$NODEPORT"
  STATUS="$(curl -s -m 5 "$ADDR/v1/sys/seal-status" 2>/dev/null)"
  if printf '%s' "$STATUS" | grep -q '"sealed":true'; then
    log "Vault is SEALED — unsealing via $ADDR"
    # Read the key only when needed; send it in the BODY via stdin (never in argv/ps).
    KEY="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('$KEYFILE')))['unseal_keys_b64'][0])" 2>/dev/null)"
    if [ -z "$KEY" ]; then log "ERROR: could not read unseal key from $KEYFILE"; sleep "$INTERVAL"; continue; fi
    RESP="$(printf '{"key":"%s"}' "$KEY" | curl -s -m 10 -X PUT --data @- "$ADDR/v1/sys/unseal" 2>/dev/null)"
    KEY=""
    if printf '%s' "$RESP" | grep -q '"sealed":false'; then
      log "unseal SUCCESS — Vault is now unsealed"
    else
      log "unseal incomplete: $(printf '%s' "$RESP" | grep -o '"sealed":[a-z]*' | head -1 || echo 'no response')"
    fi
  fi
  sleep "$INTERVAL"
done
