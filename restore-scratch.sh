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
# run: execute unless --dry-run (then just print). Use for every mutating command.
# shellcheck disable=SC2086,SC2294
run()  { if [ "$DRY_RUN" = 1 ]; then echo "  DRYRUN> $*"; else log "+ $*"; eval "$@"; fi; }

phase_done() { [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" -ge "$1" ] 2>/dev/null; }
# mark_phase ratchets: it only ever advances the marker, so a --from-phase re-run on an
# already-further-along box does not regress it (marker = highest completed phase).
mark_phase() {
  [ "$DRY_RUN" = 1 ] && return 0
  local cur; cur="$(cat "$MARKER" 2>/dev/null)"; [[ "$cur" =~ ^[0-9]+$ ]] || cur=-1
  [ "$1" -gt "$cur" ] && echo "$1" > "$MARKER"
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
  sudo -n true 2>/dev/null || log "NOTE: sudo may prompt for a password during install phases."
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

  # docker (official convenience repo)
  if ! command -v docker >/dev/null 2>&1; then
    run "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh"
    run "sudo sh /tmp/get-docker.sh"
    run "sudo usermod -aG docker cloud"
    log "NOTE: docker group membership for 'cloud' applies on next login; this run uses sudo where needed."
  fi

  # Reproduce the host docker daemon config the live cluster was built on: cgroupfs cgroup
  # driver (minikube's docker driver negotiated this on the live box), a 100m per-container
  # log cap (single-disk box — uncapped json logs can fill /), and overlay2. nvidia-ctk
  # (below) then MERGES the nvidia runtime into this same file. Only write on a FRESH box
  # (no existing daemon.json) so a re-run never clobbers the nvidia runtime stanza.
  if [ ! -f /etc/docker/daemon.json ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "  DRYRUN> write /etc/docker/daemon.json (cgroupfs, log max-size 100m, overlay2) + restart docker"
    else
      sudo mkdir -p /etc/docker
      sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "storage-driver": "overlay2"
}
JSON
      sudo systemctl restart docker 2>/dev/null || true
      log "wrote /etc/docker/daemon.json (cgroupfs + 100m log cap + overlay2)"
    fi
  fi

  # kubectl (pinned-stable via official pkg repo)
  if ! command -v kubectl >/dev/null 2>&1; then
    run "sudo mkdir -p /etc/apt/keyrings"
    run "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    run "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list"
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
    run "sudo ubuntu-drivers autoinstall"
    log "WARNING: NVIDIA driver installed — a REBOOT is likely required before GPU passthrough works."
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

  run "sudo mkdir -p /mnt/minikube-backups/minikube-mnt"
  run "sudo mkdir -p /mnt/kachra/container-registry-images"
  run "sudo mkdir -p /mnt/predictonomy-postgres /mnt/predictonomy-backups"
  run "sudo chown -R cloud:cloud /mnt/minikube-backups /mnt/kachra"
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
  run "tar -xzf '$ARCHIVE_PATH' -C '$stage'"

  # 4a. ~/.vault FIRST — only copy of the Vault unseal key/root token. Verify non-empty.
  run "mkdir -p '$HOME/.vault' && chmod 700 '$HOME/.vault'"
  run "cp -a '$stage/home/cloud/.vault/.' '$HOME/.vault/'"
  [ -s "$HOME/.vault/cluster-keys.json" ] || die "restored ~/.vault/cluster-keys.json is missing/empty — Vault cannot be unsealed"
  run "chmod 600 '$HOME/.vault/cluster-keys.json'"
  log "vault keys restored OK"

  # 4b. The bulk shared volume.
  run "cp -a '$stage/mnt/minikube-backups/minikube-mnt/.' /mnt/minikube-backups/minikube-mnt/"

  # 4c. SOPS age key: minikube-mnt/keys-sops-IMPORTANT.txt -> ~/.config/sops/age/keys.txt
  #     (start-scratch's setup-jenkins-credentials.sh + per-app vaultSync need it).
  if [ -s "/mnt/minikube-backups/minikube-mnt/keys-sops-IMPORTANT.txt" ]; then
    run "mkdir -p '$HOME/.config/sops/age'"
    run "cp '/mnt/minikube-backups/minikube-mnt/keys-sops-IMPORTANT.txt' '$HOME/.config/sops/age/keys.txt'"
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
    echo "  DRYRUN> SKIP_APP_BUILDS=1 $SCRIPT_DIR/start-scratch.sh"; mark_phase 6; return
  fi
  SKIP_APP_BUILDS=1 "$SCRIPT_DIR/start-scratch.sh" || die "start-scratch.sh (platform bring-up) failed — inspect and re-run --from-phase 6"
  mark_phase 6
}

# ============================== PHASE 7: NGINX ==============================
phase7_nginx() {
  should_run 7 || { log "phase 7 already done, skipping"; return; }
  log "PHASE 7 — bring up nginx-proxy-manager (all proxy hosts + certs)"
  [ -f /home/cloud/Ideaprojects/nginx/docker-compose.yml ] || die "nginx compose missing (phase 5)"
  # 5million network now exists (created by start-scratch in phase 6). NPM data/ +
  # letsencrypt/ were overlaid in phase 5, so all proxy hosts + certs come back.
  run "cd /home/cloud/Ideaprojects/nginx && docker compose up -d"
  mark_phase 7
}

# ============================== PHASE 8: RE-ARM AUTOMATION ==============================
phase8_automation() {
  should_run 8 || { log "phase 8 already done, skipping"; return; }
  log "PHASE 8 — re-arm restart policy, crontabs, host units/network, unseal loop"

  # Keep the cluster across host reboots.
  run "docker update --restart=unless-stopped minikube || true"

  # Reinstall the cloud crontab from the canonical source of truth (cron/cloud-crontab):
  # STEP0 automation (vault-auto-unseal, cluster-autostart, reduce-node-docker-cache) + the
  # per-project autonomous agents (predictonomy/yolo/dyingpaleblue). The host crontab is a
  # restore-scratch (host-setup) concern — start-scratch.sh (platform bring-up) does NOT touch it.
  # Agents stay DISARMED until AGENT_PERMISSION_MODE is set in each app's .env.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> $SCRIPT_DIR/install-cron.sh (canonical cloud crontab)"
  else
    "$SCRIPT_DIR/install-cron.sh" && log "cloud crontab installed (canonical)" || log "WARN: cloud crontab install failed"
  fi

  # Reinstall the SINGLE root backup cron line (needs root to read 0600 keys file).
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> sudo crontab -u root - (weekly backup-minikube-mnt.sh Mon 05:00)"
  else
    echo '0 5 * * 1 /bin/bash /home/cloud/Ideaprojects/STEP0/backup-minikube-mnt.sh >> /var/log/minikube-backup.log 2>&1' \
      | sudo crontab -u root - && log "root backup cron installed" || log "WARN: root cron install failed"
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
  #     the 10GbE link watchdog and the dev-box kube-access firewall re-applier. The latter
  #     MUST be the unit (not start-scratch's one-shot rule apply) because DOCKER-USER is
  #     wiped on every dockerd restart, so only the boot unit keeps dev-box API access alive.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> sudo $SCRIPT_DIR/10gbe-link-watchdog.sh --install ; sudo $SCRIPT_DIR/enable-devbox-kube-access.sh --install"
  else
    sudo "$SCRIPT_DIR/10gbe-link-watchdog.sh" --install >/dev/null 2>&1 \
      && log "10gbe-link-watchdog.service installed" || log "WARN: 10gbe-link-watchdog --install failed (re-run by hand)."
    sudo "$SCRIPT_DIR/enable-devbox-kube-access.sh" --install >/dev/null 2>&1 \
      && log "devbox-kube-access.service installed" || log "WARN: enable-devbox-kube-access --install failed (re-run by hand)."
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
     is invalid and 400s regardless, which reads as a false failure. See architecture.md
     "Grafana public access".
==================================================================
DONE
  mark_phase 9
  RS_NOTIFIED=1
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
