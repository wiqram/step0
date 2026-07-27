#!/bin/bash
# tests/test-resource-crunch-watch.sh — the alert state machine, plus one end-to-end pass.
#
# The state machine is what has to be right. Get it wrong in one direction and the
# channel floods every 5 minutes until it is muted; wrong in the other and it never
# speaks at all. Both failures look identical from the outside ("no alerts"), which is
# exactly why they are tested here rather than observed in production.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fail=0
assert_eq() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi; }
assert_contains() { case "$1" in *"$2"*) echo "ok: $3" ;; *) echo "FAIL: $3 — [$2] not in:"; echo "$1" | sed 's/^/    /'; fail=1 ;; esac; }
assert_missing()  { case "$1" in *"$2"*) echo "FAIL: $3 — [$2] unexpectedly present"; fail=1 ;; *) echo "ok: $3" ;; esac; }

# RC_LIB_ONLY stops the script before it touches the cluster, the GPU or the state file.
# shellcheck source=/dev/null
RC_LIB_ONLY=1 source "$REPO/resource-crunch-watch.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ST="$TMP/state"; : > "$ST"

# ---- rc_breached: an unreadable sensor is NOT a breach --------------------------
assert_eq "$(rc_breached 95 90)"   "1" "value above threshold breaches"
assert_eq "$(rc_breached 90 90)"   "1" "value AT threshold breaches (>=)"
assert_eq "$(rc_breached 89 90)"   "0" "value below threshold is calm"
assert_eq "$(rc_breached '' 90)"   "0" "missing reading is not a breach"
assert_eq "$(rc_breached 'n/a' 90)" "0" "unparseable reading is not a breach"

# ---- rc_state_get / rc_state_put ------------------------------------------------
assert_eq "$(rc_state_get "$ST" 'node-mem')" "0 0 0" "unknown key reads as calm"
rc_state_put "$ST" 'node-mem' 2 0 0
rc_state_put "$ST" 'gpu-temp' 5 1 1700000000
assert_eq "$(rc_state_get "$ST" 'node-mem')"  "2 0 0"           "state round-trips"
assert_eq "$(rc_state_get "$ST" 'gpu-temp')"  "5 1 1700000000"  "second key is independent"
rc_state_put "$ST" 'node-mem' 3 1 1700000500
assert_eq "$(rc_state_get "$ST" 'node-mem')"  "3 1 1700000500"  "update replaces, not appends"
assert_eq "$(rc_state_get "$ST" 'gpu-temp')"  "5 1 1700000000"  "updating one key leaves the other intact"
assert_eq "$(wc -l < "$ST")" "2" "no duplicate rows accumulate"
# A key that is a prefix of another must not be confused for it (the state file is
# matched on "key<TAB>", not on the bare name).
rc_state_put "$ST" 'disk' 9 1 42
assert_eq "$(rc_state_get "$ST" 'disk')" "9 1 42"      "prefix key stored"
rc_state_put "$ST" 'disk-var' 1 0 0
assert_eq "$(rc_state_get "$ST" 'disk')" "9 1 42"      "'disk-var' does not clobber 'disk'"

# ---- rc_decide: walk the whole lifecycle ---------------------------------------
# need=3, cooldown=3600. Fields of the answer: verdict consec alerting last.
d() { rc_decide "$@" ; }
assert_eq "$(d 1 0 0 0 1000 3 3600)" "silent 1 0 0"        "1st breach is silent (a spike is not a crunch)"
assert_eq "$(d 1 1 0 0 1000 3 3600)" "silent 2 0 0"        "2nd breach still silent"
assert_eq "$(d 1 2 0 0 1000 3 3600)" "alert 3 1 1000"      "3rd consecutive breach alerts"
assert_eq "$(d 1 3 1 1000 1100 3 3600)" "silent 4 1 1000"  "still breached inside the cooldown stays quiet"
assert_eq "$(d 1 4 1 1000 4599 3 3600)" "silent 5 1 1000"  "one second before the cooldown expires: quiet"
assert_eq "$(d 1 5 1 1000 4600 3 3600)" "remind 6 1 4600"  "cooldown expiry re-notifies and re-stamps"
assert_eq "$(d 0 6 1 4600 5000 3 3600)" "recovered 0 0 4600" "clearing sends exactly one recovery"
assert_eq "$(d 0 0 0 4600 5100 3 3600)" "silent 0 0 4600"  "staying clear says nothing more"
# A breach that lapses before it is sustained must start counting from scratch —
# otherwise five separate one-off spikes across a day would fake a sustained crunch.
assert_eq "$(d 0 2 0 0 1000 3 3600)" "silent 0 0 0"        "an interrupted breach resets the counter"
assert_eq "$(d 1 0 0 0 1200 3 3600)" "silent 1 0 0"        "and starts again from 1"
# need=1 (an operator who wants immediate alerts) must alert on the first sample.
assert_eq "$(d 1 0 0 0 1000 1 3600)" "alert 1 1 1000"      "RC_NEED_CONSEC=1 alerts immediately"

# ---- end to end: real probes, forced thresholds, nothing sent -------------------
# Every disk on this box is above 1% used, so RC_DISK_PCT=1 guarantees a breach from a
# genuine reading. RC_NEED_CONSEC=1 makes it alert on the first pass.
E2E="$TMP/e2e-state"
out="$(RC_STATE="$E2E" RC_LOG="$TMP/e2e.log" RC_DISK_PCT=1 RC_NEED_CONSEC=1 NTFY_DRY_RUN=1 \
       bash "$REPO/resource-crunch-watch.sh" --dry-run 2>&1 >/dev/null)"
assert_contains "$out" "yolo-private-cloud-resource-crunch" "posts to the registered channel"
assert_contains "$out" "Resource crunch:"                   "alert title names the event"
assert_contains "$out" "disk /var"                          "the breaching metric is named"
assert_contains "$out" "[high]"                             "a crunch is high priority"
assert_contains "$out" "sustained"                          "message states how long it has lasted"
# One push for the whole run, even though three disks breached together.
assert_eq "$(printf '%s\n' "$out" | grep -c 'DRYRUN ntfy')" "1" "one aggregated push, not one per metric"

# Same state, thresholds back to normal -> exactly one recovery note.
out="$(RC_STATE="$E2E" RC_LOG="$TMP/e2e.log" NTFY_DRY_RUN=1 \
       bash "$REPO/resource-crunch-watch.sh" --dry-run 2>&1 >/dev/null)"
assert_contains "$out" "Resource crunch cleared" "clearing sends a recovery note"
assert_contains "$out" "[low]"                   "recovery is low priority"
assert_missing  "$out" "Resource crunch:"        "recovery run does not also re-alert"

# And a third pass, everything calm, must be completely silent.
out="$(RC_STATE="$E2E" RC_LOG="$TMP/e2e.log" NTFY_DRY_RUN=1 \
       bash "$REPO/resource-crunch-watch.sh" --dry-run 2>&1 >/dev/null)"
assert_missing "$out" "DRYRUN ntfy" "a calm run sends nothing at all"

# --status must never mutate state or push.
before="$(cat "$E2E")"
out="$(RC_STATE="$E2E" NTFY_DRY_RUN=1 bash "$REPO/resource-crunch-watch.sh" --status 2>&1 >/dev/null)"
assert_missing "$out" "DRYRUN ntfy" "--status sends nothing"
assert_eq "$(cat "$E2E")" "$before" "--status leaves the state file untouched"

exit $fail
