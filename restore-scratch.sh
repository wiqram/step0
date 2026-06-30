#!/bin/bash
####################################
#
# restore-scratch.sh — COLD disaster recovery: bare Ubuntu -> fully wired private cloud
# from the latest GCS Coldline backup. Inverse of backup-minikube-mnt.sh; ends by
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
die()  { echo "[restore FATAL] $*" >&2; exit 1; }
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
  2. You can complete an interactive `gcloud auth login` with an account that
     has read on gs://private_cloud_backup (project igtrader-296013).
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
  log "PHASE 1 — install host tooling (docker, kubectl, minikube, helm, jq, gcloud, NVIDIA)"

  # base packages
  run "sudo apt-get update -y"
  run "sudo apt-get install -y ca-certificates curl gnupg jq git apt-transport-https"

  # docker (official convenience repo)
  if ! command -v docker >/dev/null 2>&1; then
    run "curl -fsSL https://get.docker.com -o /tmp/get-docker.sh"
    run "sudo sh /tmp/get-docker.sh"
    run "sudo usermod -aG docker cloud"
    log "NOTE: docker group membership for 'cloud' applies on next login; this run uses sudo where needed."
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

  # gcloud SDK (no-root, home install) to ~/google-cloud-sdk
  if [ ! -x "$HOME/google-cloud-sdk/bin/gcloud" ]; then
    run "curl -fsSL https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz -o /tmp/gcloud.tgz"
    run "tar -xzf /tmp/gcloud.tgz -C \"$HOME\""
    run "\"$HOME/google-cloud-sdk/install.sh\" --quiet --path-update true"
  fi

  log "phase 1 done. If NVIDIA driver was just installed, REBOOT then re-run: ./restore-scratch.sh"
  mark_phase 1
}

# ============================== PHASE 2: PULL BACKUP ==============================
GCLOUD="$HOME/google-cloud-sdk/bin/gcloud"
GCS_BUCKET="private_cloud_backup"
GCS_PROJECT="igtrader-296013"
BACKUP_DIR="/mnt/minikube-backups"
ARCHIVE_PATH=""   # set by phase2, consumed by phase4

phase2_pull() {
  should_run 2 || { log "phase 2 already done, skipping"; ARCHIVE_PATH="$(cat "$BACKUP_DIR/.restore-archive" 2>/dev/null)"; return; }
  log "PHASE 2 — gcloud login + pull latest backup"
  [ -x "$GCLOUD" ] || die "gcloud not found at $GCLOUD (phase 1 must complete first)"
  run "sudo mkdir -p '$BACKUP_DIR' && sudo chown cloud:cloud '$BACKUP_DIR'"

  # Interactive login (operator's own Google identity). Skipped under --dry-run.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> $GCLOUD auth login   (interactive)"
    echo "  DRYRUN> $GCLOUD config set project $GCS_PROJECT"
  else
    "$GCLOUD" auth login || die "gcloud auth login failed"
    "$GCLOUD" config set project "$GCS_PROJECT" || die "gcloud set project failed"
  fi

  # Find newest archive by date embedded in filename (restore-lib pick_latest_archive).
  local listing latest
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> $GCLOUD storage ls gs://$GCS_BUCKET/private-cloud-*.tgz | pick_latest_archive"
    ARCHIVE_PATH="$BACKUP_DIR/<latest>.tgz"; return
  fi
  listing="$("$GCLOUD" storage ls "gs://$GCS_BUCKET/private-cloud-*.tgz")" || die "cannot list bucket"
  latest="$(printf '%s\n' "$listing" | pick_latest_archive)"
  [ -n "$latest" ] || die "no private-cloud-*.tgz found in gs://$GCS_BUCKET"
  log "latest backup: $latest"
  "$GCLOUD" storage cp "$latest" "$BACKUP_DIR/" || die "download failed"
  ARCHIVE_PATH="$BACKUP_DIR/$(basename "$latest")"
  echo "$ARCHIVE_PATH" > "$BACKUP_DIR/.restore-archive"
  [ -s "$ARCHIVE_PATH" ] || die "downloaded archive is empty: $ARCHIVE_PATH"
  log "downloaded: $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | awk '{print $1}'))"
  mark_phase 2
}

# ============================== PHASE 3: STORAGE LAYOUT ==============================
phase3_dirs() {
  should_run 3 || { log "phase 3 already done, skipping"; return; }
  log "PHASE 3 — recreate storage directories (single-disk layout)"
  run "sudo mkdir -p /mnt/minikube-backups/minikube-mnt"
  run "sudo mkdir -p /mnt/kachra/container-registry-images"
  run "sudo mkdir -p /mnt/predictonomy-postgres /mnt/predictonomy-backups"
  run "sudo chown -R cloud:cloud /mnt/minikube-backups /mnt/kachra"
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

  # 4e. nginx: data/ + letsencrypt/ are runtime-only (gitignored) and live ONLY in the
  #     backup. The repo (compose file) is cloned in phase 5; here we stage the data so
  #     phase 5 can overlay it after the clone. Stash to a known spot.
  run "rm -rf /mnt/minikube-backups/nginx-data-restore && mkdir -p /mnt/minikube-backups/nginx-data-restore"
  run "cp -a '$stage/home/cloud/Ideaprojects/nginx/.' /mnt/minikube-backups/nginx-data-restore/"

  # 4f. STEP0: keep freshly-cloned code; overlay only backed-up runtime files. Note .env
  #     carries NTFY_URL AND the Jenkins credential (JENKINS_CRED) the app deploys need.
  if [ -f "$stage/home/cloud/Ideaprojects/STEP0/.env" ]; then
    run "cp '$stage/home/cloud/Ideaprojects/STEP0/.env' '$SCRIPT_DIR/.env'"
  fi
  run "mkdir -p '$SCRIPT_DIR/logs'"
  [ -d "$stage/home/cloud/Ideaprojects/STEP0/logs" ] && run "cp -a '$stage/home/cloud/Ideaprojects/STEP0/logs/.' '$SCRIPT_DIR/logs/' || true"

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

  # Overlay the restored nginx runtime data (from phase 4e) onto the freshly-cloned repo.
  if [ -d /mnt/minikube-backups/nginx-data-restore ] && [ "$DRY_RUN" != 1 ]; then
    run "cp -a /mnt/minikube-backups/nginx-data-restore/data /home/cloud/Ideaprojects/nginx/ 2>/dev/null || true"
    run "cp -a /mnt/minikube-backups/nginx-data-restore/letsencrypt /home/cloud/Ideaprojects/nginx/ 2>/dev/null || true"
    log "nginx data/ + letsencrypt/ overlaid onto cloned nginx repo"
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
  log "PHASE 8 — re-arm restart policy, crontabs, unseal loop"

  # Keep the cluster across host reboots.
  run "docker update --restart=unless-stopped minikube || true"

  # Reinstall the cloud crontab verbatim (CRON_TZ ordering matters). The app-agent lines
  # (Predictonomy/yolo) are installed unconditionally; cron simply logs errors if a repo
  # path is absent, so a partial restore is harmless.
  local cron_tmp="/tmp/restore-cloud-crontab.$$"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> install cloud crontab (vault-auto-unseal, cluster-autostart, reduce-node-docker-cache + app agents)"
  else
    cat > "$cron_tmp" <<'CRON'
23 */3 * * * /home/cloud/IdeaProjects/Predictonomy/ops/agent/run-cycle.sh >> /home/cloud/IdeaProjects/Predictonomy/ops/agent/logs/cron.log 2>&1

# Predictonomy postgres-backup health check — 01:15 UTC, 15m after the 0 1 * * * CronJob (ops/agent/check-backup.sh)
CRON_TZ=UTC
15 1 * * * /home/cloud/IdeaProjects/Predictonomy/ops/agent/check-backup.sh >> /home/cloud/IdeaProjects/Predictonomy/ops/agent/logs/cron.log 2>&1

# Vault auto-unseal — keep the minikube Vault unsealed so backups/secrets never stall (N-0006/N-0009)
# @reboot starts the ~10s loop; */5 watchdog restarts it if it ever dies (flock = single instance).
@reboot /home/cloud/Ideaprojects/STEP0/vault-auto-unseal.sh >> /home/cloud/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1
*/5 * * * * /home/cloud/Ideaprojects/STEP0/vault-auto-unseal.sh >> /home/cloud/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1

# Cluster auto-start/heal — resume the minikube cluster after a host reboot if it was running
# (Docker unless-stopped does the restart; this reconciles k8s health + alerts on failure). N-0006 #3
@reboot sleep 30 && /home/cloud/Ideaprojects/STEP0/cluster-autostart.sh >> /home/cloud/Ideaprojects/STEP0/logs/cluster-autostart.log 2>&1
*/10 * * * * /home/cloud/Ideaprojects/STEP0/cluster-autostart.sh >> /home/cloud/Ideaprojects/STEP0/logs/cluster-autostart.log 2>&1
# YOLO Improvement Agent — one scoped cycle every 3h (see ops/agent/README.md)
17 */3 * * * /home/cloud/IdeaProjects/IG-Trading-Microservices/ops/agent/run-cycle.sh >> /home/cloud/IdeaProjects/IG-Trading-Microservices/ops/agent/logs/cron.log 2>&1

# Node docker build-cache cap — bound /var against Jenkins build churn (plan.md R7). Daily 04:30 local.
CRON_TZ=Europe/London
30 4 * * * /home/cloud/Ideaprojects/STEP0/reduce-node-docker-cache.sh >> /home/cloud/Ideaprojects/STEP0/logs/reduce-node-docker-cache.log 2>&1
CRON
    crontab "$cron_tmp" && log "cloud crontab installed" || log "WARN: cloud crontab install failed"
    rm -f "$cron_tmp"
  fi

  # Reinstall the SINGLE root backup cron line (needs root to read 0600 keys file).
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> sudo crontab -u root - (weekly backup-minikube-mnt.sh Mon 05:00)"
  else
    echo '0 5 * * 1 /bin/bash /home/cloud/Ideaprojects/STEP0/backup-minikube-mnt.sh >> /var/log/minikube-backup.log 2>&1' \
      | sudo crontab -u root - && log "root backup cron installed" || log "WARN: root cron install failed"
  fi

  # Start the unseal loop NOW (don't wait for @reboot) so Vault unseals immediately.
  run "mkdir -p '$SCRIPT_DIR/logs'"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> setsid $SCRIPT_DIR/vault-auto-unseal.sh >> $SCRIPT_DIR/logs/vault-auto-unseal.log 2>&1 &"
  else
    setsid "$SCRIPT_DIR/vault-auto-unseal.sh" >> "$SCRIPT_DIR/logs/vault-auto-unseal.log" 2>&1 < /dev/null &
    log "vault-auto-unseal loop launched"
  fi
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
  fi
  cat <<'DONE'
==================================================================
RESTORE COMPLETE — platform is up; apps are NOT yet deployed.

Verify:
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
==================================================================
DONE
  mark_phase 9
  log "restore-scratch: ALL PHASES COMPLETE."
}

# ============================== MAIN ==============================
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
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
