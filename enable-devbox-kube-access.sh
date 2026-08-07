#!/bin/bash
# enable-devbox-kube-access.sh — allow the dev box to reach the prod minikube API over 10GbE.
#
# WHAT: inserts two ACCEPT rules into the iptables DOCKER-USER chain so forwarded traffic
#       from the dev box (10.10.10.2, on the enp5s0 10GbE point-to-point link) can reach the
#       minikube Kubernetes API at 172.16.238.2:8443 on the 5million docker bridge.
#
# NOTE: the prod 10GbE NIC is enp5s0 as of 2026-08-07 — it was enp4s0 until the GM9000 NVMe
#       install shifted every PCI bus number up by one (AQC113CS 04:00.0 → 05:00.0; the I225-V
#       LAN NIC likewise enp6s0 → enp7s0). Interface names here are COMMENTARY ONLY: the rules
#       below match on dest IP+port, so a future rename cannot break them. Don't add an -i match.
#
# WHY:  traffic entering on enp5s0 and destined for a container on the docker bridge is
#       cross-interface *forwarded* traffic, which Docker's FORWARD chain drops by default.
#       DOCKER-USER is traversed before Docker's own forward rules and is never clobbered by
#       docker, so it's the correct place for this allow. Rules match on dest IP+port (NOT the
#       bridge interface name br-<id>, which changes whenever start-scratch recreates 5million).
#
# SCOPE: API only (tcp/8443). This is enough for kubectl AND IntelliJ Services → Kubernetes
#        (browse/logs/port-forward all tunnel through the API server). No registry/NodePort.
#
# PERSISTENCE: DOCKER-USER is recreated EMPTY when dockerd restarts, so these rules must be
#        re-applied at boot. Run with --install to set up a systemd oneshot (After=docker.service)
#        that re-runs this script on every boot. start-scratch.sh / restart-minikube.sh also call
#        this (no flag) so a cluster rebuild re-arms access.
#
# USAGE:
#   sudo ./enable-devbox-kube-access.sh                    # (re)apply the firewall rules now
#   sudo ./enable-devbox-kube-access.sh --install          # apply now + install & enable the systemd unit
#   sudo ./enable-devbox-kube-access.sh --remove           # delete the rules (leaves systemd unit alone)
#        ./enable-devbox-kube-access.sh --emit-kubeconfig [path]  # write prod-minikube kubeconfig for the dev box (no root)
#
# DEV-BOX SIDE: after --install here, run devbox-connect-prod.sh on the dev box (route + kubeconfig).
set -eu

DEV_IP="${DEV_IP:-10.10.10.2}"        # dev box, other end of the enp5s0 /30
API_IP="${API_IP:-172.16.238.2}"      # minikube node / kube API on the 5million bridge
API_PORT="${API_PORT:-8443}"          # kube API server port

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STABLE_PATH="/usr/local/sbin/enable-devbox-kube-access.sh"   # where the systemd unit runs it from
UNIT_PATH="/etc/systemd/system/devbox-kube-access.service"
SYSCTL_DROPIN="/etc/sysctl.d/99-devbox-kube-forward.conf"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }; }

# Emit a portable, cert-embedded kubeconfig for the dev box. Cluster/user/context are all renamed
# to 'prod-minikube' (anchored sed on full key lines only — never touches base64 cert blobs) so it
# coexists with the dev box's own local 'minikube' context when merged. No root needed.
emit_kubeconfig() {
  local out="${1:-/home/cloud/prod-minikube.kubeconfig}"
  kubectl config view --flatten --minify | sed -E '
    s/^(-? *name: )minikube$/\1prod-minikube/;
    s/^( *cluster: )minikube$/\1prod-minikube/;
    s/^( *user: )minikube$/\1prod-minikube/;
    s/^(current-context: )minikube$/\1prod-minikube/' > "$out"
  chmod 600 "$out"
  echo "devbox-kube-access: wrote prod-minikube kubeconfig -> $out (copy to the dev box; see devbox-connect-prod.sh)"
}

# Delete-then-insert so repeated runs never stack duplicate rules. `iptables -D` is idempotent
# enough here: we loop until the exact rule is gone before (re)inserting.
del_rule() { while iptables -C DOCKER-USER "$@" 2>/dev/null; do iptables -D DOCKER-USER "$@"; done; }

apply_rules() {
  need_root
  # Inbound: dev box -> kube API
  del_rule -s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT
  iptables -I DOCKER-USER -s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT
  # Return: kube API -> dev box (established/related only)
  del_rule -d "$DEV_IP" -s "$API_IP" -p tcp --sport "$API_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -I DOCKER-USER -d "$DEV_IP" -s "$API_IP" -p tcp --sport "$API_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # Belt-and-suspenders: keep ip_forward on across reboots (docker also sets it at runtime).
  if [ ! -f "$SYSCTL_DROPIN" ]; then
    echo "net.ipv4.ip_forward=1" > "$SYSCTL_DROPIN"
    sysctl -p "$SYSCTL_DROPIN" >/dev/null
  fi
  echo "devbox-kube-access: rules applied ($DEV_IP -> $API_IP:$API_PORT)"
}

remove_rules() {
  need_root
  del_rule -s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT
  del_rule -d "$DEV_IP" -s "$API_IP" -p tcp --sport "$API_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  echo "devbox-kube-access: rules removed"
}

install_unit() {
  need_root
  install -m 0755 "$SELFDIR/$(basename "${BASH_SOURCE[0]}")" "$STABLE_PATH"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Allow dev box to reach prod minikube API over 10GbE (DOCKER-USER rules)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$STABLE_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable devbox-kube-access.service >/dev/null
  # Run once via systemd too, so the unit's state reflects reality and the boot path is validated
  # now rather than discovered broken at next reboot. (RemainAfterExit -> stays 'active'.)
  systemctl restart devbox-kube-access.service
  echo "devbox-kube-access: systemd unit installed, enabled & started ($UNIT_PATH)"
}

case "${1:-}" in
  --install)          apply_rules; install_unit ;;
  --remove)           remove_rules ;;
  --emit-kubeconfig)  emit_kubeconfig "${2:-}" ;;
  "")                 apply_rules ;;
  *) echo "usage: $0 [--install|--remove|--emit-kubeconfig [path]]" >&2; exit 1 ;;
esac
