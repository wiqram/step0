#!/bin/bash
####################################
#
# Bound the docker build cache — on the NODE and on the HOST — so it stops creeping
# up /var. (Name kept for cron/doc stability; it covers both sides since 2026-08-04.)
#
####################################
#
# WHY THIS EXISTS (plan.md R7):
#   Jenkins builds every app image INSIDE minikube's embedded docker daemon, whose
#   data-root is the `minikube` docker volume at
#   /var/lib/docker/volumes/minikube/_data — i.e. on /var (sda7). Each build adds
#   buildkit cache layers and orphans the previous image. Nothing reclaims them, so
#   /var creeps up indefinitely (observed: 13 GB build cache, ~55% /var).
#
#   The build CACHE is the real grower — dangling images share layers with tagged
#   images and free ~0 B. So the cap below (--keep-storage) is what actually keeps
#   /var flat; the image prune is just tidy-up.
#
# HOST SIDE ADDED 2026-08-04, after /var hit 90% and the kubelet declared
# DiskPressure=True: the node was tainted, and Prometheus itself plus several app pods
# sat Pending — i.e. the monitoring stack went down with the disk. This script existed
# and had been running daily throughout, because everything it pruned was on the NODE.
# The space was on the HOST, in two places it never touched:
#   * the host's own buildkit cache          (2.8 GB reclaimed by hand that day)
#   * ORPHANED NAMED BUILD-CACHE VOLUMES     (11 GB: yolo-gomod, yolo-gobuildcache,
#     yolo-pipcache, yolo-npmcache, go-mod-cache, …). Jenkins mounts these into build
#     containers; when a job is renamed or retired its volume is simply left behind,
#     referenced by nothing, forever. NOTHING reclaimed them — that was the real gap.
#
# WHY THE VOLUME PRUNE IS AN ALLOWLIST AND NOT `docker volume prune`:
#   A blanket prune removes every unused volume, and on this box the unused list also
#   contains `nginx_npm_data` (the proxy-host + TLS config for every public domain),
#   `letsencrypt`, and `radcliffe_radcliffe-db-data`. Running it would take the site
#   configuration and a database with the build caches. So a volume is removed ONLY if
#   ALL THREE hold: docker reports it dangling (referenced by no container), its name
#   matches VOL_ALLOW (a build-tool cache), and its name does NOT match VOL_DENY
#   (anything that smells like state). Verified against the 11 volumes actually removed
#   on 2026-08-04 and against a dozen data-volume names: catches every cache, touches
#   no data volume. Deleting a cache costs one slower build; there is no data in them.
#
# WHY NOT reduce-docker-minikube-space.sh:
#   That script uses `docker system prune -a -f` (host AND node), which deletes EVERY
#   image not bound to a running container — including app images the node cached from
#   the registry and base images Jenkins reuses → next deploy/build re-pulls and
#   rebuilds everything. That's the manual emergency hammer, NOT something to schedule.
#   This script is the gentle, daily, surgical version: cache cap + dangling only, no -a.
#
# SCHEDULE: the CLOUD crontab (cron/cloud-crontab), daily 04:30 Europe/London — before
#   the Monday 05:00 root backup. Not root's crontab; it needs only docker group access.
#
# Usage:
#   ./reduce-node-docker-cache.sh             # prune node + host
#   ./reduce-node-docker-cache.sh --dry-run   # print what WOULD be removed, change nothing

# Single-instance guard (flock). A slow prune overlapping the next day's run (or a
# manual sudo invocation) would have two `docker builder prune` racing the same
# daemon. Grab an exclusive, non-blocking lock; if another run holds it, exit quietly.
LOCKFILE="/tmp/reduce-node-docker-cache.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another reduce-node-docker-cache run holds $LOCKFILE; exiting."; exit 0; }

# Cap the node's buildkit cache. --reserved-space retains the most-recently-used layers
# up to this ceiling (keeps incremental builds fast) and removes the rest. This is the
# knob that bounds /var; tune the size, not the schedule, if /var still drifts.
# NOTE: on docker 29.x this flag is `--reserved-space` (it was renamed from the older
# `--keep-storage`, which now only warns). Bump if a minikube/docker downgrade reverts it.
RESERVED_SPACE="3GB"

# Host-side buildkit cache cap. Smaller than the node's: the host daemon only builds
# the occasional image, the node is where Jenkins works.
HOST_RESERVED_SPACE="${HOST_RESERVED_SPACE:-2GB}"

# A volume is removed only if it is dangling AND matches ALLOW AND does NOT match DENY.
# See the header for why this is an allowlist. Extend ALLOW when a new build tool shows
# up; extend DENY the moment a data volume's name looks even slightly cache-like.
VOL_ALLOW='^[A-Za-z0-9_.-]*(go-?mod|go-?build|npm-?cache|pip-?cache|yarn-?cache|gradle-?cache|maven-?cache|cargo-?cache)[A-Za-z0-9_.-]*$'
VOL_DENY='(data|db|postgres|mysql|mongo|redis|vault|letsencrypt|registry|minikube|grafana|prometheus)'

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") : ;;
  *) echo "unknown arg: $1 (use --dry-run)" >&2; exit 2 ;;
esac

echo "=== reduce-node-docker-cache $(date) ==="
[ "$DRY_RUN" = 1 ] && echo "--- DRY RUN: nothing will be removed ---"
echo "--- /var BEFORE ---"
df -h /var | tail -1

echo "--- node docker df BEFORE ---"
minikube ssh -- docker system df

# 1) Cap the build cache (the actual /var grower). No -a: keep recent layers.
echo "--- pruning node build cache (reserved-space=$RESERVED_SPACE) ---"
if [ "$DRY_RUN" = 1 ]; then echo "    (dry-run) minikube ssh -- docker builder prune -f --reserved-space $RESERVED_SPACE"
else minikube ssh -- docker builder prune -f --reserved-space "$RESERVED_SPACE"; fi

# 2) Remove dangling (untagged) images. Safe: nothing can reference them. Frees little
#    on its own (shared layers) but keeps the image list from accumulating orphans.
echo "--- pruning node dangling images ---"
if [ "$DRY_RUN" = 1 ]; then echo "    (dry-run) minikube ssh -- docker image prune -f"
else minikube ssh -- docker image prune -f; fi

echo "--- node docker df AFTER ---"
minikube ssh -- docker system df

# ============================ HOST SIDE (added 2026-08-04) ========================
# Everything above runs INSIDE minikube. The 2026-08-04 DiskPressure incident was
# caused entirely by host-side growth this script never looked at. See the header.

echo "--- host docker df BEFORE ---"
docker system df

# 3) Host buildkit cache.
echo "--- pruning host build cache (reserved-space=$HOST_RESERVED_SPACE) ---"
if [ "$DRY_RUN" = 1 ]; then echo "    (dry-run) docker builder prune -f --reserved-space $HOST_RESERVED_SPACE"
else docker builder prune -f --reserved-space "$HOST_RESERVED_SPACE"; fi

# 4) Host dangling images. Same reasoning as (2); still no -a, so tagged images that
#    Jenkins and the apps reuse are untouched.
echo "--- pruning host dangling images ---"
if [ "$DRY_RUN" = 1 ]; then echo "    (dry-run) docker image prune -f"
else docker image prune -f; fi

# 5) Orphaned named BUILD-CACHE volumes — the 11 GB nothing reclaimed. Allowlisted, see
#    header. `-f dangling=true` is docker's own "referenced by no container", so a volume
#    mounted into a running build is never a candidate.
echo "--- removing orphaned build-cache volumes (allowlisted) ---"
_vol_found=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  printf '%s\n' "$v" | grep -qE "$VOL_ALLOW" || continue          # not a build cache
  if printf '%s\n' "$v" | grep -qiE "$VOL_DENY"; then
    echo "    SKIP (deny-list) $v"                                 # looks like state
    continue
  fi
  _vol_found=1
  if [ "$DRY_RUN" = 1 ]; then
    echo "    (dry-run) would remove volume $v"
  else
    if docker volume rm "$v" >/dev/null 2>&1; then echo "    removed volume $v"
    else echo "    FAILED to remove volume $v (in use?)"; fi
  fi
done <<< "$(docker volume ls -q -f dangling=true 2>/dev/null)"
[ "$_vol_found" = 1 ] || echo "    none (no orphaned build-cache volumes)"

echo "--- host docker df AFTER ---"
docker system df

echo "--- /var AFTER ---"
df -h /var | tail -1
echo "=== done $(date) ==="
