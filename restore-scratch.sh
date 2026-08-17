#!/bin/bash
####################################
#
# restore-scratch.sh — COLD disaster recovery: bare Ubuntu -> fully wired private cloud
# from the latest WD Cloud (LAN NFS) backup. Inverse of backup-minikube-mnt.sh; ends by
# running start-scratch.sh (SKIP_APP_BUILDS=1) then pausing before app deploys.
#
# Design: docs/superpowers/specs/2026-06-30-restore-scratch-design.md
# Plan:   docs/superpowers/plans/2026-06-30-restore-scratch.md
####################################
# Deliberately NOT `set -e`: a ~100GB DR run must not die silently mid-way. Each phase
# validates its own critical steps via die()/need(). Resumable via a phase marker.
#
# Usage:
#   ./restore-scratch.sh                 # run all phases from the last completed one
#   ./restore-scratch.sh --from-phase N  # force-resume at phase N (0-9)
#   ./restore-scratch.sh --dry-run       # print intended actions, mutate nothing
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/restore-lib.sh"
# Push notifications -> ntfy `yolo-private-cloud-restore-scratch`. Best-effort source:
# on a bare Ubuntu box STEP0 is cloned by hand before this runs, so the lib is normally
# right here — but a DR must never fail for want of a notification.
# shellcheck source=/dev/null
if [ -r "$SCRIPT_DIR/ntfy-lib.sh" ]; then source "$SCRIPT_DIR/ntfy-lib.sh"; else
  ntfy_push() { :; }; NTFY_TOPIC_RESTORE_SCRATCH=""
fi

MARKER="/mnt/minikube-backups/.restore-phase"   # last COMPLETED phase number
DRY_RUN=0
FROM_PHASE=""
LOG_DIR="$SCRIPT_DIR/logs"

# ---- args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --from-phase) shift; FROM_PHASE="${1:-}" ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
# Validate --from-phase early (it feeds numeric comparisons in should_run).
if [ -n "$FROM_PHASE" ] && ! [[ "$FROM_PHASE" =~ ^[0-9]$ ]]; then
  echo "--from-phase must be a single digit 0-9" >&2; exit 2
fi

# ---- helpers ----
log()  { echo "[restore $(date '+%H:%M:%S')] $*"; }

# rs_notify <title> <body> [priority] [tags] — the restore-scratch channel's single
# entry point. Silent under --dry-run: that mode mutates nothing and exists to be run
# repeatedly while reading the plan, so it must not page anyone. RS_NOTIFIED records
# that a terminal message (done or failed) has gone out, so the EXIT trap below only
# speaks when the run ended some OTHER way — a Ctrl-C, a SIGTERM, an `exit` added
# later. A DR run that stops silently at 03:00 is the case worth catching.
RS_START=$(date +%s)
RS_NOTIFIED=0
RS_INCOMPLETE=""   # space-separated phase numbers that had failing commands (see mark_phase)
rs_notify() {
  [ "$DRY_RUN" = 1 ] && return 0
  ntfy_push "$NTFY_TOPIC_RESTORE_SCRATCH" "$1" "$2" "${3:-default}" "${4:-cloud}"
  return 0
}
rs_elapsed() { local e=$(( $(date +%s) - RS_START )); echo "$(( e / 3600 ))h $(( (e % 3600) / 60 ))m"; }
rs_phase() { cat "$MARKER" 2>/dev/null || echo "none"; }

die()  {
  echo "[restore FATAL] $*" >&2
  RS_NOTIFIED=1
  rs_notify "restore-scratch FAILED" \
"$*

Host: $(hostname -s). Elapsed: $(rs_elapsed). Last completed phase: $(rs_phase).
Resume after fixing with:  ./restore-scratch.sh --from-phase <n>" \
    "urgent" "rotating_light,floppy_disk"
  exit 1
}
rs_on_exit() {
  local rc=$?
  [ "$RS_NOTIFIED" = 1 ] && return 0
  [ "$DRY_RUN" = 1 ] && return 0
  rs_notify "restore-scratch ENDED early (rc=$rc)" \
"The run stopped without reaching the handoff and without a FATAL - interrupted, killed,
or the host went down. Host: $(hostname -s). Elapsed: $(rs_elapsed).
Last completed phase: $(rs_phase). Resume with:  ./restore-scratch.sh --from-phase <n>" \
    "high" "warning,floppy_disk"
  return 0
}
trap rs_on_exit EXIT
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
# ---- phase integrity ------------------------------------------------------------------
# The script is deliberately not `set -e`, and run() used to DISCARD the exit status of
# every command it executed. Combined with a marker that advanced unconditionally, a phase
# could fail from end to end and still report itself complete. That is not hypothetical:
# on 2026-08-07 sudo-rs refused to authenticate without a tty, all ~30 mutating commands in
# phase 1 failed, the log said "phase 1 done", the marker went to 1, and the box had no
# docker, kubectl, minikube or helm. The next run then SKIPPED phase 1 because it was
# "done". A DR tool that misreports its own state is worse than one that stops.
#
# So: run() records failures, and mark_phase refuses to advance past a phase that had any.
# The phase is simply not marked — the run continues (a 100GB DR should not abort on one
# bad command) but a re-run redoes that phase instead of skipping it. Commands that are
# ALLOWED to fail already say so with `|| true`, which returns 0 and is not recorded; the
# 8 such calls in this file are exactly the tolerated ones.
RUN_FAILED=()

# run: execute unless --dry-run (then just print). Use for every mutating command.
# Returns the command's own exit status, so existing `run "..." || die "..."` still works.
# shellcheck disable=SC2086,SC2294
run()  {
  if [ "$DRY_RUN" = 1 ]; then echo "  DRYRUN> $*"; return 0; fi
  log "+ $*"
  local rc=0
  eval "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    RUN_FAILED+=("rc=$rc  $*")
    log "  ^^ FAILED (rc=$rc)"
  fi
  return "$rc"
}

# free_web_ports — nothing on the HOST may hold :80 or :443. nginx-proxy-manager binds both
# (phase 7) and is the only public ingress: every *.traderyolo.com domain and every
# Let's Encrypt HTTP-01 renewal goes through it.
#
# A stock Ubuntu install ships apache2 ENABLED and listening on :80. Found on 2026-08-07 on
# the freshly-installed 26.04 box: `docker compose up` failed with
#   failed to bind host port 0.0.0.0:80/tcp: address already in use
# and — the part that actually cost time — compose left the NPM container CREATED but
# attached to no network with no published ports, so the next `up` merely STARTED that
# broken container. It sat "unhealthy" resolving nothing, which looks nothing like a port
# clash. Hence: clear the ports BEFORE anything tries to bind them, and force-recreate in
# phase 7 rather than trusting a container that may be a corpse of a failed create.
#
# Deliberately not a `die`: an operator may be running some other proxy on purpose. We stop
# and disable the known offenders, then report anything still holding the ports.

# web_server_wants_ports <svc> — true only if <svc> is really enabled at boot or running now.
# Test the REPORTED STATE, never the exit status: `systemctl is-enabled httpd` prints "alias"
# and exits 0 on Ubuntu (apache2.service declares Alias=httpd.service), so an exit-status test
# "finds" a service that is not installed. Meanwhile a genuinely disabled apache2 prints
# "disabled" and exits 1 — i.e. the exit status is backwards for both cases that matter.
web_server_wants_ports() {
  local en ac
  en="$(systemctl is-enabled "$1" 2>/dev/null)"
  ac="$(systemctl is-active  "$1" 2>/dev/null)"
  case "$en" in enabled|enabled-runtime) return 0 ;; esac
  [ "$ac" = "active" ]
}

free_web_ports() {
  local svc still
  for svc in apache2 nginx lighttpd caddy; do
    if web_server_wants_ports "$svc"; then
      log "WARN: host service '$svc' is enabled/active and will fight nginx-proxy-manager for :80/:443 — disabling it"
      run "sudo systemctl disable --now $svc || true"
    fi
  done
  # Report whatever is left, whoever it is. ss needs root to name the process.
  still="$(sudo -n ss -tlnp 2>/dev/null | grep -E ':(80|443)\s' || true)"
  if [ -n "$still" ]; then
    log "WARN: something is STILL listening on :80/:443 — nginx-proxy-manager will fail to bind:"
    printf '%s\n' "$still" | sed 's/^/        /'
    log "      Free those ports before phase 7, or NPM (all public ingress + cert renewal) stays down."
  else
    log "ports :80/:443 are free for nginx-proxy-manager"
  fi
}

phase_done() { [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" -ge "$1" ] 2>/dev/null; }
# mark_phase ratchets: it only ever advances the marker, so a --from-phase re-run on an
# already-further-along box does not regress it (marker = highest completed phase).
mark_phase() {
  [ "$DRY_RUN" = 1 ] && return 0
  # Refuse to certify a phase whose commands did not actually succeed. Clearing RUN_FAILED
  # here is what scopes it per-phase: mark_phase is the last statement of every phase, and
  # a phase that die()s never reaches this, so nothing leaks into the next one.
  if [ "${#RUN_FAILED[@]}" -gt 0 ]; then
    log "PHASE $1 NOT MARKED COMPLETE — ${#RUN_FAILED[@]} command(s) failed:"
    local c
    for c in "${RUN_FAILED[@]}"; do log "      $c"; done
    log "      Marker stays at $(rs_phase). Fix the above, then: ./restore-scratch.sh --from-phase $1"
    RS_INCOMPLETE="${RS_INCOMPLETE:+$RS_INCOMPLETE }$1"
    rs_notify "restore-scratch phase $1 INCOMPLETE" \
"${#RUN_FAILED[@]} command(s) failed in phase $1 on $(hostname -s); the phase was NOT marked done.
First failure: ${RUN_FAILED[0]}
Resume after fixing with:  ./restore-scratch.sh --from-phase $1" \
      "high" "warning"
    RUN_FAILED=()
    return 0
  fi
  local cur; cur="$(cat "$MARKER" 2>/dev/null)"; [[ "$cur" =~ ^[0-9]+$ ]] || cur=-1
  [ "$1" -gt "$cur" ] && echo "$1" > "$MARKER"
  RUN_FAILED=()
  return 0
}
# should_run: true unless this phase already completed (honours --from-phase override)
should_run() {
  local p="$1"
  if [ -n "$FROM_PHASE" ]; then [ "$p" -ge "$FROM_PHASE" ]; return; fi
  ! phase_done "$p"
}

# ============================== PHASE 0: PREFLIGHT ==============================
phase0_preflight() {
  should_run 0 || { log "phase 0 already done, skipping"; return; }
  log "PHASE 0 — preflight"
  [ "$(whoami)" = "cloud" ] || die "run as user 'cloud' (got $(whoami))"
  [ "$HOME" = "/home/cloud" ] || die "unexpected \$HOME: $HOME"
  # sudo has to work for the WHOLE run, not just the first minute. Ubuntu 26.04 ships
  # sudo-rs (0.2.x) as the default `sudo`, and it will not use a cached credential without a
  # controlling tty. Run headless (nohup/CI/an agent) every single `sudo` then fails with
  # "sudo: A terminal is required to authenticate" — and because run() does not check exit
  # status, the phases keep going, log success, and ratchet the phase marker. On 2026-08-07
  # that produced a "completed" phase 1 with docker, kubectl, minikube and helm all absent.
  # A DR that lies about what it did is worse than one that stops, so: stop.
  if ! sudo -n true 2>/dev/null; then
    if [ -t 0 ]; then
      log "NOTE: sudo will prompt for a password during install phases."
    else
      die "sudo needs a password and there is no tty — on Ubuntu 26.04 (sudo-rs) EVERY mutating
step would fail silently while this script reported success. Either run it from a real terminal,
or give this shell a working non-interactive sudo first, e.g.:
    printf '#!/bin/sh\\necho \$YOUR_PASSWORD\\n' > /tmp/askpass && chmod 700 /tmp/askpass
    mkdir -p /tmp/sudoshim && printf '#!/bin/sh\\nexec /usr/bin/sudo -A \"\$@\"\\n' > /tmp/sudoshim/sudo
    chmod 755 /tmp/sudoshim/sudo
    SUDO_ASKPASS=/tmp/askpass PATH=/tmp/sudoshim:\$PATH ./restore-scratch.sh"
    fi
  fi
  need curl
  cat <<'PRE'
------------------------------------------------------------------
restore-scratch.sh — COLD disaster recovery. Before continuing, confirm:
  1. GitHub auth is configured for this user (SSH key or token) so the
     private wiqram/* repos can be cloned. (You already cloned STEP0 to get here.)
  2. The WD Cloud NAS (192.168.50.169) is reachable on the LAN and its NFS share
     holds the latest private-cloud-*.tgz backup (this box will mount it to copy).
  3. You control DNS for the app domains / *.traderyolo.com — the script PAUSES
     before app deploys so you can repoint them at this host.
This box will be heavily modified (docker, minikube, NVIDIA drivers installed;
~100GB pulled; cron + restart policies set).
------------------------------------------------------------------
PRE
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: skipping confirmation"; else
    read -r -p "Proceed? type 'restore' to continue: " ans
    [ "$ans" = "restore" ] || die "aborted by operator"
  fi
  run "mkdir -p '$LOG_DIR'"
  mark_phase 0
}

# ============================== PHASE 1: HOST TOOLING ==============================
phase1_tooling() {
  should_run 1 || { log "phase 1 already done, skipping"; return; }
  log "PHASE 1 — install host tooling (docker, kubectl, minikube, helm, jq, nfs-common, NVIDIA)"

  # Reproduce the host identity (a bare box keeps its installer-chosen hostname). The
  # 127.0.1.1 /etc/hosts line and any hostname-derived config assume `private-cloud`.
  if [ "$(hostname -s 2>/dev/null)" != "private-cloud" ]; then
    run "sudo hostnamectl set-hostname private-cloud"
  fi

  # base packages (ethtool is needed in phase 8 to find the atlantic 10GbE NIC by driver)
  run "sudo apt-get update -y"
  run "sudo apt-get install -y ca-certificates curl gnupg jq git apt-transport-https nfs-common ethtool"

  # Clear :80/:443 now, not at phase 7. A stock Ubuntu ships apache2 enabled, and by the
  # time phase 7 discovers the clash it has already left a half-created NPM container behind.
  free_web_ports

  # Raise the inotify limits BEFORE the cluster exists. The kernel default of 128 user
  # instances is far too low for a node running ~40 pods: promtail watches every container
  # log file and dies at startup with
  #   failed to make file target manager: too many open files
  # which reads as a promtail bug rather than a host limit. Hit on the fresh 26.04 install
  # 2026-08-07. The minikube node is a CONTAINER sharing this kernel, so setting it here is
  # what fixes the node — there is nothing to set inside minikube.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> write /etc/sysctl.d/99-kubernetes-inotify.conf + sysctl -p"
  elif [ ! -f /etc/sysctl.d/99-kubernetes-inotify.conf ]; then
    printf '# Kubernetes node inotify limits — see restore-scratch.sh phase 1.\n# Default 128 instances starves promtail ("too many open files") on a ~40-pod node.\nfs.inotify.max_user_instances = 1024\nfs.inotify.max_user_watches = 524288\n' \
      | sudo tee /etc/sysctl.d/99-kubernetes-inotify.conf >/dev/null \
      && sudo sysctl -p /etc/sysctl.d/99-kubernetes-inotify.conf >/dev/null 2>&1 \
      && log "inotify limits raised (1024 instances / 524288 watches)" \
      || log "WARN: could not raise inotify limits — promtail may fail with 'too many open files'."
  else
    log "inotify limits already configured (/etc/sysctl.d/99-kubernetes-inotify.conf)"
  fi

  # Order the docker unit behind its own partition, BEFORE docker exists. On this box
  # /var/lib/docker is a separate filesystem (docs/GM9000-MIGRATION.md §1.2, p5 'docker-data').
  # Without this drop-in dockerd can start before that mount lands, write its whole graph
  # into the underlying directory, and then have the mount shadow it — images and volumes
  # are not lost, they are simply invisible, and the partition looks mysteriously empty.
  # Safe to write before docker is installed: the drop-in applies when the unit appears.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> write /etc/systemd/system/docker.service.d/require-docker-mount.conf"
  elif [ -e /dev/disk/by-label/docker-data ]; then
    sudo mkdir -p /etc/systemd/system/docker.service.d
    printf '[Unit]\nRequiresMountsFor=/var/lib/docker\n' \
      | sudo tee /etc/systemd/system/docker.service.d/require-docker-mount.conf >/dev/null
    sudo systemctl daemon-reload 2>/dev/null || true
    log "docker.service drop-in: RequiresMountsFor=/var/lib/docker"
  fi

  # docker (official convenience repo)
  if ! command -v docker >/dev/null 2>&1; then
    run "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh"
    run "sudo sh /tmp/get-docker.sh"
    run "sudo usermod -aG docker cloud"
    log "NOTE: docker group membership for 'cloud' applies on next login; this run uses sudo where needed."
  fi

  # Reproduce the host docker daemon config the live cluster is built on: the SYSTEMD cgroup
  # driver, a 100m per-container log cap (uncapped json logs can fill /), and overlay2.
  # nvidia-ctk (below) then MERGES the nvidia runtime into this same file. Only write on a
  # FRESH box (no existing daemon.json) so a re-run never clobbers the nvidia runtime stanza.
  #
  # 2026-08-07: this was `native.cgroupdriver=cgroupfs`, which was correct only while the
  # host ran cgroup v1. Ubuntu 26.04 ships systemd 259 and has REMOVED cgroup v1 entirely
  # (both legacy and hybrid hierarchies) — the box is cgroup2fs and cannot be put back.
  # `cgroupfs` on a v2 host gives docker the wrong driver against a systemd-managed
  # hierarchy: containers fail to start or the node misreports resources, and never with a
  # clean error at the point of misconfiguration. `systemd` is also what kubeadm expects.
  # See docs/UBUNTU-UPGRADE.md §0 and §2.3, which called out this exact line as the thing that
  # would silently revert the migration if restore-scratch.sh were re-run afterwards.
  if [ ! -f /etc/docker/daemon.json ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "  DRYRUN> write /etc/docker/daemon.json (systemd cgroup driver, log max-size 100m, overlay2) + restart docker"
    else
      sudo mkdir -p /etc/docker
      sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "storage-driver": "overlay2"
}
JSON
      sudo systemctl restart docker 2>/dev/null || true
      log "wrote /etc/docker/daemon.json (systemd cgroup driver + 100m log cap + overlay2)"
    fi
  fi

  # Guard the same invariant on a box that ALREADY has a daemon.json (the branch above is
  # skipped there): a stale cgroupfs setting is invisible until the cluster misbehaves.
  if [ -f /etc/docker/daemon.json ] && grep -q 'native.cgroupdriver=cgroupfs' /etc/docker/daemon.json 2>/dev/null; then
    if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ]; then
      log "WARN: /etc/docker/daemon.json says native.cgroupdriver=cgroupfs but this host is cgroup v2."
      log "      Fix before starting the cluster:"
      log "        sudo sed -i 's/native.cgroupdriver=cgroupfs/native.cgroupdriver=systemd/' /etc/docker/daemon.json"
      log "        sudo systemctl restart docker && docker info | grep -i cgroup"
    fi
  fi

  # kubectl (pinned-stable via official pkg repo).
  #
  # THIS PIN MUST TRACK WHAT MINIKUBE ACTUALLY DEPLOYS. start-scratch.sh passes no
  # --kubernetes-version, so the API server is whatever the installed minikube defaults to
  # (minikube v1.38.1 -> k8s v1.35.1; confirmed against the prod node's own cached
  # preload tarball). kubectl's supported skew is +/-1 minor: this was pinned to v1.31
  # against a v1.35 server — four minors out — which does not fail loudly, it fails as
  # unknown fields being dropped and subresources not resolving.
  # When you bump minikube, re-check with:
  #   minikube start --help | grep -A2 kubernetes-version    # or the release's constants.go
  K8S_APT_MINOR="${K8S_APT_MINOR:-v1.35}"
  if ! command -v kubectl >/dev/null 2>&1; then
    run "sudo mkdir -p /etc/apt/keyrings"
    run "curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_APT_MINOR/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    run "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_APT_MINOR/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list"
    run "sudo apt-get update -y && sudo apt-get install -y kubectl"
  fi

  # minikube
  if ! command -v minikube >/dev/null 2>&1; then
    run "curl -fsSL https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 -o /tmp/minikube"
    run "sudo install /tmp/minikube /usr/local/bin/minikube"
  fi

  # helm
  if ! command -v helm >/dev/null 2>&1; then
    run "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  fi

  # NVIDIA driver + container toolkit (GPU). Driver may require a REBOOT before
  # minikube --gpus all works. We install ubuntu-drivers' recommended + the toolkit.
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    run "sudo apt-get install -y ubuntu-drivers-common"
    # 2026-08-07: ubuntu-drivers-common 1:0.10.9 (Ubuntu 26.04) rewrote the CLI as a
    # click app — `autoinstall` is GONE, the subcommand is now `install`. The old form
    # does NOT fail loudly: it prints a usage block and exits, and run() does not check
    # status, so phase 1 logged "driver installed" and marked itself done with no driver
    # present at all. That only surfaces much later, when `minikube start --gpus all`
    # comes up with no GPU. Prefer `install`; fall back to `autoinstall` on <=24.04.
    if ubuntu-drivers -h 2>&1 | grep -qE '^[[:space:]]+install\b'; then
      run "sudo ubuntu-drivers install"
    else
      run "sudo ubuntu-drivers autoinstall"
    fi
    # Verify rather than assume — this is the failure mode described above.
    if dpkg -l 2>/dev/null | grep -q '^ii  nvidia-driver-'; then
      log "WARNING: NVIDIA driver installed — a REBOOT is required before GPU passthrough works."
    else
      log "WARN: no nvidia-driver-* package present after ubuntu-drivers ran."
      log "      minikube --gpus all (phase 6) will get NO GPU. Install by hand:"
      log "        sudo ubuntu-drivers list && sudo apt-get install -y nvidia-driver-580"
      log "      then REBOOT and resume with: ./restore-scratch.sh --from-phase 2"
    fi
  fi
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    run "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    run "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    run "sudo apt-get update -y && sudo apt-get install -y nvidia-container-toolkit"
    run "sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
  fi

  # gcloud SDK (no-root, home install) to ~/google-cloud-sdk — kept for the
  # commented-out GCS Coldline fallback in backup-minikube-mnt.sh; the live DR
  # pull now comes from the WD Cloud NFS share (phase 2), not GCS.
  if [ ! -x "$HOME/google-cloud-sdk/bin/gcloud" ]; then
    run "curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz -o /tmp/gcloud.tgz"
    run "tar -xzf /tmp/gcloud.tgz -C \"$HOME\""
    run "\"$HOME/google-cloud-sdk/install.sh\" --quiet --path-update true"
  fi

  log "phase 1 done. If NVIDIA driver was just installed, REBOOT then re-run: ./restore-scratch.sh"
  mark_phase 1
}

# ============================== PHASE 2: PULL BACKUP ==============================
WD_HOST="192.168.50.169"                       # WD Cloud 6TB on the LAN
WD_EXPORT="/nfs/private-cloud"                  # dedicated NFS share (see backup-minikube-mnt.sh setup)
WD_MOUNT="/mnt/wdcloud"
WD_DEST="$WD_MOUNT"                             # dedicated share — archives at the mount root
BACKUP_DIR="/mnt/minikube-backups"
ARCHIVE_PATH=""   # set by phase2, consumed by phase4

phase2_pull() {
  should_run 2 || { log "phase 2 already done, skipping"; ARCHIVE_PATH="$(cat "$BACKUP_DIR/.restore-archive" 2>/dev/null)"; return; }
  log "PHASE 2 — mount WD Cloud (NFS) + pull latest backup"
  run "sudo mkdir -p '$BACKUP_DIR' && sudo chown cloud:cloud '$BACKUP_DIR'"
  run "sudo mkdir -p '$WD_MOUNT'"

  # Mount the WD NFS share if it is not already mounted.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> sudo mount -t nfs -o hard,timeo=600,retrans=3 $WD_HOST:$WD_EXPORT $WD_MOUNT"
    echo "  DRYRUN> ls $WD_DEST/private-cloud-*.tgz | pick_latest_archive"
    ARCHIVE_PATH="$BACKUP_DIR/<latest>.tgz"; return
  fi
  if ! mountpoint -q "$WD_MOUNT"; then
    run "sudo mount -t nfs -o hard,timeo=600,retrans=3 '$WD_HOST:$WD_EXPORT' '$WD_MOUNT'" \
      || die "cannot mount WD Cloud $WD_HOST:$WD_EXPORT at $WD_MOUNT"
  fi

  # Find newest archive by date embedded in filename (restore-lib pick_latest_archive).
  local listing latest
  listing="$(ls "$WD_DEST"/private-cloud-*.tgz 2>/dev/null)" || true
  [ -n "$listing" ] || die "no private-cloud-*.tgz found in $WD_DEST"
  latest="$(printf '%s\n' "$listing" | pick_latest_archive)"
  [ -n "$latest" ] || die "no private-cloud-*.tgz found in $WD_DEST"
  log "latest backup: $latest"
  # backup-minikube-mnt.sh runs from ROOT's crontab (it needs the 0600 SMB creds), so any
  # archive already sitting in $BACKUP_DIR is root:root 0644. This cp runs as 'cloud', and
  # cp opens the destination O_WRONLY|O_TRUNC rather than unlinking it — so overwriting a
  # root-owned archive fails with EACCES even though 'cloud' owns the directory. Only bites
  # on a RE-run (or a box where a backup already landed), which is exactly the DR case.
  # Hand the existing archives to 'cloud' first; harmless when they are already cloud's.
  if [ -e "$BACKUP_DIR/$(basename "$latest")" ] && [ ! -w "$BACKUP_DIR/$(basename "$latest")" ]; then
    run "sudo chown cloud:cloud '$BACKUP_DIR'/private-cloud-*.tgz"
  fi
  cp "$latest" "$BACKUP_DIR/" || die "copy from WD Cloud failed"
  ARCHIVE_PATH="$BACKUP_DIR/$(basename "$latest")"
  echo "$ARCHIVE_PATH" > "$BACKUP_DIR/.restore-archive"
  [ -s "$ARCHIVE_PATH" ] || die "copied archive is empty: $ARCHIVE_PATH"
  log "downloaded: $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | awk '{print $1}'))"
  mark_phase 2
}

# ============================== PHASE 3: STORAGE LAYOUT ==============================
phase3_dirs() {
  should_run 3 || { log "phase 3 already done, skipping"; return; }
  log "PHASE 3 — recreate storage directories + mount the dedicated backup disk"

  # --- Dedicated backup disk (NON-destructive) --------------------------------------
  # The live prod box is TWO-disk: a separate ~638G disk holds /mnt/minikube-backups
  # (label 'minikube-backups', ~150G+ of cluster state) and /mnt/kachra (label 'Kachra',
  # registry blobs). A 44G root disk canNOT hold the restored minikube-mnt. We NEVER
  # auto-format (destructive); instead: if the labelled filesystem already exists, mount it
  # (+ persist an fstab line); if it does NOT, WARN loudly with the exact prep commands so
  # the operator attaches/formats the disk before the bulk extract (phase 4) targets root.
  ensure_labeled_mount() {   # $1=label  $2=mountpoint
    local label="$1" mp="$2"
    # Detect via the udev by-label symlink (no root needed) or an existing mount.
    if mountpoint -q "$mp" 2>/dev/null || [ -e "/dev/disk/by-label/$label" ]; then
      if [ "$DRY_RUN" = 1 ]; then echo "  DRYRUN> ensure $mp is mounted from label '$label' (+fstab)"; return; fi
      if ! mountpoint -q "$mp"; then
        sudo mkdir -p "$mp"
        grep -q " $mp " /etc/fstab 2>/dev/null \
          || echo "/dev/disk/by-label/$label $mp auto nosuid,nodev,nofail,x-gvfs-show 0 0" | sudo tee -a /etc/fstab >/dev/null
        sudo mount "$mp" 2>/dev/null || true
      fi
      log "backup disk: label '$label' -> $mp OK"
    else
      log "WARN: no filesystem labelled '$label' found — $mp would live on the ROOT disk."
      log "      Root is ~44G; the backup alone is ~150G+ and will NOT fit. Attach the disk, then:"
      log "        sudo mkfs.ext4 -L $label /dev/sdXN   &&   sudo mkdir -p $mp"
      log "        echo '/dev/disk/by-label/$label $mp auto nosuid,nodev,nofail 0 0' | sudo tee -a /etc/fstab"
      log "        sudo mount $mp   # then re-run: ./restore-scratch.sh --from-phase 3"
    fi
  }
  ensure_labeled_mount minikube-backups /mnt/minikube-backups
  ensure_labeled_mount Kachra           /mnt/kachra

  # --- OS-level partition layout (VERIFY ONLY — never mutates) -----------------------------
  # docs/GM9000-MIGRATION.md §1.2 puts /var, /home and /var/lib/docker on their own labelled
  # partitions of the 4TB NVMe. Those mountpoints are chosen in the INSTALLER, not here — but
  # the installer silently NOT applying them is a real, observed failure. After the 2026-08-07
  # reinstall all three partitions existed with the correct labels and sizes while /etc/fstab
  # carried only / and /boot/efi: the desktop auto-mounted them under /run/media/cloud/, so
  # /var, /home and every docker image landed on the 120G root and the 900G docker-data
  # partition sat empty. Nothing errors at any point — the box just fills up weeks later.
  # So: warn loudly, change nothing. Repairing this needs an unmounted /var, i.e. an operator.
  check_partition_mount() {   # $1=label  $2=expected mountpoint
    local label="$1" mp="$2" want got
    [ -e "/dev/disk/by-label/$label" ] || return 0     # partition absent on this box — fine
    want="$(readlink -f "/dev/disk/by-label/$label")"
    got="$(findmnt -no SOURCE --target "$mp" 2>/dev/null || true)"
    if [ -n "$got" ] && [ "$(readlink -f "$got" 2>/dev/null)" = "$want" ]; then
      log "layout: $mp is on '$label' ($want) OK"
    else
      log "WARN: partition '$label' ($want) exists, but $mp is served by ${got:-<nothing>}."
      log "      $mp is NOT on its intended partition — everything written there goes to root."
      log "      Expected /etc/fstab line:"
      log "        /dev/disk/by-label/$label  $mp  ext4  defaults  0 2"
    fi
  }
  check_partition_mount ubuntu-var  /var
  check_partition_mount ubuntu-home /home
  check_partition_mount docker-data /var/lib/docker

  run "sudo mkdir -p /mnt/minikube-mnt"
  run "sudo mkdir -p /mnt/kachra/container-registry-images"
  run "sudo mkdir -p /mnt/predictonomy-postgres /mnt/predictonomy-backups"
  # NOT -R, and NOT over minikube-mnt. A recursive chown here destroys the per-container
  # UIDs inside the shared volume (vault=100, grafana=472, the postgres/mysql/mongo 999s),
  # which phase 4 then cannot put back. Observed 2026-08-07: vault-0 wedged on
  # "open /vault/data/core/_migration: permission denied" because core/ ended up 1000:1000
  # mode 700 while vault runs as uid 100. Only the mountpoints themselves need to be cloud's.
  run "sudo chown cloud:cloud /mnt/minikube-backups /mnt/kachra /mnt/minikube-mnt"
  # Per-app SOPS age keys offline mirror (normally restored by phase 4a with ~/.vault;
  # pre-create so seed-age-keys.sh (run by start-vault.sh in phase 6) can re-seed Vault).
  run "mkdir -p '$HOME/.vault/age-keys' && chmod 700 '$HOME/.vault/age-keys'"
  mark_phase 3
}

# ============================== PHASE 4: EXTRACT ==============================
phase4_extract() {
  should_run 4 || { log "phase 4 already done, skipping"; return; }
  log "PHASE 4 — extract backup"
  [ "$DRY_RUN" = 1 ] && { echo "  DRYRUN> tar -xzf <archive> -C <stage>  (selective placement)"; mark_phase 4; return; }
  [ -s "$ARCHIVE_PATH" ] || die "archive missing/empty: $ARCHIVE_PATH (run phase 2)"

  # The tar stored absolute paths (leading / stripped). Extract to a staging root, then
  # place selectively so we DON'T clobber the freshly-cloned STEP0 code with old code.
  local stage="/mnt/minikube-backups/restore-staging"
  run "rm -rf '$stage' && mkdir -p '$stage'"
  # `sudo tar -xpzf`, NOT `tar -xzf`. backup-minikube-mnt.sh runs from ROOT's crontab, so the
  # archive carries the true per-container UIDs — but tar only RESTORES ownership when it runs
  # as root (and --same-owner, which is root's default, needs -p to also keep the modes).
  # Extracting as 'cloud' silently rewrites every file to cloud:cloud, which breaks every
  # containerised datastore that runs as a non-root UID: vault (100), grafana (472),
  # postgres/mysql/mongo (999). Observed 2026-08-07 — vault-0 could not read its own
  # /vault/data/core (ended up 1000:1000 mode 700) and the restore stalled with the platform
  # half-deployed. Same reason 4b below copies with `sudo cp -a`.
  run "sudo tar --numeric-owner -xpzf '$ARCHIVE_PATH' -C '$stage'"

  # 4a. ~/.vault FIRST — only copy of the Vault unseal key/root token. Verify non-empty.
  run "mkdir -p '$HOME/.vault' && chmod 700 '$HOME/.vault'"
  # The stage is root-owned now (see the sudo tar above) and cluster-keys.json is 0600, so
  # a plain cp as 'cloud' cannot even read it. Copy as root, then hand the tree back.
  # Check the SOURCE before copying. Testing only the destination is what made this guard
  # useless on 2026-08-07: the extract had failed, the copy copied nothing, and the check
  # still passed against the cluster-keys.json left behind by an EARLIER run — so the script
  # logged "vault keys restored OK" having restored nothing. The one file that cannot be
  # regenerated deserves a check that cannot be satisfied by stale data.
  sudo test -s "$stage/home/cloud/.vault/cluster-keys.json" \
    || die "cluster-keys.json is missing/empty IN THE ARCHIVE ($stage/home/cloud/.vault/) — the extract did not produce it. Vault cannot be unsealed; fix the extract before continuing."
  run "sudo cp -a '$stage/home/cloud/.vault/.' '$HOME/.vault/'"
  run "sudo chown -R cloud:cloud '$HOME/.vault'"
  [ -s "$HOME/.vault/cluster-keys.json" ] || die "restored ~/.vault/cluster-keys.json is missing/empty — Vault cannot be unsealed"
  run "chmod 600 '$HOME/.vault/cluster-keys.json'"
  log "vault keys restored OK"

  # 4b. The bulk shared volume. `sudo cp -a` so the per-container UIDs survive (see the tar
  # comment above). The SOURCE path inside the archive depends on when the archive was made:
  # the volume lived at /mnt/minikube-backups/minikube-mnt until 2026-08-07, when it moved to
  # its own NVMe partition at /mnt/minikube-mnt. Old archives are still perfectly valid
  # restore sources, so accept either rather than silently restoring nothing.
  local vol_src=""
  for _c in "$stage/mnt/minikube-mnt" "$stage/mnt/minikube-backups/minikube-mnt"; do
    [ -d "$_c" ] && { vol_src="$_c"; break; }
  done
  [ -n "$vol_src" ] || die "no minikube-mnt found in the archive (looked for /mnt/minikube-mnt and the pre-2026-08-07 /mnt/minikube-backups/minikube-mnt)"
  log "shared volume source in archive: $vol_src"

  # SIDE-COPY THE DB SNAPSHOT TREE BEFORE MERGING THE ARCHIVE OVER IT.
  # yolo-db-snapshots/ (the db-snapshot CronJob's logical dumps — the ONLY valid Mongo
  # restore source, see CLAUDE.md "Never copy a running database") lives INSIDE the mount
  # this restore is about to overwrite, and inside the weekly archive. So a restore replays
  # the snapshot tree as it stood on backup day, and any snapshot taken since is at best
  # untouched and at worst shadowed by an older file of the same name — at exactly the moment
  # those newer dumps are most wanted. On 2026-08-07 the rebuild-and-restore left every store
  # at its 08-03 state with the 08-04/05/06 dumps gone.
  # `cp -a src/. dest/` MERGES rather than wipes, so newer differently-named dumps do survive
  # today — but that is an undocumented property of one line, it does not survive an operator
  # who clears the mount first, and it does not stop a same-named overwrite. Cheap insurance:
  # stash whatever is on disk now, on the OTHER disk (sda1 staging), before touching anything.
  # Nothing is ever deleted from here automatically — it is a lifeboat, not a cache.
  if sudo test -d /mnt/minikube-mnt/yolo-db-snapshots && \
     [ -n "$(sudo ls -A /mnt/minikube-mnt/yolo-db-snapshots 2>/dev/null)" ]; then
    _snap_side="/mnt/minikube-backups/pre-restore-db-snapshots-$(date +%m-%d-%y-%H%M)"
    log "existing DB snapshot tree found — side-copying to $_snap_side BEFORE the archive merge"
    run "sudo mkdir -p '$_snap_side'"
    if sudo cp -a /mnt/minikube-mnt/yolo-db-snapshots/. "$_snap_side/" 2>/dev/null; then
      log "DB snapshots preserved at $_snap_side ($(sudo du -sh "$_snap_side" 2>/dev/null | cut -f1)) — NOT auto-deleted; remove by hand once you are satisfied with the restore"
    else
      log "WARN: could not side-copy /mnt/minikube-mnt/yolo-db-snapshots — post-backup dumps may be shadowed by the archive's older copies. Check $_snap_side before proceeding."
    fi
  else
    log "no existing DB snapshot tree on the mount (expected on a bare-metal restore) — nothing to preserve"
  fi

  run "sudo cp -a '$vol_src/.' /mnt/minikube-mnt/"

  # 4c. SOPS age key: minikube-mnt/keys-sops-IMPORTANT.txt -> ~/.config/sops/age/keys.txt
  #     (start-scratch's setup-jenkins-credentials.sh + per-app vaultSync need it).
  if sudo test -s "/mnt/minikube-mnt/keys-sops-IMPORTANT.txt"; then
    run "mkdir -p '$HOME/.config/sops/age'"
    run "sudo cp '/mnt/minikube-mnt/keys-sops-IMPORTANT.txt' '$HOME/.config/sops/age/keys.txt'"
    run "sudo chown cloud:cloud '$HOME/.config/sops/age/keys.txt'"
    run "chmod 600 '$HOME/.config/sops/age/keys.txt'"
  else
    log "WARN: SOPS age key not found in minikube-mnt — app secret decryption will fail until it is placed."
  fi

  # 4d. qcguy-ghost (full).
  run "mkdir -p '$HOME/Ideaprojects/qcguy-ghost'"
  run "cp -a '$stage/home/cloud/Ideaprojects/qcguy-ghost/.' '$HOME/Ideaprojects/qcguy-ghost/'"

  # 4e. nginx: data/ + letsencrypt/ AND docker-compose.yml are runtime-only and live ONLY
  #     in the backup (the compose was never committed to wiqram/nginx — the clone brings
  #     just the docs). Stage the WHOLE nginx dir here so phase 5 can overlay data/,
  #     letsencrypt/ AND the compose onto the clone. Stash to a known spot.
  run "rm -rf /mnt/minikube-backups/nginx-data-restore && mkdir -p /mnt/minikube-backups/nginx-data-restore"
  run "cp -a '$stage/home/cloud/Ideaprojects/nginx/.' /mnt/minikube-backups/nginx-data-restore/"

  # 4f. STEP0: keep freshly-cloned code; overlay only backed-up runtime files. Note .env
  #     carries NTFY_URL AND the Jenkins credential (JENKINS_CRED) the app deploys need.
  if [ -f "$stage/home/cloud/Ideaprojects/STEP0/.env" ]; then
    run "cp '$stage/home/cloud/Ideaprojects/STEP0/.env' '$SCRIPT_DIR/.env'"
  fi
  run "mkdir -p '$SCRIPT_DIR/logs'"
  [ -d "$stage/home/cloud/Ideaprojects/STEP0/logs" ] && run "cp -a '$stage/home/cloud/Ideaprojects/STEP0/logs/.' '$SCRIPT_DIR/logs/' || true"

  # 4g. WD My Cloud nightly-backup toolkit (~/wd-backup): the rsync script, its config
  #     AND the SMB credential files (.smb-cred-*), which live OUTSIDE STEP0 and are in
  #     NO git repo — so the DR archive is their only restore source. Captured by
  #     backup-minikube-mnt.sh (logs excluded). Phase 8 re-arms it (install-on-prod.sh
  #     + the 02:00 cron). If absent (archive predates the change) phase 8 warns with the
  #     dev-box re-pull command.
  if [ -d "$stage/home/cloud/wd-backup" ]; then
    run "mkdir -p '$HOME/wd-backup'"
    run "cp -a '$stage/home/cloud/wd-backup/.' '$HOME/wd-backup/'"
    run "chmod 600 '$HOME/wd-backup'/.smb-cred* 2>/dev/null || true"
    log "wd-backup toolkit restored (~/wd-backup)"
  else
    log "WARN: ~/wd-backup not in this archive (predates the change) — phase 8 will note the dev-box re-pull."
  fi

  # 4h. Tailscale node identity. tailscaled.state IS this machine's identity on the tailnet:
  #     put it back and the rebuilt box rejoins as the SAME machine — same 100.x address,
  #     same ALREADY-APPROVED subnet route — so off-LAN access to jenkins/grafana returns
  #     with NO browser login and NO route re-approval. Without it phase 8 can only get as
  #     far as printing a login URL and waiting for a human.
  #     Staged to a persistent path (not $HOME, not $stage — this function deletes $stage
  #     below, and phase 8 runs much later, possibly in a separate --from-phase 8 invocation).
  #     Stays root:root 0600: it is a private key.
  if sudo test -s "$stage/var/lib/tailscale/tailscaled.state"; then
    run "sudo rm -rf /mnt/minikube-backups/tailscale-state-restore"
    run "sudo mkdir -p /mnt/minikube-backups/tailscale-state-restore"
    run "sudo cp -a '$stage/var/lib/tailscale/tailscaled.state' /mnt/minikube-backups/tailscale-state-restore/"
    run "sudo chmod 700 /mnt/minikube-backups/tailscale-state-restore"
    run "sudo chmod 600 /mnt/minikube-backups/tailscale-state-restore/tailscaled.state"
    log "tailscale node identity staged — phase 8 will rejoin the tailnet non-interactively"
  else
    log "NOTE: no tailscale node identity in this archive (predates the change, or tailscale was not installed)."
    log "      Phase 8 will fall back to TAILSCALE_AUTHKEY in .env, then to interactive auth."
  fi

  run "rm -rf '$stage'"
  mark_phase 4
}

# ============================== PHASE 5: CLONE REPOS ==============================
phase5_clone() {
  should_run 5 || { log "phase 5 already done, skipping"; return; }
  log "PHASE 5 — clone infra + app repos (github.com/wiqram/*)"
  need git
  # Preserve BOTH case-variant trees exactly.
  run "mkdir -p /home/cloud/Ideaprojects /home/cloud/IdeaProjects"

  # restore_repo_manifest emits: <target_dir> <git_url> <branch>
  local dir url branch
  while read -r dir url branch; do
    [ -z "$dir" ] && continue
    if [ -d "$dir/.git" ]; then
      log "exists, skipping clone: $dir"
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      echo "  DRYRUN> git clone --branch $branch $url $dir"; continue
    fi
    if git clone --branch "$branch" "$url" "$dir"; then
      :
    elif git clone "$url" "$dir" && git -C "$dir" checkout "$branch"; then
      :
    else
      log "WARN: clone/checkout failed for $url ($branch) — clone manually"
    fi
  done < <(restore_repo_manifest)

  # Overlay the restored nginx RUNTIME (from phase 4e) onto the freshly-cloned repo.
  # data/ + letsencrypt/ are gitignored and live ONLY in the backup. docker-compose.yml
  # ALSO lives only in the backup — it was NEVER committed to wiqram/nginx (the clone
  # brings just the docs), so without this phase 7's `docker compose up` would die on a
  # missing compose. The backup staging holds the last-known-good compose (it defines the
  # nginx-proxy-manager @172.16.238.10 + mariadb @.11 on the 5million net), so place it
  # here. mkdir guards the case where the clone failed outright (empty/unreachable remote):
  # nginx then comes up wholly from the backup.
  if [ -d /mnt/minikube-backups/nginx-data-restore ] && [ "$DRY_RUN" != 1 ]; then
    run "mkdir -p /home/cloud/Ideaprojects/nginx"
    run "cp -a /mnt/minikube-backups/nginx-data-restore/data /home/cloud/Ideaprojects/nginx/ 2>/dev/null || true"
    run "cp -a /mnt/minikube-backups/nginx-data-restore/letsencrypt /home/cloud/Ideaprojects/nginx/ 2>/dev/null || true"
    if [ -f /mnt/minikube-backups/nginx-data-restore/docker-compose.yml ]; then
      run "cp -a /mnt/minikube-backups/nginx-data-restore/docker-compose.yml /home/cloud/Ideaprojects/nginx/"
      log "nginx data/ + letsencrypt/ + docker-compose.yml overlaid onto cloned nginx repo"
    else
      log "WARN: docker-compose.yml absent from nginx backup staging — phase 7 will fail. Place ~/Ideaprojects/nginx/docker-compose.yml by hand before continuing."
    fi
  fi
  mark_phase 5
}

# ============================== PHASE 6: CLUSTER BRING-UP ==============================
phase6_cluster() {
  should_run 6 || { log "phase 6 already done, skipping"; return; }
  log "PHASE 6 — platform bring-up via start-scratch.sh (SKIP_APP_BUILDS=1)"
  # ensure-registry-store.sh runs INSIDE start-scratch before minikube start; the dirs
  # it binds were created in phase 3. start-scratch creates the 5million network, cold
  # minikube (single-disk mounts), durable registry, monitoring, vault (unseals from the
  # restored keys+storage), jenkins, and the vault->jenkins cred sync.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> helm repo update"
    echo "  DRYRUN> SKIP_APP_BUILDS=1 $SCRIPT_DIR/start-scratch.sh"; mark_phase 6; return
  fi
  # helm's repo LIST (~/.config/helm/repositories.yaml) and its index CACHE
  # (~/.cache/helm/repository/*-index.yaml) are separate, and only the list survives a
  # restore that brings a home directory back. `helm repo add` is skip-if-present — it
  # prints "already exists with the same configuration, skipping" and does NOT fetch an
  # index — so every downstream `helm install` then dies with
  #   Error: no cached repo found. (try 'helm repo update')
  # after the namespaces/PVs have already been created, i.e. half-deployed. Hit for real
  # on 2026-08-07 at the vault install. `helm repo update` is idempotent and cheap; on a
  # genuinely bare box it is a no-op because there are no repos configured yet.
  if command -v helm >/dev/null 2>&1; then
    run "helm repo update 2>&1 | tail -2 || true"
  fi
  SKIP_APP_BUILDS=1 "$SCRIPT_DIR/start-scratch.sh" || die "start-scratch.sh (platform bring-up) failed — inspect and re-run --from-phase 6"
  mark_phase 6
}

# ============================== PHASE 7: NGINX ==============================
phase7_nginx() {
  should_run 7 || { log "phase 7 already done, skipping"; return; }
  log "PHASE 7 — bring up nginx-proxy-manager (all proxy hosts + certs)"
  [ -f /home/cloud/Ideaprojects/nginx/docker-compose.yml ] || die "nginx compose missing (phase 5)"
  # Belt and braces: phase 1 already cleared :80/:443, but a reboot or an apt run between
  # then and now can bring apache2 back, and this is the step that actually needs the ports.
  free_web_ports
  # 5million network now exists (created by start-scratch in phase 6). NPM data/ +
  # letsencrypt/ were overlaid in phase 5, so all proxy hosts + certs come back.
  #
  # --force-recreate, NOT a plain `up -d`. When a create fails partway (2026-08-07: the
  # port-80 bind lost to apache2) compose leaves the container EXISTING but attached to no
  # network and publishing no ports. A later `up -d` sees a container by that name and just
  # STARTS it, so NPM comes up "unhealthy", cannot resolve its own db, and serves nothing —
  # with no mention of ports anywhere in the logs. Recreating costs a few seconds and makes
  # the outcome independent of whatever wreckage a previous attempt left.
  run "cd /home/cloud/Ideaprojects/nginx && docker compose up -d --force-recreate"
  # Verify rather than assume: `docker compose up` exits 0 for a container that then dies.
  if [ "$DRY_RUN" != 1 ]; then
    sleep 15
    if docker ps --filter name=nginx-proxy-manager --format '{{.Status}}' 2>/dev/null | grep -q '^Up'; then
      log "nginx-proxy-manager is up ($(docker port nginx-proxy-manager 2>/dev/null | tr '\n' ' '))"
      docker exec nginx-proxy-manager nginx -t >/dev/null 2>&1 \
        && log "NPM nginx config test OK" \
        || log "WARN: NPM is running but 'nginx -t' failed — check the proxy host confs."
    else
      log "WARN: nginx-proxy-manager is NOT up after phase 7. Public ingress and cert renewal are DOWN."
      log "      docker logs nginx-proxy-manager | tail -30"
      log "      Common cause: something else holds :80/:443 (see the free_web_ports warnings above)."
    fi
  fi
  mark_phase 7
}

# ============================== PHASE 8: RE-ARM AUTOMATION ==============================
phase8_automation() {
  should_run 8 || { log "phase 8 already done, skipping"; return; }
  log "PHASE 8 — re-arm restart policy, crontabs, host units/network, unseal loop"

  # Boot-persistence check for the web ports. Phase 1 disabled the offenders and phase 7
  # needed the ports NOW; this asks the different question "will they still be free after a
  # reboot?". apache2 in particular is re-enabled by some apt operations, and the failure is
  # invisible until the next restart takes every public domain down at once.
  for _svc in apache2 nginx lighttpd caddy; do
    if web_server_wants_ports "$_svc"; then
      log "WARN: '$_svc' is enabled at boot and will race nginx-proxy-manager for :80/:443 after a reboot — disabling"
      run "sudo systemctl disable --now $_svc || true"
    fi
  done

  # Keep the cluster across host reboots.
  run "docker update --restart=unless-stopped minikube || true"

  # Reinstall BOTH host crontabs from their canonical sources of truth:
  #   cron/cloud-crontab — STEP0 automation (vault-auto-unseal, cluster-autostart,
  #     reduce-node-docker-cache, alerting-pipeline-watch, prune-registry) + the per-project
  #     autonomous agents (predictonomy/yolo/dyingpaleblue).
  #   cron/root-crontab  — the weekly DR backup (root because backup-minikube-mnt.sh reads
  #     0700 datastore dirs / 0600 SMB creds, and tar only records true numeric owners as root).
  # The host crontabs are a restore-scratch (host-setup) concern — start-scratch.sh (platform
  # bring-up) does NOT touch them. Agents stay DISARMED until AGENT_PERMISSION_MODE is set.
  #
  # ⚠️ Until 2026-08-08 the root line was a STRING LITERAL right here, piped to
  # `sudo crontab -u root -`, and existed in no committed file. That meant the job producing
  # the platform's only off-disk insurance was reproduced from a copy that nothing diffed
  # against anything — the live crontab and this literal could drift apart silently, and
  # verify-recovery.sh could only check that *a* backup line existed, not that it was the
  # right one. Do not reintroduce it here: edit cron/root-crontab.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> $SCRIPT_DIR/install-cron.sh --cloud  (canonical cron/cloud-crontab)"
    echo "  DRYRUN> sudo $SCRIPT_DIR/install-cron.sh --root  (canonical cron/root-crontab: weekly DR backup)"
  else
    "$SCRIPT_DIR/install-cron.sh" --cloud && log "cloud crontab installed (canonical)" || log "WARN: cloud crontab install failed"
    sudo "$SCRIPT_DIR/install-cron.sh" --root \
      && log "root crontab installed (canonical — weekly DR backup)" \
      || log "WARN: root crontab install failed — the WEEKLY DR BACKUP IS NOT SCHEDULED. Re-arm: sudo $SCRIPT_DIR/install-cron.sh --root"
  fi

  # Re-arm the nightly WD My Cloud rsync backup (8TB .68 -> 16TB .251). Its toolkit
  # (~/wd-backup: script + conf + SMB creds) was restored from the DR archive in phase 4.
  # install-on-prod.sh installs deps (cifs-utils/rsync/smbclient), fixes cred perms,
  # adapts paths and installs /etc/cron.d/wd-backup (02:00). It preflights the NAS under
  # `set -e`, so a momentarily-dark NAS would abort it BEFORE the cron is written — hence
  # the fallback: force `wd-backup.sh install-cron` (which never touches the NAS) so the
  # nightly job is armed regardless. Wholly best-effort — a separate tenant job must never
  # fail the cluster restore.
  if [ -x /home/cloud/wd-backup/install-on-prod.sh ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "  DRYRUN> sudo /home/cloud/wd-backup/install-on-prod.sh  (deps+creds+NAS preflight+02:00 cron)"
    elif sudo /home/cloud/wd-backup/install-on-prod.sh; then
      log "WD My Cloud nightly backup re-armed (install-on-prod.sh OK)"
    else
      log "WARN: install-on-prod.sh failed (NAS unreachable?) — forcing cron install; run 'sudo ~/wd-backup/wd-backup.sh check' once the NAS is up."
      sudo /home/cloud/wd-backup/wd-backup.sh install-cron \
        && log "WD My Cloud cron installed (fallback, no NAS preflight)" \
        || log "WARN: WD My Cloud cron install failed too — re-arm manually: sudo ~/wd-backup/install-on-prod.sh"
    fi
  else
    log "WARN: ~/wd-backup/install-on-prod.sh missing — WD My Cloud nightly backup NOT re-armed."
    log "      Re-pull from the dev box, then install: rsync -av --exclude logs vik@10.10.10.2:wd-backup/ ~/wd-backup/ && sudo ~/wd-backup/install-on-prod.sh"
  fi

  # --- Reproduce host-level config the DR archive does NOT carry -------------------------
  # These live in /etc + NetworkManager (outside every backed-up path). Their source scripts
  # ARE cloned with STEP0 (phase 5) but nothing ran their installers, so a fresh box would
  # boot without the 10GbE link config, the boot-time watchdog/firewall units, or the
  # persistent off-site-backup mount.

  # (a) Static 10GbE /30 profile (prod side = 10.10.10.1/30). Only the LINK is flaky; the
  #     ADDRESSING must exist for the watchdog to bounce and for dev<->prod traffic. The
  #     watchdog only bounces an existing link — it never creates the /30. Auto-detect the
  #     atlantic (Aquantia 10GBASE-T) NIC by driver so a NIC rename on the new box is
  #     tolerated. Idempotent: skip if a 10.10.10.x address is already present.
  if ip -o -f inet addr show 2>/dev/null | awk '$4 ~ /^10\.10\.10\./{print}' | grep -q .; then
    log "10GbE /30 already configured — skipping NM profile creation"
  else
    ten_if=""
    for i in $(ls /sys/class/net 2>/dev/null); do
      [ "$(ethtool -i "$i" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')" = "atlantic" ] && { ten_if="$i"; break; }
    done
    if [ -z "$ten_if" ]; then
      log "WARN: no 'atlantic' 10GbE NIC found — dev<->prod 10GbE link cannot be configured on this box."
    elif [ "$DRY_RUN" = 1 ]; then
      echo "  DRYRUN> nmcli connection add ethernet ifname $ten_if ipv4.method manual ipv4.addresses 10.10.10.1/30"
    else
      sudo nmcli connection add type ethernet ifname "$ten_if" con-name "$ten_if" \
        ipv4.method manual ipv4.addresses 10.10.10.1/30 autoconnect yes >/dev/null 2>&1 \
        && sudo nmcli connection up "$ten_if" >/dev/null 2>&1 \
        && log "10GbE /30 profile created on $ten_if (10.10.10.1/30)" \
        || log "WARN: could not create 10GbE /30 profile on $ten_if — set by hand: sudo nmcli con add type ethernet ifname $ten_if ipv4.method manual ipv4.addresses 10.10.10.1/30"
    fi
  fi

  # (b) Boot-time systemd units (source cloned with STEP0; installers were never run):
  #     the 10GbE link watchdog, the dev-box kube-access firewall re-applier, and the Loki
  #     NodePort guard. All three MUST be units rather than one-shot rule applies, for the
  #     same reason: DOCKER-USER is wiped on every dockerd restart, so only a unit that is
  #     PartOf/After docker.service keeps the rule alive past the next daemon restart.
  #     For the guard that cuts both ways — without it, Loki's unauthenticated 30310 (30 days
  #     of pipeline logs incl. follower emails) is reachable from the whole bridge network
  #     after any Docker restart, with nothing to say so. See loki-nodeport-guard.sh.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> sudo $SCRIPT_DIR/10gbe-link-watchdog.sh --install ; sudo $SCRIPT_DIR/enable-devbox-kube-access.sh --install ; sudo $SCRIPT_DIR/loki-nodeport-guard.sh --install ; sudo $SCRIPT_DIR/tailscale-access.sh --install"
  else
    sudo "$SCRIPT_DIR/10gbe-link-watchdog.sh" --install >/dev/null 2>&1 \
      && log "10gbe-link-watchdog.service installed" || log "WARN: 10gbe-link-watchdog --install failed (re-run by hand)."
    sudo "$SCRIPT_DIR/enable-devbox-kube-access.sh" --install >/dev/null 2>&1 \
      && log "devbox-kube-access.service installed" || log "WARN: enable-devbox-kube-access --install failed (re-run by hand)."
    sudo "$SCRIPT_DIR/loki-nodeport-guard.sh" --install >/dev/null 2>&1 \
      && log "yolo-loki-nodeport-guard.service installed (SEC-LOKI-NODEPORT)" \
      || log "WARN: loki-nodeport-guard --install failed — Loki NodePort 30310 is UNRESTRICTED. Re-run: sudo $SCRIPT_DIR/loki-nodeport-guard.sh --install"
    # Tailscale: re-arms off-LAN access to the admin vhosts (jenkins/grafana/vault/...).
    # NOT output-suppressed like the three above, deliberately — this is the one that can
    # need a human (interactive auth if phase 4h found no node identity AND .env carries no
    # auth key), and swallowing its stdout would hide the login URL that unblocks it.
    # Best-effort by design: it fails OPEN in the sense that nothing else on the platform
    # depends on it, so a non-zero exit must not derail the restore.
    if sudo "$SCRIPT_DIR/tailscale-access.sh" --install; then
      log "tailscale-access installed (off-LAN access to the admin vhosts re-armed)"
    else
      log "WARN: tailscale-access --install did not complete — jenkins/grafana are reachable"
      log "      from the house and the dev box only. Nothing else is affected. Re-run:"
      log "      sudo $SCRIPT_DIR/tailscale-access.sh --install ; ./tailscale-access.sh --status"
    fi
  fi

  # (c) Persist the WD Cloud NFS off-site mount in fstab (phase 2 only mounted it transiently
  #     to pull the backup). Without this line the share is unmounted after the next reboot
  #     and the weekly off-site copy silently skips (backup-minikube-mnt.sh only WARNs).
  if ! grep -q "$WD_HOST:$WD_EXPORT" /etc/fstab 2>/dev/null; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "  DRYRUN> append WD Cloud NFS automount line to /etc/fstab"
    else
      echo "$WD_HOST:$WD_EXPORT  $WD_MOUNT  nfs  _netdev,nofail,hard,timeo=600,retrans=3,x-systemd.automount  0 0" \
        | sudo tee -a /etc/fstab >/dev/null \
        && { sudo systemctl daemon-reload 2>/dev/null || true; log "WD Cloud NFS automount persisted to /etc/fstab"; } \
        || log "WARN: could not append WD Cloud NFS line to /etc/fstab (add by hand; see backup-minikube-mnt.sh)."
    fi
  fi

  # Start the unseal loop NOW (don't wait for @reboot) so Vault unseals immediately.
  run "mkdir -p '$SCRIPT_DIR/logs'"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> setsid $SCRIPT_DIR/vault-auto-unseal.sh >> $SCRIPT_DIR/logs/vault-auto-unseal.log 2>&1 &"
  else
    setsid "$SCRIPT_DIR/vault-auto-unseal.sh" >> "$SCRIPT_DIR/logs/vault-auto-unseal.log" 2>&1 < /dev/null &
    log "vault-auto-unseal loop launched"
  fi
  # Re-arm autonomous agents' deploy-URL pointers from the restored central credential
  # (agent repos were cloned in phase 5; their gitignored .env/break-glass files aren't in the backup).
  run "'$SCRIPT_DIR/seed-agent-deploy-urls.sh' || true"
  mark_phase 8
}

# ============================== PHASE 9: VERIFY + HANDOFF ==============================
phase9_handoff() {
  log "PHASE 9 — verification + handoff"
  if [ "$DRY_RUN" != 1 ]; then
    minikube status || true
    kubectl -n vault exec vault-0 -- vault status 2>/dev/null | grep -i sealed || true
    kubectl get po -A 2>/dev/null | head -30 || true
    docker compose -f /home/cloud/Ideaprojects/nginx/docker-compose.yml ls 2>/dev/null || true

    # Pre-flight the Jenkins credential so app-build WEBHOOKS don't silently 401. The
    # restored Jenkins (JENKINS_HOME on minikube-mnt) holds the API-token hash; .env holds
    # the plaintext JENKINS_CRED. Both come from the same backup, so they normally match —
    # but a backup taken BEFORE JENKINS_CRED existed (or a token rotated after that backup)
    # leaves them out of sync. Verify against the live restored Jenkins and tell the operator.
    JCRED="$(grep -E '^JENKINS_CRED=' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )"
    JURL="http://$(minikube ip 2>/dev/null || echo 172.16.238.2):30380"
    if [ -n "$JCRED" ] && curl -sf -u "$JCRED" "$JURL/whoAmI/api/json?tree=authenticated" >/dev/null 2>&1; then
      log "Jenkins credential OK — app-build webhooks (trigger-app-builds.sh) will authenticate."
    else
      log "WARN: STEP0/.env JENKINS_CRED is missing or does NOT authenticate against the restored Jenkins."
      log "      App webhooks WILL 401 until fixed. Remedy: set JENKINS_CRED=private-cloud:<valid-token>"
      log "      in $SCRIPT_DIR/.env (Jenkins UI: user 'private-cloud' -> Configure -> API Token ->"
      log "      generate), then run ./trigger-app-builds.sh."
    fi

    # Read-only environment survey: confirms the facts a fresh box can silently get
    # wrong (fixed cluster IPs, NAS reachability/exports, the 10GbE link, host/DNS/cron).
    # Advisory — never fails the restore; the operator reads the WARN/FAIL lines.
    if [ -x "$SCRIPT_DIR/verify-recovery.sh" ]; then
      log "running verify-recovery.sh (read-only survey)..."
      "$SCRIPT_DIR/verify-recovery.sh" || log "verify-recovery.sh flagged issues (see above) — advisory, restore not aborted."
    fi
  fi
  cat <<'DONE'
==================================================================
RESTORE COMPLETE — platform is up; apps are NOT yet deployed.

Verify:
  ./verify-recovery.sh                            # full survey: IPs, NAS, 10GbE, DNS, cron
  minikube status                                 # Running
  kubectl -n vault exec vault-0 -- vault status   # Sealed = false
  kubectl get po -A                               # platform pods Running
  docker compose -f ~/Ideaprojects/nginx/docker-compose.yml ps   # NPM up

NEXT — required before app deploys:
  1. Re-point DNS for your app domains / *.traderyolo.com at THIS host's public IP.
     (Jenkins build webhooks go through jenkins.traderyolo.com -> NPM -> cluster.)
  2. Confirm https://jenkins.traderyolo.com resolves to this box.
  3. THEN deploy the apps:
        cd ~/Ideaprojects/STEP0 && ./trigger-app-builds.sh
     ** If a "Jenkins credential ... does NOT authenticate" WARN appeared above, fix
        STEP0/.env JENKINS_CRED FIRST — otherwise every webhook 401s. **
     Registry starts EMPTY (single-disk restore) — the first build of each app
     rebuilds + re-pushes its image; transient ImagePullBackOff is expected.
     (Jenkins jobs/pipelines themselves are restored with JENKINS_HOME on minikube-mnt.)
  4. Re-pull ollama models (excluded from backup):  ollama pull <model>  (see Modelfile)
  5. Per-app SOPS age keys: restored with Vault storage; on a fresh Vault, start-vault.sh
     re-seeds them from ~/.vault/age-keys/ (seed-age-keys.sh). The MASTER recovery key
     (~/.config/sops/age/keys.txt) is the anchor — keep it backed up off-box.
  6. Autonomous agents (yolo/predictonomy/dyingpaleblue): deploy-URL pointers were re-armed
     from the central JENKINS_CRED. They stay DISARMED until you set AGENT_PERMISSION_MODE in
     each agent's .env. To re-arm manually: ./seed-agent-deploy-urls.sh

MANUAL host-level steps NOT auto-reconstructed (credentials / can't be scripted safely):
  A. GitHub auth (REQUIRED before phase 5 clones): the gh token is in the OS keyring, not
     the backup. If phase 5 clones failed, run `gh auth login` (or drop a PAT) and re-run
     --from-phase 5.
  B. docker registry logins (~/.docker/config.json is NOT backed up): `docker login`
     (Docker Hub PAT avoids pull-rate limits mid-bootstrap) and, if used, the private
     registry. Not fatal — Jenkins rebuilds images — but avoids rate-limit stalls.
  C. Dedicated backup disk: if phase 3 WARNed "no filesystem labelled ..." the restore is
     targeting the 44G root and the ~150G+ minikube-mnt will NOT fit. Attach + format the
     backup disk (see the phase-3 WARN) before continuing.
  D. /etc/hosts: the live box has custom LAN names (nginx/jenkins/jenkins-slave-private-cloud.com
     -> the host's LAN IP; container-registry-private-cloud.com -> 127.0.0.1). Not auto-added
     (the LAN IP changes per box). Re-add by hand IF any build/tooling still resolves them.
  E. App wiring: some running apps are NOT in the auto-deploy path (e.g. qcx is cloned but has
     no build trigger; aisucks has no repo/job at all). Register their Jenkins job +
     trigger-app-builds.sh line + NPM host, or deploy them by hand. (Confirm which apps should
     survive — see the DR audit.)
  F. ntfy SUBSCRIPTIONS on your phone: the restored cluster alerts correctly, but a topic
     nobody is subscribed to is just silence. Subscribe in the ntfy app to at least
     `yolo-private-cloud-platform` (Alertmanager — every infra alert, incl. CPU/GPU temp,
     disk, pods) and `yolo-private-cloud-resource-crunch` (the out-of-cluster watchdog that
     fires when the alerting pipeline ITSELF is broken). Full list: ntfy-lib.sh NTFY_TOPICS.
  G. nginx-proxy-manager websockets — ONLY if NPM was rebuilt rather than restored from the
     archive. The per-host "Websockets Support" toggle lives in NPM's own database, not in
     any repo. grafana.traderyolo.com needs it ON or Grafana Live (/api/live/ws) 400s in a
     retry loop. Verify with a FORCED HTTP/1.1 upgrade — over HTTP/2 the classic handshake
     is invalid and 400s regardless, which reads as a false failure. See docs/architecture.md
     "Grafana public access".
==================================================================
DONE
  mark_phase 9
  RS_NOTIFIED=1
  # Never announce success over the top of phases that did not complete. Without this the
  # closing banner is the loudest thing in a several-hour log, and a phase that quietly
  # refused to mark itself scrolls past hours earlier.
  if [ -n "$RS_INCOMPLETE" ]; then
    log "=================================================================="
    log "restore-scratch finished, but these phases had FAILING commands and"
    log "were NOT marked complete:  $RS_INCOMPLETE"
    log "Re-run the lowest one after fixing:  ./restore-scratch.sh --from-phase <n>"
    log "=================================================================="
    rs_notify "restore-scratch ended with INCOMPLETE phases" \
"Host: $(hostname -s). Elapsed: $(rs_elapsed).
Phases with failing commands: $RS_INCOMPLETE
The platform is NOT fully restored. Re-run from the lowest:  ./restore-scratch.sh --from-phase <n>" \
      "urgent" "warning,floppy_disk"
    return 0
  fi
  rs_notify "restore-scratch COMPLETE (platform up, apps NOT deployed)" \
"All 9 phases finished on $(hostname -s) in $(rs_elapsed).

The cluster is up but NOTHING is deployed yet. Still required, in order:
  1. re-point DNS at this host's public IP
  2. confirm https://jenkins.traderyolo.com resolves here
  3. ./trigger-app-builds.sh
Then: ./verify-recovery.sh, and re-pull the ollama models (excluded from backups)." \
    "high" "white_check_mark,floppy_disk"
  log "restore-scratch: ALL PHASES COMPLETE."
}

# ============================== MAIN ==============================
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
rs_notify "restore-scratch STARTED" \
"Bare-metal disaster recovery beginning on $(hostname -s) as $(whoami).
Resuming from phase: ${FROM_PHASE:-auto (last completed: $(rs_phase))}
This takes hours and pauses before app deploys. Expect a COMPLETE or FAILED note here." \
  "default" "hourglass_flowing_sand,floppy_disk"
phase0_preflight
phase1_tooling
phase2_pull
phase3_dirs
phase4_extract
phase5_clone
phase6_cluster
phase7_nginx
phase8_automation
phase9_handoff
