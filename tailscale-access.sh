#!/bin/bash
# tailscale-access.sh — off-LAN access to the administrative vhosts (SEC-EDGE-ALLOWLIST).
#
# WHAT: installs tailscale, brings this host up as `private-cloud`, and advertises the
#       host's own PUBLIC IP as a /32 subnet route. An enrolled device (phone, laptop
#       abroad) keeps resolving jenkins/grafana.traderyolo.com to that public IP exactly
#       as before, but routes THAT ONE ADDRESS over the tailnet instead of its local
#       network. URLs unchanged, no new inbound port, and access becomes revocable per
#       device in the Tailscale console.
#
# WHY:  nginx's SEC-EDGE-ALLOWLIST (~/Ideaprojects/nginx/data/nginx/custom/http_top.conf)
#       restricts the admin vhosts to a source allowlist. A phone on cellular arrives with
#       a carrier address and gets 403. That range CANNOT be allowlisted: mobile carriers
#       use CGNAT, so it is shared by thousands of unrelated subscribers and it rotates.
#       Full rationale + rejected alternatives: nginx repo docs/edge-exposure.md §4.
#
# ⚠️ THREE THINGS THAT LOOK LIKE STYLE AND ARE NOT.
#
#    1. --accept-dns=false. Every in-cluster image pull targets
#       container-registry.traderyolo.com, which resolves to THIS host's public IP and
#       hairpins back through the router (the dominant legitimate client on the registry,
#       Vault and Jenkins vhosts). Letting Tailscale own this host's DNS risks changing how
#       that name resolves locally, and the failure mode is every pod in ImagePullBackOff —
#       a cluster-wide outage traced to a VPN client nobody would think to suspect.
#       This is asserted on EVERY run, not just at install.
#
#    2. The route must be APPROVED, and advertising is not approving. Until it is ticked in
#       the admin console (or auto-approved by ACL, see AUTOAPPROVERS below) `tailscale
#       status --json` reports PrimaryRoutes: null and enrolled devices simply do not use
#       it — with no error on either end. This script reports the distinction; it cannot
#       fix it, because approval is a control-plane action.
#
#    3. tailscaled.state IS the machine's identity, and restoring it is what makes DR
#       non-interactive. With that file in place the node comes back as the SAME machine —
#       same 100.x address, same ALREADY-APPROVED routes, no login URL, no human. Without
#       it a fresh box is a NEW machine needing browser auth and a fresh route approval.
#       backup-minikube-mnt.sh captures it; restore-scratch.sh phase 4h stages it here:
#           /mnt/minikube-backups/tailscale-state-restore/tailscaled.state
#       It is a private key. It is 0600 root and rides in the same archive as the Vault
#       root token, which is the same trust level.
#
# NOT LOAD-BEARING, deliberately: nothing on the platform may depend on this. It is an
#       operator convenience. If tailscale is dead, the cluster, the public sites and every
#       cron job are unaffected — you just cannot reach Jenkins from a train. Every caller
#       therefore invokes it best-effort and IGNORES a non-zero exit.
#
# AUTOAPPROVERS — the one manual step worth eliminating. Add to the tailnet ACL
#       (console -> Access controls) so a NEW node identity gets its route approved without
#       a human, closing the last interactive gap in DR:
#           "autoApprovers": { "routes": { "213.48.246.115/32": ["<your-login>"] } }
#       With tailscaled.state restored this never fires (the route is already approved);
#       it is the belt to that braces, for the case where the state file is lost too.
#
# USAGE:
#   sudo ./tailscale-access.sh --install    # install pkg + restore state + up + enable at boot
#   sudo ./tailscale-access.sh --ensure     # assert prefs if already installed; never installs
#        ./tailscale-access.sh --status     # read-only report (no root needed)
#   sudo ./tailscale-access.sh --uninstall  # log out, disable the unit (leaves the package)
#        ./tailscale-access.sh --dry-run --install
set -eu

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The advertised route. This is the host's PUBLIC IP — the address the vhosts resolve to
# and the address nginx's allowlist already trusts. If the ISP ever changes it, BOTH this
# and the geo block in the nginx repo must change together, or off-LAN access dies and the
# allowlist trusts a stranger. --status and verify-recovery.sh both check for that drift.
PUBLIC_IP="${TS_PUBLIC_IP:-213.48.246.115}"
TS_HOSTNAME="${TS_HOSTNAME:-private-cloud}"
# Where restore-scratch.sh phase 4h stages the node identity recovered from the DR archive.
STATE_STAGE="${TS_STATE_STAGE:-/mnt/minikube-backups/tailscale-state-restore/tailscaled.state}"
STATE_LIVE="/var/lib/tailscale/tailscaled.state"
# Fallback codename if this Ubuntu's own codename is not packaged by Tailscale yet. A brand
# new release ships before pkgs.tailscale.com has a matching suite, and the failure is an
# apt 404 mid-restore; the previous LTS repo works fine on it.
FALLBACK_CODENAME="${TS_FALLBACK_CODENAME:-noble}"

DRY_RUN=0
log() { echo "tailscale-access: $*"; }
run() { if [ "$DRY_RUN" = 1 ]; then echo "  DRYRUN> $*"; else eval "$@"; fi; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }; }

# ---------------------------------------------------------------- helpers

installed() { command -v tailscale >/dev/null 2>&1; }

# Logged in? `tailscale status` prints "Logged out." and exits non-zero when it is not.
logged_in() { tailscale status >/dev/null 2>&1; }

# Read TAILSCALE_AUTHKEY from the gitignored STEP0/.env — same reader shape as
# trigger-app-builds.sh / sync-grafana-admin.sh. Only consulted when the state file is
# ABSENT (a genuinely new machine identity); a restored state needs no key.
read_authkey() {
  local f="${TS_ENV_FILE:-$SELFDIR/.env}" v=""
  [ -r "$f" ] || return 0
  v="$(grep -E '^[[:space:]]*TAILSCALE_AUTHKEY[[:space:]]*=' "$f" 2>/dev/null | tail -1 \
        | sed -E 's/^[[:space:]]*TAILSCALE_AUTHKEY[[:space:]]*=[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')"
  printf '%s' "$v"
}

# The current public IP as the internet sees it, for drift detection. Never fatal: a box
# with no egress yet (mid-restore) must not fail here.
detect_public_ip() { curl -s -4 --max-time 8 https://ifconfig.me 2>/dev/null || echo ""; }

# --------------------------------------------------- install the package

install_package() {
  if installed; then log "package already installed ($(tailscale version 2>/dev/null | head -1))"; return 0; fi
  local codename=""
  # shellcheck source=/dev/null
  [ -r /etc/os-release ] && codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [ -n "$codename" ] || codename="$FALLBACK_CODENAME"
  # Probe before committing: an unpackaged codename 404s, and finding that out via a failed
  # `apt-get update` mid-restore is worse than falling back here.
  if ! curl -fsSL -o /dev/null --max-time 15 \
        "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" 2>/dev/null; then
    log "WARN: tailscale does not package '${codename}' — falling back to '${FALLBACK_CODENAME}'"
    codename="$FALLBACK_CODENAME"
  fi
  log "installing tailscale (ubuntu/${codename})"
  run "curl -fsSL 'https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg' -o /usr/share/keyrings/tailscale-archive-keyring.gpg"
  run "curl -fsSL 'https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list' -o /etc/apt/sources.list.d/tailscale.list"
  # Scope the update to this one list. A full `apt-get update` on a half-restored box can
  # fail on an unrelated third-party repo and take this install down with it.
  run "apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/tailscale.list -o Dir::Etc::sourceparts=/dev/null -o APT::Get::List-Cleanup=0"
  run "DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale"
}

# ------------------------------------------- restore the node identity

restore_state() {
  if [ -s "$STATE_LIVE" ]; then
    log "existing node identity present ($STATE_LIVE) — not overwriting"
    return 0
  fi
  if [ ! -s "$STATE_STAGE" ]; then
    log "no staged node identity at $STATE_STAGE (expected unless this is a DR restore)"
    return 0
  fi
  log "restoring node identity from $STATE_STAGE — this host will rejoin as the SAME machine"
  run "systemctl stop tailscaled 2>/dev/null || true"
  run "mkdir -p /var/lib/tailscale && chmod 700 /var/lib/tailscale"
  run "cp -a '$STATE_STAGE' '$STATE_LIVE'"
  run "chown root:root '$STATE_LIVE' && chmod 600 '$STATE_LIVE'"
}

# ---------------------------------------------------------- bring it up

bring_up() {
  run "systemctl enable --now tailscaled"
  # Assert prefs every run. --accept-dns=false especially: a stray `tailscale up` typed by
  # hand without it would silently arm the ImagePullBackOff failure mode described above.
  local args="--accept-dns=false --advertise-routes=${PUBLIC_IP}/32 --hostname=${TS_HOSTNAME} --reset"
  if logged_in; then
    log "already logged in — re-asserting prefs"
    run "tailscale up $args --timeout=45s </dev/null"
    return $?
  fi
  local key; key="$(read_authkey)"
  if [ -n "$key" ]; then
    log "not logged in — authenticating with TAILSCALE_AUTHKEY from .env"
    # Never echo the key. --timeout so a dead/expired key cannot hang a restore forever.
    if [ "$DRY_RUN" = 1 ]; then
      echo "  DRYRUN> tailscale up $args --authkey=<redacted> --timeout=60s"
    else
      tailscale up $args --authkey="$key" --timeout=60s </dev/null || {
        log "WARN: auth key was rejected (auth keys EXPIRE — 90 days max). Mint a new"
        log "      reusable key in the console and set TAILSCALE_AUTHKEY in STEP0/.env,"
        log "      or run: sudo tailscale up $args   and open the printed URL."
        return 1
      }
    fi
    return 0
  fi
  log "WARN: not logged in and no TAILSCALE_AUTHKEY in .env — INTERACTIVE auth needed."
  log "      Off-LAN access to jenkins/grafana stays DOWN until someone runs:"
  log "         sudo tailscale up $args"
  log "      ...and opens the printed URL. Everything else on the platform is unaffected."
  return 1
}

# --------------------------------------------------------------- status

# Route state, read from the daemon. AllowedIPs/PrimaryRoutes contain the route only once
# the control plane has APPROVED it, which is the distinction that matters (see note 2).
route_state() {
  tailscale status --json 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('unknown'); sys.exit(0)
s=d.get('Self') or {}
ip='${PUBLIC_IP}/32'
allowed = ip in (s.get('AllowedIPs') or [])
primary = ip in (s.get('PrimaryRoutes') or [])
print('approved' if (allowed and primary) else ('advertised-not-approved' if not allowed else 'partial'))
" 2>/dev/null || echo unknown
}

status() {
  echo "tailscale-access status"
  echo "  package     : $(installed && tailscale version 2>/dev/null | head -1 || echo NOT-INSTALLED)"
  echo "  daemon      : $(systemctl is-enabled tailscaled 2>/dev/null || echo not-installed) / $(systemctl is-active tailscaled 2>/dev/null || echo inactive)"
  if installed && logged_in; then
    echo "  backend     : logged in as $(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("HostName","?"))' 2>/dev/null || echo '?')"
    echo "  tailnet IP  : $(tailscale ip -4 2>/dev/null | head -1)"
    echo "  route       : ${PUBLIC_IP}/32 -> $(route_state)"
    # CorpDNS true here would mean --accept-dns=false was lost. That is the registry-hairpin
    # trap; call it out loudly rather than printing a raw boolean nobody will interpret.
    local corpdns; corpdns="$(tailscale debug prefs 2>/dev/null | grep -o '"CorpDNS": *[a-z]*' | awk '{print $2}')"
    if [ "$corpdns" = "true" ]; then
      echo "  accept-dns  : ⚠️  ENABLED — WRONG. Re-run: sudo $0 --ensure   (risks cluster-wide ImagePullBackOff)"
    else
      echo "  accept-dns  : disabled (correct — protects the container-registry hairpin)"
    fi
    echo "  peers       :"
    tailscale status 2>/dev/null | sed 's/^/                /' | head -10
  else
    echo "  backend     : LOGGED OUT (off-LAN access to the admin vhosts is DOWN)"
  fi
  # /var/lib/tailscale is 0700 root, so an unprivileged `[ -s ]` returns false whether the
  # file is missing OR merely unreadable. Reporting "ABSENT" for the latter would be a lie
  # about the one file that makes DR non-interactive — distinguish the two explicitly.
  if [ "$(id -u)" -eq 0 ]; then
    echo "  state file  : $( [ -s "$STATE_LIVE" ] && echo "present (node identity survives a reinstall)" || echo "ABSENT — DR would need interactive auth" )"
  elif sudo -n test -s "$STATE_LIVE" 2>/dev/null; then
    echo "  state file  : present (node identity survives a reinstall)"
  else
    echo "  state file  : unknown (needs root to read) — re-run: sudo $0 --status"
  fi
  local live; live="$(detect_public_ip)"
  if [ -n "$live" ] && [ "$live" != "$PUBLIC_IP" ]; then
    echo "  ⚠️  PUBLIC IP DRIFT: advertising ${PUBLIC_IP} but this host is now ${live}."
    echo "      Off-LAN access is broken AND the nginx geo block trusts a stranger."
    echo "      Fix BOTH: TS_PUBLIC_IP here, and ~/Ideaprojects/nginx/data/nginx/custom/http_top.conf"
  elif [ -n "$live" ]; then
    echo "  public IP   : $live (matches the advertised route)"
  fi
}

# ------------------------------------------------------------ uninstall

uninstall() {
  need_root
  run "tailscale down 2>/dev/null || true"
  run "tailscale logout 2>/dev/null || true"
  run "systemctl disable --now tailscaled 2>/dev/null || true"
  log "logged out and daemon disabled. Package and $STATE_LIVE left in place."
  log "Remove the machine in the Tailscale console too — that is what actually revokes it."
}

# ----------------------------------------------------------------- main

ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install)   ACTION=install ;;
    --ensure)    ACTION=ensure ;;
    --status)    ACTION=status ;;
    --uninstall) ACTION=uninstall ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '1,60p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

case "${ACTION:-status}" in
  install)
    need_root
    install_package
    restore_state
    bring_up || { log "brought up PARTIALLY — see the WARN above. Not fatal to anything else."; exit 1; }
    log "up. route ${PUBLIC_IP}/32 -> $(route_state)"
    if [ "$(route_state)" != "approved" ]; then
      log "WARN: the route is advertised but NOT APPROVED — enrolled devices will NOT use it."
      log "      Approve: console -> Machines -> ${TS_HOSTNAME} -> Edit route settings -> ${PUBLIC_IP}/32"
      log "      Or add an autoApprovers ACL so this never needs a human (see header)."
    fi
    ;;
  ensure)
    need_root
    installed || { log "not installed — nothing to ensure (run --install)"; exit 1; }
    bring_up || exit 1
    ;;
  status)    status ;;
  uninstall) uninstall ;;
esac
