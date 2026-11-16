#!/bin/bash
# tests/test-host-tmp-guard.sh — the /tmp reaper's delete rules, on a throwaway fixture tree.
#
# The reaper deletes things, so what matters most is what it must NOT delete: a live
# session's work, a dead session with uncommitted worktree changes, a recently-used cache,
# anything outside the allowlist, anything another process holds open. Every one of those is
# a fixture below, next to the things it SHOULD reap. Nothing outside $FX is touched:
# SCRATCH_ROOTS / LITTER_DIR / CLAUDE_SESSIONS / STATE_FILE all point into it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HTG_SCRIPT:-$HERE/../host-tmp-guard.sh}"
FX="$(mktemp -d)"; trap 'kill $HOLD 2>/dev/null; rm -rf "$FX"' EXIT
fail=0
ok()  { if [ -e "$1" ]; then echo "ok: kept $2"; else echo "FAIL: deleted $2 ($1)"; fail=1; fi; }
gone(){ if [ -e "$1" ]; then echo "FAIL: did not reap $2 ($1)"; fail=1; else echo "ok: reaped $2"; fi; }
old() { find "$1" -exec touch -h -d "$2" {} + ; }

R="$FX/disk/claude-1000"; L="$FX/litter"; S="$FX/sessions"; mkdir -p "$R/-proj" "$L" "$S"
LIVE=11111111-1111-4111-8111-111111111111; DEAD=22222222-2222-4222-8222-222222222222
DIRTY=33333333-3333-4333-8333-333333333333; FRESH=44444444-4444-4444-8444-444444444444
for s in $LIVE $DEAD $DIRTY $FRESH; do mkdir -p "$R/-proj/$s/scratchpad"; echo x > "$R/-proj/$s/scratchpad/f"; done
mkdir -p "$R/-proj/$LIVE/scratchpad/gocache/ab" "$R/-proj/$LIVE/scratchpad/hotcache/gocache"
echo c > "$R/-proj/$LIVE/scratchpad/gocache/ab/obj"; echo c > "$R/-proj/$LIVE/scratchpad/hotcache/gocache/obj"
mkdir -p "$R/-proj/$LIVE/scratchpad/src"; echo keep > "$R/-proj/$LIVE/scratchpad/src/main.go"
git init -q "$R/-proj/$DIRTY/scratchpad/wt" && echo dirty > "$R/-proj/$DIRTY/scratchpad/wt/x"
# a live session record: our own shell's pid is certainly alive
echo "{\"pid\":$$,\"sessionId\":\"$LIVE\"}" > "$S/$$.json"
mkdir -p "$L/puppeteer_dev_chrome_profile-AAA" "$L/puppeteer_dev_chrome_profile-HELD" "$L/tmp.OLD" "$L/precious-data" "$L/tmp.NEW"
echo p > "$L/puppeteer_dev_chrome_profile-HELD/lock"
old "$R" '20 days ago'; old "$L" '3 days ago'
touch "$R/-proj/$LIVE/scratchpad/hotcache/gocache/obj" "$R/-proj/$FRESH/scratchpad/f" "$L/tmp.NEW"
( cd "$L/puppeteer_dev_chrome_profile-HELD" && exec sleep 300 ) & HOLD=$!; sleep 0.3

run() { SCRATCH_ROOTS="$R" LITTER_DIR="$L" CLAUDE_SESSIONS="$S" STATE_FILE="$FX/state" TMP_WARN_PCT=101 \
        CLAUDE_DISK_TMP="$FX/disk" bash "$SCRIPT" "$@"; }
out=$(run --dry-run); echo "$out" | grep -q 'WOULD remove' || { echo "FAIL: dry-run listed nothing"; fail=1; }
ok "$R/-proj/$DEAD" "everything on --dry-run"
run >/dev/null 2>&1
gone "$R/-proj/$LIVE/scratchpad/gocache"            "idle cache inside a LIVE session"
ok   "$R/-proj/$LIVE/scratchpad/hotcache/gocache"   "cache used minutes ago"
ok   "$R/-proj/$LIVE/scratchpad/src/main.go"        "non-cache files of a live session"
gone "$R/-proj/$DEAD"                               "dead, idle, clean session"
ok   "$R/-proj/$DIRTY/scratchpad/wt/x"              "dead session with uncommitted worktree changes"
ok   "$R/-proj/$FRESH"                              "dead session touched just now"
gone "$L/puppeteer_dev_chrome_profile-AAA"          "idle puppeteer profile"
ok   "$L/puppeteer_dev_chrome_profile-HELD"         "profile a process has as cwd"
gone "$L/tmp.OLD"                                   "old mktemp dir"
ok   "$L/tmp.NEW"                                   "fresh mktemp dir"
ok   "$L/precious-data"                             "anything outside the allowlist"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
