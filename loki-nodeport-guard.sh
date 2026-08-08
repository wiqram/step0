#!/bin/bash
# loki-nodeport-guard.sh — restrict Loki's NodePort 30310 to this host (SEC-LOKI-NODEPORT).
#
# WHAT: inserts a single DROP rule at the top of DOCKER-USER for tcp/30310 to the minikube
#       node IP, and installs a systemd oneshot that re-asserts it whenever Docker starts.
#
# WHY:  Loki holds 30 days of the signal->trade pipeline's logs, including follower emails,
#       and answers LogQL with NO credential — it has no per-request authentication in any
#       configuration (`auth_enabled` is its multi-tenancy switch, not an auth control).
#       The NodePort cannot simply be deleted: the host-based agent loop runs OUTSIDE the
#       cluster and pushes OTLP to it (IG-Trading-Microservices ops/agent/run-cycle.sh),
#       which a ClusterIP cannot serve. So the port stays and the reachability is narrowed.
#       Full rationale + verification table: docs/security/network-hardening.md §3a
#       (SEC-LOKI-NODEPORT) in the IG-Trading-Microservices repo.
#
# ⚠️ TWO DESIGN POINTS THAT LOOK LIKE STYLE AND ARE NOT. Both were established by the
#    2026-08-08 install; changing either produces a rule that appears to work and does not.
#
#    1. DOCKER-USER, NEVER INPUT. Nothing listens on 30310 on the host — the port lives on
#       the minikube container at 172.16.238.2. Traffic from anywhere else is therefore
#       FORWARDED, and DOCKER-USER is the chain Docker guarantees to consult first for
#       forwarded traffic. An INPUT rule matches nothing: it would look like protection while
#       providing none. The same asymmetry is what keeps the agent working — host-originated
#       traffic takes OUTPUT and never enters FORWARD at all, so the local OTLP push is
#       unaffected by a FORWARD-path DROP. (Corollary, the same one enable-devbox-kube-access.sh
#       documents: a `curl` from the prod host proves NOTHING about this rule either way.)
#
#    2. A systemd unit with PartOf=docker.service, NEVER iptables-persistent. iptables-persistent
#       snapshots the WHOLE table — including Docker's dynamically managed chains — and replays
#       it at boot, which fights the daemon. And Docker REBUILDS its chains on every daemon
#       restart, so a boot-only unit leaves the port wide open from that restart until the next
#       reboot, with nothing to say so. PartOf+After=docker.service fires on both events.
#
# PERSISTENCE: --install copies this script to /usr/local/sbin and writes/enables the unit, the
#       same shape as 10gbe-link-watchdog.sh and enable-devbox-kube-access.sh. restore-scratch.sh
#       phase 8 calls it, so a bare-metal rebuild re-arms the guard automatically.
#
# USAGE:
#   sudo ./loki-nodeport-guard.sh --install   # apply now + install & enable the systemd unit
#   sudo ./loki-nodeport-guard.sh             # (re)apply the rule now, idempotently
#   sudo ./loki-nodeport-guard.sh --remove    # drop the rule and the unit
#        ./loki-nodeport-guard.sh --status    # report rule + unit state (read-only, needs root to read iptables)
set -eu

NODE_IP="${NODE_IP:-172.16.238.2}"     # minikube node — where the NodePort actually lives
PORT="${PORT:-30310}"                  # Loki NodePort
COMMENT="SEC-LOKI-NODEPORT: loki ${PORT} host-only"

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STABLE_PATH="/usr/local/sbin/yolo-loki-nodeport-guard.sh"
UNIT_NAME="yolo-loki-nodeport-guard.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

log() { echo "loki-nodeport-guard: $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }; }

rule_present() {
  iptables -C DOCKER-USER -p tcp -d "$NODE_IP" --dport "$PORT" -j DROP \
    -m comment --comment "$COMMENT" 2>/dev/null
}

apply_rule() {
  need_root
  # Docker recreates its chains on daemon restart, so this must be safe to run any number of
  # times: check first, insert only if absent.
  if rule_present; then log "rule already present"; return 0; fi
  # Position 1: nothing later in the chain may ACCEPT this traffic first.
  iptables -I DOCKER-USER 1 -p tcp -d "$NODE_IP" --dport "$PORT" -j DROP \
    -m comment --comment "$COMMENT"
  log "rule inserted (DOCKER-USER 1: DROP tcp -> $NODE_IP:$PORT)"
}

remove_rule() {
  need_root
  while rule_present; do
    iptables -D DOCKER-USER -p tcp -d "$NODE_IP" --dport "$PORT" -j DROP \
      -m comment --comment "$COMMENT"
  done
  log "rule removed"
}

install_unit() {
  need_root
  install -m 0755 "$SELFDIR/$(basename "${BASH_SOURCE[0]}")" "$STABLE_PATH"
  cat > "$UNIT_PATH" <<EOF
[Unit]
# SEC-LOKI-NODEPORT — re-assert the Loki NodePort restriction after Docker.
# PartOf + After docker.service: Docker rebuilds its iptables chains on daemon
# restart, so a boot-only unit would silently leave the port open until the next
# reboot. This fires on both.
Description=Restrict Loki NodePort $PORT to this host (SEC-LOKI-NODEPORT)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$STABLE_PATH

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null
  systemctl restart "$UNIT_NAME"
  log "systemd unit installed, enabled & started ($UNIT_PATH)"
}

remove_unit() {
  need_root
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  log "systemd unit removed (left $STABLE_PATH in place)"
}

status() {
  if [ "$(id -u)" -eq 0 ]; then
    rule_present && echo "rule:  PRESENT (DOCKER-USER, DROP tcp -> $NODE_IP:$PORT)" \
                 || echo "rule:  ABSENT  — apply with: sudo $0"
  else
    echo "rule:  (needs root to read iptables — re-run as: sudo $0 --status)"
  fi
  echo "unit:  $(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || echo not-installed) / $(systemctl is-active "$UNIT_NAME" 2>/dev/null || echo inactive)"
}

case "${1:-}" in
  --install) apply_rule; install_unit ;;
  --remove)  remove_rule; remove_unit ;;
  --status)  status ;;
  "")        apply_rule ;;
  *) echo "usage: $0 [--install|--remove|--status]" >&2; exit 1 ;;
esac
