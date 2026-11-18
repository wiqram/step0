#!/bin/bash
# tests/test-edge-hardening.sh — pure checks for edge-hardening.sh and its fail2ban files. Needs no root,
# no docker, no running NPM. The fail2ban-regex section is skipped when fail2ban is not installed.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; F=0
ok()   { echo "ok:   $*"; }
bad()  { echo "FAIL: $*"; F=1; }
eq()   { [ "$1" = "$2" ] && ok "$3" || bad "$3 — got [$1] want [$2]"; }

bash -n "$D/edge-hardening.sh" && ok "bash -n edge-hardening.sh" || bad "bash -n"

# --- pure helpers (sourced through the lib-only seam) --------------------------------------------------
NPM_CUSTOM_HOST="$T/custom" ; mkdir -p "$T/custom"
# shellcheck disable=SC1090
EDGE_LIB_ONLY=1 NPM_CUSTOM_HOST="$T/custom" source "$D/edge-hardening.sh"
for c in 173.245.48.0/20 104.16.0.0/13 131.0.72.0/22 1.2.3.4/32; do valid_v4 "$c" && ok "valid_v4 accepts $c" || bad "valid_v4 rejects $c"; done
for c in 1.2.3.4 1.2.3.4/33 999.1.1.1/24 "1.2.3/24" "; rm -rf /" 2400:cb00::/32 ""; do valid_v4 "$c" && bad "valid_v4 accepted [$c]" || ok "valid_v4 rejects [$c]"; done
for c in 2400:cb00::/32 2a06:98c0::/29 2c0f:f248::/32; do valid_v6 "$c" && ok "valid_v6 accepts $c" || bad "valid_v6 rejects $c"; done
for c in 2400:cb00:: 2400:cb00::/129 1.2.3.0/24 "x/32" "2400:cb00::/32;evil"; do valid_v6 "$c" && bad "valid_v6 accepted [$c]" || ok "valid_v6 rejects [$c]"; done
printf '173.245.48.0/20\n2400:cb00::/32\n' > "$T/in"
eq "$(render_realip < "$T/in" | grep -c '^set_real_ip_from ')" 2 "render_realip emits one directive per CIDR"
eq "$(render_geo < "$T/in" | grep -c ' 1;$')" 2 "render_geo emits one geo line per CIDR"
eq "$(render_realip < "$T/in" | data_lines | head -1)" "set_real_ip_from 173.245.48.0/20;" "data_lines ignores the dated header (idempotency compares data only)"

# --- cf_vhosts parses the explicit origin-lock list out of http_top.conf --------------------------------
cat > "$T/custom/http_top.conf" <<'EOC'
map $host $yolo_admin_vhost {
    default 0;
    vault.traderyolo.com 1;
}
map $host $yolo_cf_vhost {
    default                     0;
    qcguy.com                   1;
    www.qcguy.com               1;
}
map $host $other { default 0; x.com 1; }
EOC
eq "$(cf_vhosts | tr '\n' ' ')" "qcguy.com www.qcguy.com " "cf_vhosts reads only the \$yolo_cf_vhost map"
eq "$(NPM_CUSTOM_HOST="$D/../nginx/data/nginx/custom" bash -c "EDGE_LIB_ONLY=1 source '$D/edge-hardening.sh'; cf_vhosts" 2>/dev/null | wc -l | tr -d ' ')" "$( [ -f "$D/../nginx/data/nginx/custom/http_top.conf" ] && echo 6 || echo 0)" "the real http_top.conf lists 6 locked vhosts (0 if the nginx repo is absent)"

# --- yolo-f2b-ignore: never bans Cloudflare/ours; FAILS SAFE when the CF list is unreadable -------------
printf '# generated\n104.16.0.0/13 1;\n2606:4700::/32 1;\n' > "$T/cf.conf"
sed "s#^CF = .*#CF = \"$T/cf.conf\"#" "$D/edge-hardening/yolo-f2b-ignore" > "$T/ign"; chmod +x "$T/ign"
chk() { "$T/ign" "$1" >/dev/null 2>&1; echo $?; }
eq "$(chk 104.16.5.5)"   0 "ignore: a Cloudflare v4 edge IP is never banned"
eq "$(chk 2606:4700::1)" 0 "ignore: a Cloudflare v6 edge IP is never banned"
eq "$(chk 213.48.246.115)" 0 "ignore: our own public IP is never banned"
eq "$(chk 192.168.50.9)" 0 "ignore: the LAN is never banned"
eq "$(chk 172.16.238.5)" 0 "ignore: docker networks are never banned"
eq "$(chk 100.122.228.127)" 0 "ignore: the tailnet is never banned"
eq "$(chk 45.148.10.125)" 1 "ignore: a real scanner IP IS bannable"
eq "$(chk 2a00:1450::1)" 1 "ignore: a non-CF v6 address is bannable"
eq "$(chk not-an-ip)" 0 "ignore: garbage input fails SAFE (no ban)"
sed "s#^CF = .*#CF = \"$T/missing.conf\"#" "$D/edge-hardening/yolo-f2b-ignore" > "$T/ign2"; chmod +x "$T/ign2"
"$T/ign2" 45.148.10.125 >/dev/null 2>&1; eq "$?" 0 "ignore: unreadable Cloudflare list => NEVER ban (fail-safe)"
: > "$T/cf.conf"; "$T/ign" 45.148.10.125 >/dev/null 2>&1; eq "$?" 0 "ignore: EMPTY Cloudflare list => NEVER ban (fail-safe)"

# --- fail2ban filter: true positives caught, legit app paths never match --------------------------------
if command -v fail2ban-regex >/dev/null 2>&1; then
  m() { fail2ban-regex "[18/Nov/2026:21:10:00 +0000] - 200 200 - GET https x.com \"$1\" [Client 203.0.113.50] [Length 1]" "$D/edge-hardening/npm-scanner.filter.conf" 2>&1 | grep -E '^Lines:' | sed -E 's/.*([0-9]) matched.*/\1/'; }
  for u in /.env /.env.production /api/.env /backend/.env /.git/config /.aws/credentials /phpinfo.php /wp-login.php /wp-admin/x /xmlrpc.php /SDK/webLanguage /admin/.env /actuator/env /vendor/phpunit/x /cgi-bin/x; do eq "$(m "$u")" 1 "filter catches $u"; done
  for u in /_next/static/chunks/dev.env.js /countries/fji/demographics '/ghost/api/content/posts/?include=env' /assets/environment.js /api/v1/git/commits '/v1/market/session?exchange=XNYS' /robots.txt /actuator/health /favicon.ico /.well-known/acme-challenge/abc; do eq "$(m "$u")" 0 "filter ignores legit $u"; done
  c1=$(fail2ban-regex '203.0.113.51 - - [18/Nov/2026:21:10:00 +0000] "GET /.git/config HTTP/1.1" 404 150 "-" "curl/8" "-"' "$D/edge-hardening/npm-scanner.filter.conf" 2>&1 | grep -E '^Lines:' | sed -E 's/.*([0-9]) matched.*/\1/')
  eq "$c1" 1 "filter catches the default-host (combined-format) line"
else echo "skip: fail2ban-regex not installed (filter tests)"; fi

[ $F = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
