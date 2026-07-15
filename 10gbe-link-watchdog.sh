#!/bin/bash
# 10gbe-link-watchdog.sh — keep the dev<->prod 10GbE point-to-point link alive.
#
# WHAT: a tiny always-on watchdog that pings the peer across the 10GbE /30 link and, when the
#       peer goes unreachable for a few checks in a row, BOUNCES the local NIC (nmcli reactivate,
#       ip-link fallback) to force the PHY to re-train. Runs as a systemd service on BOTH ends.
#
# WHY:  both NICs are Aquantia/Marvell 10GBASE-T cards on the `atlantic` driver. This direct
#       point-to-point link intermittently *wedges*: ethtool still says "link detected: yes,
#       10Gb Full" and carrier stays 1, but the datapath stops passing frames — ARP fails in
#       both directions and kubectl/IntelliJ from the dev box hang. It self-recovers only after
#       minutes. This watchdog cuts that outage to seconds by re-training the link on demand.
#       NOTE: the kube-access CONFIG (dev static route, prod DOCKER-USER firewall unit,
#       prod-minikube kubeconfig) is correct and already survives reboots — the *link* is the
#       flaky part. See architecture.md §3 and enable-devbox-kube-access.sh / devbox-connect-prod.sh.
#
# SYMMETRIC: the SAME script runs on prod (enp4s0, 10.10.10.1) and the dev box (eno1, 10.10.10.2).
#       It auto-detects the local 10GbE interface + its NetworkManager connection from the /30, so
#       no per-host edits. Bouncing either end re-trains the whole link; running it on both is
#       belt-and-suspenders (whichever notices the wedge first acts). Bouncing this NIC is safe on
#       both hosts: it carries ONLY the dev<->prod link (prod's cluster/LAN is on other NICs; the
#       dev box keeps its LAN/SSH on eno2), so a bounce never touches the cluster or your SSH session.
#
# PERSISTENCE: --install writes a systemd service (Restart=always, WantedBy=multi-user.target) so
#       it comes back on every boot on whichever host you installed it on. Install on BOTH ends.
#
# USAGE:
#   sudo ./10gbe-link-watchdog.sh --install     # apply now + install & enable the systemd service
#   sudo ./10gbe-link-watchdog.sh --remove      # stop & remove the systemd service
#   ./10gbe-link-watchdog.sh                     # run the watchdog loop in the foreground (Ctrl-C to stop)
#   ./10gbe-link-watchdog.sh --once              # one probe now; bounce if wedged (for cron/manual test)
#
# TUNABLES (env): LINK_CIDR (default 10.10.10.0/30), INTERVAL, FAIL_THRESHOLD, COOLDOWN, PING_W.
set -eu

LINK_CIDR="${LINK_CIDR:-10.10.10.0/30}"   # the dev<->prod point-to-point /30
INTERVAL="${INTERVAL:-15}"                # seconds between probes
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"     # consecutive failed probes before a bounce
COOLDOWN="${COOLDOWN:-30}"                # grace period after a bounce before probing resumes
PING_W="${PING_W:-2}"                     # per-probe ping timeout (seconds)

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STABLE_PATH="/usr/local/sbin/10gbe-link-watchdog.sh"
UNIT_PATH="/etc/systemd/system/10gbe-link-watchdog.service"

log() { echo "$(date '+%F %T') 10gbe-watchdog: $*"; }

need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }; }

# Discover our own 10GbE address on the /30, the peer (the other usable host), the interface, and
# the NetworkManager connection bound to it. Re-derived on every bounce so it survives NIC renames.
# Reset all four each call so a failed discovery never leaves stale values from a previous loop.
discover() {
  SELF_IP=""; PEER_IP=""; IFACE=""; CONN=""
  # Preferred: read the live /30 address straight off the interface (present when the link is up).
  SELF_IP="$(ip -o -f inet addr show | awk '$4 ~ /^10\.10\.10\./ {sub(/\/.*/,"",$4); print $4; exit}')"
  [ -n "$SELF_IP" ] && IFACE="$(ip -o -f inet addr show | awk -v s="$SELF_IP" '$4 ~ ("^" s "/") {print $2; exit}')"
  # Fallback: when the NIC is fully DOWN (NO-CARRIER), NetworkManager marks the device "unavailable"
  # and strips its live address — so the lookup above finds nothing. But the connection PROFILE still
  # statically holds the /30 address, so recover self-IP + iface + conn from it. This is what lets the
  # watchdog identify and bounce a *dead* link (previously it crashed on an unbound PEER_IP instead).
  if [ -z "$SELF_IP" ]; then
    local c addr
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      addr="$(nmcli -t -g ipv4.addresses connection show "$c" 2>/dev/null)"
      case "$addr" in
        10.10.10.*)
          SELF_IP="${addr%%/*}"
          CONN="$c"
          IFACE="$(nmcli -t -g connection.interface-name connection show "$c" 2>/dev/null)"
          break ;;
      esac
    done < <(nmcli -t -f NAME connection show 2>/dev/null)
  fi
  [ -n "$SELF_IP" ] || { echo "no 10.10.10.x/30 address on any device or NM profile (is the 10GbE NIC present?)" >&2; return 1; }
  # /30 usable hosts are .1 and .2 — the peer is whichever we are not.
  case "$SELF_IP" in
    *.1) PEER_IP="${SELF_IP%.1}.2" ;;
    *.2) PEER_IP="${SELF_IP%.2}.1" ;;
    *)   echo "self IP $SELF_IP is not .1/.2 of a /30 — set LINK_CIDR/peer manually" >&2; return 1 ;;
  esac
  # Resolve the NM connection if the fallback didn't already give it: prefer the active binding, else
  # any profile bound to this iface (so we can bounce even when the device is currently down).
  if [ -z "$CONN" ] && [ -n "$IFACE" ]; then
    CONN="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$IFACE" '$2==d{print $1; exit}')"
    [ -n "$CONN" ] || CONN="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$IFACE" '$2==d{print $1; exit}')"
  fi
}

# Force the point-to-point link to re-train. Prefer NM (reapplies IP + the static route to the API);
# fall back to a raw interface bounce if NM isn't managing the device.
bounce() {
  # Defensive: if discovery couldn't identify the link at all, there's nothing to bounce — log and
  # bail instead of dereferencing an unbound var (which crash-looped the service under `set -eu`).
  if [ -z "${IFACE:-}" ] && [ -z "${CONN:-}" ]; then
    log "cannot bounce: 10GbE link not identified (no /30 addr on any device or NM profile)"; return 0
  fi
  log "peer ${PEER_IP:-?} unreachable ${FAIL_THRESHOLD}x over ${IFACE:-<conn:${CONN}>} — bouncing to re-train the 10GbE link"
  if [ -n "${CONN:-}" ] && command -v nmcli >/dev/null 2>&1; then
    nmcli connection up "$CONN" >/dev/null 2>&1 || { [ -n "${IFACE:-}" ] && nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true; nmcli connection up "$CONN" >/dev/null 2>&1 || true; }
  elif [ -n "${IFACE:-}" ]; then
    ip link set "$IFACE" down; sleep 2; ip link set "$IFACE" up
  fi
  log "bounce issued on ${IFACE:-<conn:${CONN}>} (conn='${CONN:-<none>}'); cooling down ${COOLDOWN}s"
}

probe_once() {
  discover || return 2
  if ping -c 2 -W "$PING_W" "$PEER_IP" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

run_loop() {
  discover || { log "cannot find 10GbE link yet; will keep retrying"; }
  log "watching: self=${SELF_IP:-?} peer=${PEER_IP:-?} iface=${IFACE:-?} conn='${CONN:-?}' interval=${INTERVAL}s threshold=$FAIL_THRESHOLD"
  local fails=0
  while true; do
    if discover && ping -c 2 -W "$PING_W" "$PEER_IP" >/dev/null 2>&1; then
      [ "$fails" -ne 0 ] && log "peer $PEER_IP reachable again after $fails failed probe(s)"
      fails=0
    else
      fails=$((fails + 1))
      log "probe failed ($fails/$FAIL_THRESHOLD) peer=${PEER_IP:-?} iface=${IFACE:-?}"
      if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
        need_root; bounce; fails=0
        sleep "$COOLDOWN"
      fi
    fi
    # small jitter so both ends don't bounce in lockstep and fight each other
    sleep "$((INTERVAL + RANDOM % 5))"
  done
}

install_unit() {
  need_root
  install -m 0755 "$SELFDIR/$(basename "${BASH_SOURCE[0]}")" "$STABLE_PATH"
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=10GbE dev<->prod link watchdog (bounces the atlantic NIC when the peer wedges)
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$STABLE_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable 10gbe-link-watchdog.service >/dev/null
  systemctl restart 10gbe-link-watchdog.service
  log "systemd service installed, enabled & started ($UNIT_PATH)"
  systemctl --no-pager status 10gbe-link-watchdog.service | head -6 || true
}

remove_unit() {
  need_root
  systemctl disable --now 10gbe-link-watchdog.service >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  log "systemd service removed (left $STABLE_PATH in place)"
}

case "${1:-}" in
  --install) install_unit ;;
  --remove)  remove_unit ;;
  --once)    if probe_once; then log "peer reachable — no action"; else need_root; discover && bounce; fi ;;
  "")        run_loop ;;
  *) echo "usage: $0 [--install|--remove|--once]" >&2; exit 1 ;;
esac
