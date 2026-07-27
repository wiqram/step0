#!/bin/bash
# ntfy-topic-check.sh — the STEP0 push-notification gate. Read-only; exit 1 on a violation.
#
# WHY THIS EXISTS
# ---------------
# A dead alert channel looks exactly like "nothing is wrong", so a half-wired
# notification is invisible until the day you needed it. The yolo repo lost this
# argument four times (docs/ARCHITECTURE.md §11a there); the failures were all
# mechanical, and so are the ones this repo can have:
#   1. a publisher pushes to a topic NOBODY is subscribed to (typo, or a channel
#      renamed in one script and not the registry);
#   2. a publisher calls ntfy_push but never sources ntfy-lib.sh, so the call is an
#      unbound-command error that `|| true`-style fail-soft handling swallows;
#   3. a topic gets hardcoded as a bare https://ntfy.sh/... URL somewhere, drifting
#      away from the registry that everything else reads.
#
# Deliberately NOT checked: the gitignored .env's legacy private NTFY_URL (a single
# random topic used by cluster-autostart.sh / vault-auto-unseal.sh for cluster
# up/down alerts). It predates the registry and is intentionally out of scope.
#
# Usage: ./ntfy-topic-check.sh          # exit 0 clean, 1 on violations
set -u
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELFDIR/ntfy-lib.sh"

RC=0
fail() { printf '  x %s\n' "$1" >&2; RC=1; }
ok()   { printf '  . %s\n' "$1"; }

# Publishers: every script expected to send on one of the five channels. A script
# listed here that stops sourcing the lib, or sends to an unregistered topic, fails
# the gate. wd-backup.sh lives OUTSIDE this repo (~/wd-backup, captured in the weekly
# DR archive) — checked best-effort so a dev box without it still passes.
PUBLISHERS="backup-minikube-mnt.sh start-scratch.sh restore-scratch.sh resource-crunch-watch.sh"
WD_PUBLISHER="/home/cloud/wd-backup/wd-backup.sh"

echo "STEP0 ntfy channel check"
echo
echo "[1/4] registry shape"
for t in $NTFY_TOPICS; do
  if ntfy_topic_shape_ok "$t"; then ok "$t"; else fail "'$t' is not a legal ntfy topic ([-_A-Za-z0-9]{1,64})"; fi
done
echo

echo "[2/4] every publisher sources ntfy-lib.sh"
for p in $PUBLISHERS; do
  f="$SELFDIR/$p"
  if [ ! -f "$f" ]; then fail "publisher $p is missing from the repo"; continue; fi
  if ! grep -q 'ntfy_push' "$f"; then fail "$p is registered as a publisher but never calls ntfy_push — its channel is DORMANT"; continue; fi
  if grep -qE 'ntfy-lib\.sh' "$f"; then ok "$p sources ntfy-lib.sh"
  else fail "$p calls ntfy_push but never sources ntfy-lib.sh — every push would be a command-not-found the fail-soft handler hides"; fi
done
if [ -f "$WD_PUBLISHER" ]; then
  if grep -q 'ntfy_push' "$WD_PUBLISHER" && grep -qE 'ntfy-lib\.sh' "$WD_PUBLISHER"; then
    ok "$(basename "$WD_PUBLISHER") (out-of-repo) sources ntfy-lib.sh"
  else
    fail "$WD_PUBLISHER does not push via ntfy-lib.sh — the nightly WD channel is DORMANT"
  fi
else
  printf '  ! %s not present on this box (dev box?) — WD channel not checked\n' "$WD_PUBLISHER"
fi
echo

echo "[3/4] no unregistered topic hardcoded as a bare ntfy.sh URL"
found=0
tmp="${TMPDIR:-/tmp}/ntfy-topic-check.$$"
trap 'rm -f "$tmp"' EXIT INT TERM
# Skip this file and the lib: the registry itself legitimately names every topic, and
# these comments quote example URLs.
grep -rnoE 'https://ntfy\.sh/[A-Za-z0-9_-]+' "$SELFDIR" \
  --include='*.sh' --include='*.md' --include='*.yaml' --include='*.yml' \
  --exclude='ntfy-lib.sh' --exclude='ntfy-topic-check.sh' 2>/dev/null > "$tmp" || true
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  found=1
  url="${hit##*:}"; topic="${url##*/}"
  if ntfy_topic_valid "$topic"; then ok "${hit%%:*} -> $topic"
  else fail "${hit%%:*} hardcodes '$topic', which is not in the ntfy-lib.sh registry"; fi
done < "$tmp"
[ "$found" -eq 1 ] || ok "none (publishers use the \$NTFY_TOPIC_* variables — preferred)"
echo

echo "[4/4] ntfy_push targets are registry VARIABLES, not string literals"
# A literal cannot be renamed in one place, which is how a channel silently forks.
lit=0
grep -rnE 'ntfy_push[[:space:]]+"?(yolo-|https)' "$SELFDIR" --include='*.sh' \
  --exclude='ntfy-topic-check.sh' 2>/dev/null > "$tmp" || true
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  lit=1
  fail "$hit — pass \$NTFY_TOPIC_* instead of a literal topic"
done < "$tmp"
[ "$lit" -eq 1 ] || ok "all ntfy_push calls use registry variables"

echo
if [ "$RC" -eq 0 ]; then echo "ntfy channel check: OK"
else echo "ntfy channel check: VIOLATIONS (see x above) — see architecture.md 'Push notifications'" >&2; fi
exit "$RC"
