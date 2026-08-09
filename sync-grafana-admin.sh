#!/bin/bash
####################################
#
# sync-grafana-admin.sh — pin Grafana's admin login, with Vault as the source of truth.
#
####################################
# WHY THIS EXISTS (2026-08-04)
#
# kube-prometheus USED TO mount Grafana's /var/lib/grafana from an **emptyDir**. Grafana
# keeps its users — including the admin password — in a SQLite DB in there, so the DB was
# destroyed on every pod restart, every rollout, and every minikube rebuild. Setting the
# password in the Grafana UI therefore lasted exactly until the next restart, after which
# the login silently reverted to the built-in admin/admin. That volume is now a durable PV
# (kube-prometheus manifests/grafana-dataVolume.yaml), so the DB survives.
#
# GF_SECURITY_ADMIN_USER / GF_SECURITY_ADMIN_PASSWORD are fed from a Secret
# `monitoring/grafana-admin` (secretKeyRef, optional: true) by kube-prometheus's
# grafana-deployment.yaml. This script is what puts that Secret there.
#
# ⚠️ But those env vars are NOT sufficient on their own — Grafana only honours them when
# it CREATES the admin user, never against an existing user DB. See the enforcement block
# at the bottom of this script, which is what actually pins the live login.
#
##### WHERE THE PASSWORD ACTUALLY LIVES ############################################
#
#   Vault  kv/grafana/admin  {admin-user, admin-password}     <- SOURCE OF TRUTH
#     |
#     |  this script (run by start-scratch.sh / restart-minikube.sh, or by hand)
#     v
#   k8s    monitoring/grafana-admin Secret
#     |
#     |  secretKeyRef, optional: true
#     v
#   Grafana GF_SECURITY_ADMIN_USER / GF_SECURITY_ADMIN_PASSWORD
#
# The password is in NO git repo — not STEP0, not kube-prometheus. Rotating it means
# rotating it in Vault and re-running this script; the next Grafana restart picks it up.
#
##### WHY GRAFANA DOES NOT READ VAULT DIRECTLY #####################################
#
# The tidier-looking option is the Vault agent injector on the Grafana pod. It was
# rejected deliberately: the injector's init container blocks until Vault answers, which
# would mean Grafana — and with it every dashboard you would use to diagnose an outage —
# cannot start whenever Vault is sealed, down, or simply not deployed yet. start-scratch.sh
# also brings monitoring up BEFORE vault, so that ordering would have to be inverted too.
#
# Projecting Vault -> Secret instead keeps Vault authoritative while leaving monitoring
# able to boot on its own. It is the same shape as the existing "mirror Vault AppRole
# material into Jenkins credentials" step in start-scratch.sh. The cost is that the value
# also sits in etcd as a Secret; on a single-node box where the operator already holds the
# Vault root token, that is not a meaningful widening.
#
##### SEEDING A FRESH VAULT ########################################################
#
# On a cluster where kv/grafana/admin does not exist yet, it is created ONCE from
# (in order): $GRAFANA_ADMIN_PASSWORD, then GRAFANA_ADMIN_PASSWORD in the gitignored
# STEP0/.env, then a generated random password. After that Vault wins forever — a later
# .env edit does NOT overwrite a live Vault value, so a rotation done properly in Vault is
# never silently reverted by a stale file. Use --reseed to force .env back over Vault.
#
# .env is captured by backup-minikube-mnt.sh (STEP0 is tarred whole) and restored by
# restore-scratch.sh, so a bare-metal rebuild seeds the same password it had before.
#
# Usage:
#   ./sync-grafana-admin.sh            # seed if absent, project to k8s, restart if changed
#   ./sync-grafana-admin.sh --status   # read-only: report state, change nothing
#   ./sync-grafana-admin.sh --reseed   # overwrite Vault from .env/env, then project
#
# NOTE: best-effort by design, NOT set -e. A Grafana login that failed to sync must never
# abort a cold bootstrap that still has apps to deploy.
####################################################################################

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${GRAFANA_ADMIN_ENV_FILE:-$SELFDIR/.env}"
KEYS_FILE="${VAULT_KEYS_FILE:-$HOME/.vault/cluster-keys.json}"
VAULT_KV_PATH="${GRAFANA_VAULT_KV_PATH:-kv/grafana/admin}"
NS="${GRAFANA_NAMESPACE:-monitoring}"
SECRET_NAME="${GRAFANA_ADMIN_SECRET:-grafana-admin}"

MODE="sync"
case "$1" in
  --status) MODE="status" ;;
  --reseed) MODE="reseed" ;;
  "")       ;;
  *)        echo "usage: $(basename "$0") [--status|--reseed]" >&2; exit 2 ;;
esac

warn() { echo "sync-grafana-admin: WARN: $*" >&2; }
info() { echo "sync-grafana-admin: $*"; }

# Same .env reader trigger-app-builds.sh uses: tolerate quotes, keep '=' in the value.
env_val() {
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"''
}

# --- Vault must be reachable AND unsealed before any of this means anything -------
# `vault status` exits NON-ZERO when sealed or uninitialized, so test the OUTPUT
# (does it parse, does it have .sealed) rather than the exit code — the same trap
# start-vault.sh documents.
STATUS_JSON="$(kubectl exec vault-0 -n vault -- vault status -format=json 2>/dev/null)"
if ! printf '%s' "$STATUS_JSON" | jq -e 'has("sealed")' >/dev/null 2>&1; then
  warn "vault-0 not reachable; leaving $NS/$SECRET_NAME untouched."
  exit 0
fi
# NOT `.sealed // true`. jq's `//` treats **false** as empty, so that idiom reports an
# UNSEALED Vault as sealed and this script would refuse to run against a healthy cluster.
# The has("sealed") gate above already covers the missing-key case.
if [ "$(printf '%s' "$STATUS_JSON" | jq -r '.sealed')" = "true" ]; then
  warn "Vault is SEALED; cannot read $VAULT_KV_PATH. Unseal, then re-run this script."
  exit 0
fi

if [ ! -s "$KEYS_FILE" ]; then
  warn "$KEYS_FILE missing/empty; cannot authenticate to Vault."
  exit 0
fi
ROOT_TOKEN="$(jq -r '.root_token // empty' "$KEYS_FILE")"
if [ -z "$ROOT_TOKEN" ]; then
  warn "no root_token in $KEYS_FILE; cannot authenticate to Vault."
  exit 0
fi

# Log in inside the pod (same mechanism start-vault.sh uses). Passing the token on
# stdin keeps it out of this host's process table.
if ! kubectl exec -i vault-0 -n vault -- vault login - <<< "$ROOT_TOKEN" >/dev/null 2>&1; then
  warn "vault login failed (token rotated?); leaving $NS/$SECRET_NAME untouched."
  exit 0
fi

# --- Read whatever Vault already holds --------------------------------------------
VAULT_JSON="$(kubectl exec vault-0 -n vault -- vault kv get -format=json "$VAULT_KV_PATH" 2>/dev/null)"
V_USER="$(printf '%s' "$VAULT_JSON" | jq -r '.data.data["admin-user"] // empty' 2>/dev/null)"
V_PASS="$(printf '%s' "$VAULT_JSON" | jq -r '.data.data["admin-password"] // empty' 2>/dev/null)"

if [ "$MODE" = "status" ]; then
  if [ -n "$V_PASS" ]; then
    info "vault  $VAULT_KV_PATH: present (admin-user=${V_USER:-<unset>})"
  else
    info "vault  $VAULT_KV_PATH: ABSENT — Grafana is on its built-in admin/admin"
  fi
  K_PASS="$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.admin-password}' 2>/dev/null)"
  if [ -z "$K_PASS" ]; then
    info "k8s    $NS/$SECRET_NAME: ABSENT"
  elif [ -n "$V_PASS" ] && [ "$(printf '%s' "$V_PASS" | base64 -w0)" = "$K_PASS" ]; then
    info "k8s    $NS/$SECRET_NAME: present and MATCHES Vault"
  else
    info "k8s    $NS/$SECRET_NAME: present but DIFFERS from Vault — run without --status"
  fi
  # Does the running pod actually consume it? A Secret nothing reads pins nothing.
  if kubectl -n "$NS" get deploy grafana -o json 2>/dev/null \
     | jq -e '.spec.template.spec.containers[]?.env[]? | select(.name=="GF_SECURITY_ADMIN_PASSWORD")' >/dev/null 2>&1; then
    info "deploy $NS/grafana: reads GF_SECURITY_ADMIN_PASSWORD from a Secret"
  else
    info "deploy $NS/grafana: NO GF_SECURITY_ADMIN_PASSWORD env — apply kube-prometheus manifests/"
  fi
  exit 0
fi

# --- Seed, if Vault has nothing (or --reseed was asked for) ------------------------
if [ -z "$V_PASS" ] || [ "$MODE" = "reseed" ]; then
  SEED_USER="${GRAFANA_ADMIN_USER:-$(env_val GRAFANA_ADMIN_USER)}"
  SEED_PASS="${GRAFANA_ADMIN_PASSWORD:-$(env_val GRAFANA_ADMIN_PASSWORD)}"
  SEED_USER="${SEED_USER:-admin}"
  if [ -z "$SEED_PASS" ]; then
    # No operator-supplied password anywhere. Generating one beats defaulting to
    # something guessable on a Grafana that is reachable from the internet via NPM.
    SEED_PASS="$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 24)"
    warn "no GRAFANA_ADMIN_PASSWORD in env or $ENV_FILE — generated a random one."
    warn "read it back with: kubectl exec vault-0 -n vault -- vault kv get $VAULT_KV_PATH"
  fi
  if kubectl exec vault-0 -n vault -- vault kv put "$VAULT_KV_PATH" \
       "admin-user=$SEED_USER" "admin-password=$SEED_PASS" >/dev/null 2>&1; then
    info "seeded $VAULT_KV_PATH (admin-user=$SEED_USER)"
    V_USER="$SEED_USER"; V_PASS="$SEED_PASS"
  else
    warn "could not write $VAULT_KV_PATH; leaving $NS/$SECRET_NAME untouched."
    exit 0
  fi
fi
V_USER="${V_USER:-admin}"

# --- Project into the monitoring namespace ----------------------------------------
if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  warn "namespace $NS does not exist yet (monitoring not deployed?); nothing to do."
  exit 0
fi

PREV="$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.admin-password}' 2>/dev/null)"
if ! kubectl -n "$NS" create secret generic "$SECRET_NAME" \
       --from-literal=admin-user="$V_USER" \
       --from-literal=admin-password="$V_PASS" \
       --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1; then
  warn "failed to apply $NS/$SECRET_NAME."
  exit 0
fi
info "applied $NS/$SECRET_NAME from $VAULT_KV_PATH"

# --- Restart Grafana only if the value it is running with is now stale -------------
# env-var Secrets are read once at container start; unlike a mounted file they are NOT
# refreshed in place. So a changed password needs a restart, and an unchanged one must
# not cause a pointless rollout on every bootstrap.
NEW="$(printf '%s' "$V_PASS" | base64 -w0)"
if ! kubectl -n "$NS" get deploy grafana >/dev/null 2>&1; then
  info "deployment $NS/grafana not present yet; it will pick the Secret up when created."
  exit 0
fi
if [ "$PREV" = "$NEW" ]; then
  info "password unchanged; not restarting grafana."
else
  info "password changed; restarting $NS/grafana to apply it"
  kubectl -n "$NS" rollout restart deployment/grafana >/dev/null 2>&1
  kubectl -n "$NS" rollout status deployment/grafana --timeout=180s \
    || warn "grafana rollout did not report ready within 180s; check 'kubectl -n $NS get po'."
fi

##### THE ENV VAR IS NOT ENOUGH — ENFORCE IT IN GRAFANA'S OWN USER DB ###############
#
# ⚠️ GF_SECURITY_ADMIN_PASSWORD only applies when Grafana CREATES the admin user, i.e.
# against an EMPTY user DB. On every later start Grafana reads its SQLite DB, finds
# user id 1 already there, and IGNORES the env var completely. So projecting Vault ->
# Secret -> env and restarting the pod changes nothing on a cluster that has booted
# even once. Verified 2026-08-09: Vault, the Secret and the pod env all read the new
# password, the pod had restarted, and the OLD password still authenticated.
#
# This used to work only by accident. /var/lib/grafana was an emptyDir, so every pod
# restart destroyed the user DB and Grafana re-created the admin from the env var —
# which is exactly the bug that motivated this script. Making that volume a durable PV
# (kube-prometheus manifests/grafana-dataVolume.yaml) fixed the data loss and, in the
# same stroke, made the env-var mechanism inert. The header comment above still
# describes the old "re-applied on every startup" behaviour; it is wrong, and that
# wrongness is why an operator-set password could silently revert.
#
# `grafana cli admin reset-admin-password` writes the user DB directly and needs NO
# existing credential, so it also recovers a Grafana nobody can log into any more.
# Probe first: the reset runs DB migrations and is far too heavy for every bootstrap,
# and a needless failed login would count against Grafana's brute-force lockout.
####################################################################################

# Basic-auth probe from INSIDE the pod, so this works with no NodePort/route assumptions.
# Credential goes over stdin, never argv, so it stays out of the pod's process table.
if printf '%s:%s' "$V_USER" "$V_PASS" | base64 -w0 \
   | kubectl exec -i -n "$NS" deploy/grafana -- sh -c \
       'read -r A; wget -q -O /dev/null --header="Authorization: Basic $A" http://127.0.0.1:3000/api/user' \
       >/dev/null 2>&1; then
  info "verified $V_USER can log in to grafana with the $VAULT_KV_PATH password."
  exit 0
fi

warn "grafana rejects the $VAULT_KV_PATH password (env var does not apply to an existing"
warn "user DB); resetting admin user id 1 directly via grafana cli."
if printf '%s' "$V_PASS" | kubectl exec -i -n "$NS" deploy/grafana -- \
     grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
     admin reset-admin-password --password-from-stdin >/dev/null 2>&1; then
  info "reset grafana admin password from $VAULT_KV_PATH."
else
  warn "grafana cli reset FAILED; the login is NOT what $VAULT_KV_PATH says."
  warn "check: kubectl -n $NS logs deploy/grafana"
fi
exit 0
