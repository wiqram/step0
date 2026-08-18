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

# Repo directory. Defined HERE, at the top, not next to its first heavy user: `set -u` is
# on, so a check that referenced it before this line did not merely mis-read — it ABORTED
# the whole survey at that point and every later check silently never ran.
VR_SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run under sudo, point the cluster tools back at the INVOKING user's config. This survey
# wants root for two things only — root's crontab and stat()ing the 0700 datastore dirs in
# §5 — but `sudo ./verify-recovery.sh` also gives kubectl and minikube root's $HOME, where
# there is no ~/.kube/config and no ~/.minikube. Every cluster check then fails, loudest of
# all `minikube ip` returning 'Profile "minikube" not found', which reads as a dead cluster
# on a perfectly healthy box. Observed 2026-08-07: as root 43 PASS / 1 FAIL, as cloud
# 37 PASS / 0 FAIL — same machine, same moment. Rebinding HOME gives one invocation
# (`sudo ./verify-recovery.sh`) full coverage instead of two partial ones.
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  _vr_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  if [ -n "$_vr_home" ] && [ -d "$_vr_home" ]; then
    export HOME="$_vr_home"
    export KUBECONFIG="${KUBECONFIG:-$_vr_home/.kube/config}"
    export MINIKUBE_HOME="${MINIKUBE_HOME:-$_vr_home/.minikube}"
  fi
fi

# ...but the HOME rebind above does NOT reach ssh. OpenSSH resolves ~/.ssh from getpwuid(), not
# from $HOME, so under sudo it reads /root/.ssh and the dev-box probe fails `Permission denied
# (publickey)` even though the invoking user has a perfectly good key — reported as "dev down or
# no key", which is doubly misleading. Since the raw/PREROUTING check in §3 needs root and this
# one must not have it, one invocation has to do both: run ssh as the invoking user.
_vr_ssh() {
  if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    sudo -n -u "$SUDO_USER" ssh "$@"
  else
    ssh "$@"
  fi
}

# ---- expected values (override via env for a different topology) ----
EXP_NODE_IP="${EXP_NODE_IP:-172.16.238.2}"        # minikube node: API/NodePorts/registry
EXP_NPM_IP="${EXP_NPM_IP:-172.16.238.10}"         # nginx-proxy-manager on the 5million net
EXP_GW_IP="${EXP_GW_IP:-172.16.238.1}"            # 5million gateway
EXP_NET="${EXP_NET:-5million}"                     # docker network name
EXP_SUBNET="${EXP_SUBNET:-172.16.0.0/16}"          # 5million subnet (fixed IPs 172.16.238.x live inside it)
EXP_REG_PORT="${EXP_REG_PORT:-5000}"               # in-cluster registry
EXP_API_PORT="${EXP_API_PORT:-8443}"               # kube API
EXP_AM_PORT="${EXP_AM_PORT:-30333}"                 # alertmanager NodePort (infra alerts -> ntfy)
EXP_GRAFANA_PORT="${EXP_GRAFANA_PORT:-30330}"       # grafana NodePort (root_url check)

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
LOKI_GUARD_SVC="${LOKI_GUARD_SVC:-yolo-loki-nodeport-guard.service}"  # SEC-LOKI-NODEPORT
EXP_LOKI_PORT="${EXP_LOKI_PORT:-30310}"            # Loki NodePort — must be host-only
DEV_OOB_SSH="${DEV_OOB_SSH:-vik@192.168.50.161}"   # dev box over the LAN (OOB) — to verify its egress back to us

EXP_HOSTNAME="${EXP_HOSTNAME:-private-cloud}"
DNS_NAME="${DNS_NAME:-jenkins.traderyolo.com}"     # public entry point; should resolve to us

# SEC-EDGE-ALLOWLIST + off-LAN access (see tailscale-access.sh, nginx docs/edge-exposure.md).
EXP_PUBLIC_IP="${EXP_PUBLIC_IP:-213.48.246.115}"   # our static public IP == the advertised /32
NPM_ALLOWLIST="${NPM_ALLOWLIST:-/home/cloud/Ideaprojects/nginx/data/nginx/custom/http_top.conf}"
NPM_ENFORCE="${NPM_ENFORCE:-/home/cloud/Ideaprojects/nginx/data/nginx/custom/server_proxy.conf}"

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
    peer_rt="$(_vr_ssh -n -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
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

  # `is-active` is NOT enough, and this is the lesson from 2026-08-07: the service reported
  # active, both DOCKER-USER rules were present and correct, the link was up — and dev->prod was
  # still 100% dead, because Docker >=28 drops off-host traffic to container IPs in a DIFFERENT
  # table (raw/PREROUTING, priority -300, before conntrack and long before FORWARD). So also
  # assert the raw ACCEPT that defeats that drop actually exists. See docs/architecture.md §3.
  if have iptables && [ "$(id -u)" -eq 0 ]; then
    if iptables -t raw -C PREROUTING -s "$EXP_10G_PEER" -d "$EXP_NODE_IP" -p tcp --dport "$EXP_API_PORT" -j ACCEPT 2>/dev/null \
    || iptables -t raw -S PREROUTING 2>/dev/null | grep -q -- "-s $EXP_10G_PEER/32 -d $EXP_NODE_IP/32 .*--dport $EXP_API_PORT -j ACCEPT"; then
      pass "raw/PREROUTING ACCEPT present ($EXP_10G_PEER -> $EXP_NODE_IP:$EXP_API_PORT) — Docker's direct-routing drop is defeated"
    elif iptables -t raw -S PREROUTING 2>/dev/null | grep -q -- "-d $EXP_NODE_IP/32 .*-j DROP"; then
      fail "Docker's direct-routing DROP for $EXP_NODE_IP is active with NO matching ACCEPT — dev->prod kubectl/IntelliJ will time out with every other check passing. Fix: sudo ./enable-devbox-kube-access.sh   (confirm with: iptables -t raw -L PREROUTING -n -v — the DROP counter climbs)"
    else
      info "no raw/PREROUTING drop for $EXP_NODE_IP (Docker <28 behaviour, or network uses trusted_host_interfaces)"
    fi
  else
    info "raw/PREROUTING check skipped (needs root) — by hand: sudo iptables -t raw -L PREROUTING -n -v"
  fi

  # SEC-LOKI-NODEPORT. The mirror image of the two rules above: those exist to let ONE host
  # through Docker's forward path, this one exists to keep everyone else out of it. Loki's
  # NodePort 30310 answers LogQL with no credential at all and holds 30 days of the
  # signal->trade pipeline's logs, including follower emails; the port can't be removed
  # because the host-side agent loop pushes OTLP to it from outside the cluster.
  # Check the UNIT and the RULE separately — Docker rebuilds DOCKER-USER on every daemon
  # restart, so an enabled unit that has not fired since is a port standing wide open with
  # a green light next to it, which is precisely the failure this whole section exists for.
  st="$(systemctl is-active "$LOKI_GUARD_SVC" 2>/dev/null)"
  case "$st" in
    active) pass "$LOKI_GUARD_SVC = active (SEC-LOKI-NODEPORT)" ;;
    *)      warn "$LOKI_GUARD_SVC = ${st:-not-installed} — Loki NodePort $EXP_LOKI_PORT is unrestricted. Install: sudo ./loki-nodeport-guard.sh --install" ;;
  esac
  if have iptables && [ "$(id -u)" -eq 0 ]; then
    # ⚠️ `.*` BEFORE `-j DROP` as well as after the address, and this is not defensive
    # padding — the first version of this check FAILed on a host where the rule was present
    # and working (caught 2026-08-08, the first sudo run). The guard inserts the rule with
    # `-m comment`, so iptables renders it as
    #   -d 172.16.238.2/32 -p tcp -m tcp --dport 30310 -m comment --comment "..." -j DROP
    # and a pattern anchoring `-j DROP` directly to `--dport` cannot match it. A survey that
    # cries wolf about an open port is worse than no survey: the next real one gets ignored.
    # Match the address, the port and the target, and stay agnostic about the modules between.
    if iptables -S DOCKER-USER 2>/dev/null | grep -qE -- "-d $EXP_NODE_IP/32 .*--dport $EXP_LOKI_PORT .*-j DROP"; then
      pass "DOCKER-USER DROP present for Loki $EXP_NODE_IP:$EXP_LOKI_PORT (host-only)"
    else
      fail "NO DOCKER-USER DROP for Loki $EXP_NODE_IP:$EXP_LOKI_PORT — unauthenticated LogQL over 30 days of pipeline logs is reachable from the bridge network. Fix: sudo ./loki-nodeport-guard.sh --install"
    fi
  else
    info "Loki NodePort rule check skipped (needs root) — by hand: sudo ./loki-nodeport-guard.sh --status"
  fi
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

# ---- Vault ACL: can the runtime identities actually WRITE where they must? -------------
# BUG-VAULT-PLATFORM-KEY-403 (found 2026-08-18). yolo-policy granted create/update on
# kv/data/yolo/followers/* only; the admin data-source key path kv/yolo/platform-data-sources
# fell through to the read-ONLY glob kv/data/yolo/*. So the admin key-upload form 403'd on
# EVERY write for a month while getPlatformSourceCreds kept returning code=OK against a store
# that never gained an ig_platform value — every consumer silently used its env fallback.
#
# ⚠️ Read-granted-write-denied is the point of this block. It has NO symptom: the app is up,
# reads work, health checks pass, and nothing logs an error. Neither "Vault is unsealed" nor
# "all pods Running" above can see it, and a rollout-time probe would not catch a policy that
# a DR restore rebuilt wrong — which is exactly why the assertion belongs here.
#
# ⚠️ This is the ONE block in this script that is not purely read-only: `vault token
# capabilities` needs a token, so we mint a 90s throwaway per policy and revoke it
# immediately. Nothing else is created and no secret is read or written — in particular we do
# NOT test-write to a real path, because those bundles hold live credentials and a
# read-modify-write probe races whoever is using the admin UI. `token capabilities` IS Vault's
# ACL evaluator, so it answers the 403 question exactly without touching any data.
# The root token is piped over stdin, never passed in argv where `ps` would show it.
# Set SKIP_VAULT_ACL=1 to opt out.
VAULT_KEYS="${VAULT_KEYS:-$HOME/.vault/cluster-keys.json}"
VR_APPS="${VR_APPS:-bestrentaladmin dyingpaleblue helpmepdf ollama predictonomy prop-investech qcguy yolo}"
# Overridable ONLY so the write-path branch below can be proven to still FAIL (point it at a
# policy lacking those paths). A check that cannot fail is worse than no check — see the
# db-snapshot-audit false-FAIL and the yolo-uptime-probe --selftest for the same lesson.
VR_YOLO_POLICY="${VR_YOLO_POLICY:-yolo-policy}"
if [ "${SKIP_VAULT_ACL:-0}" = 1 ]; then info "Vault ACL sweep skipped (SKIP_VAULT_ACL=1)"
elif ! have kubectl || ! have jq; then warn "kubectl/jq missing — skipping the Vault ACL capability sweep"
elif [ "${sealed:-}" != false ]; then warn "Vault not unsealed — skipping the Vault ACL capability sweep"
elif [ ! -r "$VAULT_KEYS" ]; then
  warn "$VAULT_KEYS unreadable — skipping the Vault ACL capability sweep (a root token is needed to mint the throwaway probe tokens)"
else
  _vt="$(jq -r '.root_token // empty' "$VAULT_KEYS" 2>/dev/null)"
  if [ -z "$_vt" ]; then warn "no .root_token in $VAULT_KEYS — skipping the Vault ACL capability sweep"; else
    _acl="$(printf '%s\n' "$_vt" | kubectl -n vault exec -i vault-0 -- env APPS="$VR_APPS" YPOL="$VR_YOLO_POLICY" sh -c '
      read -r VAULT_TOKEN || exit 1; export VAULT_TOKEN
      mint() { vault token create -policy="$1" -ttl=90s -field=token 2>/dev/null; }
      caps() { vault token capabilities "$1" "$2" 2>/dev/null | tr -d " "; }
      has()  { case ",$1," in *",$2,"*) return 0 ;; esac; return 1 ; }

      # --- yolo: the only app with a runtime Vault client (userService vault-client.js) ---
      T=$(mint "$YPOL")
      if [ -z "$T" ]; then echo "SKIP $YPOL absent or token mint refused"; else
        for p in kv/data/yolo/followers/000000000000000000000000 kv/data/yolo/platform-data-sources; do
          c=$(caps "$T" "$p")
          if has "$c" create && has "$c" update && has "$c" read
            then echo "OKW yolo runtime write path $p [$c]"
            else echo "BAD yolo CANNOT WRITE $p [${c:-?}] — admin/registration saves will 403 with no symptom"; fi
        done
        c=$(caps "$T" kv/data/yolo/user)
        if has "$c" create || has "$c" update
          then echo "BAD yolo-policy WIDENED: kv/data/yolo/user is writable [$c] — the leaf grants must not become a glob"
          else echo "OK kv/data/yolo/user still read-only [$c]"; fi
        c=$(caps "$T" kv/data/age-keys/yolo)
        if [ "$c" = deny ]
          then echo "OK app token denied on kv/data/age-keys/yolo"
          else echo "BAD app token can reach its SOPS age key kv/data/age-keys/yolo [$c]"; fi
        vault token revoke "$T" >/dev/null 2>&1
      fi

      # --- per-app: Jenkins AppRole must write; the app runtime must NOT ---
      for a in $APPS; do
        o=yolo; [ "$a" = yolo ] && o=qcguy          # a different tenant, to prove isolation
        T=$(mint "jenkins-$a-policy")
        if [ -z "$T" ]; then echo "SKIP jenkins-$a-policy absent"; else
          c=$(caps "$T" "kv/data/$a/svc")
          if has "$c" create && has "$c" update
            then echo "OK jenkins-$a-policy can sync kv/data/$a/*"
            else echo "BAD jenkins-$a-policy CANNOT WRITE kv/data/$a/* [${c:-?}] — vaultSync will fail the build"; fi
          c=$(caps "$T" "kv/data/$o/svc")
          if [ "$c" = deny ]
            then echo "OK jenkins-$a-policy isolated from $o"
            else echo "BAD jenkins-$a-policy can reach kv/data/$o/* [$c] — cross-tenant secret access"; fi
          vault token revoke "$T" >/dev/null 2>&1
        fi
        T=$(mint "$a-policy")
        if [ -z "$T" ]; then echo "SKIP $a-policy absent"; else
          c=$(caps "$T" "kv/data/$a/svc")
          has "$c" read || echo "BAD $a-policy cannot READ its own kv/data/$a/* [${c:-?}] — the app cannot boot"
          if has "$c" create || has "$c" update
            then echo "BAD $a-policy has WRITE on kv/data/$a/* [$c] — app runtimes are read-only by design"
            else echo "OK $a-policy read-only on its own secrets"; fi
          vault token revoke "$T" >/dev/null 2>&1
        fi
      done' 2>/dev/null)"
    unset _vt
    if [ -z "$_acl" ]; then warn "Vault ACL sweep produced no output (vault-0 not answering?)"; else
      _ok=0
      while IFS= read -r _l; do
        case "$_l" in
          OKW\ *) pass "Vault ACL: ${_l#OKW }" ;;                 # the paths that actually broke
          OK\ *)  _ok=$((_ok+1)) ;;                               # aggregated to keep output readable
          BAD\ *) fail "Vault ACL: ${_l#BAD }" ;;
          SKIP\ *) warn "Vault ACL: ${_l#SKIP }" ;;
        esac
      done <<< "$_acl"
      [ "$_ok" -gt 0 ] && pass "Vault ACL: $_ok further assertions passed (per-app write/read split, tenant isolation, age-key containment)"
    fi
  fi
fi

# Cron: the two backup jobs + the canonical cloud crontab.
if [ -f /etc/cron.d/wd-backup ]; then pass "/etc/cron.d/wd-backup present (nightly WD My Cloud rsync, 02:00)"
else warn "/etc/cron.d/wd-backup MISSING — re-arm: sudo ~/wd-backup/install-on-prod.sh"; fi

# ⚠️ Always read the CLOUD user's crontab explicitly — never a bare `crontab -l`.
# The header above tells you to re-run this script under sudo to get the datastore
# ownership checks. Under sudo a bare `crontab -l` reads ROOT's crontab, which holds
# only the weekly DR backup — so all three cloud-crontab checks below reported
# "not installed", "watchdog NOT present" and "DRIFTED" on a host where the cloud
# crontab was in fact installed and byte-identical to cron/cloud-crontab (found
# 2026-08-08). That is not a cosmetic false positive: the drift WARN tells you to
# reconcile with `crontab -l > cron/cloud-crontab`, and running THAT under sudo would
# overwrite the canonical crontab with root's single line — destroying every schedule
# this file exists to reproduce, during a disaster recovery, on the operator's own
# initiative. Hence this helper.
cloud_crontab() {
  if [ "$(id -u)" -eq 0 ]; then crontab -u "${SUDO_USER:-cloud}" -l 2>/dev/null
  else crontab -l 2>/dev/null; fi
}

if cloud_crontab | grep -q vault-auto-unseal; then pass "cloud crontab installed (vault-auto-unseal + agents)"
else warn "cloud crontab not installed — run ./install-cron.sh"; fi

# Root crontab holds the weekly DR backup; only readable as root. Since 2026-08-08 it has a
# canonical committed copy (cron/root-crontab), so check the same two things as for the cloud
# crontab: the job is scheduled AND the live schedule matches what a restore would reproduce.
# This one matters more than its single line suggests — it is the only job that puts data on a
# different disk. The nightly DB snapshots live on /mnt/minikube-mnt (nvme0n1p6), the same
# partition as the live stores, so a disk failure takes the stores and their snapshots together
# and this weekly archive is what is left.
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
  root_crontab="$(sudo crontab -u root -l 2>/dev/null)"
  if printf '%s\n' "$root_crontab" | grep -q backup-minikube-mnt; then
    pass "root weekly DR backup cron present (backup-minikube-mnt.sh)"
  else
    fail "root weekly DR backup cron MISSING — the ONLY off-disk backup is not scheduled. Re-arm: sudo ./install-cron.sh --root"
  fi
  if [ -r "$VR_SELFDIR/cron/root-crontab" ]; then
    if diff -q <(printf '%s\n' "$root_crontab" | grep -vE '^\s*#|^\s*$') \
               <(grep -vE '^\s*#|^\s*$' "$VR_SELFDIR/cron/root-crontab") >/dev/null 2>&1
    then
      pass "root crontab matches cron/root-crontab (install-cron.sh --root is safe to re-run)"
    else
      warn "root crontab has DRIFTED from cron/root-crontab — a restore would revert the live schedule. Inspect with: sudo ./install-cron.sh --status, then either write back (sudo crontab -u root -l > cron/root-crontab, commit) or adopt the committed one (sudo ./install-cron.sh --root)"
    fi
  else
    warn "cron/root-crontab is missing from the repo — install-cron.sh --root has nothing to install"
  fi
else
  info "root crontab checks skipped (needs sudo) — re-run with: sudo ./verify-recovery.sh, or check: sudo ./install-cron.sh --status"
fi

# Push notifications (docs/architecture.md §7a). A dead alert channel is indistinguishable
# from a healthy system, so a restore that silently dropped it is exactly the thing a
# post-restore survey should catch. Checked separately from the crontab line above
# because an OLD cloud-crontab installs cleanly and still lacks the watcher.
if cloud_crontab | grep -q alerting-pipeline-watch; then pass "alerting-pipeline watchdog cron present (ntfy yolo-private-cloud-resource-crunch)"
else warn "alerting-pipeline watchdog NOT in the cloud crontab — re-run ./install-cron.sh"; fi

# The yolo public-uptime probe, checked by name for the SAME reason as the line above and
# not covered by it: alerting-pipeline-watch.sh watches the kube-prometheus pipeline, this
# watches yolo's follower-facing serving path, and the 2026-08-03->08-07 outage is the
# proof they are different failures — that one took yolo's in-cluster Loki/Grafana alerting
# down WITH the platform and paged nobody for four days. The drift check below cannot
# substitute: a restore that clones an older STEP0 gets a cloud-crontab with no probe line,
# live and canonical agree perfectly, and the drift check PASSES while nothing is watching.
if cloud_crontab | grep -q yolo-uptime-probe; then pass "yolo public-uptime probe cron present (ntfy yolo-public-uptime)"
else warn "yolo public-uptime probe NOT in the cloud crontab — the follower-facing serving path has no outside-the-cluster watcher. Re-run ./install-cron.sh"; fi
# Its weekly --selftest is what proves the probe can still DETECT an outage; a probe that
# has quietly stopped failing is indistinguishable from a healthy platform.
if cloud_crontab | grep -q 'yolo-uptime-probe.*--selftest'; then pass "yolo uptime probe weekly --selftest scheduled"
else warn "yolo uptime probe --selftest NOT scheduled — nothing proves the probe can still fail. Re-run ./install-cron.sh"; fi

# Canonical-vs-live crontab drift. install-cron.sh installs cron/cloud-crontab VERBATIM,
# so that file — not the live crontab — is what a bare-metal restore reproduces. Drift is
# one-directional and silent: fixes get made with `crontab -e` and never written back, and
# nothing notices until a restore quietly reverts them. Found 2026-08-04 with the canonical
# copy still carrying superseded Predictonomy schedules AND the YOLO agent still ENABLED
# after it had been deliberately paused — install-cron.sh would have resurrected it.
# Compares SCHEDULE LINES only: comments drifting apart is untidy, not dangerous.
if [ -r "$VR_SELFDIR/cron/cloud-crontab" ]; then
  if diff -q <(cloud_crontab | grep -vE '^\s*#|^\s*$') \
             <(grep -vE '^\s*#|^\s*$' "$VR_SELFDIR/cron/cloud-crontab") >/dev/null 2>&1
  then
    pass "cloud crontab matches cron/cloud-crontab (install-cron.sh is safe to re-run)"
  else
    warn "cloud crontab has DRIFTED from cron/cloud-crontab — a restore would revert the live schedule. Reconcile with: crontab -u cloud -l > cron/cloud-crontab (then commit), or re-run ./install-cron.sh to adopt the committed one. Note the -u cloud: a bare 'crontab -l' under sudo reads ROOT's crontab and would overwrite the canonical file with root's single backup line"
  fi
else
  warn "cron/cloud-crontab is missing from the repo — install-cron.sh has nothing to install"
fi

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

  # ---- Alertmanager is actually WIRED to a notifier (docs/architecture.md §7b) ----------
  # THE reason this check exists: upstream kube-prometheus ships Default/Watchdog/Critical/
  # null as BARE NAMES with no configuration, and in that state every one of its ~138
  # alerting rules evaluates, fires, reaches Alertmanager and is silently DISCARDED. That
  # was true on this box for months — six alerts firing, two of them critical, nothing ever
  # sent anywhere — and it is indistinguishable from a healthy cluster from the outside.
  # ntfy-topic-check.sh cannot catch it: that validates the manifest TEXT, whereas this
  # asks the running Alertmanager what config it actually loaded.
  # NOTE the status API redacts webhook URLs to "<secret>", so presence of a receiver
  # block is the only thing assertable here — which is exactly what was missing.
  _am="http://$EXP_NODE_IP:${EXP_AM_PORT:-30333}"
  if curl -s -m 5 -o /dev/null "$_am/-/healthy" 2>/dev/null; then
    if curl -s -m 5 "$_am/api/v2/status" 2>/dev/null | grep -q 'webhook_configs'; then
      pass "Alertmanager receivers are wired to a notifier (ntfy) — infra alerts can reach you"
    else
      fail "Alertmanager is running but its receivers are EMPTY — all ~138 kube-prometheus alert rules are firing into a void. Re-apply kube-prometheus manifests/alertmanager-secret.yaml"
    fi
  else
    warn "Alertmanager not answering on $_am — cannot confirm infra alerts have anywhere to go"
  fi

  # ---- Grafana root_url is not the default localhost --------------------------------
  # Unset, Grafana advertises http://localhost:3000/ to every client. A desktop browser
  # never notices (it navigates with relative paths); phones, alert-notification deep
  # links and share/snapshot URLs all break. Asked over the NODEPORT deliberately, so this
  # still works mid-restore before DNS/NPM are back.
  _gf="http://$EXP_NODE_IP:${EXP_GRAFANA_PORT:-30330}"
  _appurl="$(curl -s -m 5 "$_gf/login" 2>/dev/null | grep -o '"appUrl":"[^"]*"' | head -1 | cut -d'"' -f4)"
  case "$_appurl" in
    "")             warn "could not read Grafana appUrl from $_gf — Grafana down?" ;;
    *localhost*)    fail "Grafana root_url is unset (appUrl=$_appurl) — phones, alert deep links and share URLs will all point at localhost. Fix in kube-prometheus manifests/grafana-config.yaml" ;;
    *)              pass "Grafana root_url set (appUrl=$_appurl)"
                    note "Grafana appUrl: $_appurl" ;;
  esac
fi

# ---- SEC-EDGE-ALLOWLIST: the edge lockdown itself -------------------------------------
# This is the control that stopped the admin vhosts (NPM's own admin UI + API, the
# kube-apiserver, Vault, the registry's /v2/_catalog, an unauthenticated Prometheus) being
# reachable by name from the internet — nginx routes on the Host header, so "not in DNS"
# protects nothing. It lives in two hand-written files that are the ONLY part of NPM's
# data/ under version control. A restore that loses them comes back serving all of it to
# the world again, silently and with every site working perfectly. FAIL, not WARN.
if [ -f "$NPM_ALLOWLIST" ] && [ -f "$NPM_ENFORCE" ]; then
  if grep -q 'yolo_deny' "$NPM_ENFORCE" 2>/dev/null && grep -q "$EXP_PUBLIC_IP" "$NPM_ALLOWLIST" 2>/dev/null; then
    pass "SEC-EDGE-ALLOWLIST present (geo + enforcement, trusts $EXP_PUBLIC_IP)"
  else
    fail "SEC-EDGE-ALLOWLIST files exist but look wrong — enforcement 'if (\$yolo_deny)' or the $EXP_PUBLIC_IP trust entry is missing. Losing the latter puts EVERY k8s image pull into ImagePullBackOff (they hairpin in as that address); losing the former re-exposes the admin vhosts."
  fi
  # Live check beats file check: NPM regenerates its proxy-host confs from its DB on every
  # restart, so the question is whether the running nginx is enforcing, not whether a file
  # is on disk. An untrusted vantage is required — the docker bridge is deliberately NOT in
  # the geo (a curl from this host proves nothing; loopback is trusted).
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nginx-proxy-manager$'; then
    _deny="$(docker run --rm --network bridge curlimages/curl:latest -s -o /dev/null \
               -m 8 -w '%{http_code}' -H "Host: $DNS_NAME" http://172.17.0.1/ 2>/dev/null || echo "")"
    case "$_deny" in
      403) pass "edge deny branch live: untrusted source -> 403 on $DNS_NAME" ;;
      "")  warn "could not test the deny branch (no curl image / no docker bridge) — verify by hand before trusting the edge" ;;
      *)   fail "UNTRUSTED SOURCE GOT HTTP $_deny FROM $DNS_NAME — the admin vhosts are exposed to the internet. Check $NPM_ENFORCE is included and 'docker exec nginx-proxy-manager nginx -t'." ;;
    esac
  fi
else
  fail "SEC-EDGE-ALLOWLIST missing ($NPM_ALLOWLIST / $NPM_ENFORCE) — the admin vhosts (NPM admin UI+API, kube-apiserver, Vault, registry catalog, Prometheus) are reachable by Host header from the whole internet. Restore from the nginx repo: git -C ~/Ideaprojects/nginx checkout -- data/nginx/custom/"
fi

# ---- Tailscale: off-LAN access to those same vhosts -----------------------------------
# Deliberately NOT fatal in most branches: tailscale is an operator convenience and nothing
# on the platform depends on it (the box dual-purpose serves the public sites regardless).
# The exception is accept-dns, which can take the CLUSTER down — see below.
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    _ts_json="$(tailscale status --json 2>/dev/null)"
    _ts_route="$(printf '%s' "$_ts_json" | python3 -c "
import json,sys
try: s=(json.load(sys.stdin).get('Self') or {})
except Exception: print('unknown'); sys.exit(0)
ip='$EXP_PUBLIC_IP/32'
print('approved' if ip in (s.get('AllowedIPs') or []) and ip in (s.get('PrimaryRoutes') or []) else 'not-approved')
" 2>/dev/null || echo unknown)"
    case "$_ts_route" in
      approved) pass "tailscale up; $EXP_PUBLIC_IP/32 subnet route APPROVED (off-LAN access to jenkins/grafana works)" ;;
      # The silent one. Advertising is not approving: enrolled devices simply do not use an
      # unapproved route, with no error at either end, so this looks identical to "working"
      # from the server side. An autoApprovers ACL removes the human step for good.
      not-approved) warn "tailscale is up but the $EXP_PUBLIC_IP/32 route is NOT APPROVED — off-LAN devices silently fall back to their own network and get 403. Approve: console -> Machines -> $EXP_HOSTNAME -> Edit route settings (or add an autoApprovers ACL)" ;;
      *) warn "could not read tailscale route state" ;;
    esac
    # accept-dns MUST stay off. If it is on, this host's DNS is served by the tailnet, and
    # container-registry.traderyolo.com — which every image pull resolves and hairpins
    # through the router — can stop resolving to the public IP. Failure mode is cluster-wide
    # ImagePullBackOff traced to a VPN client. That is a platform outage, so: FAIL.
    if tailscale debug prefs 2>/dev/null | grep -q '"CorpDNS": *true'; then
      fail "tailscale accept-dns is ENABLED — this host's DNS is now the tailnet's. Risks cluster-wide ImagePullBackOff via the container-registry.traderyolo.com hairpin. Fix: sudo $(dirname "$0")/tailscale-access.sh --ensure"
    else
      pass "tailscale accept-dns disabled (container-registry hairpin protected)"
    fi
    _adv="$(printf '%s' "$_ts_json" | python3 -c "
import json,sys
try: print(','.join((json.load(sys.stdin).get('Self') or {}).get('AllowedIPs') or []))
except Exception: pass" 2>/dev/null)"
    note "tailscale: $(tailscale ip -4 2>/dev/null | head -1) advertising [$_adv]"
  else
    warn "tailscale installed but LOGGED OUT — off-LAN access to the admin vhosts is down (house LAN + dev box unaffected). Re-arm: sudo $(dirname "$0")/tailscale-access.sh --install"
  fi
else
  warn "tailscale not installed — jenkins/grafana reachable only from the house LAN and the dev box. Install: sudo $(dirname "$0")/tailscale-access.sh --install"
fi

# ============================== 5. HOST STORAGE LAYOUT ==============================
section "5. Host storage layout (docs/GM9000-MIGRATION.md §1.2 — partitions are chosen in the INSTALLER)"

# Why this section exists. On 2026-08-07, after the fresh 26.04 install, all three NVMe
# partitions were present with the correct labels AND the correct sizes — while /etc/fstab
# carried only / and /boot/efi. The desktop's udisks auto-mounted them under
# /run/media/cloud/, so /var, /home and every docker image were writing to the 120G root
# while the 900G docker-data partition sat empty. There is no error at any point in that
# story: the box simply runs out of disk weeks later, and on this host a full /var means
# DiskPressure=True, a tainted node, and Prometheus stuck Pending (see CLAUDE.md on
# reduce-node-docker-cache.sh). A partition existing is not the same as a partition being
# USED, and only fstab can tell you which.
check_mount_source() {   # $1=label  $2=expected mountpoint  $3=severity (fail|warn)
  local label="$1" mp="$2" sev="${3:-fail}" want got
  if [ ! -e "/dev/disk/by-label/$label" ]; then
    info "no partition labelled '$label' on this box — skipping $mp (different topology?)"
    return 0
  fi
  want="$(readlink -f "/dev/disk/by-label/$label" 2>/dev/null)"
  got="$(findmnt -no SOURCE --target "$mp" 2>/dev/null || true)"
  got="$(readlink -f "${got:-}" 2>/dev/null || true)"
  if [ -n "$got" ] && [ "$got" = "$want" ]; then
    pass "$mp is on '$label' ($want), $(df -h --output=avail "$mp" 2>/dev/null | tail -1 | tr -d ' ') free"
  else
    local where; where="$(findmnt -no SOURCE --target "$mp" 2>/dev/null || echo '<nothing>')"
    "$sev" "$mp is served by $where, NOT the '$label' partition ($want) — writes there land on the root disk. Add to /etc/fstab:  /dev/disk/by-label/$label  $mp  ext4  defaults  0 2"
    # A partition that exists but is auto-mounted elsewhere is the exact 2026-08-07 symptom.
    local auto; auto="$(findmnt -no TARGET "$want" 2>/dev/null | head -1)"
    [ -n "$auto" ] && [ "$auto" != "$mp" ] && info "  ('$label' is currently mounted at $auto — likely a desktop/udisks automount)"
  fi
}
check_mount_source ubuntu-var       /var
check_mount_source ubuntu-home      /home
check_mount_source docker-data      /var/lib/docker
check_mount_source minikube-backups /mnt/minikube-backups
check_mount_source Kachra           /mnt/kachra
# 2026-08-07: minikube-mnt moved off the HDD onto its own NVMe partition (p6,
# 'minikube-data'), mounted AT the existing path so no script needed changing. Every PV
# the cluster fsyncs lives here — five Postgres, MySQL, Mongo, Redis, Loki, Vault,
# Jenkins. Measured on this box: 4K synchronous writes are 0.96ms on p6 vs 29.6ms on the
# WD10EZEX (7200rpm) it came from, a 31x difference on the one operation those workloads
# block on. This check matters MORE than the others: because it is a nested mount, if p6
# fails to mount the path still EXISTS (it is a plain directory on sda1) and everything
# silently works — just 31x slower, on the HDD, with no error anywhere.
check_mount_source minikube-data    /mnt/minikube-mnt

# --- Datastore ownership on the shared volume ------------------------------------------
# Why. The weekly archive is written by ROOT's crontab, so it carries the real per-container
# UIDs. But tar and cp only RESTORE ownership when they run as root. On 2026-08-07 phase 4
# ran them as 'cloud' and flattened the whole volume to 1000:1000. Nothing errored. The
# cluster came up, monitoring deployed, and then vault-0 sat in a readiness loop on
#   open /vault/data/core/_migration: permission denied
# because core/ was 1000:1000 mode 700 while vault runs as a non-root UID. Every
# containerised datastore has this exposure: loki=10001, the postgres set=70/999,
# mysql/mongo=999. The failure lands AFTER the platform is half-built, which is the worst
# time to find it. These two checks turn that into a FAIL line before anything is deployed.
#
# We deliberately do NOT assert exact UIDs: they legitimately differ per image generation
# (this box has postgres data owned by 70 in three instances and 999 in a fourth). The
# invariant that actually holds is "not owned by cloud" — no datastore container runs as
# the login user, so uid 1000 on this data is always the restore bug, never a valid state.
MNT_VOL="${MNT_VOL:-/mnt/minikube-mnt}"
_stat_owner() { sudo -n stat -c '%u' "$1" 2>/dev/null; }
_stat_mode()  { sudo -n stat -c '%a' "$1" 2>/dev/null; }

if [ -d "$MNT_VOL" ]; then
  _owner_checked=0
  for _d in vault-data/core yolo-loki qcguy-mysql yolo-quantstore trading-microservices \
            dyingpaleblue-postgres/pgdata predictonomy-postgres/pgdata \
            yolo-postgres/pgdata prop-investech-postgres/pgdata; do
    [ -e "$MNT_VOL/$_d" ] || continue
    _u="$(_stat_owner "$MNT_VOL/$_d")"
    if [ -z "$_u" ]; then continue; fi          # unreadable without sudo -n; summarised below
    _owner_checked=$((_owner_checked+1))
    if [ "$_u" = "1000" ]; then
      fail "$_d is owned by uid 1000 (cloud) — the restore ran tar/cp without root, so every non-root datastore container has lost access to its own data. Re-extract with: sudo tar -xpzf <archive> && sudo cp -a"
    else
      pass "$_d owned by uid $_u (not the login user)"
    fi
  done
  [ "$_owner_checked" = 0 ] && info "datastore ownership not checked (needs passwordless sudo; re-run with sudo)"

  # PostgreSQL REFUSES to start unless its data directory is 0700 or 0750:
  #   FATAL: data directory has invalid permissions / Permissions should be u=rwx (0700)...
  # So this cannot be "normalised" to a friendlier mode — loosening it IS the fatal error.
  for _pg in dyingpaleblue-postgres predictonomy-postgres yolo-postgres prop-investech-postgres; do
    [ -e "$MNT_VOL/$_pg/pgdata" ] || continue
    _m="$(_stat_mode "$MNT_VOL/$_pg/pgdata")"
    [ -z "$_m" ] && continue
    case "$_m" in
      700|750) pass "$_pg/pgdata mode $_m (postgres requires 0700 or 0750)" ;;
      *)       fail "$_pg/pgdata mode is $_m — postgres refuses to start unless it is 0700 or 0750 ('data directory has invalid permissions')" ;;
    esac
  done
else
  warn "$MNT_VOL does not exist — the shared cluster volume is missing"
fi

# --- Logical DB snapshots: the ONLY restorable copy of the Mongo databases -------------
# The weekly archive tars the raw datastore directories while the databases are RUNNING.
# Postgres and MySQL survive that — they replay a WAL/binlog on startup. MongoDB does NOT:
# WiredTiger writes are not atomic across files, so a live tar captures blocks from
# different moments, and the restored copy fails its own checksums with
#   WiredTiger.wt: potential hardware corruption, read checksum error ...
# (the wording says hardware; it is not). Proven on 2026-08-07: the `mongo` deployment
# CrashLoopBackOff'd on exactly this after a faithful --numeric-owner restore, and had to be
# rebuilt from a mongodump archive instead.
#
# So the raw yolo-quantstore / trading-microservices / yolo-notifications directories in the
# archive are NOT a usable Mongo restore source. The db-snapshot CronJob's logical dumps in
# yolo-db-snapshots/<db>/<ts>/*.archive.gz ARE — and nothing verified they existed until now.
# A DR that discovers this at restore time has already lost the data.
SNAP_ROOT="${SNAP_ROOT:-$MNT_VOL/yolo-db-snapshots}"
SNAP_MAX_AGE_DAYS="${SNAP_MAX_AGE_DAYS:-2}"
SNAP_NS="${SNAP_NS:-yolo}"

# A stale tree is only a problem if something is still supposed to be refreshing it. When a
# database is RETIRED its snapshot tree stays on disk and ages forever, so a naive freshness
# check nags about it every single run — and a warning that can never be cleared trains you
# to ignore the ones that matter. `atlas` is exactly that: retired on 2026-07-05 by the
# MONGO-MIGRATE cutover from MongoDB Atlas to in-cluster mongo, last snapshot 2026-07-03.
# So ask the cluster which databases still have a snapshot CronJob, and only hold THOSE to
# the freshness bar. Self-correcting: retire a database and this stops nagging on its own;
# add one and it starts checking without anybody editing this file.
SNAP_JOBS=""
if have kubectl; then
  _snap_jobs_all="$(kubectl get cronjobs -n "$SNAP_NS" -o name 2>/dev/null \
                | sed 's|.*/db-snapshot-||' | grep -v '^cronjob' || true)"
  # Not every db-snapshot-* CronJob PRODUCES a dump. `db-snapshot-audit` is the auditor OF
  # the other five: it mounts the snapshot tree `readOnly: true` and reports on their
  # freshness. It therefore can never write $SNAP_ROOT/audit, and there is no "audit"
  # database to restore — so holding it to the producer bar below made this script FAIL
  # permanently on a completely healthy box (found 2026-08-10, while its own log read
  # "audit OK — 5 store(s) present, non-empty and fresh"). That is not a cosmetic bug:
  # restore-scratch.sh phase 9 runs this script and it exits 1 on any FAIL, so a permanent
  # false FAIL is precisely what teaches an operator to stop believing the exit code — the
  # same "a dead channel looks like a healthy system" failure the ntfy registry exists for.
  # Ask the CLUSTER which jobs are verifiers rather than hardcoding the name: a read-only
  # mount structurally cannot produce a dump, so the mount IS the test, and a future
  # auditor gets classified correctly with nobody remembering to edit this file.
  for _j in $_snap_jobs_all; do
    _ro="$(kubectl get cronjob "db-snapshot-$_j" -n "$SNAP_NS" \
             -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[*].volumeMounts[?(@.name=="snapshots")].readOnly}' 2>/dev/null)"
    case "$_ro" in
      *true*) info "db-snapshot-$_j mounts the snapshot tree read-only — verifier, not a producer; not held to the backup bar" ; continue ;;
    esac
    SNAP_JOBS="${SNAP_JOBS}${_j}
"
  done
fi
if [ -d "$SNAP_ROOT" ]; then
  # DISCOVER the per-database trees rather than hardcoding names. The snapshot CronJob's
  # comments say private/notifications/quant, but this box also has atlas/ and postgres/ —
  # a hardcoded list silently skips whatever it does not know about, and a database with no
  # verified backup is exactly what this check exists to catch.
  _snap_dbs="$(find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)"
  [ -z "$_snap_dbs" ] && warn "$SNAP_ROOT exists but contains no per-database trees — no logical DB backups at all"
  for _db in $_snap_dbs; do
    _d="$SNAP_ROOT/$_db"
    # Newest dump by mtime, whatever the timestamped dirs are called. Match BOTH formats:
    # mongodump writes *.archive.gz, pg_dump writes *.dump/*.sql — matching only the mongo
    # one reports a healthy postgres tree as a FAIL (it did, on the first run of this check).
    # ...and *.tar.gz, because not every snapshot target is a DATABASE. `shadow` is the
    # AI-expert decision corpus: a directory of .json/.jsonl files with no mongod in front
    # of it, so a tarball IS its correct and only dump format — there is no mongodump to
    # take. Omitting it made this check FAIL on a tree whose backup was demonstrably good
    # (valid archive, 7 files, written that morning by an active CronJob), and that false
    # FAIL was then mis-filed in docs/plan.md as "a Mongo with no recoverable backup" and
    # nearly acted on as a retired database to delete. Same class of bug as the postgres one
    # above: an allowlist of dump extensions silently indicts every format not on it.
    _pat=( -name '*.archive.gz' -o -name '*.dump' -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' )
    # Judge the newest snapshot RUN, not the newest FILE — two steps, deliberately.
    # One run writes several artefacts milliseconds apart: shadow writes the 476K
    # shadow-ai.tar.gz and then, 4ms LATER, a 110-byte hotpath-shadow.tar.gz (an empty
    # source dir, faithfully archived). "Newest file" therefore lands on the empty one and
    # reports a perfectly good backup as "an empty dump restores nothing". Sorting
    # mtime-then-size does NOT save you either — the mtimes genuinely differ, so size never
    # breaks the tie. Step 1 picks the newest run; step 2 takes the LARGEST artefact in it,
    # which is the one that says whether the run actually captured anything.
    _fmt='%T@ %s %p\n'
    _vr_dumps() {   # newest-first listing of dump artefacts under $1, root-readable if possible
      local _o
      _o="$(sudo -n find "$1" \( "${_pat[@]}" \) -printf "$_fmt" 2>/dev/null)"
      [ -z "$_o" ] && _o="$(find "$1" \( "${_pat[@]}" \) -printf "$_fmt" 2>/dev/null)"
      printf '%s\n' "$_o"
    }
    _a="$(_vr_dumps "$_d" | sort -k1,1rn | head -1)"
    if [ -z "$_a" ]; then
      fail "$_db: no dump file (*.archive.gz/*.dump/*.sql/*.tar.gz) under $_d — for Mongo the raw datastore dirs in the weekly tar are NOT a valid restore source, so this database may have no recoverable backup"
      continue
    fi
    _snapdir="$(dirname "$(printf '%s\n' "$_a" | awk '{print $3}')")"
    _b="$(_vr_dumps "$_snapdir" | sort -k2,2rn | head -1)"      # largest artefact in that run
    _mtime="$(printf '%s\n' "$_b" | awk '{print $1}')"
    _sz="$(printf '%s\n'  "$_b" | awk '{print $2}')"
    _path="$(printf '%s\n' "$_b" | awk '{print $3}')"
    _age=$(( ( $(date +%s) - ${_mtime%%.*} ) / 86400 ))
    # Is anything still scheduled to refresh this tree? Empty SNAP_JOBS means we could not
    # ask (no kubectl / cluster down / yolo not deployed) — then fall back to checking
    # everything, because silently skipping a live database is the worse failure.
    _live=1
    if [ -n "$SNAP_JOBS" ] && ! printf '%s\n' "$SNAP_JOBS" | grep -qx "$_db"; then
      _live=0
    fi
    if [ "${_sz:-0}" -lt 1024 ]; then
      fail "$_db: newest snapshot $(basename "$_path") is ${_sz:-0} bytes — an empty dump restores nothing"
    elif [ "$_live" = 0 ]; then
      info "$_db: no db-snapshot-$_db CronJob targets this tree — retired database, ${_age}d old snapshot kept for history (not a failure)"
    elif [ "$_age" -gt "$SNAP_MAX_AGE_DAYS" ]; then
      warn "$_db: newest DB snapshot is ${_age}d old ($(basename "$(dirname "$_path")")) — the db-snapshot CronJob may be failing; this is the only restorable copy"
    else
      pass "$_db: DB snapshot ${_age}d old, $(( _sz / 1024 ))KB ($(basename "$(dirname "$_path")"))"
    fi
  done
  # The reverse gap: a CronJob exists but has produced no tree at all — a database with NO
  # backup, which the per-tree loop cannot see because it only iterates over trees that
  # exist. Distinguish two very different cases, or this FAILs on every fresh restore:
  #   - the job has NEVER been scheduled (lastScheduleTime empty): normal on a young
  #     cluster, and normal for a newly added target. WARN, and say when it will resolve.
  #   - the job HAS run and still produced nothing: it is failing. FAIL.
  # Both matter because for Mongo the raw datastore dirs in the weekly tar are not a valid
  # restore source, so "no logical dump" really does mean "no way back".
  for _j in $SNAP_JOBS; do
    [ -d "$SNAP_ROOT/$_j" ] && continue
    _last="$(kubectl get cronjob "db-snapshot-$_j" -n "$SNAP_NS" \
               -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null)"
    _sched="$(kubectl get cronjob "db-snapshot-$_j" -n "$SNAP_NS" \
               -o jsonpath='{.spec.schedule}' 2>/dev/null)"
    if [ -z "$_last" ]; then
      warn "db-snapshot-$_j has never run yet (schedule '${_sched:-?}') and $SNAP_ROOT/$_j does not exist — that database has NO logical backup until its first run. Expected on a freshly rebuilt cluster or a newly added target; re-check after the next scheduled run."
    else
      fail "db-snapshot-$_j last ran $_last but $SNAP_ROOT/$_j was never written — the job is failing and that database has no logical backup. Check: kubectl -n $SNAP_NS logs job/\$(kubectl -n $SNAP_NS get jobs -o name | grep db-snapshot-$_j | tail -1 | cut -d/ -f2)"
    fi
  done
else
  info "$SNAP_ROOT absent — yolo not deployed on this box?"
fi

# --- PVC durability: anything on the default StorageClass is NOT backed up --------------
# A PVC that omits storageClassName falls through to minikube's default `standard` class —
# a dynamic provisioner writing to /tmp/hostpath-provisioner INSIDE the minikube container
# (host /var/lib/docker/volumes/minikube/_data/). That path is not under /mnt/minikube-mnt,
# so `minikube delete` — every cold rebuild — destroys it, and the weekly DR archive never
# contained it. The convention here is an explicit hostPath PV with storageClassName:
# manual, whose /mnt/<name> maps to host /mnt/minikube-mnt/<name>.
#
# This is invisible without a check: the app redeploys, its migrations recreate the schema,
# and everything looks healthy — you only discover it when you try to restore. Found on
# 2026-08-07: bestrentaladmin's postgres (47MB) and open-webui (890MB of chat history) had
# been running this way, bestrentaladmin being the ONLY database on the box with no backup
# at all while all four of its siblings were durable. Same mechanism that destroyed Vault's
# runtime KV before 2026-07-20.
#
# Known-benign names can be listed in PVC_EPHEMERAL_OK: some volumes genuinely hold nothing
# worth keeping (mongo/redis *config* dirs are rewritten from the manifest on every start).
PVC_EPHEMERAL_OK="${PVC_EPHEMERAL_OK:-mongodb-config mongodb-notifications-config quantstore-db-config redis-claim1}"
if have kubectl; then
  _dyn="$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.storageClassName}{"\n"}{end}' 2>/dev/null \
           | awk '$2=="standard"{print $1}')"
  if [ -z "$_dyn" ]; then
    pass "every PVC uses a durable hostPath PV (nothing on the default StorageClass)"
  else
    for _p in $_dyn; do
      _n="${_p#*/}"
      if printf '%s\n' $PVC_EPHEMERAL_OK | grep -qx "$_n"; then
        info "$_p is on the default StorageClass but is a known-disposable config volume"
      else
        fail "$_p uses the default 'standard' StorageClass — its data lives in the minikube container, is DESTROYED by minikube delete, and is in NO backup. Give it an explicit hostPath PV (storageClassName: manual, hostPath /mnt/<name>) like dyingpaleblue-postgres-pv, and migrate the data with the workload scaled to 0."
      fi
    done
  fi
fi

# --- Jenkins agent workspace volume: a 10x build-speed setting with no declarative home ---
# Jenkins agents get their /home/jenkins/agent workspace from the pod template's
# workspaceVolume. It shipped as DynamicPVCWorkspaceVolume, which provisions a FRESH PVC per
# agent. With minikube's `standard` class (volumeBindingMode: Immediate) the pod cannot
# schedule until that PVC exists, so every build paid a
#   FailedScheduling: pod has unbound immediate PersistentVolumeClaims
# plus the scheduler's exponential back-off. Measured on this box 2026-08-07, same job, same
# stage: 102.5s to provision an agent vs 4.1s when one was reused; qcguy end-to-end went
# 3.1 min -> 0.3 min (10x) after switching to EmptyDirWorkspaceVolume, and
# "Deploy K8s" 83.8s -> 2.2s. The workspace is ephemeral (fresh clone every build) and the
# PVC's reclaim policy was Delete, so the PVC was pure cost for zero benefit.
#
# Why this check exists rather than just a doc note: there is NO Jenkins Configuration-as-Code
# here. The setting lives only in JENKINS_HOME/config.xml — persisted state, not something a
# script recreates. It survives pod restarts, minikube rebuilds and DR restores, BUT any
# archive taken before 2026-08-07 still contains DynamicPVC, so restoring one silently
# reverts it. Builds get 10x slower again with nothing in any log to say why.
JENKINS_CFG="${JENKINS_CFG:-$MNT_VOL/jenkins/config.xml}"
if [ -e "$JENKINS_CFG" ]; then
  _wv="$(sudo -n grep -o 'EmptyDirWorkspaceVolume\|DynamicPVCWorkspaceVolume' "$JENKINS_CFG" 2>/dev/null | head -1)"
  [ -z "$_wv" ] && _wv="$(grep -o 'EmptyDirWorkspaceVolume\|DynamicPVCWorkspaceVolume' "$JENKINS_CFG" 2>/dev/null | head -1)"
  case "$_wv" in
    EmptyDirWorkspaceVolume)   pass "Jenkins agent workspace = emptyDir (no per-build PVC; ~98s/agent saved)" ;;
    DynamicPVCWorkspaceVolume) warn "Jenkins agent workspace is DynamicPVC — every build provisions a PVC and waits on scheduler back-off (~98s per agent, measured 10x slower end-to-end). Fix: scale deploy/jenkins to 0, in $JENKINS_CFG replace the workspaceVolume class with ...volumes.workspace.EmptyDirWorkspaceVolume plus <memory>false</memory>, scale back to 1. Jenkins rewrites config.xml on shutdown, so it MUST be stopped before editing." ;;
    *)                         info "could not read the Jenkins workspaceVolume class from $JENKINS_CFG" ;;
  esac
else
  info "$JENKINS_CFG not present — jenkins not deployed on this box?"
fi

# Root headroom. Everything above exists to keep this number healthy.
_rootuse="$(df -h --output=pcent / 2>/dev/null | tail -1 | tr -d ' %')"
if [ -n "$_rootuse" ]; then
  note "root filesystem: ${_rootuse}% used, $(df -h --output=avail / | tail -1 | tr -d ' ') free"
  if   [ "$_rootuse" -ge 90 ]; then fail "root filesystem ${_rootuse}% full — kubelet declares DiskPressure and taints the node well before 100%"
  elif [ "$_rootuse" -ge 75 ]; then warn "root filesystem ${_rootuse}% full — check what is not on its own partition"
  else pass "root filesystem ${_rootuse}% used"; fi
fi

# ---- DR manifest drift: the branch restore-scratch would clone vs what prod runs ----
# This is the quietest failure in the whole restore path. A stale branch here clones a repo
# that builds and deploys perfectly while missing whatever prod actually runs — no error at
# any point. It was wrong for `ollama` on 2026-08-04 (manifest said `main`, prod had been on
# `Claude-agent-update` for weeks), which would have restored a cluster with no ollama
# metrics shim, no router metrics and no ServiceMonitors.
if [ -r "$VR_SELFDIR/restore-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$VR_SELFDIR/restore-lib.sh" 2>/dev/null || true
  if command -v restore_repo_manifest >/dev/null 2>&1; then
    _drift=0
    while read -r _dir _url _br; do
      [ -n "$_dir" ] || continue
      [ -d "$_dir/.git" ] || continue          # not cloned yet: phase 5's job, not a drift
      _actual="$(git -C "$_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      if [ -n "$_actual" ] && [ "$_actual" != "$_br" ]; then
        warn "restore manifest drift: $(basename "$_dir") is on '$_actual' but restore-lib.sh says '$_br' — a bare-metal restore would clone the WRONG branch"
        _drift=$((_drift+1))
      fi
    done <<< "$(restore_repo_manifest)"
    [ "$_drift" -eq 0 ] && pass "restore-lib.sh branch manifest matches every cloned repo"
  fi
fi

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
