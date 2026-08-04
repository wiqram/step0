#!/bin/bash
# tests/test-ntfy-lib.sh — unit tests for ntfy-lib.sh pure functions.
# No network: ntfy_push is exercised via NTFY_DRY_RUN=1.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../ntfy-lib.sh"
fail=0
assert_eq() { # $1=actual $2=expected $3=label
  if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi
}
assert_true()  { if "$@"; then echo "ok: $*"; else echo "FAIL: expected success — $*"; fail=1; fi; }
assert_false() { if "$@"; then echo "FAIL: expected failure — $*"; fail=1; else echo "ok: ! $*"; fi; }

# ---- the seven registered channels are exactly the ones the user asked for ------
assert_eq "$NTFY_TOPIC_BACKUP"           "yolo-private-cloud-backup"         "weekly backup topic"
assert_eq "$NTFY_TOPIC_WD_BACKUP"        "yolo-wd-cloud-backup"              "nightly WD topic"
assert_eq "$NTFY_TOPIC_START_SCRATCH"    "yolo-private-cloud-start-scratch"  "start-scratch topic"
assert_eq "$NTFY_TOPIC_RESTORE_SCRATCH"  "yolo-private-cloud-restore-scratch" "restore-scratch topic"
assert_eq "$NTFY_TOPIC_RESOURCE_CRUNCH"  "yolo-private-cloud-resource-crunch" "pipeline-watchdog topic"
# The two non-bash publishers: Alertmanager and Grafana POST to ntfy themselves, from
# inside the cluster, so they never call ntfy_push. Registered regardless — this list is
# what ntfy-topic-check.sh's manifest scan validates those hardcoded URLs against.
assert_eq "$NTFY_TOPIC_PLATFORM"         "yolo-private-cloud-platform"       "platform (Alertmanager) topic"
assert_eq "$NTFY_TOPIC_GRAFANA"          "yolo-grafana"                      "grafana (yolo app alerts) topic"
assert_eq "$(printf '%s\n' $NTFY_TOPICS | wc -l)" "7" "registry holds 7 topics"

# ---- shape: ntfy's own [-_A-Za-z0-9]{1,64} rule --------------------------------
assert_true  ntfy_topic_shape_ok "yolo-private-cloud-backup"
assert_true  ntfy_topic_shape_ok "a_b-C9"
assert_false ntfy_topic_shape_ok ""
assert_false ntfy_topic_shape_ok "has/slash"        # ntfy has no hierarchy
assert_false ntfy_topic_shape_ok "has space"
assert_false ntfy_topic_shape_ok "$(printf 'a%.0s' $(seq 1 65))"   # 65 chars > limit

# ---- registration: a legal-but-unregistered topic must be REJECTED -------------
# This is the typo case — "…-backups" is a valid ntfy topic that nobody subscribes to.
assert_true  ntfy_topic_valid "yolo-private-cloud-backup"
assert_false ntfy_topic_valid "yolo-private-cloud-backups"
assert_false ntfy_topic_valid "yolo-ops"            # a yolo-repo topic, not ours

# ---- header sanitising: the BUG-CANARY-NTFY-EM-DASH class of failure ------------
assert_eq "$(ntfy_header_safe 'backup OK — 5.2G')" "backup OK - 5.2G" "em dash folded to hyphen"
assert_eq "$(ntfy_header_safe 'a–b')"              "a-b"              "en dash folded"
assert_eq "$(ntfy_header_safe '“q” ‘s’')"          '"q" '"'"'s'"'"''  "smart quotes folded"
assert_eq "$(ntfy_header_safe 'wait…')"            "wait..."          "ellipsis folded"
assert_eq "$(ntfy_header_safe $'two\nlines')"      "twolines"         "newline stripped (would split the header)"
assert_eq "$(ntfy_header_safe 'plain ASCII 123')"  "plain ASCII 123"  "ASCII untouched"
# Anything not covered by the explicit folds still degrades to '?' rather than throwing.
assert_eq "$(ntfy_header_safe 'x€')"               "x???"             "unmapped multibyte replaced byte-wise"

# ---- ntfy_push is fail-soft: never non-zero, never writes stdout ----------------
out="$(NTFY_DRY_RUN=1 ntfy_push "$NTFY_TOPIC_BACKUP" "t" "b" default "floppy_disk" 2>/dev/null)"
assert_eq "$out" "" "ntfy_push writes nothing to stdout"
NTFY_DRY_RUN=1 ntfy_push "$NTFY_TOPIC_BACKUP" "t" "b" >/dev/null 2>&1
assert_eq "$?" "0" "ntfy_push returns 0 on success"
ntfy_push "totally-unregistered" "t" "b" >/dev/null 2>&1
assert_eq "$?" "0" "ntfy_push returns 0 even when it refuses an unregistered topic"
NTFY_ENABLED=0 ntfy_push "$NTFY_TOPIC_BACKUP" "t" "b" >/dev/null 2>&1
assert_eq "$?" "0" "ntfy_push returns 0 when disabled"
# The dry-run trace must show the SANITISED title, i.e. sanitising happens before send.
trace="$(NTFY_DRY_RUN=1 ntfy_push "$NTFY_TOPIC_BACKUP" 'weekly — done' "b" 2>&1 >/dev/null)"
case "$trace" in *"weekly - done"*) echo "ok: dry-run trace carries the sanitised title" ;;
  *) echo "FAIL: dry-run trace missing sanitised title — got [$trace]"; fail=1 ;; esac

# ---- byte formatting -----------------------------------------------------------
assert_eq "$(ntfy_human_bytes 5368709120)" "5.0G" "bytes -> human"
assert_eq "$(ntfy_human_bytes 0)"          "0"    "zero bytes"
assert_eq "$(ntfy_human_bytes '')"         "?"    "empty input is not an arithmetic error"
assert_eq "$(ntfy_human_bytes 'n/a')"      "?"    "non-numeric input is not an arithmetic error"

exit $fail
