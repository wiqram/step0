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
#   4. a publisher that is NOT BASH. Alertmanager's webhook_configs and Grafana's
#      contact point both POST to ntfy from inside the cluster, so they can never call
#      ntfy_push and checks 1-3 never see them. `yolo-grafana` was live for months
#      without being in the registry and nothing failed, because the gate only ever
#      read shell scripts. Check [5/5] closes that: it scans the two manifests that
#      carry those URLs and validates them against the same registry.
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

# Publishers: every script expected to send on one of the registered channels. A script
# listed here that stops sourcing the lib, or sends to an unregistered topic, fails
# the gate. wd-backup.sh lives OUTSIDE this repo (~/wd-backup, captured in the weekly
# DR archive) — checked best-effort so a dev box without it still passes.
PUBLISHERS="backup-minikube-mnt.sh start-scratch.sh restore-scratch.sh alerting-pipeline-watch.sh yolo-uptime-probe.sh"
WD_PUBLISHER="/home/cloud/wd-backup/wd-backup.sh"

# Non-bash publishers: manifests that hardcode an ntfy URL because the thing doing the
# POST is Alertmanager or Grafana, not a script. Both live OUTSIDE this repo, so they are
# checked best-effort — a dev box without them still passes.
#
# NOTE THE CASING. These are the two Ideaprojects directories that differ only by the
# capital P (see CLAUDE.md): kube-prometheus is under Ideaprojects, the yolo repo under
# IdeaProjects. Do not "normalise" either path — they are different directories.
MANIFEST_PUBLISHERS="
/home/cloud/Ideaprojects/kube-prometheus/manifests/alertmanager-secret.yaml
/home/cloud/IdeaProjects/IG-Trading-Microservices/monitoring/grafana-alerting/alerting.yaml
"

echo "STEP0 ntfy channel check"
echo
echo "[1/5] registry shape"
for t in $NTFY_TOPICS; do
  if ntfy_topic_shape_ok "$t"; then ok "$t"; else fail "'$t' is not a legal ntfy topic ([-_A-Za-z0-9]{1,64})"; fi
done
echo

echo "[2/5] every publisher sources ntfy-lib.sh"
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

echo "[3/5] no unregistered topic hardcoded as a bare ntfy.sh URL"
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

echo "[4/5] ntfy_push targets are registry VARIABLES, not string literals"
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

echo "[5/5] non-bash publishers (Alertmanager, Grafana) target REGISTERED topics"
# The gap this closes: checks 1-4 all read shell scripts, so a topic that only ever
# appears in a Kubernetes manifest is invisible to them. That is not hypothetical —
# yolo-grafana was being published to by Grafana's contact point for months while
# absent from NTFY_TOPICS, and every check above passed the whole time.
#
# These files are outside the repo, so a missing one is a NOTE, not a failure: a dev
# box legitimately has neither. A file that IS present and names an unregistered topic
# is a hard failure, same as any other drift from the registry.
seen_manifest=0
for m in $MANIFEST_PUBLISHERS; do
  [ -n "$m" ] || continue
  if [ ! -f "$m" ]; then
    printf '  ! %s not present on this box (dev box?) — not checked\n' "$m"
    continue
  fi
  # A manifest may embed the URL query-escaped (Alertmanager templates ntfy's ?tpl=
  # parameters), so match the topic segment only and stop at the first non-topic byte.
  if ! grep -qoE 'ntfy\.sh/[A-Za-z0-9_-]+' "$m" 2>/dev/null; then
    fail "$(basename "$m") is registered as a manifest publisher but names no ntfy topic — its channel is DORMANT"
    continue
  fi
  grep -oE 'ntfy\.sh/[A-Za-z0-9_-]+' "$m" 2>/dev/null | sort -u > "$tmp" || true
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    seen_manifest=1
    topic="${url##*/}"
    if ntfy_topic_valid "$topic"; then ok "$(basename "$m") -> $topic"
    else fail "$(basename "$m") publishes to '$topic', which is not in the ntfy-lib.sh registry"; fi
  done < "$tmp"
done
[ "$seen_manifest" -eq 1 ] || printf '  ! no manifest publisher was readable on this box\n'

echo
if [ "$RC" -eq 0 ]; then echo "ntfy channel check: OK"
else echo "ntfy channel check: VIOLATIONS (see x above) — see docs/architecture.md 'Push notifications'" >&2; fi
exit "$RC"
