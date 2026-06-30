#!/bin/bash
####################################
#
# Bound the node's docker build cache so it stops creeping up /var.
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
# WHY NOT reduce-docker-minikube-space.sh:
#   That script uses `docker system prune -a -f` (host AND node), which deletes EVERY
#   image not bound to a running container — including app images the node cached from
#   the registry and base images Jenkins reuses → next deploy/build re-pulls and
#   rebuilds everything. That's the manual emergency hammer, NOT something to schedule.
#   This script is the gentle, daily, surgical version: cache cap + dangling only, no -a.
#
# SCHEDULE: root cron, daily ~04:30 (before the Monday 05:00 backup). See crontab.

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

echo "=== reduce-node-docker-cache $(date) ==="
echo "--- /var BEFORE ---"
df -h /var | tail -1

echo "--- node docker df BEFORE ---"
minikube ssh -- docker system df

# 1) Cap the build cache (the actual /var grower). No -a: keep recent layers.
echo "--- pruning node build cache (reserved-space=$RESERVED_SPACE) ---"
minikube ssh -- docker builder prune -f --reserved-space "$RESERVED_SPACE"

# 2) Remove dangling (untagged) images. Safe: nothing can reference them. Frees little
#    on its own (shared layers) but keeps the image list from accumulating orphans.
echo "--- pruning node dangling images ---"
minikube ssh -- docker image prune -f

echo "--- node docker df AFTER ---"
minikube ssh -- docker system df

echo "--- /var AFTER ---"
df -h /var | tail -1
echo "=== done $(date) ==="
