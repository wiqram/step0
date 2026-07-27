#!/bin/bash
# tests/test-run-notifications.sh — the start-scratch / restore-scratch channels.
#
# These two scripts rebuild the cluster, so neither can be run for real in a test.
# What IS testable — and what actually breaks — is the notification MACHINERY around
# them: does a run announce itself, does an abort produce a FAILED push rather than
# silence, and does a --dry-run stay quiet. Both are exercised without touching the
# cluster: start-scratch via its (self-contained) notification header, restore-scratch
# by driving the real script into its earliest die(), which happens in phase 0 before
# anything is mutated.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fail=0
assert_contains() { case "$1" in *"$2"*) echo "ok: $3" ;; *) echo "FAIL: $3 — [$2] not in:"; echo "$1" | sed 's/^/    /'; fail=1 ;; esac; }
assert_missing()  { case "$1" in *"$2"*) echo "FAIL: $3 — [$2] unexpectedly present"; fail=1 ;; *) echo "ok: $3" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$REPO/ntfy-lib.sh" "$TMP/"

# ============================ start-scratch ==================================
# The notification header runs before any cluster work and ends at the STARTED push.
# Extracting it lets the ERR/EXIT traps be driven to both outcomes for real.
awk '{print} /hourglass_flowing_sand,cloud/{exit}' "$REPO/start-scratch.sh" > "$TMP/header.sh"
grep -q 'trap ss_finish EXIT' "$TMP/header.sh" || { echo "FAIL: could not extract the start-scratch header"; exit 1; }

cp "$TMP/header.sh" "$TMP/ok.sh";   echo 'echo "bootstrap body ran"' >> "$TMP/ok.sh"
cp "$TMP/header.sh" "$TMP/bad.sh";  echo 'false' >> "$TMP/bad.sh"   # set -e aborts here

out="$(NTFY_DRY_RUN=1 bash "$TMP/ok.sh" 2>&1 >/dev/null)"
assert_contains "$out" "yolo-private-cloud-start-scratch" "start-scratch posts to its own channel"
assert_contains "$out" "start-scratch STARTED"            "announces the run at the top"
assert_contains "$out" "start-scratch COMPLETED"          "reports completion"
# Match the TITLE form: the STARTED body legitimately mentions both words ("expect a
# COMPLETED or FAILED note"), so a bare word match would be testing the wrong thing.
assert_missing  "$out" "start-scratch FAILED"             "a clean run reports no failure"

NTFY_DRY_RUN=1 bash "$TMP/bad.sh" >/dev/null 2>"$TMP/bad.err"; rc=$?
out="$(cat "$TMP/bad.err")"
[ "$rc" -ne 0 ] && echo "ok: an aborted bring-up still exits non-zero" || { echo "FAIL: aborted run exited 0"; fail=1; }
assert_contains "$out" "start-scratch FAILED (rc=1)"      "abort produces a FAILED push, not silence"
assert_contains "$out" "[urgent]"                         "a half-built cluster is urgent"
assert_contains "$out" "false"                            "the failing command is named"
assert_missing  "$out" "start-scratch COMPLETED"          "an aborted run never claims completion"

# SKIP_APP_BUILDS must be reflected honestly — the operator needs to know whether the
# apps went out or whether trigger-app-builds.sh is still owed.
out="$(SKIP_APP_BUILDS=1 NTFY_DRY_RUN=1 bash "$TMP/ok.sh" 2>&1 >/dev/null)"
assert_contains "$out" "SKIPPED" "SKIP_APP_BUILDS=1 is reported as skipped"
out="$(NTFY_DRY_RUN=1 bash "$TMP/ok.sh" 2>&1 >/dev/null)"
assert_contains "$out" "Jenkins build triggers fired" "without SKIP_APP_BUILDS the apps are reported as deployed"

# ============================ restore-scratch =================================
# Drive the REAL script into its first die(): phase 0 rejects an unexpected $HOME,
# which happens before any mutation (the only prior step is a mkdir -p of a directory
# that already exists). This exercises the shipped STARTED push and die() path.
out="$(HOME=/tmp/not-cloud NTFY_DRY_RUN=1 bash "$REPO/restore-scratch.sh" 2>&1 >/dev/null)"; rc=$?
assert_contains "$out" "yolo-private-cloud-restore-scratch" "restore-scratch posts to its own channel"
assert_contains "$out" "restore-scratch STARTED"            "announces the DR run"
assert_contains "$out" "restore-scratch FAILED"             "die() pushes a failure"
assert_contains "$out" "[urgent]"                           "a failed DR is urgent"
assert_contains "$out" "--from-phase"                       "failure message says how to resume"
assert_missing  "$out" "ENDED early"                        "die() suppresses the EXIT-trap duplicate"

# --dry-run must page nobody: it exists to be re-read repeatedly.
out="$(NTFY_DRY_RUN=1 bash "$REPO/restore-scratch.sh" --dry-run 2>&1 >/dev/null)"
assert_missing "$out" "yolo-private-cloud-restore-scratch" "--dry-run sends nothing"

# --help exits before the EXIT trap is armed, so it must not push either.
out="$(NTFY_DRY_RUN=1 bash "$REPO/restore-scratch.sh" --help 2>&1 >/dev/null)"
assert_missing "$out" "yolo-private-cloud-restore-scratch" "--help sends nothing"

exit $fail
