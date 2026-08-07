#!/usr/bin/env bash
# ensure-registry-store.sh — make the sdb2 registry blob store visible inside the minikube node.
# R8 (plan.md): persist the registry off /var so a cluster stop no longer wipes every image.
#
# MECHANISM (see k8s/registry/README.md for the full reasoning):
#   minikube's docker driver binds ONE host dir into the node: /mnt/minikube-mnt → /mnt.
#   sdb2 (/mnt/kachra) is a separate disk that is NOT in the node. The docker driver takes only one
#   --mount-string and its bind is rprivate, so we cannot add sdb2 to a *running* node. Instead we
#   bind sdb2's image dir INTO the minikube-mnt tree on the HOST (persisted in /etc/fstab). Because
#   docker bind-mounts are recursive (rbind), this nested mount is captured when the minikube container
#   is (re)created — i.e. it takes effect on the next COLD boot (minikube delete + start-scratch.sh).
#   The node then sees it at /mnt/container-registry-images, which the registry PV hostPath points to.
#
# MUST run BEFORE `minikube start` creates the container. Idempotent. Needs sudo for mount/fstab.
set -euo pipefail

SRC="/mnt/kachra/container-registry-images"                                   # sdb2 — durable, off /var
DST="/mnt/minikube-mnt/container-registry-images"            # inside the dir minikube binds to /mnt
FSTAB_LINE="$SRC $DST none bind 0 0"

sudo mkdir -p "$SRC" "$DST"

# Persist the bind across host reboots (idempotent: only add if absent).
if ! grep -qsF "$FSTAB_LINE" /etc/fstab; then
  echo "ensure-registry-store: adding fstab bind $SRC -> $DST"
  echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
fi

# Mount it now if not already mounted (so it exists before the next container creation).
if ! mountpoint -q "$DST"; then
  echo "ensure-registry-store: binding $SRC -> $DST"
  sudo mount --bind "$SRC" "$DST"
fi

echo "ensure-registry-store: OK — node will see this at /mnt/container-registry-images after the next cold boot."
