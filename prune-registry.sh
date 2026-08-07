#!/bin/bash
####################################
#
# prune-registry.sh — prune old per-build image tags from the in-cluster registry,
# then garbage-collect the blob store. DRY-RUN BY DEFAULT: nothing is deleted
# without --apply.
#
# WHY: the yolo pipeline pushes a `bNNNN` tag per service per build and nothing ever
# pruned them — by 2026-08-06 that was 8 services x 302 tags (+ marketstream 97),
# ~2,500 tagged manifests in a 37G blob store on sdb2 (/mnt/kachra) growing 4–6G/week.
# Every other app pushes a single moving tag (latest / cloud) and needs no tag
# pruning — their superseded manifests go untagged on overwrite and the final GC pass
# (--delete-untagged) reclaims those for free.
#
# WHAT IT DOES, per repo in /v2/_catalog:
#   1. keep-set = every tag NOT matching ^b[0-9]+$ (latest, cloud, ...) PLUS the
#      newest $KEEP_BUILDS (default 10) bNNNN tags by build number.
#   2. resolves every tag to its manifest digest (HEAD /v2/<repo>/manifests/<tag>).
#      ⚠️ The keep-set is a set of DIGESTS, not tag names: deleting a manifest by
#      digest removes EVERY tag pointing at it, and `latest` normally shares its
#      digest with the newest bNNNN — so any digest a kept tag points at is never
#      deleted, whichever tag first led us to it.
#   3. DELETE /v2/<repo>/manifests/<digest> for prune-tag digests outside the
#      keep-set (the k8s/registry deployment sets REGISTRY_STORAGE_DELETE_ENABLED).
#   4. runs `registry garbage-collect --delete-untagged` inside the kube-system
#      registry pod (tries the registry:3 config path, then the :2 one), then a
#      rollout restart — the daemon caches blob refs in memory, so disk is only
#      really freed after the restart.
#
# WHEN TO RUN: with Jenkins idle. A GC racing an in-flight push can corrupt that
# upload (upstream distribution caveat) — glance at the Jenkins queue first.
# Manual for now. If this ever moves to cron it becomes an unattended job and MUST
# follow the alerting convention: source ntfy-lib.sh, register a topic in
# NTFY_TOPICS, add itself to ntfy-topic-check.sh PUBLISHERS (see CLAUDE.md §7a).
#
# NOTE: delete-docker-reg-images.sh in this repo targets the ancient Registry-v1
# on-disk layout (/var/lib/docker/registry + ancestry files) and does NOT work on
# this registry:3 store. This script is its living replacement.
#
# Usage:
#   ./prune-registry.sh                    # dry-run: report what would be deleted
#   ./prune-registry.sh --apply            # delete manifests + garbage-collect
#   ./prune-registry.sh --apply --skip-gc  # delete manifests only (GC separately)
#   KEEP_BUILDS=20 ./prune-registry.sh     # keep more build history per service
#
####################################
set -u

REG_URL="${REG_URL:-http://172.16.238.2:5000}"
KEEP_BUILDS="${KEEP_BUILDS:-10}"
NS="kube-system"
# Digest resolution must offer every manifest flavour Jenkins/buildkit may have
# pushed; a missing Accept makes the registry answer with a schema1 conversion whose
# digest does NOT match the stored manifest, and the later DELETE would 404.
ACCEPT="application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json"

APPLY=0; SKIP_GC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    --skip-gc) SKIP_GC=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[prune-registry] $*"; }
die() { echo "[prune-registry FATAL] $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

digest_for() {  # $1=repo $2=tag -> prints sha256:... (empty on failure)
  curl -sfI --max-time 10 -H "Accept: $ACCEPT" "$REG_URL/v2/$1/manifests/$2" 2>/dev/null \
    | awk 'tolower($1)=="docker-content-digest:"{print $2}' | tr -d '\r'
}

# --- Jenkins-idle guard --------------------------------------------------------------
# The header says "run with Jenkins idle" because a garbage-collect racing an in-flight
# push can corrupt the blob store: GC decides a blob is unreferenced, deletes it, and the
# manifest that was about to reference it then points at nothing. Until 2026-08-07 that
# was enforced only by PRINTING a reminder to a human, which is why this script could not
# be scheduled — and so it never ran, and the registry grew unbounded (302 build tags per
# service by 2026-08-06).
#
# Now it CHECKS. If Jenkins reports a running build or a non-empty queue, we skip this
# run entirely and exit 0: a deferred prune is a non-event (the next run picks it up),
# whereas a corrupted registry means every image has to be rebuilt. Unreachable Jenkins or
# a missing credential is treated the same way — refuse rather than guess.
# Set PRUNE_FORCE=1 to override when you know the queue is idle.
jenkins_is_busy() {
  local cred host busy queued
  cred="$(grep -E '^JENKINS_CRED=' "$(dirname "$0")/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'')"
  host="${JENKINS_HOST:-jenkins.traderyolo.com}"
  [ -n "$cred" ] || { log "no JENKINS_CRED — cannot confirm Jenkins is idle"; return 0; }
  busy="$(curl -skg --max-time 10 -u "$cred" \
      "https://$host/api/json?tree=jobs[lastBuild[building]]" 2>/dev/null \
      | grep -o '"building":true' | wc -l)"
  queued="$(curl -skg --max-time 10 -u "$cred" "https://$host/queue/api/json?tree=items[id]" 2>/dev/null \
      | grep -o '"id"' | wc -l)"
  [ -z "$busy" ] && { log "could not reach Jenkins — cannot confirm it is idle"; return 0; }
  if [ "$busy" -gt 0 ] || [ "$queued" -gt 0 ]; then
    log "Jenkins is busy ($busy building, $queued queued)"
    return 0
  fi
  return 1
}

if [ "$APPLY" = 1 ] && [ "${PRUNE_FORCE:-0}" != "1" ]; then
  if jenkins_is_busy; then
    log "SKIPPING this run — a GC racing an in-flight push can corrupt the blob store."
    log "  The next scheduled run will retry. Override with PRUNE_FORCE=1 if you know it is idle."
    exit 0
  fi
  log "Jenkins idle — safe to prune."
fi

[ "$APPLY" = 1 ] && log "APPLY mode — manifests WILL be deleted." \
                 || log "dry-run (pass --apply to delete). keep=$KEEP_BUILDS build tags per repo."

repos=$(curl -sf --max-time 10 "$REG_URL/v2/_catalog?n=1000" | jq -r '.repositories[]') \
  || die "registry unreachable at $REG_URL"

total_del=0; total_kept=0; total_skip_shared=0; total_unresolved=0
for repo in $repos; do
  # `.tags[]?` tolerates "tags": null (a repo whose manifests were all deleted).
  tags=$(curl -sf --max-time 10 "$REG_URL/v2/$repo/tags/list" | jq -r '.tags[]?') || tags=""
  [ -n "$tags" ] || { log "$repo: no tags — skipping"; continue; }

  build_tags=$(printf '%s\n' "$tags" | grep -E '^b[0-9]+$' || true)
  named_tags=$(printf '%s\n' "$tags" | grep -vE '^b[0-9]+$' || true)
  n_build=$(printf '%s' "$build_tags" | grep -c . || true)

  if [ "$n_build" -le "$KEEP_BUILDS" ]; then
    log "$repo: $n_build build tags (<= $KEEP_BUILDS) — nothing to prune"
    continue
  fi

  # sort -V orders b999 < b1246 correctly (numeric run comparison).
  keep_builds=$(printf '%s\n' "$build_tags" | sort -V | tail -n "$KEEP_BUILDS")
  prune_tags=$(printf '%s\n' "$build_tags" | grep -vxF -f <(printf '%s\n' "$keep_builds"))

  # Resolve the digest keep-set: named tags + the kept builds.
  declare -A keep_digest=()
  while read -r t; do
    [ -n "$t" ] || continue
    d=$(digest_for "$repo" "$t")
    if [ -n "$d" ]; then keep_digest[$d]=1; else
      log "WARN: $repo:$t (KEEP tag) did not resolve to a digest — being conservative, continuing"
    fi
  done <<EOF
$named_tags
$keep_builds
EOF

  # Walk the prune tags, dedupe by digest, protect the keep-set.
  declare -A doomed=()
  unresolved=0
  while read -r t; do
    [ -n "$t" ] || continue
    d=$(digest_for "$repo" "$t")
    if [ -z "$d" ]; then unresolved=$((unresolved+1)); continue; fi
    [ -n "${keep_digest[$d]:-}" ] && { total_skip_shared=$((total_skip_shared+1)); continue; }
    doomed[$d]=1
  done <<EOF
$prune_tags
EOF

  n_doom=${#doomed[@]}
  n_keep=$(( $(printf '%s' "$named_tags" | grep -c . || true) + KEEP_BUILDS ))
  total_kept=$((total_kept+n_keep)); total_unresolved=$((total_unresolved+unresolved))
  if [ "$APPLY" = 1 ]; then
    ok=0
    for d in "${!doomed[@]}"; do
      curl -sf --max-time 20 -X DELETE "$REG_URL/v2/$repo/manifests/$d" >/dev/null \
        && ok=$((ok+1)) || log "WARN: DELETE failed for $repo@$d"
    done
    log "$repo: deleted $ok/$n_doom manifests (kept $n_keep tags, $unresolved unresolved)"
    total_del=$((total_del+ok))
  else
    log "$repo: would delete $n_doom manifests (keep $n_keep tags: named + newest $KEEP_BUILDS builds)"
    total_del=$((total_del+n_doom))
  fi
  unset keep_digest doomed
done

verb=$( [ "$APPLY" = 1 ] && echo "deleted" || echo "would delete" )
log "---- summary: $verb $total_del manifests; $total_skip_shared prune-tag digest(s) spared (shared with a kept tag); $total_unresolved unresolved"

# ---- garbage-collect + restart (frees the actual disk) --------------------------------
[ "$APPLY" = 1 ] || { log "dry-run: skipping garbage-collect. Done."; exit 0; }
[ "$SKIP_GC" = 1 ] && { log "--skip-gc: manifests deleted; run GC later to free disk."; exit 0; }

pod=$(kubectl -n "$NS" get po -l actual-registry=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$pod" ] || die "no registry pod found (label actual-registry=true in $NS) — run GC by hand"
log "garbage-collect in pod $pod (this pauses nothing but should not race a push)..."
if kubectl -n "$NS" exec "$pod" -- registry garbage-collect --delete-untagged=true /etc/distribution/config.yml \
   || kubectl -n "$NS" exec "$pod" -- registry garbage-collect --delete-untagged=true /etc/docker/registry/config.yml; then
  log "GC done — restarting the registry (it caches blob refs in memory)"
  kubectl -n "$NS" rollout restart deploy/registry \
    && kubectl -n "$NS" rollout status deploy/registry --timeout=180s
  log "blob store usage now:"; df -h /mnt/kachra | tail -1
else
  die "garbage-collect failed in $pod — blobs are NOT freed yet; inspect the pod and re-run GC manually"
fi
