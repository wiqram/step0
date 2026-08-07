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
if crontab -l 2>/dev/null | grep -q alerting-pipeline-watch; then pass "alerting-pipeline watchdog cron present (ntfy yolo-private-cloud-resource-crunch)"
else warn "alerting-pipeline watchdog NOT in the cloud crontab — re-run ./install-cron.sh"; fi

# Canonical-vs-live crontab drift. install-cron.sh installs cron/cloud-crontab VERBATIM,
# so that file — not the live crontab — is what a bare-metal restore reproduces. Drift is
# one-directional and silent: fixes get made with `crontab -e` and never written back, and
# nothing notices until a restore quietly reverts them. Found 2026-08-04 with the canonical
# copy still carrying superseded Predictonomy schedules AND the YOLO agent still ENABLED
# after it had been deliberately paused — install-cron.sh would have resurrected it.
# Compares SCHEDULE LINES only: comments drifting apart is untidy, not dangerous.
if [ -r "$VR_SELFDIR/cron/cloud-crontab" ]; then
  if diff -q <(crontab -l 2>/dev/null | grep -vE '^\s*#|^\s*$') \
             <(grep -vE '^\s*#|^\s*$' "$VR_SELFDIR/cron/cloud-crontab") >/dev/null 2>&1
  then
    pass "cloud crontab matches cron/cloud-crontab (install-cron.sh is safe to re-run)"
  else
    warn "cloud crontab has DRIFTED from cron/cloud-crontab — a restore would revert the live schedule. Reconcile with: crontab -l > cron/cloud-crontab (then commit), or re-run ./install-cron.sh to adopt the committed one"
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

  # ---- Alertmanager is actually WIRED to a notifier (architecture.md §7b) ----------
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

# ============================== 5. HOST STORAGE LAYOUT ==============================
section "5. Host storage layout (GM9000-MIGRATION.md §1.2 — partitions are chosen in the INSTALLER)"

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
