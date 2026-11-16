#!/bin/bash
####################################
#
# Keep /tmp from eating the HOST's RAM (2026-11-16).
#
####################################
#
# WHY THIS EXISTS:
#   On Ubuntu 25.10+ /tmp is a tmpfs, and systemd's stock tmp.mount sizes it at 50% of
#   RAM. On this box (61Gi after the DIMM loss) that is ~30Gi of /tmp ON TOP OF a 41Gi
#   minikube cgroup — the two together promise more memory than exists. tmpfs pages
#   cannot be dropped like page cache, only swapped, so whatever lands in /tmp pushes
#   the desktop, IntelliJ and every Claude Code session out to swap.
#
#   On 2026-11-16 the box was crawling with swap 27/29Gi and zram full. /tmp held 24Gi:
#   ~21Gi of Claude Code session scratchpads (/tmp/claude-1000/<project>/<session>/
#   scratchpad/ — Go build caches, git worktrees, tarballs from the yolo agent fleet),
#   plus 28 leaked puppeteer Chrome profiles and leftover `mktemp -d` repo copies.
#   systemd-tmpfiles' 10-day /tmp age rule never fired: a Go cache is read on every
#   build, so its atime never ages.
#
# THE FIX IS THREE LAYERS (this script owns all three):
#   1. SOURCE  — `CLAUDE_CODE_TMPDIR=$HOME/.cache/claude-tmp` in ~/.claude/settings.json
#                (verified 2026-11-16: the session dir lands at
#                <that>/claude-1000/<project>/<session>/). New Claude sessions — interactive,
#                cron-launched agents, all of them — then put their scratch on the NVMe
#                /home (500G free) instead of RAM. Sessions already running keep /tmp
#                until they restart. Deliberately NOT a global TMPDIR: that would move
#                every program's temp files and change behaviour far beyond this problem.
#   2. BOUND   — the default (cron) mode below. Anything that grows needs an automated,
#                scheduled bound, and moving scratch to disk only changes WHICH resource
#                fills. Reaps, by ALLOWLIST only (same reasoning as
#                reduce-node-docker-cache.sh: never a blanket delete):
#                  a. build-tool CACHE dirs (CACHE_NAMES) inside any Claude scratch root,
#                     idle >= CACHE_IDLE_MIN, nothing holding them open;
#                  b. allowlisted top-level /tmp litter (TMP_TOP_ALLOW) owned by us,
#                     idle >= TMP_IDLE_MIN, nothing holding it open;
#                  c. whole Claude SESSION dirs, only when ALL hold: the session is not
#                     live (~/.claude/sessions/<pid>.json with a live pid), nothing inside
#                     changed for SESSION_IDLE_DAYS, no process has a cwd/fd inside, and
#                     no git worktree inside has uncommitted changes (those are reported,
#                     never deleted — a scratchpad worktree may be someone's only copy).
#                "Idle" = the NEWEST file anywhere in the tree, not the dir's own mtime:
#                a session dir's top-level mtime can be days old while it is in use.
#   3. HARD CAP — `--install-cap` (root): a tmp.mount drop-in capping /tmp at TMP_CAP
#                (default 8G). A runaway writer then gets ENOSPC instead of swapping the
#                whole desktop out. Takes effect at the next boot even if the live
#                remount is refused because /tmp currently holds more than the cap.
#
#   3b. DISK /tmp — `--install-disk-tmp` (root; the RECOMMENDED layer 3, 2026-11-16): stop
#                /tmp being RAM at all. An fstab bind of $DISK_TMP_SRC (on the GM9000 NVMe
#                /home partition, 500G free) onto /tmp; an fstab entry for /tmp supersedes
#                the stock tmp.mount unit. Small temp files are still RAM-fast — they sit in
#                PAGE CACHE — but page cache is reclaimable (written back, then dropped)
#                where tmpfs pages can only be swapped, so a big /tmp no longer pushes the
#                desktop into swap. Bound by the reaper above + systemd-tmpfiles' 10d rule.
#                Deliberately /home, not / : filling / breaks the OS; /home filling breaks
#                only what writes there. NEEDS A REBOOT — never swapped live: GNOME/X11
#                sockets (/tmp/.X11-unix, .ICE-unix) and every running program's open temp
#                files are in the current tmpfs. Mutually exclusive with --install-cap
#                (a tmp.mount.d drop-in would apply its tmpfs Options to the bind too), so
#                each install removes the other.
#
#   Swap/memory-pressure ALERTING is NOT here: per CLAUDE.md that is Alertmanager's job
#   (kube-prometheus manifests/platform-hardware-prometheusRule.yaml, HostSwap* rules —
#   node-exporter's swap/PSI series are the host's). This script pushes to ntfy only for
#   the one thing Prometheus cannot see: the HOST's /tmp (node-exporter's /tmp is the
#   minikube node's, a different filesystem) — at most once per AP cooldown.
#
# SCHEDULE: cloud crontab, hourly. No root needed for modes other than --install-cap.
#
# Usage:
#   ./host-tmp-guard.sh                    # reap (cron mode)
#   ./host-tmp-guard.sh --dry-run          # print what WOULD be removed
#   ./host-tmp-guard.sh --status           # read-only: /tmp, swap, layers 1+3 present?
#   ./host-tmp-guard.sh --install-settings # layer 1 (as the desktop user)
#   sudo ./host-tmp-guard.sh --install-disk-tmp # layer 3b (recommended; takes effect on reboot)
#   sudo ./host-tmp-guard.sh --install-cap # layer 3, alternative: keep tmpfs, cap it
#   ./host-tmp-guard.sh --install          # 1 + 3b; 3b via `sudo -n` or prints the cmd
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-reap}"

# The desktop user — under sudo, act on the invoking user's home, not root's.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_UID="$(id -u "$TARGET_USER")"

CLAUDE_DISK_TMP="${CLAUDE_DISK_TMP:-$TARGET_HOME/.cache/claude-tmp}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$TARGET_HOME/.claude/settings.json}"
CLAUDE_SESSIONS="${CLAUDE_SESSIONS:-$TARGET_HOME/.claude/sessions}"
SCRATCH_ROOTS="${SCRATCH_ROOTS:-/tmp/claude-$TARGET_UID $CLAUDE_DISK_TMP/claude-$TARGET_UID}"

TMP_CAP="${TMP_CAP:-8G}"
DISK_TMP_SRC="${DISK_TMP_SRC:-/home/host-tmp}"     # layer 3b: /tmp on the NVMe /home partition
FSTAB="${FSTAB:-/etc/fstab}"
FSTAB_LINE="$DISK_TMP_SRC /tmp none bind,nosuid,nodev,x-systemd.requires-mounts-for=/home 0 0"
DROPIN="${DROPIN:-/etc/systemd/system/tmp.mount.d/50-size-cap.conf}"

CACHE_NAMES='gocache|go-build|gobuildcache|gomodcache|gomod-cache|gopath|pipcache|pip-cache|npm-cache|\.npm|yarn-cache|node-compile-cache|\.cache'
CACHE_IDLE_MIN="${CACHE_IDLE_MIN:-360}"           # 6h: no build touched it since
TMP_TOP_ALLOW='puppeteer_dev_chrome_profile-*|tmp.*|boot-*|yolo-parity-*|claude-chrome-screenshots*|ui-verifier-pool*|oldproto*'
TMP_IDLE_MIN="${TMP_IDLE_MIN:-1440}"              # 1 day
LITTER_DIR="${LITTER_DIR:-/tmp}"                  # overridable for tests only
SESSION_IDLE_DAYS_TMP="${SESSION_IDLE_DAYS_TMP:-2}"   # in RAM: short
SESSION_IDLE_DAYS_DISK="${SESSION_IDLE_DAYS_DISK:-14}" # on disk: generous

TMP_WARN_PCT="${TMP_WARN_PCT:-70}"                # of /tmp's size, after reaping
ALERT_COOLDOWN_S="${ALERT_COOLDOWN_S:-21600}"     # 6h
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/logs/.host-tmp-guard-state}"

DRY=0; [ "$MODE" = "--dry-run" ] && DRY=1
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# ---------------------------------------------------------------- helpers
# Minutes since the newest file anywhere under $1 changed (dir mtimes count too).
idle_min() {
  local newest
  newest=$(find "$1" -xdev -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  [ -z "$newest" ] && { echo 999999; return; }
  echo $(( ( $(date +%s) - ${newest%.*} ) / 60 ))
}

# Every path some process of ours has as cwd or an open fd, computed once per run.
OPEN_PATHS=""
load_open_paths() {
  OPEN_PATHS=$(for p in /proc/[0-9]*; do
      readlink "$p/cwd" 2>/dev/null
      for f in "$p"/fd/*; do readlink "$f" 2>/dev/null; done
    done | grep '^/' | sort -u)
}
in_use() { printf '%s\n' "$OPEN_PATHS" | grep -qF -- "$1/" || printf '%s\n' "$OPEN_PATHS" | grep -qxF -- "$1"; }

LIVE_SESSIONS=""
load_live_sessions() {
  local f pid
  for f in "$CLAUDE_SESSIONS"/*.json; do
    [ -f "$f" ] || continue
    pid=$(basename "$f" .json)
    kill -0 "$pid" 2>/dev/null || continue
    # sessionId + any formerNames[].sessionId (a renamed/resumed session).
    LIVE_SESSIONS+=" $(grep -oE '"sessionId":"[0-9a-f-]{36}"' "$f" | cut -d'"' -f4 | tr '\n' ' ')"
  done
}

dirty_worktree() {   # prints the first worktree under $1 with uncommitted changes
  local g wt
  while IFS= read -r g; do
    wt=$(dirname "$g")
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]; then echo "$wt"; return 0; fi
  done < <(find "$1" -xdev -maxdepth 6 -name .git 2>/dev/null)
  return 1
}

FREED_K=0
remove() {   # $1=path $2=reason
  local k; k=$(du -xsk "$1" 2>/dev/null | cut -f1); k=${k:-0}
  if [ "$DRY" = 1 ]; then log "WOULD remove ($2, $((k/1024))M): $1"
  else rm -rf --one-file-system -- "$1" && log "removed ($2, $((k/1024))M): $1"; fi
  FREED_K=$((FREED_K + k))
}

tmp_used_pct() { df --output=pcent /tmp | tail -1 | tr -dc '0-9'; }

# ---------------------------------------------------------------- reap
reap() {
  exec 9>"$SCRIPT_DIR/logs/.host-tmp-guard.lock" 2>/dev/null && { flock -n 9 || { log "another run holds the lock"; exit 0; }; }
  load_open_paths; load_live_sessions
  local root d proj sess days wt

  # a. build caches inside any scratch root (live sessions included — it's only cache).
  for root in $SCRATCH_ROOTS; do
    [ -d "$root" ] || continue
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      [ "$(idle_min "$d")" -ge "$CACHE_IDLE_MIN" ] || continue
      in_use "$d" && continue
      remove "$d" "cache idle>=${CACHE_IDLE_MIN}m"
    done < <(find "$root" -xdev -mindepth 2 -type d -regextype posix-extended -regex ".*/($CACHE_NAMES)" -prune 2>/dev/null)
  done

  # b. allowlisted top-level /tmp litter we own.
  shopt -s nullglob
  # read -ra, NOT `pats=($TMP_TOP_ALLOW)`: an unquoted split also GLOBS each pattern against
  # the cwd, and with nullglob on, every pattern that matches nothing there silently vanishes.
  local pats; IFS='|' read -ra pats <<< "$TMP_TOP_ALLOW"
  local pat
  for pat in "${pats[@]}"; do
    for d in "$LITTER_DIR"/$pat; do
      [ "$(stat -c %u "$d" 2>/dev/null)" = "$TARGET_UID" ] || continue
      [ "$(idle_min "$d")" -ge "$TMP_IDLE_MIN" ] || continue
      in_use "$d" && continue
      remove "$d" "tmp litter idle>=${TMP_IDLE_MIN}m"
    done
  done

  # c. whole dead Claude session dirs: <root>/<project>/<session-uuid>
  for root in $SCRATCH_ROOTS; do
    [ -d "$root" ] || continue
    case "$root" in /tmp/*) days=$SESSION_IDLE_DAYS_TMP ;; *) days=$SESSION_IDLE_DAYS_DISK ;; esac
    for proj in "$root"/*/; do
      for d in "$proj"*/; do
        d=${d%/}; sess=$(basename "$d")
        [[ "$sess" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
        case " $LIVE_SESSIONS " in *" $sess "*) continue ;; esac
        [ "$(idle_min "$d")" -ge $((days * 1440)) ] || continue
        in_use "$d" && continue
        if wt=$(dirty_worktree "$d"); then log "KEPT (uncommitted changes in $wt) — dead session $d"; continue; fi
        remove "$d" "dead session idle>=${days}d"
      done
      [ "$DRY" = 1 ] || rmdir "$proj" 2>/dev/null
    done
  done
  log "$([ "$DRY" = 1 ] && echo 'would free' || echo 'freed') $((FREED_K/1024))M; /tmp now $(tmp_used_pct)% used"
  [ "$DRY" = 1 ] || alert_if_full
}

alert_if_full() {
  local pct now last=0
  pct=$(tmp_used_pct); now=$(date +%s)
  [ -f "$STATE_FILE" ] && last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "${pct:-0}" -lt "$TMP_WARN_PCT" ]; then rm -f "$STATE_FILE"; return; fi
  [ $((now - last)) -lt "$ALERT_COOLDOWN_S" ] && return
  # shellcheck source=ntfy-lib.sh
  . "$SCRIPT_DIR/ntfy-lib.sh"
  local top; top=$(du -xsh /tmp/* /tmp/.[!.]* 2>/dev/null | sort -h | tail -3 | tr '\t\n' ' ;')
  ntfy_push "$NTFY_TOPIC_RESOURCE_CRUNCH" "prod /tmp ${pct}% full (RAM-backed)" \
    "host /tmp is ${pct}% of $(df -h --output=size /tmp | tail -1 | tr -d ' ') after reaping. Largest: ${top}. Each GB here is a GB of RAM or swap. See host-tmp-guard.sh --status." \
    high "warning"
  echo "$now" > "$STATE_FILE"
}

# ---------------------------------------------------------------- install
install_settings() {
  command -v jq >/dev/null || { echo "jq required"; return 1; }
  local cur
  mkdir -p "$CLAUDE_DISK_TMP" && chmod 700 "$CLAUDE_DISK_TMP"
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  cur=$(jq -r '.env.CLAUDE_CODE_TMPDIR // empty' "$CLAUDE_SETTINGS")
  if [ "$cur" = "$CLAUDE_DISK_TMP" ]; then echo "settings: CLAUDE_CODE_TMPDIR already $cur"; return 0; fi
  cp -p "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.pre-tmpdir" 2>/dev/null
  jq --arg v "$CLAUDE_DISK_TMP" '.env = ((.env // {}) + {CLAUDE_CODE_TMPDIR: $v})' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp.$$" \
    && mv "$CLAUDE_SETTINGS.tmp.$$" "$CLAUDE_SETTINGS"
  [ -n "${SUDO_USER:-}" ] && chown "$TARGET_USER:" "$CLAUDE_SETTINGS" "$CLAUDE_DISK_TMP"
  echo "settings: CLAUDE_CODE_TMPDIR=$CLAUDE_DISK_TMP (new Claude sessions only; running ones keep /tmp)"
}

install_cap() {
  [ "$(id -u)" = 0 ] || { echo "--install-cap needs root: sudo $0 --install-cap"; return 1; }
  if grep -qE '^[^#]*[[:space:]]/tmp[[:space:]]' "$FSTAB"; then
    echo "cap: $FSTAB already mounts /tmp (disk /tmp, layer 3b) — nothing to cap. Remove that line first to go back to tmpfs."; return 0
  fi
  mkdir -p "$(dirname "$DROPIN")"
  # Same options as the stock unit, plus size=. `%%` = a literal % in a unit file.
  printf '# host-tmp-guard.sh (STEP0): cap the RAM-backed /tmp. See that script.\n[Mount]\nOptions=mode=1777,strictatime,nosuid,nodev,size=%s,nr_inodes=1m,x-systemd.graceful-option=usrquota\n' "$TMP_CAP" > "$DROPIN"
  systemctl daemon-reload
  local used_k cap_k
  used_k=$(df -k --output=used /tmp | tail -1 | tr -dc 0-9)
  cap_k=$(numfmt --from=iec "$TMP_CAP"); cap_k=$((cap_k / 1024))
  if [ "$used_k" -lt "$cap_k" ]; then
    mount -o remount,size="$TMP_CAP" /tmp && echo "cap: /tmp remounted at $TMP_CAP"
  else
    echo "cap: drop-in written; live remount SKIPPED (/tmp holds $((used_k/1024/1024))G >= $TMP_CAP). Applies at next boot, or re-run after reaping."
  fi
}

install_disk_tmp() {
  [ "$(id -u)" = 0 ] || { echo "--install-disk-tmp needs root: sudo $0 --install-disk-tmp"; return 1; }
  mountpoint -q "$(dirname "$DISK_TMP_SRC")" || [ "$(dirname "$DISK_TMP_SRC")" = / ] \
    || { echo "disk-tmp: $(dirname "$DISK_TMP_SRC") is not a mount — refusing (would land on /)"; return 1; }
  mkdir -p "$DISK_TMP_SRC" && chown root:root "$DISK_TMP_SRC" && chmod 1777 "$DISK_TMP_SRC"
  if [ -f "$DROPIN" ]; then rm -f "$DROPIN" && echo "disk-tmp: removed tmpfs cap drop-in $DROPIN"; fi
  if grep -qxF "$FSTAB_LINE" "$FSTAB"; then
    echo "disk-tmp: fstab already has the /tmp bind"
  elif grep -qE '^[^#]*[[:space:]]/tmp[[:space:]]' "$FSTAB"; then
    echo "disk-tmp: $FSTAB has a DIFFERENT /tmp entry — refusing to guess; fix by hand:"; grep -nE '[[:space:]]/tmp[[:space:]]' "$FSTAB"; return 1
  else
    cp -p "$FSTAB" "$FSTAB.pre-disk-tmp"
    printf '# host-tmp-guard.sh (STEP0): /tmp on NVMe /home, not RAM. See that script.\n%s\n' "$FSTAB_LINE" >> "$FSTAB"
    echo "disk-tmp: appended to $FSTAB (backup $FSTAB.pre-disk-tmp)"
  fi
  systemctl daemon-reload
  findmnt -n -o SOURCE,FSTYPE /tmp | grep -q tmpfs \
    && echo "disk-tmp: active after the NEXT REBOOT (not swapped live — desktop sockets live in the current /tmp)" \
    || echo "disk-tmp: /tmp is already disk-backed"
}

status() {
  echo "/tmp:   $(df -h --output=used,size,pcent /tmp | tail -1)   (stock = 50% of RAM)"
  free -h | awk '/Swap/{print "swap:   "$3" used of "$2}'
  local cur; cur=$(jq -r '.env.CLAUDE_CODE_TMPDIR // "UNSET"' "$CLAUDE_SETTINGS" 2>/dev/null)
  echo "layer1: CLAUDE_CODE_TMPDIR=$cur  $([ "$cur" = "$CLAUDE_DISK_TMP" ] && echo OK || echo "-> ./host-tmp-guard.sh --install-settings")"
  local fst; fst=$(findmnt -n -o FSTYPE /tmp)
  if [ "$fst" != tmpfs ]; then echo "layer3: /tmp is disk-backed ($fst) OK"
  elif grep -qxF "$FSTAB_LINE" "$FSTAB" 2>/dev/null; then echo "layer3: disk /tmp configured, PENDING REBOOT"
  elif [ -f "$DROPIN" ]; then echo "layer3: tmpfs capped ($(grep -o 'size=[^,]*' "$DROPIN"))"
  else echo "layer3: /tmp is UNCAPPED tmpfs -> sudo ./host-tmp-guard.sh --install-disk-tmp  (then reboot)"; fi
  local r; for r in $SCRATCH_ROOTS; do [ -d "$r" ] && echo "scratch: $(du -xsh "$r" 2>/dev/null)"; done
}

case "$MODE" in
  reap|--dry-run)     reap ;;
  --status)           status ;;
  --install-settings) install_settings ;;
  --install-cap)      install_cap ;;
  --install-disk-tmp) install_disk_tmp ;;
  --install)          install_settings
                      if [ "$(id -u)" = 0 ]; then install_disk_tmp
                      elif sudo -n true 2>/dev/null; then sudo "$0" --install-disk-tmp
                      else echo "disk-tmp: run once yourself: sudo $0 --install-disk-tmp  (then reboot)"; fi ;;
  -h|--help)          sed -n '/^# Usage:/,/^set -uo/p' "$0" | sed '$d' ;;
  *) echo "unknown mode: $MODE (see --help)"; exit 2 ;;
esac
