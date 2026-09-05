#!/bin/bash
# docker-runtime-upgrade.sh — upgrade docker-ce/containerd on THIS host only in a market-closed
# window, automatically, and hold them the rest of the week (OBS-ALERT-EXECERR, 2026-09-05).
#
# WHY
#   2026-09-05 12:56 BST an interactive `sudo apt upgrade` pulled docker-ce 29.7.2→29.8.0. Its
#   postinst restarts containerd+docker, and on a single-node minikube that restarts EVERY pod:
#   77 containers down, Loki 503 for ~10 minutes, 13 unrelated Grafana rules paged and cleared.
#   Docker's packages come from download.docker.com, which is NOT in unattended-upgrades'
#   Allowed-Origins — so they were never upgraded automatically; a human's `apt upgrade` was the
#   only path, at whatever time the human happened to type it.
#
#   This script replaces that with something MORE automatic, not less: the runtime packages
#   are `apt-mark hold` so a weekday `apt upgrade` skips them, and a root systemd timer
#   upgrades them every Saturday 04:32 Europe/London (US/UK markets closed, no yolo CronJob in
#   the window: rapid-signal-publisher is Sun-Fri, signal-eval-weekend 10:00, prune-registry
#   Sunday, the DR backup Monday). No human is in the loop.
#
# WHAT A RUN DOES (root, from the timer or by hand)
#   1. refuses outside Saturday unless --force (a hand run on a trading day is the bug);
#   2. apt-get update; simulates the upgrade; if NOTHING is pending, logs and exits 0
#      SILENTLY — most weeks say nothing, so this is not a new notification source;
#   3. unhold → apt-get install --only-upgrade <runtime pkgs> → re-hold (re-hold is in a
#      trap, so a failed apt still leaves the packages held);
#   4. waits up to CLUSTER_WAIT for the cluster to reconverge: node Ready, every yolo
#      Deployment at its replica count, Loki /ready — the same things a human would check;
#   5. ONE ntfy push on NTFY_TOPIC_PLATFORM: what was upgraded and whether the cluster came
#      back (priority high if it did not — cluster-autostart.sh's */10 cron will keep
#      reconciling, but somebody should know).
#
# THE HOLD IS THE INSTALL. `--install` applies the hold AND the timer; a bare-metal rebuild
# reproduces both via restore-scratch.sh (phase 8, next to the other --install units).
# verify-recovery.sh checks the timer is enabled. `apt-mark showhold` is the proof.
#
# Usage:
#   sudo ./docker-runtime-upgrade.sh --install     # hold packages + install/enable timer
#   sudo ./docker-runtime-upgrade.sh --uninstall   # remove timer + unhold (back to ad-hoc)
#        ./docker-runtime-upgrade.sh --status      # hold state, next timer run, last result
#        ./docker-runtime-upgrade.sh --check       # what WOULD be upgraded (no root, no change)
#        ./docker-runtime-upgrade.sh --converged   # the post-upgrade health check, on demand (no root)
#   sudo ./docker-runtime-upgrade.sh [--force]     # run the window now (--force = ignore Saturday)
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

PKGS="${PKGS:-docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras}"
OWNER_USER="${OWNER_USER:-cloud}"                       # whose kubeconfig/minikube profile owns the cluster
STEP0_DIR="${STEP0_DIR:-/home/$OWNER_USER/Ideaprojects/STEP0}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/$OWNER_USER/.kube/config}"
LOKI_URL="${LOKI_URL:-http://172.16.238.2:30310}"
NAMESPACE="${NAMESPACE:-yolo}"
CLUSTER_WAIT="${CLUSTER_WAIT:-900}"                     # seconds to wait for reconvergence
WINDOW_TZ="${WINDOW_TZ:-Europe/London}"
WINDOW_DOW="${WINDOW_DOW:-6}"                           # 6 = Saturday (date +%u)
LOG="${LOG:-/var/log/docker-runtime-upgrade.log}"
STABLE_PATH="/usr/local/sbin/docker-runtime-upgrade.sh"
UNIT="docker-runtime-upgrade"
SVC_PATH="/etc/systemd/system/$UNIT.service"
TMR_PATH="/etc/systemd/system/$UNIT.timer"
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ntfy: the STEP0 registry lib (fail-soft, returns 0 always). Absent → say nothing, still upgrade.
# shellcheck source=/dev/null
if [ -r "$STEP0_DIR/ntfy-lib.sh" ]; then . "$STEP0_DIR/ntfy-lib.sh"; else ntfy_push() { :; }; NTFY_TOPIC_PLATFORM=""; fi

log() { local m; m="$(date -u +%Y-%m-%dT%H:%M:%SZ) docker-runtime-upgrade: $*"; echo "$m"; { echo "$m" >> "$LOG"; } 2>/dev/null || true; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }; }
held_ok() { local p; for p in $PKGS; do dpkg -l "$p" >/dev/null 2>&1 || continue; apt-mark showhold 2>/dev/null | grep -qx "$p" || return 1; done; }
hold()   { apt-mark hold   $PKGS >/dev/null 2>&1 || true; }
unhold() { apt-mark unhold $PKGS >/dev/null 2>&1 || true; }
pending() { apt-get -s --only-upgrade install $PKGS 2>/dev/null | awk '/^Inst /{print $2" "$3" -> "$4}'; }

kube() { KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"; }
cluster_converged() {
  kube get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -qx Ready || return 1
  # every Deployment in the namespace at its desired replica count (0/0 counts as converged)
  kube -n "$NAMESPACE" get deploy -o jsonpath='{range .items[*]}{.spec.replicas}{" "}{.status.availableReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '{d=$1+0; a=$2+0; if (a<d) bad++} END{exit bad>0}' || return 1
  [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$LOKI_URL/ready" 2>/dev/null)" = "200" ] || return 1
}

run_window() {
  need_root
  local force="${1:-0}" dow
  dow="$(TZ="$WINDOW_TZ" date +%u)"
  if [ "$force" != 1 ] && [ "$dow" != "$WINDOW_DOW" ]; then
    log "refusing: today is not the upgrade window (dow=$dow, want $WINDOW_DOW in $WINDOW_TZ); use --force to override"
    exit 3
  fi
  exec 9>/run/lock/docker-runtime-upgrade.lock; flock -n 9 || { log "another run holds the lock"; exit 0; }
  apt-get update -qq >/dev/null 2>&1 || log "WARN: apt-get update failed; using the cached index"
  local plan; plan="$(pending)"
  if [ -z "$plan" ]; then log "nothing to upgrade ($PKGS all current) — silent"; hold; exit 0; fi
  log "upgrading:"; echo "$plan" | sed 's/^/  /' | tee -a "$LOG"
  trap 'hold' EXIT
  unhold
  local rc=0 t0 elapsed=0 verdict
  t0="$(date +%s)"
  if apt-get install -y --only-upgrade $PKGS >>"$LOG" 2>&1; then log "apt-get finished OK"; else rc=$?; log "apt-get FAILED rc=$rc"; fi
  hold; trap - EXIT
  log "waiting up to ${CLUSTER_WAIT}s for the cluster to reconverge"
  until cluster_converged; do
    elapsed=$(( $(date +%s) - t0 )); [ "$elapsed" -ge "$CLUSTER_WAIT" ] && break; sleep 15
  done
  if cluster_converged; then verdict="cluster back: node Ready, $NAMESPACE deployments at replica count, Loki /ready — after $(( $(date +%s) - t0 ))s"
  else verdict="cluster NOT converged after ${CLUSTER_WAIT}s — cluster-autostart.sh keeps reconciling every 10 min; check: kubectl -n $NAMESPACE get deploy ; $LOG"; fi
  log "$verdict"
  if [ "$rc" -eq 0 ] && cluster_converged; then
    ntfy_push "$NTFY_TOPIC_PLATFORM" "Docker runtime upgraded (scheduled window)" \
"$(hostname -s): the Saturday runtime window upgraded
$plan
Docker restarted, so every pod restarted once (expected). $verdict
Packages are held again until next Saturday 04:32 $WINDOW_TZ." \
      "default" "package,white_check_mark"
  else
    ntfy_push "$NTFY_TOPIC_PLATFORM" "Docker runtime window: attention needed" \
"$(hostname -s): apt rc=$rc for
$plan
$verdict" "high" "rotating_light,package"
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
}

install_all() {
  need_root
  hold
  install -m 0755 "$SELFDIR/$(basename "${BASH_SOURCE[0]}")" "$STABLE_PATH"
  cat > "$SVC_PATH" <<UNIT
[Unit]
Description=Upgrade docker-ce/containerd in the Saturday market-closed window (OBS-ALERT-EXECERR)
Documentation=file://$STEP0_DIR/docker-runtime-upgrade.sh
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$STABLE_PATH
Environment=STEP0_DIR=$STEP0_DIR
Environment=OWNER_USER=$OWNER_USER
UNIT
  cat > "$TMR_PATH" <<UNIT
[Unit]
Description=Saturday 04:32 $WINDOW_TZ docker/containerd upgrade window

[Timer]
OnCalendar=Sat *-*-* 04:32:00 $WINDOW_TZ
Persistent=false
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "$UNIT.timer" >/dev/null
  log "installed: $(echo $PKGS | wc -w) packages held; $UNIT.timer enabled (next: $(systemctl show "$UNIT.timer" -p NextElapseUSecRealtime --value))"
}

uninstall_all() {
  need_root
  systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
  rm -f "$SVC_PATH" "$TMR_PATH"; systemctl daemon-reload
  unhold
  log "removed: timer gone, packages UNHELD (ad-hoc apt upgrade will restart the cluster again)"
}

status() {
  if held_ok; then echo "hold:   PRESENT ($PKGS)"; else echo "hold:   ABSENT  — apply with: sudo $0 --install"; fi
  local st; st="$(systemctl is-enabled "$UNIT.timer" 2>/dev/null)" || st="not-installed"
  echo "timer:  $st / next: $(systemctl show "$UNIT.timer" -p NextElapseUSecRealtime --value 2>/dev/null || echo -)"
  echo "last:   $(grep -E 'nothing to upgrade|cluster back|NOT converged|apt-get FAILED' "$LOG" 2>/dev/null | tail -1 || echo -)"
  local p; p="$(pending)"; echo "pending: ${p:-none}"
}

case "${1:-}" in
  --install)   install_all ;;
  --uninstall) uninstall_all ;;
  --status)    status ;;
  --check)     p="$(pending)"; echo "would upgrade: ${p:-nothing}"; held_ok && echo "held: yes" || echo "held: NO" ;;
  --converged) cluster_converged && echo "converged: yes (node Ready, $NAMESPACE deployments at replica count, Loki /ready)" || { echo "converged: NO"; exit 1; } ;;
  --force)     run_window 1 ;;
  "")          run_window 0 ;;
  *) echo "unknown arg: $1" >&2; sed -n '/^# Usage:/,/^set -/p' "$0" | grep '^#' ; exit 2 ;;
esac
