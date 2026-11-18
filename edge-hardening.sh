#!/bin/bash
####################################
#
# Edge hardening for the NPM front door + host listeners (2026-11-18).
#
####################################
#
# WHY: a read-only audit of NPM's live config + the NPM access logs (predictonomy-ce / master-prod
# security investigation, 2026-11-18) found, and this session confirmed by test:
#
#  1. X-REAL-IP FORGERY BYPASSED THE ADMIN ALLOWLIST. NPM's stock nginx.conf has
#       set_real_ip_from 10/8, 172.16/12, 192.168/16;  real_ip_header X-Real-IP;
#     so any client whose TCP peer is private (a container/pod on the 5million net, the LAN, the
#     10GbE link) chooses its own $remote_addr. `geo $yolo_src_trusted` keyed on that rewritten
#     address, so a container sending `X-Real-IP: 213.48.246.115` got HTTP 200 from Vault's health
#     endpoint (no header / 8.8.8.8 -> 403). Fix: the trust decision keys on $realip_remote_addr (the
#     real TCP peer), and server_proxy.conf replaces the real-IP source for every proxy host: only
#     Cloudflare peers may supply CF-Connecting-IP.
#  2. X-FORWARDED-FOR SPOOFING. proxy.conf uses $proxy_add_x_forwarded_for, which APPENDS to a
#     client-sent XFF, so an app reading the leftmost entry sees an attacker-chosen IP. Fix:
#     `more_clear_input_headers X-Forwarded-For` (server_proxy.conf) so the upstream sees exactly
#     one entry — the real client. (proxy_set_header at server level cannot override NPM's
#     location-level one; clearing the incoming header is what works. Proven in a throwaway
#     container from the same image before it touched prod.)
#  3. CLOUDFLARE BYPASS. qcguy.com & co. sit behind Cloudflare but the origin answered anyone who
#     sent the Host header directly (verified 200), skipping CF's WAF/rate-limits, and their logs
#     recorded only Cloudflare IPs. Fix: real-IP from CF-Connecting-IP (CF peers only) + an ORIGIN
#     LOCK: a CF-fronted vhost answers 403 unless the true peer is Cloudflare, trusted (hairpin/LAN,
#     which includes the platform's own pulls) or an ACME challenge.
#
# THIS SCRIPT OWNS THE PARTS THAT CHANGE OVER TIME OR LIVE OUTSIDE THE NGINX REPO:
#   --refresh-cf   regenerate custom/cloudflare_realip.conf + cloudflare_geo.conf from Cloudflare's
#                  published ranges. Cloudflare changes these rarely but a STALE list is the one way
#                  this hardening can take sites down (new edge range -> origin lock 403s real
#                  visitors), so it is on a cron (cloud-crontab) and fails safe: bad fetch, bad
#                  validation or a failing `nginx -t` leaves the previous files in place.
#   --install-rpcbind (root)  firewall rpcbind :111 to loopback + LAN + 10GbE (see below).
#   --install-fail2ban (root) ban repeat scanners of secret paths (see below).
#   --ensure-default-444      make NPM's default site close the connection (unknown Host / bare IP).
#   --status       read-only report of every layer; exit 1 on a missing/broken layer.
# The static nginx directives live in the nginx repo: data/nginx/custom/{http_top,server_proxy}.conf.
#
# rpcbind (:111) — WHY NOT DISABLED, AND WHY A FIREWALL RATHER THAN A BIND: the DR off-site backup
# mount /mnt/wdcloud is NFSv3 (`vers=3`, local_lock=none, statd registered), which needs a working
# LOCAL rpcbind — disabling it would silently break the weekly off-site backup. Restricting what it
# LISTENS on does not work: a systemd rpcbind.socket drop-in was tried and rpcbind still opens its own
# wildcard sockets (0.0.0.0 and [::] stayed open), and `rpcbind -h <LAN ip>` would make its bind depend
# on that address existing at early boot. So the guard is an iptables chain on INPUT:
# EDGE-RPCBIND accepts lo + the house LAN + the 10GbE link and DROPs everything else to :111 (tailnet,
# docker bridges, anything new). It only matches INBOUND requests to our port 111 — the NAS's replies
# to OUR lookups have source port 111 and are untouched. Applied by a systemd unit ordered before the
# network comes up; NOT iptables-persistent (same reason as loki-nodeport-guard.sh).
#
# fail2ban (npm-scanner jail): bans an IP that requests >=3 secret/exploit paths (/.env, /.git/, /.aws/,
# phpinfo, wp-login ...) within 10 min, for 24 h, FROM THE NPM ACCESS LOGS. Design points that matter:
#   * Ban rule goes in DOCKER-USER, never INPUT — NPM is a container, so this traffic is FORWARDED and an
#     INPUT rule would match nothing (same asymmetry as loki-nodeport-guard.sh).
#   * NEVER ban Cloudflare, ourselves, the LAN, the docker bridges or the tailnet. This is not hypothetical:
#     dry-running the filter against the pre-fix logs, 122 of 234 would-be-banned IPs were Cloudflare EDGE
#     addresses (those logs predate the real-IP fix), i.e. a naive jail would have banned Cloudflare and
#     taken qcguy & co. down. `ignorecommand` (yolo-f2b-ignore) checks the GENERATED cloudflare_geo.conf
#     live (so a --refresh-cf is picked up with no root) and FAILS SAFE: if that list cannot be read it
#     never bans.
#   * Match on the URI, not the status: the SPAs answer 200 for unknown paths, so "404 on /.env" would miss.
#   * Bounded: 24 h bans, sqlite purged after 7 d. The stock Debian sshd jail is switched OFF — out of scope.
#   * Cloudflare-fronted traffic logs the REAL client (real-IP fix), which iptables cannot ban (the packet
#     source is Cloudflare) — those entries are inert by construction, never harmful.
#
# Files are written THROUGH `docker exec` because custom/ is root-owned (the container wrote it).
####################################
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPM="${NPM_CONTAINER:-nginx-proxy-manager}"
CUSTOM_HOST="${NPM_CUSTOM_HOST:-/home/cloud/Ideaprojects/nginx/data/nginx/custom}"
CUSTOM_CTR=/data/nginx/custom
CF_V4_URL="${CF_V4_URL:-https://www.cloudflare.com/ips-v4}"
CF_V6_URL="${CF_V6_URL:-https://www.cloudflare.com/ips-v6}"
CF_MAX_AGE_DAYS="${CF_MAX_AGE_DAYS:-45}"
RPC_ALLOW="${EDGE_RPC_ALLOW:-192.168.50.0/24 10.10.10.0/30}"   # + loopback, always
RPC_CHAIN=EDGE-RPCBIND
RPC_STABLE=/usr/local/sbin/yolo-edge-rpcbind-guard.sh
RPC_UNIT=yolo-edge-rpcbind-guard.service
F2B_IGNORE=/usr/local/sbin/yolo-f2b-ignore
F2B_LOGS="${NPM_LOGS_HOST:-/home/cloud/Ideaprojects/nginx/data/logs}"
DRY=0; MODE="${1:---status}"
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; done
say() { printf '%s\n' "$*"; }
# ntfy (defensive: a box without the lib still works, just silently). Only used by --notify (cron).
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/ntfy-lib.sh" ] && . "$SCRIPT_DIR/ntfy-lib.sh" 2>/dev/null
NOTIFY=0; for a in "$@"; do [ "$a" = "--notify" ] && NOTIFY=1; done

npm_up() { docker inspect -f '{{.State.Running}}' "$NPM" 2>/dev/null | grep -q true; }
npm_put() { docker exec -i "$NPM" sh -c "cat > $CUSTOM_CTR/$1"; }          # $1 = filename, stdin = content
npm_get() { docker exec "$NPM" sh -c "cat $CUSTOM_CTR/$1 2>/dev/null"; }
npm_test() { docker exec "$NPM" nginx -t 2>&1; }
npm_reload() { docker exec "$NPM" nginx -s reload 2>&1; }

# ---- Cloudflare ranges -------------------------------------------------------------------------
valid_v4() {
  grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' <<<"$1" || return 1
  local o; for o in $(tr './' '  ' <<<"${1%/*}"); do [ "$((10#$o))" -le 255 ] || return 1; done
}
valid_v6() { grep -Eq '^[0-9a-fA-F:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$' <<<"$1" && [[ "$1" == *:* ]]; }

render_realip() { # stdin: one CIDR per line
  echo "# GENERATED by STEP0/edge-hardening.sh --refresh-cf — do not edit. Cloudflare ranges, $(date -u +%F)."
  echo "# Included from server_proxy.conf (server context): only these peers may supply CF-Connecting-IP."
  while read -r c; do echo "set_real_ip_from $c;"; done
}
render_geo() {
  echo "# GENERATED by STEP0/edge-hardening.sh --refresh-cf — do not edit. Cloudflare ranges, $(date -u +%F)."
  echo "# Included from the \$yolo_peer_is_cf geo block in http_top.conf (origin lock)."
  while read -r c; do echo "$c 1;"; done
}
data_lines() { grep -vE '^\s*(#|$)'; }

refresh_cf() {
  npm_up || { say "FAIL: $NPM is not running"; return 1; }
  local v4 v6 c all bad=0 n4 n6
  v4=$(curl -fsS -m 25 "$CF_V4_URL" 2>/dev/null) || { say "FAIL: could not fetch $CF_V4_URL (previous files kept)"; return 1; }
  v6=$(curl -fsS -m 25 "$CF_V6_URL" 2>/dev/null) || { say "FAIL: could not fetch $CF_V6_URL (previous files kept)"; return 1; }
  n4=0; n6=0
  while read -r c; do [ -z "$c" ] && continue; if valid_v4 "$c"; then n4=$((n4+1)); else say "FAIL: bad v4 line [$c]"; bad=1; fi; done <<<"$v4"
  while read -r c; do [ -z "$c" ] && continue; if valid_v6 "$c"; then n6=$((n6+1)); else say "FAIL: bad v6 line [$c]"; bad=1; fi; done <<<"$v6"
  # Sanity floor: Cloudflare publishes 15 v4 / 7 v6. A short list would 403 real visitors on origin lock.
  [ "$n4" -ge 10 ] && [ "$n6" -ge 5 ] || { say "FAIL: implausibly short list (v4=$n4 v6=$n6) — previous files kept"; return 1; }
  [ "$bad" = 0 ] || { say "FAIL: validation errors — previous files kept"; return 1; }
  all=$(printf '%s\n%s\n' "$v4" "$v6" | grep -E '.' | sort -u)
  local new_r new_g old_r old_g
  new_r=$(render_realip <<<"$all"); new_g=$(render_geo <<<"$all")
  old_r=$(npm_get cloudflare_realip.conf); old_g=$(npm_get cloudflare_geo.conf)
  if [ "$(data_lines <<<"$new_r")" = "$(data_lines <<<"$old_r")" ] && [ "$(data_lines <<<"$new_g")" = "$(data_lines <<<"$old_g")" ] && [ -n "$old_r" ]; then
    say "cloudflare ranges unchanged ($n4 v4, $n6 v6)"; return 0; fi
  if [ $DRY = 1 ]; then say "DRYRUN> would write cloudflare_realip.conf + cloudflare_geo.conf ($n4 v4, $n6 v6), nginx -t, reload"; return 0; fi
  # write, test, reload — revert BOTH files on any failure (a broken file left on disk takes every site down)
  printf '%s\n' "$new_r" | npm_put cloudflare_realip.conf && printf '%s\n' "$new_g" | npm_put cloudflare_geo.conf || { say "FAIL: write"; return 1; }
  if t=$(npm_test); then npm_reload >/dev/null && say "cloudflare ranges updated ($n4 v4, $n6 v6) and nginx reloaded"
  else
    say "FAIL: nginx -t rejected the new ranges — reverting. $t"
    if [ -n "$old_r" ]; then printf '%s\n' "$old_r" | npm_put cloudflare_realip.conf; printf '%s\n' "$old_g" | npm_put cloudflare_geo.conf
    else docker exec "$NPM" sh -c "rm -f $CUSTOM_CTR/cloudflare_realip.conf $CUSTOM_CTR/cloudflare_geo.conf"; fi
    return 1
  fi
}

# ---- rpcbind guard (root) ----------------------------------------------------------------------
need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }; }
rpc_apply() {
  need_root
  iptables -N "$RPC_CHAIN" 2>/dev/null || true
  iptables -F "$RPC_CHAIN"
  iptables -A "$RPC_CHAIN" -i lo -j RETURN
  local n; for n in $RPC_ALLOW; do iptables -A "$RPC_CHAIN" -s "$n" -j RETURN; done
  iptables -A "$RPC_CHAIN" -j DROP
  local pr; for pr in tcp udp; do
    iptables -C INPUT -p "$pr" --dport 111 -j "$RPC_CHAIN" 2>/dev/null || iptables -I INPUT 1 -p "$pr" --dport 111 -j "$RPC_CHAIN"
  done
  say "rpcbind guard applied (allow: lo $RPC_ALLOW; everything else to :111 dropped)"
}
rpc_remove() {
  need_root
  local pr; for pr in tcp udp; do while iptables -C INPUT -p "$pr" --dport 111 -j "$RPC_CHAIN" 2>/dev/null; do iptables -D INPUT -p "$pr" --dport 111 -j "$RPC_CHAIN"; done; done
  iptables -F "$RPC_CHAIN" 2>/dev/null; iptables -X "$RPC_CHAIN" 2>/dev/null; true
}
rpc_install() {
  need_root
  install -m 0755 "${BASH_SOURCE[0]}" "$RPC_STABLE"
  rm -f /etc/systemd/system/rpcbind.socket.d/10-restrict-listen.conf   # an earlier, ineffective attempt
  rmdir /etc/systemd/system/rpcbind.socket.d 2>/dev/null || true
  cat > "/etc/systemd/system/$RPC_UNIT" <<EOC
[Unit]
# Managed by STEP0/edge-hardening.sh --install-rpcbind. See that file for why this is a firewall rule.
Description=Restrict rpcbind :111 to loopback + LAN (STEP0 edge hardening)
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RPC_STABLE --apply-rpcbind-guard
ExecStop=$RPC_STABLE --remove-rpcbind-guard

[Install]
WantedBy=multi-user.target
EOC
  systemctl daemon-reload; systemctl enable "$RPC_UNIT" >/dev/null 2>&1; systemctl daemon-reload
  systemctl daemon-reload; systemctl restart rpcbind.socket 2>/dev/null || true
  systemctl restart "$RPC_UNIT" && say "installed + started $RPC_UNIT"
}

# ---- default site -> 444 -----------------------------------------------------------------------------
# NPM regenerates /data/nginx/default_host/site.conf ONLY through its own setting.update() (a DB edit +
# restart does NOT — tried 2026-11-18), so call that function in-process: it patches the row, regenerates,
# runs nginx -t, reloads, and cleans up after itself on failure. No restart, no blip. Idempotent.
ensure_default_444() {
  npm_up || { say "FAIL: $NPM is not running"; return 1; }
  if docker exec "$NPM" grep -q 'return 444' /data/nginx/default_host/site.conf 2>/dev/null; then say "default site already 444"; return 0; fi
  [ $DRY = 1 ] && { say "DRYRUN> would set NPM default-site=444 via internalSetting.update"; return 0; }
  docker exec "$NPM" sh -c 'cd /app && timeout 60 node --input-type=module -e "
import internalSetting from \"./internal/setting.js\";
try { await internalSetting.update({ can: async () => true }, { id: \"default-site\", value: \"444\" }); process.exit(0); }
catch (e) { console.log(\"ERROR\", e && e.message); process.exit(1); }" >/dev/null 2>&1' \
    && docker exec "$NPM" grep -q 'return 444' /data/nginx/default_host/site.conf && say "default site set to 444" \
    || { say "FAIL: could not set default site to 444"; return 1; }
}

# ---- fail2ban (root) ---------------------------------------------------------------------------------
f2b_install() {
  need_root
  command -v fail2ban-client >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null || { say "FAIL: apt install fail2ban"; return 1; }
  install -m 0755 "$SCRIPT_DIR/edge-hardening/yolo-f2b-ignore" "$F2B_IGNORE"
  install -m 0644 "$SCRIPT_DIR/edge-hardening/npm-scanner.filter.conf" /etc/fail2ban/filter.d/npm-scanner.conf
  sed "s#@LOGDIR@#$F2B_LOGS#g" "$SCRIPT_DIR/edge-hardening/npm-scanner.jail.local" > /etc/fail2ban/jail.d/npm-scanner.local
  chmod 0644 /etc/fail2ban/jail.d/npm-scanner.local
  grep -q '^dbpurgeage' /etc/fail2ban/fail2ban.local 2>/dev/null || printf '[Definition]\ndbpurgeage = 7d\n' >> /etc/fail2ban/fail2ban.local
  mkdir -p /etc/systemd/system/fail2ban.service.d
  cat > /etc/systemd/system/fail2ban.service.d/10-after-docker.conf <<'EOF'
# DOCKER-USER must exist when the ban action starts, and Docker rebuilds its chains on every daemon restart.
[Unit]
After=docker.service
PartOf=docker.service
EOF
  systemctl daemon-reload
  fail2ban-client -t >/dev/null 2>&1 || { say "FAIL: fail2ban config test failed:"; fail2ban-client -t 2>&1 | tail -5; return 1; }
  systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban
  sleep 2; fail2ban-client status npm-scanner >/dev/null 2>&1 && say "fail2ban npm-scanner jail active" || { say "FAIL: jail did not start"; return 1; }
}

# ---- status (read-only; PASS/WARN/FAIL lines, consumed by verify-recovery.sh) ----------------------------
cf_age_days() { local m; m=$(docker exec "$NPM" stat -c %Y "$CUSTOM_CTR/cloudflare_geo.conf" 2>/dev/null) || return 1; echo $(( ( $(date +%s) - m ) / 86400 )); }
cf_vhosts() { awk '/^map \$host \$yolo_cf_vhost \{/{f=1;next} f&&/^\}/{exit} f&&$2=="1;"{print $1}' "$CUSTOM_HOST/http_top.conf" 2>/dev/null; }
in_cf() { python3 -I -c '
import sys,ipaddress
nets=[ipaddress.ip_network(l.split()[0]) for l in open(sys.argv[1]) if l[:1].isdigit() or l[:1] in "23abcdef"]
a=ipaddress.ip_address(sys.argv[2]); sys.exit(0 if any(a in n for n in nets if n.version==a.version) else 1)' "$CUSTOM_HOST/cloudflare_geo.conf" "$1" 2>/dev/null; }

do_status() {
  local bad=0 p t age h ip eff
  P() { say "PASS $*"; }; Fl() { say "FAIL $*"; bad=1; }; Wn() { say "WARN $*"; }
  if ! npm_up; then Fl "$NPM is not running"; return 1; fi
  # 1) admin port not published on every interface
  p=$(docker port "$NPM" 81/tcp 2>/dev/null | tr '\n' ' ')
  if [ -z "$p" ]; then P "NPM admin :81 not published at all"
  elif grep -qE '(^|[ ])(0\.0\.0\.0|\[::\]):81' <<<"$p"; then Fl "NPM admin :81 published on a wildcard address ($p) — compose must say '127.0.0.1:81:81'"
  else P "NPM admin :81 bound to loopback only ($p)"; fi
  # 2) effective nginx config carries the real-IP / XFF / trust fixes (what NPM actually loaded, not the files)
  eff=$(docker exec "$NPM" nginx -T 2>/dev/null)
  grep -q 'more_clear_input_headers X-Forwarded-For' <<<"$eff" && P "X-Forwarded-For cleared at the edge (no XFF spoofing)" || Fl "X-Forwarded-For is NOT cleared at the edge (server_proxy.conf)"
  grep -q 'real_ip_header CF-Connecting-IP' <<<"$eff" && P "real-IP source = CF-Connecting-IP (Cloudflare peers only)" || Fl "server-level real_ip_header CF-Connecting-IP missing (X-Real-IP forgery possible)"
  grep -q 'geo \$realip_remote_addr \$yolo_src_trusted' <<<"$eff" && P "admin allowlist keys on the TCP peer (\$realip_remote_addr)" || Fl "geo \$yolo_src_trusted is not keyed on \$realip_remote_addr — admin allowlist forgeable"
  # 3) Cloudflare range files: present, plausible, fresh
  t=$(npm_get cloudflare_geo.conf | grep -cE '^[0-9a-fA-F:.]+/[0-9]+ 1;')
  if [ "${t:-0}" -ge 15 ]; then P "cloudflare ranges present ($t CIDRs)"; else Fl "cloudflare_geo.conf missing/short ($t CIDRs) — ./edge-hardening.sh --refresh-cf"; fi
  if age=$(cf_age_days); then [ "$age" -le "$CF_MAX_AGE_DAYS" ] && P "cloudflare ranges fresh (${age}d old)" || Wn "cloudflare ranges ${age}d old (> ${CF_MAX_AGE_DAYS}d) — the weekly cron is not refreshing them"; fi
  # 4) every origin-locked vhost still resolves to Cloudflare (a site that LEFT Cloudflare 403s for everyone)
  for h in $(cf_vhosts); do
    ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$ip" ]; then Wn "origin-locked vhost $h does not resolve"
    elif in_cf "$ip"; then P "origin-locked $h -> $ip (Cloudflare)"
    else Fl "origin-locked $h resolves to $ip which is NOT Cloudflare — it is 403ing real visitors; remove it from \$yolo_cf_vhost in http_top.conf"; fi
  done
  # 5) default site closes the connection
  docker exec "$NPM" grep -q 'return 444' /data/nginx/default_host/site.conf 2>/dev/null && P "default site = 444 (unknown Host/bare IP closed)" || Wn "default site is not 444 — ./edge-hardening.sh --ensure-default-444"
  # 6) the live forge probe, from a genuinely untrusted vantage: the minikube node is a PRIVATE PEER on the 5million net
  if docker exec minikube true 2>/dev/null; then
    t=$(docker exec minikube curl -sk -m 8 -o /dev/null -w '%{http_code}' --resolve vault.traderyolo.com:443:172.16.238.10 -H 'X-Real-IP: 213.48.246.115' https://vault.traderyolo.com/v1/sys/health 2>/dev/null)
    [ "$t" = 403 ] && P "X-Real-IP forgery from a private peer is refused (403)" || Fl "X-Real-IP forgery from a private peer got HTTP ${t:-none} (expected 403) — admin allowlist bypassable"
  else Wn "minikube node not up — forge probe skipped"; fi
  # 7) host: rpcbind guard + fail2ban
  systemctl is-active --quiet "$RPC_UNIT" && P "rpcbind guard unit active" || Fl "rpcbind guard unit not active — sudo ./edge-hardening.sh --install-rpcbind"
  if [ "$(id -u)" = 0 ]; then iptables -C INPUT -p tcp --dport 111 -j "$RPC_CHAIN" 2>/dev/null && P "rpcbind :111 INPUT jump present" || Fl "rpcbind :111 INPUT jump missing"; fi
  if systemctl is-active --quiet fail2ban; then
    P "fail2ban active"
    [ "$(id -u)" = 0 ] && { fail2ban-client status npm-scanner >/dev/null 2>&1 && P "fail2ban npm-scanner jail running" || Fl "fail2ban npm-scanner jail NOT running"; }
  else Fl "fail2ban not active — sudo ./edge-hardening.sh --install-fail2ban"; fi
  [ -x "$F2B_IGNORE" ] && "$F2B_IGNORE" 104.16.0.1 && P "fail2ban never bans Cloudflare (ignore check)" || Fl "yolo-f2b-ignore missing or would ban a Cloudflare address"
  return $bad
}

install_all() { # root: host layers + best-effort nginx-side ensures
  need_root
  rpc_install || return 1
  f2b_install || return 1
  if npm_up; then refresh_cf || true; ensure_default_444 || true; else say "NPM not up yet — run '$0 --refresh-cf' and '--ensure-default-444' after it starts (the nginx repo already carries the committed conf + generated CF files)"; fi
}

# test seam: tests/test-edge-hardening.sh sources this file for the pure helpers
[ "${EDGE_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

case "$MODE" in
  --refresh-cf)
    out=$(refresh_cf 2>&1); rc=$?; echo "$out"
    age=$(cf_age_days 2>/dev/null || echo 0)
    if [ "$NOTIFY" = 1 ] && { [ $rc -ne 0 ] || [ "${age:-0}" -gt "$CF_MAX_AGE_DAYS" ]; } && command -v ntfy_push >/dev/null 2>&1; then
      ntfy_push "$NTFY_TOPIC_RESOURCE_CRUNCH" "Cloudflare ranges: refresh $( [ $rc -ne 0 ] && echo FAILED || echo STALE ) on private-cloud" \
        "edge-hardening --refresh-cf rc=$rc, files ${age}d old. The origin lock on the Cloudflare-fronted sites depends on this list; a stale list can 403 real visitors. Run: STEP0/edge-hardening.sh --refresh-cf" high warning
    fi
    exit $rc;;
  --install) install_all;;
  --status) do_status;;
  --install-rpcbind) rpc_install;;
  --install-fail2ban) f2b_install;;
  --ensure-default-444) ensure_default_444;;
  --apply-rpcbind-guard) rpc_apply;;
  --remove-rpcbind-guard) rpc_remove;;
  *) echo "usage: $0 --install | --status | --refresh-cf [--notify] | --install-rpcbind | --install-fail2ban | --ensure-default-444 | --dry-run" >&2; exit 2;;
esac
