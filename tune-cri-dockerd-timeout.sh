#!/bin/bash
####################################
#
# tune-cri-dockerd-timeout.sh — raise cri-dockerd's per-operation deadline.
#
####################################
# WHY THIS EXISTS (2026-07-29)
#
# /var/lib/docker lives on sda7 — the same ageing SATA SSD (Samsung 840) as /. When
# several Jenkins builds and their app rollouts run at once that disk saturates:
# sustained 95-99% util, ~180ms write-await, ~150ms FLUSH-await, and /proc/pressure/io
# "full" around 48% (i.e. half of all wall-clock with EVERY task stalled on IO) while
# the CPU sat 88% idle. Container creation is an overlay2 WRITE, so on a pegged disk a
# single CreateContainer can outlast cri-dockerd's default 2m deadline. When it does:
#
#   1. cri-dockerd aborts      -> kubelet logs "CreateContainerError: operation
#                                 timeout: context deadline exceeded"
#   2. dockerd finishes anyway -> an orphan container holding the deterministic
#                                 k8s_<container>_<pod>_<ns>_<uid>_0 name
#   3. kubelet retries         -> "Conflict. The container name ... is already in
#                                 use", i.e. CreateContainerError AGAIN
#   4. kubelet GC reaps the orphan ~a minute later and the whole cycle repeats
#
# That burns 2-4 minutes PER CONTAINER, which is why a cold start-scratch could leave
# pods sitting in Init/PodInitializing/CreateContainerError more or less indefinitely.
# The image is irrelevant: we observed the timeout while creating hashicorp/vault:2.0.2,
# an image the event log confirmed was ALREADY present on the node. Nothing was
# downloading — it is the write path, not the pull.
#
# Raising the deadline does not make the disk faster. It makes a slow-but-progressing
# create SUCCEED instead of failing and orphaning, which removes the retry storm (and
# the retry storm's own extra IO). The throughput fixes live elsewhere: stop firing
# every deploy at once (trigger-app-builds.sh throttling) and, ultimately, move
# /var/lib/docker onto NVMe.
#
# Idempotent: only writes + restarts when the wanted value is not already in effect,
# so it is safe to call on every bring-up. Does NOT survive `minikube delete` — which
# is exactly why start-scratch.sh and restart-minikube.sh call it after `minikube start`.
#
# Usage:  ./tune-cri-dockerd-timeout.sh            # apply the default 15m
#         CRI_TIMEOUT=30m ./tune-cri-dockerd-timeout.sh
set -eu

CRI_TIMEOUT="${CRI_TIMEOUT:-15m}"
# Sorts AFTER minikube's own 10-cni.conf so our ExecStart is the one that wins.
DROPIN="/etc/systemd/system/cri-docker.service.d/20-runtime-timeout.conf"

command -v minikube >/dev/null || { echo "tune-cri-dockerd-timeout: minikube not on PATH" >&2; exit 1; }

# Built here, run inside the node. We deliberately DERIVE the current effective
# ExecStart instead of hardcoding it, so a minikube upgrade that changes
# --pod-infra-container-image (or adds flags) is carried over verbatim rather than
# silently reverted by this drop-in.
remote_script="$(cat <<REMOTE
set -eu
dropin="$DROPIN"
want="--runtime-request-timeout=$CRI_TIMEOUT"

if systemctl cat cri-docker.service 2>/dev/null | grep -q -- "\$want"; then
  echo "cri-dockerd already running with \$want — nothing to do"
  exit 0
fi

base="\$(systemctl cat cri-docker.service 2>/dev/null \
        | grep '^ExecStart=/usr/bin/cri-dockerd' | tail -1 | sed 's/^ExecStart=//')"
[ -n "\$base" ] || { echo "could not read cri-docker ExecStart" >&2; exit 1; }
# Strip any previous value so re-running with a different CRI_TIMEOUT actually changes it.
base="\$(printf '%s' "\$base" | sed -E 's/ --runtime-request-timeout=[^ ]*//g')"

mkdir -p "\$(dirname "\$dropin")"
{
  echo '[Service]'
  echo 'ExecStart='
  echo "ExecStart=\$base \$want"
} > "\$dropin"

systemctl daemon-reload
# Restarting cri-dockerd drops the kubelet's CRI connection for a moment; the kubelet
# reconnects on its own and dockerd keeps every running container alive meanwhile.
systemctl restart cri-docker.service
echo "applied: \$want"
REMOTE
)"

# base64 over the wire so no amount of quoting in the script above can be mangled by
# the ssh/shell layers in between.
minikube ssh -- "echo $(printf '%s' "$remote_script" | base64 -w0) | base64 -d | sudo bash"

echo "tune-cri-dockerd-timeout: verifying..."
minikube ssh -- 'systemctl cat cri-docker.service | grep -c -- "--runtime-request-timeout" >/dev/null \
  && systemctl is-active cri-docker.service' \
  && echo "tune-cri-dockerd-timeout: OK (${CRI_TIMEOUT})"
