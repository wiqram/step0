#!/usr/bin/env bash
# cluster-autostart.sh — bring the minikube cluster back to HEALTH after a host reboot,
# but ONLY when it was meant to be running. Run by cron (@reboot + */10 watchdog).
#
# WHY: minikube's container ships with restart policy `no`, so a host reboot leaves prod down
# until someone runs `minikube start` (N-0006 #3). Docker IS enabled at boot, so the real fix is
# the container restart policy — this script also enforces it and reconciles k8s health.
#
# DECISION TREE (matches the two operator scenarios):
#   * container RUNNING + k8s healthy        -> nothing to do.
#   * container RUNNING + k8s unhealthy      -> `minikube start` to reconcile (fixes kubeconfig/IP
#                                               drift + unhealthy control plane after an unclean crash).
#   * container EXITED (after a grace window) -> operator ran `minikube stop` => RESPECT it, do nothing.
#   * container ABSENT                        -> a from-scratch rebuild is a HUMAN decision (it implies
#                                               a re-deploy) => ALERT via ntfy, do NOT auto-create.
#   * `minikube start` fails                  -> ALERT via ntfy; NEVER `minikube delete` (destructive).
#
# The intent oracle is Docker's `unless-stopped` policy (enforced below): Docker auto-restarts a
# cluster that was running, and leaves an explicitly-stopped one down — so the container's post-boot
# state already reflects intent. Vault is re-unsealed separately by vault-auto-unseal.sh.
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

SELFDIR="$(cd "$(dirname "$0")" && pwd)"   # STEP0 repo root
CONTAINER="minikube"
LOGDIR="$SELFDIR/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/cluster-autostart.log"
LOCK="$LOGDIR/.cluster-autostart.lock"
# ntfy alert topic from STEP0/.env (gitignored); env override wins.
NTFY_URL="${NTFY_URL:-$(grep -E '^NTFY_URL=' "$SELFDIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )}"

log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$LOG"; }
ntfy(){ [ -n "${NTFY_URL:-}" ] || return 0; curl -fsS -m 15 -H "Title: $1" -H "Priority: ${3:-high}" -H "Tags: ${4:-rotating_light,cloud}" -d "$2" "$NTFY_URL" >/dev/null 2>&1 || log "WARN: ntfy push failed"; }

# Single instance (the */10 watchdog no-ops while a run is in flight).
exec 9>"$LOCK"; flock -n 9 || exit 0

# 1. Wait for the Docker daemon (boot ordering — @reboot may fire before docker is ready).
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
if ! docker info >/dev/null 2>&1; then log "docker daemon not up after 120s — aborting"; ntfy "minikube autostart: docker daemon DOWN" "host up but docker not running after 120s"; exit 1; fi

state="$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo absent)"

# 2. ABSENT -> from-scratch is a human call (implies re-deploy). Alert, do not auto-create.
if [ "$state" = absent ]; then
  log "minikube container ABSENT — NOT auto-creating (from-scratch rebuild is a human decision; implies redeploy)"
  ntfy "minikube cluster ABSENT after boot" "The minikube container is gone. A from-scratch 'minikube start' (+ redeploy) is needed — left for the operator, not auto-run."
  exit 2
fi

# 3. Enforce the restart policy (minikube resets it to 'no' whenever it recreates the container).
pol="$(docker inspect "$CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)"
if [ "$pol" != "unless-stopped" ]; then docker update --restart=unless-stopped "$CONTAINER" >/dev/null 2>&1 && log "re-applied restart=unless-stopped (was '$pol')"; fi

# 4. Grace window: Docker auto-restarts an `unless-stopped` container at daemon start. If it is still
#    not running after the grace, it was explicitly stopped -> respect intent, do nothing.
for _ in $(seq 1 10); do
  state="$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null)"
  [ "$state" = "running" ] && break
  sleep 3
done
if [ "$state" != "running" ]; then
  log "container is '$state' after grace — intentional stop (or operator maintenance); RESPECTING, not starting"
  exit 0
fi

# 5. Container is running — let k8s self-heal first; only reconcile if it stays unhealthy.
k8s_ok(){ minikube status -o json 2>/dev/null | grep -q '"APIServer":"Running"' && minikube status -o json 2>/dev/null | grep -q '"Kubelet":"Running"'; }
for _ in $(seq 1 40); do k8s_ok && { log "cluster healthy (container up, APIServer+Kubelet Running)"; exit 0; }; sleep 3; done

# 6. Up but unhealthy after ~2min -> reconcile with `minikube start` (fixes kubeconfig/IP + control plane).
log "container running but k8s unhealthy after 120s — reconciling with 'minikube start --driver=docker'"
if timeout 360 minikube start --driver=docker >>"$LOG" 2>&1; then
  if k8s_ok; then log "reconcile OK — cluster healthy"; ntfy "minikube cluster auto-recovered" "Host rebooted; cluster reconciled to healthy via minikube start." default "white_check_mark,cloud"; exit 0
  else log "minikube start returned but k8s still unhealthy"; ntfy "minikube auto-recover INCOMPLETE" "minikube start ran but APIServer/Kubelet not Running — manual check needed."; exit 1; fi
else
  log "minikube start FAILED — manual recovery needed (possibly from-scratch). NOT auto-deleting."
  ntfy "minikube auto-recover FAILED" "minikube start failed after reboot. Manual recovery needed — see ops/agent/logs/cluster-autostart.log. NOT auto-deleting (data-safe)."
  exit 1
fi
