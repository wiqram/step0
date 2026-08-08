#!/usr/bin/env bash
# ensure-registry-store.sh — make the `Kachra` registry blob store visible inside the minikube node.
# R8 (docs/plan.md): persist the registry off /var so a cluster stop no longer wipes every image.
#
# MECHANISM (see k8s/registry/README.md for the full reasoning):
#   minikube's docker driver binds ONE host dir into the node: /mnt/minikube-mnt → /mnt.
#   /mnt/kachra is a SEPARATE filesystem that is NOT in the node. The docker driver takes only one
#   --mount-string and its bind is rprivate, so we cannot add it to a *running* node. Instead we
#   bind its image dir INTO the minikube-mnt tree on the HOST (persisted in /etc/fstab). Because
#   docker bind-mounts are recursive (rbind), this nested mount is captured when the minikube container
#   is (re)created — i.e. it takes effect on the next COLD boot (minikube delete + start-scratch.sh).
#   The node then sees it at /mnt/container-registry-images, which the registry PV hostPath points to.
#
# MUST run BEFORE `minikube start` creates the container. Idempotent. Needs sudo for mount/fstab.
set -euo pipefail

# Addressed by LABEL via /etc/fstab, never by device node. `Kachra` lived on the 1TB WD10EZEX
# HDD (sda2) until 2026-08-07, when it moved to its own NVMe partition (nvme0n1p7) by swapping
# the labels — so nothing here changed. Do not re-introduce a device name in this comment or
# the code; the label is the contract (docs/GM9000-MIGRATION.md §1.2).
SRC="/mnt/kachra/container-registry-images"                  # label `Kachra` — durable, off /var
DST="/mnt/minikube-mnt/container-registry-images"            # inside the dir minikube binds to /mnt
FSTAB_LINE="$SRC $DST none bind 0 0"

# Only escalate when there is actually something to create. `sudo mkdir -p` on directories that
# already exist still triggers an authentication PROMPT, and this script runs from start-scratch.sh
# immediately before `minikube start` — so a warm re-run stalled a long bootstrap on a password
# for zero work. Worse on Ubuntu 26.04, where sudo-rs caches per-tty: a fresh terminal always
# prompts, and a headless run cannot answer at all.
if [ ! -d "$SRC" ] || [ ! -d "$DST" ]; then
  sudo mkdir -p "$SRC" "$DST"
fi

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
