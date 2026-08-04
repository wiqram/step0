#!/bin/bash
####################################
#
# verify-recovery.sh — post-restore sanity survey for the private-cloud box.
#
# Read-only. Mutates NOTHING. Run it AFTER restore-scratch.sh (or after any
# reboot/crash recovery) to confirm the facts that a fresh machine can silently
# get wrong: fixed cluster IPs, NAS reachability + exports, the dev<->prod 10GbE
# link, and host/DNS/service/cron state. Every expected value is a constant near
# the top (override via env) — when the hardware or ISP changes, this is the one
# place that tells you WHAT drifted and where to fix it (NPM proxy hosts, DNS A
# records, NIC name, /etc/fstab, etc.).
#
# Usage:
#   ./verify-recovery.sh            # full survey, human-readable PASS/WARN/FAIL
#   ./verify-recovery.sh --quiet    # only print WARN/FAIL lines + the summary
#   (some checks read root's crontab; run with sudo to include them, else they WARN)
#
# Exit code: 0 if no FAILs (WARNs allowed), 1 if any FAIL. Advisory only — nothing here
# changes state, so a non-zero exit just flags "look at the WARN/FAIL lines above".
####################################
set -u

# ---- expected values (override via env for a different topology) ----
EXP_NODE_IP="${EXP_NODE_IP:-172.16.238.2}"        # minikube node: API/NodePorts/registry
EXP_NPM_IP="${EXP_NPM_IP:-172.16.238.10}"         # nginx-proxy-manager on the 5million net
EXP_GW_IP="${EXP_GW_IP:-172.16.238.1}"            # 5million gateway
EXP_NET="${EXP_NET:-5million}"                     # docker network name
EXP_SUBNET="${EXP_SUBNET:-172.16.0.0/16}"          # 5million subnet (fixed IPs 172.16.238.x live inside it)
EXP_REG_PORT="${EXP_REG_PORT:-5000}"               # in-cluster registry
EXP_API_PORT="${EXP_API_PORT:-8443}"               # kube API

WD_DR_NAS="${WD_DR_NAS:-192.168.50.169}"           # WD Cloud DR NAS (NFS)
WD_DR_EXPORT="${WD_DR_EXPORT:-/nfs/private-cloud}"  # its NFS export
WD_DR_MOUNT="${WD_DR_MOUNT:-/mnt/wdcloud}"          # persistent mount point
WD_SRC_NAS="${WD_SRC_NAS:-192.168.50.68}"          # WD My Cloud 8TB master (SMB)
WD_DST_NAS="${WD_DST_NAS:-192.168.50.251}"         # WD My Cloud 16TB backup (SMB)

EXP_10G_SELF="${EXP_10G_SELF:-10.10.10.1}"         # this box's 10GbE /30 addr (prod)
EXP_10G_PEER="${EXP_10G_PEER:-10.10.10.2}"         # dev box across the /30
EXP_10G_DRIVER="${EXP_10G_DRIVER:-atlantic}"       # Aquantia/Marvell 10GBASE-T
WATCHDOG_SVC="${WATCHDOG_SVC:-10gbe-link-watchdog.service}"
KUBEACCESS_SVC="${KUBEACCESS_SVC:-devbox-kube-access.service}"
DEV_OOB_SSH="${DEV_OOB_SSH:-vik@192.168.50.161}"   # dev box over the LAN (OOB) — to verify its egress back to us

EXP_HOSTNAME="${EXP_HOSTNAME:-private-cloud}"
DNS_NAME="${DNS_NAME:-jenkins.traderyolo.com}"     # public entry point; should resolve to us

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# ---- reporting helpers ----
C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[1m"; C_0="\033[0m"
[ -t 1 ] || { C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""; }   # no colour when piped
P=0; W=0; F=0
declare -a DETECTED                                 # environment-specific values worth eyeballing
pass() { P=$((P+1)); [ "$QUIET" = 1 ] || printf "  ${C_G}PASS${C_0} %s\n" "$*"; }
warn() { W=$((W+1));                 printf "  ${C_Y}WARN${C_0} %s\n" "$*"; }
fail() { F=$((F+1));                 printf "  ${C_R}FAIL${C_0} %s\n" "$*"; }
info() { [ "$QUIET" = 1 ] || printf "  ${C_B}info${C_0} %s\n" "$*"; }
note() { DETECTED+=("$*"); }                        # remembered for the closing summary
section() { printf "\n${C_B}== %s ==${C_0}\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
tcp() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }   # port-open probe

# ============================== 1. FIXED CLUSTER IPs ==============================
section "1. Fixed cluster IPs (172.16.238.x — owned by the 5million docker net + minikube)"

if have minikube; then
  node_ip="$(minikube ip 2>/dev/null)"
  if [ -z "$node_ip" ]; then fail "minikube ip returned nothing — is the cluster up? (minikube status)"
  elif [ "$node_ip" = "$EXP_NODE_IP" ]; then pass "minikube node IP = $node_ip"
  else fail "minikube node IP = $node_ip, expected $EXP_NODE_IP (NodePorts/registry/NPM targets all assume $EXP_NODE_IP)"; fi
  note "minikube node IP: ${node_ip:-<none>}"
else warn "minikube not installed — cannot check node IP"; fi

if have docker; then
  if docker network inspect "$EXP_NET" >/dev/null 2>&1; then
    sub="$(docker network inspect "$EXP_NET" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
    gw="$(docker network inspect "$EXP_NET" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
    [ "$sub" = "$EXP_SUBNET" ] && pass "docker network $EXP_NET subnet = $sub" \
      || fail "docker network $EXP_NET subnet = ${sub:-<none>}, expected $EXP_SUBNET"
    [ "$gw" = "$EXP_GW_IP" ] && pass "docker network $EXP_NET gateway = $gw" \
      || warn "docker network $EXP_NET gateway = ${gw:-<none>}, expected $EXP_GW_IP"
    # nginx-proxy-manager should sit at the fixed .10 on this network.
    if docker network inspect "$EXP_NET" --format '{{range .Containers}}{{.IPv4Address}} {{end}}' 2>/dev/null | grep -q "$EXP_NPM_IP/"; then
      npm_ctr="$(docker network inspect "$EXP_NET" --format '{{range .Containers}}{{.Name}}={{.IPv4Address}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep "$EXP_NPM_IP/" | cut -d= -f1)"
      pass "nginx-proxy-manager at $EXP_NPM_IP on $EXP_NET (container: ${npm_ctr:-?})"
    else
      warn "no container at $EXP_NPM_IP on $EXP_NET — NPM not up yet? (public TLS ingress). Bring it up: cd ~/Ideaprojects/nginx && docker compose up -d"
    fi
  else fail "docker network $EXP_NET not found — created by start-scratch.sh; without it fixed IPs are undefined"; fi
else warn "docker not installed — cannot check the $EXP_NET network"; fi

tcp "$EXP_NODE_IP" "$EXP_REG_PORT" && pass "registry reachable at $EXP_NODE_IP:$EXP_REG_PORT" \
  || warn "registry $EXP_NODE_IP:$EXP_REG_PORT not answering (empty after a single-disk restore until first build)"
tcp "$EXP_NODE_IP" "$EXP_API_PORT" && pass "kube API reachable at $EXP_NODE_IP:$EXP_API_PORT" \
  || fail "kube API $EXP_NODE_IP:$EXP_API_PORT not answering — cluster down?"

# ============================== 2. NAS REACHABILITY + EXPORTS ==============================
section "2. Backup NAS reachability + exports (LAN 192.168.50.x)"

ping_ok() { ping -c1 -W2 "$1" >/dev/null 2>&1; }

# 2a. WD Cloud DR NAS (NFS) — the source restore-scratch pulls FROM and the off-site mirror target.
if ping_ok "$WD_DR_NAS"; then
  pass "WD Cloud DR NAS $WD_DR_NAS reachable"
  mounted=0; mountpoint -q "$WD_DR_MOUNT" 2>/dev/null && mounted=1
  if [ "$mounted" = 1 ]; then pass "$WD_DR_MOUNT is mounted (off-site copy will land here)"
  else warn "$WD_DR_MOUNT not mounted — automount on first access, or: sudo mount $WD_DR_MOUNT (check /etc/fstab)"; fi
  # showmount confirms the export is advertised. WD OS3 firmware often does NOT list an
  # export over MOUNT/rpcbind even when it is exported and mounts fine — so if the share
  # is already mounted, a missing showmount line is just informational, not a WARN.
  if have showmount; then
    if showmount -e "$WD_DR_NAS" 2>/dev/null | grep -q "$WD_DR_EXPORT"; then
      pass "NFS export $WD_DR_EXPORT advertised by $WD_DR_NAS"
    elif [ "$mounted" = 1 ]; then
      info "$WD_DR_NAS does not list $WD_DR_EXPORT via showmount, but it IS mounted (known WD OS3 quirk — export works)"
    else warn "NFS export $WD_DR_EXPORT NOT advertised by $WD_DR_NAS and not mounted (one-time WD dashboard setup; see backup-minikube-mnt.sh)"; fi
  else warn "showmount not installed (nfs-common) — cannot list $WD_DR_NAS exports"; fi
  note "WD Cloud DR NAS $WD_DR_NAS mounted at $WD_DR_MOUNT: $(mountpoint -q "$WD_DR_MOUNT" 2>/dev/null && echo yes || echo NO)"
else fail "WD Cloud DR NAS $WD_DR_NAS UNREACHABLE — off-site backup + DR restore source is down"; fi

# 2b. WD My Cloud pair (SMB) — the nightly tenant rsync job (re-armed by restore-scratch phase 8).
for pair in "8TB-master:$WD_SRC_NAS" "16TB-backup:$WD_DST_NAS"; do
  role="${pair%%:*}"; host="${pair#*:}"
  ping_ok "$host" && pass "WD My Cloud $role $host reachable" \
    || warn "WD My Cloud $role $host unreachable (nightly wd-backup.sh will skip until it is powered on)"
done

# ============================== 3. 10GbE DEV<->PROD LINK ==============================
section "3. dev<->prod 10GbE point-to-point link (/30) + watchdog"

# Detect our live 10GbE /30 address + iface the same way 10gbe-link-watchdog.sh does.
self10="$(ip -o -f inet addr show 2>/dev/null | awk '$4 ~ /^10\.10\.10\./ {sub(/\/.*/,"",$4); print $4; exit}')"
if [ -n "$self10" ]; then
  iface10="$(ip -o -f inet addr show 2>/dev/null | awk -v s="$self10" '$4 ~ ("^" s "/") {print $2; exit}')"
  note "10GbE: self=$self10 iface=${iface10:-?}"
  [ "$self10" = "$EXP_10G_SELF" ] && pass "10GbE self IP = $self10 on ${iface10:-?}" \
    || warn "10GbE self IP = $self10 (expected $EXP_10G_SELF) — iface may have been renamed on the new box; watchdog auto-detects but verify the /30"
  # carrier / operstate
  if [ -n "${iface10:-}" ]; then
    op="$(cat "/sys/class/net/$iface10/operstate" 2>/dev/null)"
    [ "$op" = "up" ] && pass "$iface10 operstate = up" || warn "$iface10 operstate = ${op:-?} (link may be wedged — see 10gbe-link-watchdog.sh)"
    if have ethtool; then
      drv="$(ethtool -i "$iface10" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')"
      [ "$drv" = "$EXP_10G_DRIVER" ] && pass "$iface10 driver = $drv" \
        || info "$iface10 driver = ${drv:-?} (expected $EXP_10G_DRIVER)"
    fi
  fi
  ping_ok "$EXP_10G_PEER" && pass "dev-box peer $EXP_10G_PEER reachable over 10GbE" \
    || warn "peer $EXP_10G_PEER unreachable — link wedged or dev box down. OOB via LAN: ssh vik@192.168.50.161"

  # Egress-path check. A stray more-specific route (e.g. a /32 for the peer, or the prod
  # route mis-pinned to the 1GbE LAN NM profile) silently sends dev<->prod traffic over the
  # 1GbE LAN instead of this /30 — the link is "up" and everything works, just ~10x slower.
  # This bit us once (dev egress pinned to the LAN via a /32; a full day to spot). So verify
  # BOTH directions actually leave via the 10GbE iface, not just that the peer pings.
  if [ -n "${iface10:-}" ]; then
    self_rt="$(ip route get "$EXP_10G_PEER" 2>/dev/null | head -1)"
    self_oif="$(printf '%s' "$self_rt" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
    note "our route to $EXP_10G_PEER: ${self_rt:-<none>}"
    if [ "$self_oif" = "$iface10" ]; then pass "our route to $EXP_10G_PEER egresses the 10GbE iface ($iface10)"
    else fail "our route to $EXP_10G_PEER egresses '${self_oif:-?}', not the 10GbE iface $iface10 — a stray/more-specific route is sending dev traffic over the wrong NIC (silent ~10x throttle). Check: ip route get $EXP_10G_PEER"; fi
  fi

  # The reverse direction is the one that actually bit us, and it lives on the DEV box — so
  # ask it (best-effort, read-only) how it routes back to us. Its src IP must be on the /30
  # (10.10.10.x); a LAN src means dev->prod is silently on the 1GbE.
  if have ssh; then
    peer_rt="$(ssh -n -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null "$DEV_OOB_SSH" "ip route get $EXP_10G_SELF" 2>/dev/null | head -1)"
    if [ -z "$peer_rt" ]; then
      warn "could not check dev-box egress to us (ssh $DEV_OOB_SSH failed — dev down or no key). By hand: ssh $DEV_OOB_SSH ip route get $EXP_10G_SELF (src must be 10.10.10.x)"
    else
      peer_src="$(printf '%s' "$peer_rt" | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
      note "dev-box route to $EXP_10G_SELF: $peer_rt"
      case "$peer_src" in
        10.10.10.*) pass "dev box routes back to us via the 10GbE /30 (src $peer_src) — not the LAN" ;;
        "")         warn "dev-box egress src to $EXP_10G_SELF unknown: $peer_rt" ;;
        *)          fail "dev box routes to us via a NON-10GbE path (src $peer_src) — dev->prod traffic is on the LAN, silently ~10x throttled. Remove the stray route from the dev box's LAN NM profile, e.g.: nmcli con mod \"Wired connection 3\" -ipv4.routes \"$EXP_NODE_IP/32 $EXP_10G_SELF\" && nmcli dev reapply <lan-iface>. The prod route belongs ONLY on the 10GbE connection (see devbox-connect-prod.sh)." ;;
      esac
    fi
  fi
else
  warn "no 10.10.10.x/30 address on any interface — 10GbE NIC absent/down (config survives reboots; the LINK is the flaky part)"
  note "10GbE: no /30 address present"
fi

if have systemctl; then
  for svc in "$WATCHDOG_SVC" "$KUBEACCESS_SVC"; do
    st="$(systemctl is-active "$svc" 2>/dev/null)"
    case "$st" in
      active) pass "$svc = active" ;;
      inactive|failed|"") warn "$svc = ${st:-not-installed} — reinstall: (watchdog) sudo ./10gbe-link-watchdog.sh --install ; (access) sudo ./enable-devbox-kube-access.sh --install" ;;
      *) info "$svc = $st" ;;
    esac
  done
fi

# ============================== 4. HOST + DNS + SERVICES + CRON ==============================
section "4. Host identity, public DNS, services, cron"

hn="$(hostname -s 2>/dev/null)"
[ "$hn" = "$EXP_HOSTNAME" ] && pass "hostname = $hn" || warn "hostname = $hn (expected $EXP_HOSTNAME)"

# Public IP + does the public DNS name still point at us? (Post-move, the A record must be repointed.)
pub_ip=""
if have curl; then pub_ip="$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)"; fi
[ -n "$pub_ip" ] && { info "public IP (this box, per api.ipify.org) = $pub_ip"; note "public IP: $pub_ip"; } \
  || warn "could not determine public IP (no outbound? curl missing?)"
if have getent; then
  dns_ip="$(getent ahostsv4 "$DNS_NAME" 2>/dev/null | awk 'NR==1{print $1}')"
  note "$DNS_NAME resolves to: ${dns_ip:-<unresolved>}"
  if [ -z "$dns_ip" ]; then warn "$DNS_NAME does not resolve — DNS not set up"
  elif [ -n "$pub_ip" ] && [ "$dns_ip" = "$pub_ip" ]; then pass "$DNS_NAME -> $dns_ip (matches this box's public IP)"
  else warn "$DNS_NAME -> $dns_ip but this box's public IP is ${pub_ip:-?} — repoint DNS or confirm NAT/port-forward (app webhooks flow through here)"; fi
fi

# Vault sealed state + a quick pod health count (advisory).
if have kubectl; then
  sealed="$(kubectl -n vault exec vault-0 -- vault status 2>/dev/null | awk -F'[[:space:]]+' '/^Sealed/{print $2}')"
  case "$sealed" in
    false) pass "Vault is unsealed" ;;
    true)  fail "Vault is SEALED — vault-auto-unseal.sh should fix within ~10s; check ~/Ideaprojects/STEP0/logs/vault-auto-unseal.log" ;;
    *)     warn "could not read Vault status (vault-0 not up yet?)" ;;
  esac
  notrun="$(kubectl get po -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"{c++} END{print c+0}')"
  [ "${notrun:-0}" -eq 0 ] && pass "all pods Running/Completed" \
    || warn "$notrun pod(s) not Running/Completed (transient ImagePullBackOff is expected right after a single-disk restore)"
else warn "kubectl not installed — skipping Vault/pod checks"; fi

# Cron: the two backup jobs + the canonical cloud crontab.
if [ -f /etc/cron.d/wd-backup ]; then pass "/etc/cron.d/wd-backup present (nightly WD My Cloud rsync, 02:00)"
else warn "/etc/cron.d/wd-backup MISSING — re-arm: sudo ~/wd-backup/install-on-prod.sh"; fi

if crontab -l 2>/dev/null | grep -q vault-auto-unseal; then pass "cloud crontab installed (vault-auto-unseal + agents)"
else warn "cloud crontab not installed — run ./install-cron.sh"; fi

# Root crontab holds the weekly DR backup; only readable as root.
if sudo -n true 2>/dev/null; then
  if sudo crontab -u root -l 2>/dev/null | grep -q backup-minikube-mnt; then pass "root weekly DR backup cron present (backup-minikube-mnt.sh)"
  else warn "root weekly DR backup cron MISSING — reinstall (see restore-scratch.sh phase 8)"; fi
else info "root crontab check skipped (needs sudo) — re-run with: sudo ./verify-recovery.sh, or check: sudo crontab -u root -l"; fi

# Push notifications (architecture.md §7a). A dead alert channel is indistinguishable
# from a healthy system, so a restore that silently dropped it is exactly the thing a
# post-restore survey should catch. Checked separately from the crontab line above
# because an OLD cloud-crontab installs cleanly and still lacks the watcher.
if crontab -l 2>/dev/null | grep -q resource-crunch-watch; then pass "resource-crunch watcher cron present (ntfy yolo-private-cloud-resource-crunch)"
else warn "resource-crunch watcher NOT in the cloud crontab — re-run ./install-cron.sh"; fi

# Monitoring wiring. Both of these are silent when wrong — which is the whole reason
# they belong in a survey rather than in a runbook someone reads after noticing.
if have kubectl; then
  # The two metrics APIs must be served by DIFFERENT things. metrics-server losing
  # metrics.k8s.io means `kubectl top` and every CPU HPA go dark with no error; the
  # adapter missing custom.metrics.k8s.io means custom HPAs sit at <unknown> forever.
  rm_owner="$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.spec.service.namespace}/{.spec.service.name}' 2>/dev/null)"
  case "$rm_owner" in
    kube-system/metrics-server) pass "v1beta1.metrics.k8s.io owned by metrics-server (kubectl top / CPU HPAs)" ;;
    "")                         warn "v1beta1.metrics.k8s.io not registered — kubectl top will be empty" ;;
    *)                          fail "v1beta1.metrics.k8s.io hijacked by $rm_owner — see kube-prometheus manifests/CUSTOM-METRICS.md" ;;
  esac
  cm_avail="$(kubectl get apiservice v1beta1.custom.metrics.k8s.io -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null)"
  if [ "$cm_avail" = "True" ]; then
    n_cm="$(kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 2>/dev/null | tr ',' '\n' | grep -c '"name"')"
    pass "v1beta1.custom.metrics.k8s.io available via prometheus-adapter (${n_cm:-0} metrics offered)"
  else
    warn "v1beta1.custom.metrics.k8s.io not available — custom-metric HPAs will report <unknown>"
  fi

  # Grafana's /var/lib/grafana is an emptyDir, so without this Secret the admin login
  # silently reverts to the built-in admin/admin on the next pod restart.
  if kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    pass "monitoring/grafana-admin present (Grafana login pinned from Vault)"
  else
    warn "monitoring/grafana-admin MISSING — Grafana is on admin/admin; run ./sync-grafana-admin.sh"
  fi
fi

VR_SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "$VR_SELFDIR/ntfy-topic-check.sh" ]; then
  if "$VR_SELFDIR/ntfy-topic-check.sh" >/dev/null 2>&1; then pass "ntfy channel registry consistent (./ntfy-topic-check.sh)"
  else warn "ntfy channel registry has violations — run ./ntfy-topic-check.sh for detail"; fi
fi

# ============================== SUMMARY ==============================
section "Detected environment-specific values (what a new box can change)"
for d in "${DETECTED[@]}"; do printf "  • %s\n" "$d"; done

printf "\n${C_B}== Summary ==${C_0}\n"
printf "  ${C_G}%d PASS${C_0}   ${C_Y}%d WARN${C_0}   ${C_R}%d FAIL${C_0}\n" "$P" "$W" "$F"
if [ "$F" -gt 0 ]; then printf "  ${C_R}%s${C_0}\n" "FAILs present — the cluster is not fully wired. Address the FAIL lines above."; exit 1
elif [ "$W" -gt 0 ]; then printf "  ${C_Y}%s${C_0}\n" "No FAILs, but review WARNs (often just NAS/dev-box powered off, or DNS pending)."; exit 0
else printf "  ${C_G}%s${C_0}\n" "All checks passed."; exit 0; fi
