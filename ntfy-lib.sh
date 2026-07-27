#!/bin/bash
# ntfy-lib.sh — the STEP0 push-notification channel registry + a fail-soft publisher.
# Sourceable ONLY: sourcing this file must not execute anything except definitions.
#
# WHY A SHARED LIB (and not a copy of the two-line curl in cluster-autostart.sh)
# -----------------------------------------------------------------------------
# The yolo repo has now half-wired its ntfy channel FOUR times, and every failure
# looked identical from the outside: a dead alert channel is indistinguishable from
# "nothing is wrong". Its post-mortems (docs/ARCHITECTURE.md §11a there) name three
# mechanical causes, all of which this file removes by construction:
#   * a topic that nobody registered / a typo'd topic name  -> ntfy_topic_valid()
#     rejects anything not in NTFY_TOPICS, and ntfy-topic-check.sh fails the repo.
#   * a non-latin1 byte in an HTTP header (BUG-CANARY-NTFY-EM-DASH: a U+2014 em dash
#     in a Title threw BEFORE the request was sent, and the fail-soft handler ate it)
#     -> ntfy_header_safe() folds the typographic characters this repo's comments are
#     full of down to ASCII. Bodies are left alone; only headers are latin1-bound.
#   * the publisher aborting its CALLER. Every script here runs unattended (cron, a
#     two-hour DR run); a notification must never be the thing that kills it. Hence
#     ntfy_push ALWAYS returns 0 and never writes to stdout.
#
# TOPIC NAMES ARE NOT SECRETS. ntfy.sh topics are world-readable AND world-writable,
# so they are committed in the clear here (same "plain-name scheme" as yolo) — and
# for exactly that reason a message body must carry no secret, token or PII.
# ntfy's own constraint: a topic is [-_A-Za-z0-9]{1,64}, no slashes, no wildcards —
# there is no hierarchy, so the "namespace" is just a `yolo-` prefix convention.
#
# The legacy single-topic NTFY_URL in the gitignored .env (cluster-autostart.sh,
# vault-auto-unseal.sh) is a DIFFERENT, private random topic and is deliberately left
# alone — it carries cluster up/down alerts, not the five channels below.

# Server base. Override for a self-hosted ntfy instance; no trailing slash.
NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"

# ---- the registry: one line per channel; this is the source of truth ----------
# Adding a channel? Add the variable AND the name to NTFY_TOPICS, or ntfy_push
# refuses to send to it and ntfy-topic-check.sh fails.
NTFY_TOPIC_BACKUP="${NTFY_TOPIC_BACKUP:-yolo-private-cloud-backup}"                     # weekly DR backup (backup-minikube-mnt.sh)
NTFY_TOPIC_WD_BACKUP="${NTFY_TOPIC_WD_BACKUP:-yolo-wd-cloud-backup}"                    # nightly WD My Cloud rsync (~/wd-backup/wd-backup.sh)
NTFY_TOPIC_START_SCRATCH="${NTFY_TOPIC_START_SCRATCH:-yolo-private-cloud-start-scratch}"      # cold platform bring-up (start-scratch.sh)
NTFY_TOPIC_RESTORE_SCRATCH="${NTFY_TOPIC_RESTORE_SCRATCH:-yolo-private-cloud-restore-scratch}" # bare-metal DR (restore-scratch.sh)
NTFY_TOPIC_RESOURCE_CRUNCH="${NTFY_TOPIC_RESOURCE_CRUNCH:-yolo-private-cloud-resource-crunch}" # CPU/mem/GPU/temp/disk pressure (resource-crunch-watch.sh)

# Space-separated list of every topic this repo is allowed to publish to.
NTFY_TOPICS="$NTFY_TOPIC_BACKUP $NTFY_TOPIC_WD_BACKUP $NTFY_TOPIC_START_SCRATCH $NTFY_TOPIC_RESTORE_SCRATCH $NTFY_TOPIC_RESOURCE_CRUNCH"

# ntfy_topic_shape_ok <topic> — true if ntfy itself would accept the name.
# ntfy rejects anything outside [-_A-Za-z0-9]{1,64} with a 400 that a fail-soft
# publisher would swallow, so check it here where the failure is visible.
ntfy_topic_shape_ok() {
  local t="${1:-}"
  [ -n "$t" ] || return 1
  [ "${#t}" -le 64 ] || return 1
  case "$t" in *[!-_A-Za-z0-9]*) return 1 ;; esac
  return 0
}

# ntfy_topic_valid <topic> — true if the topic is BOTH well-shaped and registered.
# The registration half is what catches a typo: "yolo-private-cloud-backups" is a
# perfectly legal ntfy topic that simply nobody is subscribed to.
ntfy_topic_valid() {
  local t="${1:-}" known
  ntfy_topic_shape_ok "$t" || return 1
  for known in $NTFY_TOPICS; do [ "$t" = "$known" ] && return 0; done
  return 1
}

# ntfy_header_safe <string> — fold to a single line of printable ASCII (latin1-safe).
# HTTP headers are latin1; a UTF-8 dash/quote in Title or Tags is a hard client-side
# failure, and a newline would split the header. The explicit sed pass maps the
# typographic characters that actually show up in this repo's prose to their ASCII
# twin FIRST, so a title reads "backup OK - 5.2G" rather than "backup OK ??? 5.2G";
# whatever survives that is replaced byte-wise.
ntfy_header_safe() {
  printf '%s' "${1:-}" \
    | sed -e 's/[—–]/-/g' -e 's/[“”]/"/g' -e "s/[‘’]/'/g" -e 's/…/.../g' -e 's/[·•]/*/g' \
    | LC_ALL=C tr -d '\n\r' \
    | LC_ALL=C tr -c '\40-\176' '?'
}

# ntfy_push <topic> <title> <body> [priority] [tags]
#   priority: min | low | default | high | urgent   (ntfy's own scale)
#   tags:     comma-separated ntfy tag/emoji short-codes, e.g. "floppy_disk,cloud"
#
# ALWAYS returns 0 — a notification failure must never abort a backup, a bootstrap or
# a DR restore. Diagnostics go to stderr (the cron log), never stdout, so a caller can
# still capture command output around it. Set NTFY_DRY_RUN=1 to print the request
# instead of sending it (used by tests/test-ntfy-lib.sh and by --dry-run callers).
ntfy_push() {
  local topic="${1:-}" title="${2:-}" body="${3:-}" prio="${4:-default}" tags="${5:-}"

  if [ "${NTFY_ENABLED:-1}" = "0" ]; then
    return 0
  fi
  if ! ntfy_topic_valid "$topic"; then
    echo "WARN: ntfy topic '$topic' is not registered in ntfy-lib.sh — not sending." >&2
    return 0
  fi

  local safe_title safe_tags
  safe_title="$(ntfy_header_safe "$title")"
  safe_tags="$(ntfy_header_safe "$tags")"

  local args=(-fsS -m "${NTFY_TIMEOUT:-15}" -H "Title: $safe_title" -H "Priority: $prio")
  [ -n "$safe_tags" ] && args+=(-H "Tags: $safe_tags")

  if [ "${NTFY_DRY_RUN:-0}" = "1" ]; then
    echo "DRYRUN ntfy -> $NTFY_BASE/$topic [$prio] [$safe_tags] $safe_title" >&2
    echo "$body" >&2
    return 0
  fi

  curl "${args[@]}" --data-binary "$body" "$NTFY_BASE/$topic" >/dev/null 2>&1 \
    || echo "WARN: ntfy push to $topic failed (network/topic) — continuing." >&2
  return 0
}

# ntfy_human_bytes <bytes> — "5368709120" -> "5.0G". Used in every message body so the
# numbers are readable on a phone lock screen. Non-numeric input yields "?" rather
# than an arithmetic error (du/df on an absent mount prints nothing).
ntfy_human_bytes() {
  local b="${1:-}"
  case "$b" in
    ''|*[!0-9]*) echo "?"; return 0 ;;
    0)           echo "0"; return 0 ;;   # numfmt renders this "0.0B"; "0" reads better
  esac
  numfmt --to=iec --suffix=B --format='%.1f' "$b" 2>/dev/null | sed 's/B$//' \
    || echo "$b"
}
