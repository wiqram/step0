#!/bin/bash
# tests/test-backup-notification.sh — renders the weekly-backup ntfy summary from the
# REAL block at the end of backup-minikube-mnt.sh, against a fake $dest / $WD_DEST.
#
# Why extract-and-eval rather than a hand-copied duplicate: the failure this guards
# against is the summary block breaking (unbound var, bad quoting, a renamed variable)
# in a job that runs once a WEEK from a root cron. A copy would drift and pass while
# the shipped block was broken. The block is delimited by the banner comment below,
# which is part of the shipped file.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../backup-minikube-mnt.sh"
fail=0
assert_contains() { # $1=haystack $2=needle $3=label
  case "$1" in *"$2"*) echo "ok: $3" ;; *) echo "FAIL: $3 — [$2] not in output:"; echo "$1" | sed 's/^/    /'; fail=1 ;; esac
}

# shellcheck source=/dev/null
source "$HERE/../ntfy-lib.sh"

# The shipped summary block: from its banner to end-of-file.
BLOCK="$(awk '/^# Weekly push notification -> ntfy/{found=1} found' "$SRC")"
[ -n "$BLOCK" ] || { echo "FAIL: could not locate the summary block in $SRC"; exit 1; }

# ---- fake environment ----------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
hostname="private-cloud"
dest="$TMP/local"; WD_MOUNT="$TMP/wd"; WD_DEST="$WD_MOUNT"
mkdir -p "$dest" "$WD_DEST"
# 3 local archives (2MB, 1MB, 1MB), 2 off-site.
head -c 2097152 /dev/zero > "$dest/$hostname-07-27-26.tgz"
head -c 1048576 /dev/zero > "$dest/$hostname-07-20-26.tgz"
head -c 1048576 /dev/zero > "$dest/$hostname-07-13-26.tgz"
head -c 2097152 /dev/zero > "$WD_DEST/$hostname-07-27-26.tgz"
head -c 1048576 /dev/zero > "$WD_DEST/$hostname-07-20-26.tgz"
archive_file="$hostname-07-27-26.tgz"

render() { # $1=tar_rc $2=WD_STATUS $3=NTFY_WARNINGS $4=mounted(0|1)
  tar_rc="$1"; WD_STATUS="$2"; NTFY_WARNINGS="$3"; tar_elapsed=412
  # Shadow mountpoint so both the "NAS up" and "NAS dark" branches are reachable
  # without a real mount.
  if [ "$4" = "1" ]; then mountpoint() { return 0; }; else mountpoint() { return 1; }; fi
  NTFY_DRY_RUN=1 eval "$BLOCK" 2>&1 >/dev/null
}

# ---- happy path ----------------------------------------------------------------
out="$(render 0 copied "" 1)"
assert_contains "$out" "yolo-private-cloud-backup"  "posts to the registered channel"
assert_contains "$out" "Weekly backup OK - 2.0M"    "title carries this run's size"
assert_contains "$out" "[default]"                  "clean run is default priority"
assert_contains "$out" "local ($dest): 3 backups, 4.0M total" "local count + total size"
assert_contains "$out" "off-site (WD Cloud): 2 backups, 3.0M total" "off-site count + total size"
assert_contains "$out" "off-site copy: copied"      "off-site status"
assert_contains "$out" "tar rc=0"                   "tar exit code reported"
case "$out" in *warnings:*) echo "FAIL: clean run must not print a warnings section"; fail=1 ;;
  *) echo "ok: clean run has no warnings section" ;; esac

# ---- degraded: NAS dark (the one-disk week) ------------------------------------
out="$(render 0 skipped '
- off-site SKIPPED: NAS dark' 0)"
assert_contains "$out" "Weekly backup completed with warnings" "warning title"
assert_contains "$out" "[high]"                                "warnings raise priority to high"
assert_contains "$out" "off-site (WD Cloud): n/a"              "unmounted NAS yields n/a, not a stat error"
assert_contains "$out" "off-site SKIPPED"                      "warning text is carried"

# ---- tar failure ---------------------------------------------------------------
out="$(render 2 skipped '
- tar FAILED' 0)"
assert_contains "$out" "Weekly backup FAILED (tar rc=2)" "tar failure title"
assert_contains "$out" "[urgent]"                        "tar failure is urgent"

# ---- tar rc=1 is a warning, not a failure (files changed mid-read) -------------
out="$(render 1 copied '
- tar exited 1' 1)"
assert_contains "$out" "completed with warnings" "tar rc=1 degrades rather than fails"

exit $fail
