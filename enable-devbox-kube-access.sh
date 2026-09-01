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

# 10GbE NIC facing the dev box. DERIVED from the route to $DEV_IP, never hardcoded: the name
# drifts (enp4s0 -> enp5s0 when the GM9000 NVMe renumbered PCI on 2026-08-07). Used ONLY to
# pin the raw/PREROUTING ACCEPT to the point-to-point link, so a host on the general LAN cannot
# reach the API by spoofing $DEV_IP — worth having, as rp_filter here is loose (2), not strict.
# If detection fails we omit -i rather than fail: the rule is still scoped by src+dst+dport.
SELF_IP="${SELF_IP:-10.10.10.1}"      # this host's end of the /30 — used only to validate detection
LINK_IFACE="${LINK_IFACE:-$(ip -o route get "$DEV_IP" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)}"
# ⚠️ Validate the detection, don't trust it. `ip route get` falls through to the DEFAULT route
# whenever the /30 isn't up yet — which happens on every boot where the dev box is powered off
# (point-to-point link, no peer -> no carrier -> NM never activates the profile) and happened
# 2026-08-30 as a pure race (unit ran at 13:14:24, enp5s0 got its IP at :25). The result was the
# ACCEPT pinned to the LAN NIC (enp7s0): dev-box SYNs arriving on enp5s0 missed it, hit Docker's
# raw drop, and kubectl timed out with every documented setting looking correct. If the detected
# iface doesn't own $SELF_IP it is NOT the point-to-point link — fall back to the unpinned rule
# (still src+dst+dport scoped), which works; a wrong pin is a silent total failure.
if [ -n "$LINK_IFACE" ] && ! ip -o -4 addr show dev "$LINK_IFACE" 2>/dev/null | grep -q " ${SELF_IP}/"; then
  LINK_IFACE=""
fi

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

# Same idea for the raw/PREROUTING table — see raw_rule_args below for why this chain matters.
if [ -n "$LINK_IFACE" ]; then
  RAW_ARGS=(-i "$LINK_IFACE" -s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT)
else
  RAW_ARGS=(-s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT)
fi
# Delete EVERY prior variant of our ACCEPT — any -i pin or none — not just the one matching the
# current RAW_ARGS. A rule pinned to the wrong iface by a stale detection (see above) would
# otherwise survive a corrective re-run: `-D` with today's args can't match yesterday's pin, and
# the leftover ACCEPT on the LAN NIC quietly defeats the anti-spoof point of pinning at all.
del_raw() {
  iptables-save -t raw 2>/dev/null | sed -n 's/^-A PREROUTING //p' | \
    grep -E -- "-s ${DEV_IP}/32 -d ${API_IP}/32 .*--dport ${API_PORT} -j ACCEPT" | \
    while read -r rule; do eval "iptables -t raw -D PREROUTING $rule"; done
}

apply_rules() {
  need_root
  # Inbound: dev box -> kube API
  del_rule -s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT
  iptables -I DOCKER-USER -s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT
  # Return: kube API -> dev box (established/related only)
  del_rule -d "$DEV_IP" -s "$API_IP" -p tcp --sport "$API_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -I DOCKER-USER -d "$DEV_IP" -s "$API_IP" -p tcp --sport "$API_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # ⚠️ DOCKER-USER ALONE IS NO LONGER ENOUGH (Docker >= 28; this box runs 29.7.2).
  # Docker now ships "direct routing" protection: for every container IP on a user-defined
  # bridge it installs a raw/PREROUTING rule
  #     ip daddr <container-ip> iifname != "br-<id>" drop
  # so container IPs are unreachable from outside the host by default. raw/PREROUTING runs at
  # priority -300 — BEFORE conntrack and long before FORWARD — so the DOCKER-USER ACCEPTs above
  # never even see the packet. Symptom (diagnosed 2026-08-07): the dev box's SYNs arrive on the
  # 10GbE NIC and are visible in tcpdump, nothing reaches the bridge, DOCKER-USER's counters stay
  # at 0, and kubectl just times out — while every part of the documented config looks correct.
  # Confirm with: iptables -t raw -L PREROUTING -n -v  (the DROP's counter is the one climbing).
  # This ACCEPT short-circuits raw traversal for exactly our one flow, so the drop never applies.
  # Docker rewrites this table on restart, which is why the systemd unit re-applies it at boot.
  # The durable alternative is recreating the network with
  # `-o com.docker.network.bridge.trusted_host_interfaces=<iface>`, which start-scratch.sh should
  # adopt — it cannot be set on a live network, so it waits for the next cold bootstrap.
  del_raw
  iptables -t raw -I PREROUTING 1 "${RAW_ARGS[@]}"

  # Belt-and-suspenders: keep ip_forward on across reboots (docker also sets it at runtime).
  if [ ! -f "$SYSCTL_DROPIN" ]; then
    echo "net.ipv4.ip_forward=1" > "$SYSCTL_DROPIN"
    sysctl -p "$SYSCTL_DROPIN" >/dev/null
  fi
  echo "devbox-kube-access: rules applied ($DEV_IP -> $API_IP:$API_PORT, incl. raw/PREROUTING)"
}

remove_rules() {
  need_root
  del_rule -s "$DEV_IP" -d "$API_IP" -p tcp --dport "$API_PORT" -j ACCEPT
  del_rule -d "$DEV_IP" -s "$API_IP" -p tcp --sport "$API_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  del_raw
  echo "devbox-kube-access: rules removed"
}

install_unit() {
  need_root
  install -m 0755 "$SELFDIR/$(basename "${BASH_SOURCE[0]}")" "$STABLE_PATH"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Allow dev box to reach prod minikube API over 10GbE (DOCKER-USER + raw/PREROUTING)
After=docker.service
Wants=docker.service
# PartOf is what makes this survive a dockerd RESTART, not just a reboot. Docker rebuilds
# DOCKER-USER *and* its raw/PREROUTING direct-routing drops from scratch every time it starts,
# which silently discards our rules — and a plain `After=` oneshot only ever runs at boot, so
# before 2026-08-07 any `systemctl restart docker` (or a docker package upgrade) left dev-box
# access dead until the next reboot, with the unit still reporting active. PartOf propagates
# docker's restart to us, so ExecStart re-runs and re-applies both sets of rules.
PartOf=docker.service

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
