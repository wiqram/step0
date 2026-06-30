# restore-scratch.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `restore-scratch.sh`, a phased/resumable cold disaster-recovery script that rebuilds the entire STEP0 private cloud on a bare Ubuntu box from the latest GCS Coldline backup, pausing before app deploys.

**Architecture:** Approach C — refactor the 6 Jenkins app-build triggers out of `start-scratch.sh` into `trigger-app-builds.sh` guarded by `SKIP_APP_BUILDS`, then `restore-scratch.sh` does the restore-specific work (install tooling → `gcloud` pull → extract → clone repos → dirs → `SKIP_APP_BUILDS=1 ./start-scratch.sh` → nginx → cron → pause). Pure, testable logic (latest-archive picker, repo manifest) lives in a sourced `restore-lib.sh` with a real unit test.

**Tech Stack:** Bash, Docker, Minikube, kubectl, Helm, gcloud SDK (`gcloud storage`), Nginx Proxy Manager (docker compose), shellcheck for static checks.

**Spec:** `docs/superpowers/specs/2026-06-30-restore-scratch-design.md`

**Testing note (read first):** This is infrastructure bash that installs system packages, mutates a host, and pulls ~100 GB. It **cannot** be run end-to-end in the dev session — doing so would corrupt the live box. So "tests" here are: (1) a genuine bash unit test for the pure logic in `restore-lib.sh`; (2) `bash -n` syntax checks; (3) `shellcheck`; (4) `--dry-run` execution that prints each phase's intended actions without mutating anything. Full end-to-end validation happens on a real throwaway Ubuntu VM, which is out of scope for this plan to execute but is documented as the acceptance test in the final task.

**Conventions to follow (match existing STEP0 scripts):**
- Heavy inline `#` comments; keep alternative commands commented for reference.
- `flock` single-instance guard for anything cron-like (see `backup-minikube-mnt.sh`).
- Fixed facts: user `cloud`, `$HOME=/home/cloud`, network `5million`, node IP `172.16.238.2`, NPM `172.16.238.10`, bucket `gs://private_cloud_backup`, project `igtrader-296013`, gcloud at `~/google-cloud-sdk/bin/gcloud`, repos under `github.com/wiqram/*`.
- Preserve the two case-variant trees exactly: `~/Ideaprojects` (infra) and `~/IdeaProjects` (apps).

---

## File Structure

| File | Responsibility |
|---|---|
| `trigger-app-builds.sh` (create) | The 6 Jenkins app-build `curl` triggers extracted verbatim from `start-scratch.sh`. Independently runnable. |
| `start-scratch.sh` (modify ~L146–188) | Replace the extracted block with a `SKIP_APP_BUILDS` guard calling `trigger-app-builds.sh`. No other behaviour change. |
| `restore-lib.sh` (create) | Pure, sourceable functions: `pick_latest_archive`, `restore_repo_manifest`. No side effects. |
| `tests/test-restore-lib.sh` (create) | Bash unit test asserting `pick_latest_archive` and the manifest. |
| `restore-scratch.sh` (create) | The DR orchestrator: phases 0–9, resumable via phase marker, `--dry-run`/`--from-phase` flags, non-`set -e`. |
| `RESTART-RECOVERY.md`, `architecture.md` (modify) | Cross-reference the new cold DR path. |

---

## Task 1: Extract `trigger-app-builds.sh` and guard `start-scratch.sh`

**Files:**
- Create: `/home/cloud/Ideaprojects/STEP0/trigger-app-builds.sh`
- Modify: `/home/cloud/Ideaprojects/STEP0/start-scratch.sh:146-188`

- [ ] **Step 1: Create `trigger-app-builds.sh` with the verbatim triggers**

```bash
#!/bin/bash
####################################
#
# trigger-app-builds.sh — fire each app's Jenkins deploy job.
#
####################################
# Extracted from start-scratch.sh so the cold bootstrap and the disaster-recovery
# path (restore-scratch.sh) can run the platform bring-up WITHOUT firing app builds
# (set SKIP_APP_BUILDS=1 when calling start-scratch.sh), then trigger the builds
# separately once DNS points at this host.
#
# Each curl carries the inline Jenkins API credential + per-job build token (these
# already live in the repo; rotating/relocating them is tracked in plan.md P0 #1 and
# is out of scope here). Requires: jenkins.traderyolo.com reachable (NPM + DNS up).
#
# NOTE: best-effort, NOT set -e — a single unreachable job must not abort the rest.

echo "building qcguy"
curl -X POST https://private-cloud:REVOKED-2026-06-30@jenkins.traderyolo.com/job/qcguy/build?token=qcguy

echo "building predictonomy"
curl -X POST https://private-cloud:REVOKED-2026-06-30@jenkins.traderyolo.com/job/predictonomy/build?token=predict

echo "building bestrentaladmin"
curl -X POST https://private-cloud:REVOKED-2026-06-30@jenkins.traderyolo.com/job/bestrentaladmin/build?token=best

echo "building dyingpaleblue"
curl -X POST https://private-cloud:REVOKED-2026-06-30@jenkins.traderyolo.com/job/dyingpaleblue/build?token=dying

echo "building ollama"
curl -X POST https://private-cloud:REVOKED-2026-06-30@jenkins.traderyolo.com/job/ollama/build?token=ollama

echo "building yolo pipeline but before that sleeping for 1 min"
sleep 1m
curl -X POST https://private-cloud:REVOKED-2026-06-30@jenkins.traderyolo.com/job/trading-microservices/build?token=yolo

echo "trigger-app-builds: all app build jobs triggered."
```

- [ ] **Step 2: Make it executable and syntax-check**

Run: `chmod +x /home/cloud/Ideaprojects/STEP0/trigger-app-builds.sh && bash -n /home/cloud/Ideaprojects/STEP0/trigger-app-builds.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Replace the block in `start-scratch.sh` with the guard**

In `start-scratch.sh`, replace lines 140–189 (the `#####qcguy#####` comment through the `trading-microservices` curl, i.e. everything from `echo "building qcguy"` and its surrounding commented sections up to and including the yolo curl) with:

```bash
#################app deploys (Jenkins)#############################
# The actual per-app deploys are Jenkins job triggers, extracted to
# trigger-app-builds.sh. restore-scratch.sh sets SKIP_APP_BUILDS=1 to bring up the
# platform first and fire these only AFTER DNS points at the host.
if [ -z "${SKIP_APP_BUILDS:-}" ]; then
  "$(dirname "$SCRIPT_PATH")/trigger-app-builds.sh"
else
  echo "SKIP_APP_BUILDS set — skipping Jenkins app-build triggers. Run ./trigger-app-builds.sh after DNS is confirmed."
fi
```

Keep the `echo "End - NOT deploying splunk"` line (originally L191) and everything after it unchanged.

- [ ] **Step 4: Syntax-check start-scratch.sh and verify the guard both ways**

Run:
```bash
bash -n /home/cloud/Ideaprojects/STEP0/start-scratch.sh && echo SYNTAX_OK
grep -n 'SKIP_APP_BUILDS' /home/cloud/Ideaprojects/STEP0/start-scratch.sh
grep -c 'jenkins.traderyolo.com/job/' /home/cloud/Ideaprojects/STEP0/trigger-app-builds.sh
```
Expected: `SYNTAX_OK`; the grep shows the guard at the new block; the count is `6` (qcguy, predictonomy, bestrentaladmin, dyingpaleblue, ollama, trading-microservices).

- [ ] **Step 5: Verify no live trigger curls remain in start-scratch.sh**

Run: `grep -nE '^[^#]*curl -X POST https://private-cloud.*jenkins.traderyolo.com/job/' /home/cloud/Ideaprojects/STEP0/start-scratch.sh || echo NONE_LEFT`
Expected: `NONE_LEFT` (all live app-build curls now live only in trigger-app-builds.sh; commented examples may remain).

- [ ] **Step 6: Commit**

```bash
cd /home/cloud/Ideaprojects/STEP0
git add trigger-app-builds.sh start-scratch.sh
git commit -m "refactor: extract app-build triggers to trigger-app-builds.sh + SKIP_APP_BUILDS guard"
```

---

## Task 2: `restore-lib.sh` pure functions + unit test (TDD)

**Files:**
- Create: `/home/cloud/Ideaprojects/STEP0/restore-lib.sh`
- Test: `/home/cloud/Ideaprojects/STEP0/tests/test-restore-lib.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/bin/bash
# tests/test-restore-lib.sh — unit tests for restore-lib.sh pure functions.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../restore-lib.sh"
fail=0
assert_eq() { # $1=actual $2=expected $3=label
  if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi
}

# pick_latest_archive: newest by MM-DD-YY embedded in filename, NOT lexical.
sample=$(cat <<'EOF'
gs://private_cloud_backup/private-cloud-10-06-25.tgz
gs://private_cloud_backup/private-cloud-03-09-26.tgz
gs://private_cloud_backup/private-cloud-06-29-26.tgz
gs://private_cloud_backup/private-cloud-06-16-26.tgz
gs://private_cloud_backup/some-unrelated-object.txt
EOF
)
got=$(printf '%s\n' "$sample" | pick_latest_archive)
assert_eq "$got" "gs://private_cloud_backup/private-cloud-06-29-26.tgz" "pick_latest_archive picks newest by date"

# Year rollover: 01-05-27 (2027) must beat 12-31-26 (2026) despite lexical order.
roll=$(printf '%s\n' \
  "gs://b/private-cloud-12-31-26.tgz" \
  "gs://b/private-cloud-01-05-27.tgz" | pick_latest_archive)
assert_eq "$roll" "gs://b/private-cloud-01-05-27.tgz" "pick_latest_archive handles year rollover"

# manifest: 12 repos, tab/space separated dir url branch; spot-check the feature branch.
n=$(restore_repo_manifest | grep -c 'github.com/wiqram/')
assert_eq "$n" "12" "manifest lists 12 repos"
dpb=$(restore_repo_manifest | awk '/dyingpaleblue/{print $3}')
assert_eq "$dpb" "fix-migrate-postgres-readiness" "dyingpaleblue pinned to feature branch"

exit $fail
```

- [ ] **Step 2: Run the test, verify it fails (no restore-lib.sh yet)**

Run: `bash /home/cloud/Ideaprojects/STEP0/tests/test-restore-lib.sh; echo "exit=$?"`
Expected: error sourcing `restore-lib.sh` (No such file) → non-zero exit.

- [ ] **Step 3: Implement `restore-lib.sh`**

```bash
#!/bin/bash
# restore-lib.sh — pure, sourceable helpers for restore-scratch.sh. No side effects.
# Sourcing this file must not execute anything except function definitions.

# pick_latest_archive: read candidate gs:// URIs on stdin, print the single newest
# private-cloud-MM-DD-YY.tgz by the date EMBEDDED IN THE FILENAME (not lexical order,
# not GCS listing order). Mirrors the date parse in backup-minikube-mnt.sh's prune.
pick_latest_archive() {
  sed -E 's#.*/private-cloud-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$#20\3-\1-\2 &#' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' \
    | sort \
    | tail -1 \
    | awk '{print $2}'
}

# restore_repo_manifest: emit "<target_dir> <git_url> <branch>" per infra/app repo to
# clone on a fresh box. STEP0 is cloned by hand (bootstrap) and is intentionally absent.
# Branches captured 2026-06-30; update when prod's deployed branches change.
restore_repo_manifest() {
  cat <<'EOF'
/home/cloud/Ideaprojects/vault https://github.com/wiqram/vault.git main
/home/cloud/Ideaprojects/jenkins https://github.com/wiqram/jenkins.git master
/home/cloud/Ideaprojects/kube-prometheus https://github.com/wiqram/kube-prometheus.git main
/home/cloud/Ideaprojects/nginx https://github.com/wiqram/nginx.git master
/home/cloud/Ideaprojects/qcguy-ghost https://github.com/wiqram/qcguy-ghost.git main
/home/cloud/IdeaProjects/bestrentaladmin https://github.com/wiqram/bestrentaladmin.git main
/home/cloud/IdeaProjects/dyingpaleblue https://github.com/wiqram/dyingpaleblue.git fix-migrate-postgres-readiness
/home/cloud/IdeaProjects/ollama https://github.com/wiqram/ollama.git main
/home/cloud/IdeaProjects/Predictonomy https://github.com/wiqram/Predictonomy.git master
/home/cloud/IdeaProjects/IG-Trading-Microservices https://github.com/wiqram/IG-Trading-Microservices.git Claude-agent-update
/home/cloud/IdeaProjects/qcx https://github.com/wiqram/qcx.git main
/home/cloud/IdeaProjects/radcliffe https://github.com/wiqram/radcliffe.git main
EOF
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash /home/cloud/Ideaprojects/STEP0/tests/test-restore-lib.sh; echo "exit=$?"`
Expected: all `ok:` lines, `exit=0`.

- [ ] **Step 5: shellcheck the lib**

Run: `shellcheck /home/cloud/Ideaprojects/STEP0/restore-lib.sh || true`
Expected: no errors (warnings acceptable; fix any genuine ones).

- [ ] **Step 6: Commit**

```bash
cd /home/cloud/Ideaprojects/STEP0
git add restore-lib.sh tests/test-restore-lib.sh
git commit -m "feat: restore-lib.sh pure helpers (latest-archive picker, repo manifest) + unit test"
```

---

## Task 3: `restore-scratch.sh` skeleton — phase framework + Phase 0 preflight

**Files:**
- Create: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`

- [ ] **Step 1: Write the skeleton (framework + flags + Phase 0)**

```bash
#!/bin/bash
####################################
#
# restore-scratch.sh — COLD disaster recovery: bare Ubuntu -> fully wired private cloud
# from the latest GCS Coldline backup. Inverse of backup-minikube-mnt.sh; ends by
# running start-scratch.sh (SKIP_APP_BUILDS=1) then pausing before app deploys.
#
# Design: docs/superpowers/specs/2026-06-30-restore-scratch-design.md
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

# ---- helpers ----
log()  { echo "[restore $(date '+%H:%M:%S')] $*"; }
die()  { echo "[restore FATAL] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
# run: execute unless --dry-run (then just print). Use for every mutating command.
run()  { if [ "$DRY_RUN" = 1 ]; then echo "  DRYRUN> $*"; else log "+ $*"; eval "$@"; fi; }

phase_done() { [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" -ge "$1" ] 2>/dev/null; }
mark_phase() { [ "$DRY_RUN" = 1 ] || echo "$1" > "$MARKER"; }
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

# ============================== MAIN ==============================
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
phase0_preflight
# (phases 1-9 appended in later tasks)
log "restore-scratch: reached end of implemented phases."
```

- [ ] **Step 2: Make executable + syntax check**

Run: `chmod +x /home/cloud/Ideaprojects/STEP0/restore-scratch.sh && bash -n /home/cloud/Ideaprojects/STEP0/restore-scratch.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: shellcheck**

Run: `shellcheck /home/cloud/Ideaprojects/STEP0/restore-scratch.sh || true`
Expected: no errors (the `eval` in `run()` will warn SC2086/SC2294 — acceptable and intentional for a generic command runner; add `# shellcheck disable=SC2086,SC2294` above `run()` if noisy).

- [ ] **Step 4: Dry-run reaches the end without mutating**

Run: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh --dry-run`
Expected: prints the PHASE 0 banner, "dry-run: skipping confirmation", a `DRYRUN> mkdir -p .../logs` line, and "reached end of implemented phases." No prompt, no real mkdir of the marker.

- [ ] **Step 5: Commit**

```bash
cd /home/cloud/Ideaprojects/STEP0
git add restore-scratch.sh
git commit -m "feat: restore-scratch.sh skeleton — phase framework, flags, preflight"
```

---

## Task 4: Phase 1 — install host tooling

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh` (insert `phase1_tooling` before MAIN; call it after `phase0_preflight`)

- [ ] **Step 1: Add the `phase1_tooling` function**

```bash
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
```

Then in MAIN, after `phase0_preflight`, add: `phase1_tooling`.

- [ ] **Step 2: Syntax + shellcheck**

Run: `bash -n restore-scratch.sh && shellcheck restore-scratch.sh || true; echo done`
Expected: parses; shellcheck only the accepted `run()`/eval warnings.

- [ ] **Step 3: Dry-run shows the install plan without executing**

Run: `cd /home/cloud/Ideaprojects/STEP0 && ./restore-scratch.sh --dry-run --from-phase 1 2>&1 | grep -E 'DRYRUN>|PHASE 1' | head -20`
Expected: `PHASE 1` line plus `DRYRUN>` lines for apt/docker/kubectl/minikube/helm/nvidia/gcloud. No packages actually installed.

- [ ] **Step 4: Commit**

```bash
git add restore-scratch.sh && git commit -m "feat(restore): phase 1 — install host tooling"
```

---

## Task 5: Phase 2 — interactive gcloud login + pull latest backup

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`

- [ ] **Step 1: Add `phase2_pull`**

```bash
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
```

Add `phase2_pull` to MAIN after `phase1_tooling`.

- [ ] **Step 2: Syntax + shellcheck**

Run: `bash -n restore-scratch.sh && shellcheck restore-scratch.sh || true; echo done`
Expected: parses; only accepted warnings.

- [ ] **Step 3: Dry-run shows the gcloud commands and the pipe to the tested picker**

Run: `./restore-scratch.sh --dry-run --from-phase 2 2>&1 | grep -E 'PHASE 2|DRYRUN>' | head`
Expected: `auth login`, `config set project igtrader-296013`, and the `storage ls ... | pick_latest_archive` line. No download.

- [ ] **Step 4: Commit**

```bash
git add restore-scratch.sh && git commit -m "feat(restore): phase 2 — gcloud login + pull latest backup (uses restore-lib picker)"
```

---

## Task 6: Phase 3+4 — storage layout + extract (vault keys, age key, STEP0 overlay)

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`

- [ ] **Step 1: Add `phase3_dirs` and `phase4_extract`**

```bash
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
  [ "$DRY_RUN" = 1 ] && { echo "  DRYRUN> tar -xzf <archive> -C /  (selectively)"; mark_phase 4; return; }
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

  # 4f. STEP0: keep freshly-cloned code; overlay only backed-up runtime files.
  if [ -f "$stage/home/cloud/Ideaprojects/STEP0/.env" ]; then
    run "cp '$stage/home/cloud/Ideaprojects/STEP0/.env' '$SCRIPT_DIR/.env'"
  fi
  run "mkdir -p '$SCRIPT_DIR/logs'"
  [ -d "$stage/home/cloud/Ideaprojects/STEP0/logs" ] && run "cp -a '$stage/home/cloud/Ideaprojects/STEP0/logs/.' '$SCRIPT_DIR/logs/' || true"

  run "rm -rf '$stage'"
  mark_phase 4
}
```

Add `phase3_dirs` and `phase4_extract` to MAIN after `phase2_pull`.

- [ ] **Step 2: Syntax + shellcheck**

Run: `bash -n restore-scratch.sh && shellcheck restore-scratch.sh || true; echo done`
Expected: parses; only accepted warnings.

- [ ] **Step 3: Dry-run prints the extract intent and the vault-first ordering**

Run: `./restore-scratch.sh --dry-run --from-phase 3 2>&1 | grep -E 'PHASE 3|PHASE 4|DRYRUN>' | head`
Expected: PHASE 3 mkdir lines, PHASE 4 prints the `tar -xzf <archive>` dryrun line.

- [ ] **Step 4: Commit**

```bash
git add restore-scratch.sh && git commit -m "feat(restore): phases 3-4 — storage dirs + selective extract (vault keys, age key, STEP0 overlay)"
```

---

## Task 7: Phase 5 — clone repos per manifest + overlay nginx data

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`

- [ ] **Step 1: Add `phase5_clone`**

```bash
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
    git clone --branch "$branch" "$url" "$dir" \
      || git clone "$url" "$dir" && git -C "$dir" checkout "$branch" \
      || log "WARN: clone/checkout failed for $url ($branch) — clone manually"
  done < <(restore_repo_manifest)

  # Overlay the restored nginx runtime data (from phase 4f) onto the freshly-cloned repo.
  if [ -d /mnt/minikube-backups/nginx-data-restore ] && [ "$DRY_RUN" != 1 ]; then
    run "cp -a /mnt/minikube-backups/nginx-data-restore/data /home/cloud/Ideaprojects/nginx/ 2>/dev/null || true"
    run "cp -a /mnt/minikube-backups/nginx-data-restore/letsencrypt /home/cloud/Ideaprojects/nginx/ 2>/dev/null || true"
    log "nginx data/ + letsencrypt/ overlaid onto cloned nginx repo"
  fi
  mark_phase 5
}
```

Add `phase5_clone` to MAIN after `phase4_extract`.

- [ ] **Step 2: Syntax + shellcheck**

Run: `bash -n restore-scratch.sh && shellcheck restore-scratch.sh || true; echo done`
Expected: parses (the `||`/`&&` chain in the clone is intentional; if shellcheck flags SC2015, restructure into an explicit `if git clone ... ; then : ; else ...` block).

- [ ] **Step 3: Dry-run prints exactly 12 clone commands with correct branches**

Run: `./restore-scratch.sh --dry-run --from-phase 5 2>&1 | grep -c 'DRYRUN> git clone'`
Expected: `12`. Spot-check: `./restore-scratch.sh --dry-run --from-phase 5 2>&1 | grep dyingpaleblue` shows `--branch fix-migrate-postgres-readiness`.

- [ ] **Step 4: Commit**

```bash
git add restore-scratch.sh && git commit -m "feat(restore): phase 5 — clone repos per manifest + overlay nginx data"
```

---

## Task 8: Phase 6+7 — cluster bring-up + nginx

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`

- [ ] **Step 1: Add `phase6_cluster` and `phase7_nginx`**

```bash
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
  # letsencrypt/ were overlaid in phase 5, so all 23 proxy hosts + certs come back.
  run "cd /home/cloud/Ideaprojects/nginx && docker compose up -d"
  mark_phase 7
}
```

Add both to MAIN after `phase5_clone`.

- [ ] **Step 2: Syntax + shellcheck**

Run: `bash -n restore-scratch.sh && shellcheck restore-scratch.sh || true; echo done`
Expected: parses; only accepted warnings.

- [ ] **Step 3: Dry-run shows the guarded start-scratch call and the compose up**

Run: `./restore-scratch.sh --dry-run --from-phase 6 2>&1 | grep -E 'DRYRUN>' `
Expected: `SKIP_APP_BUILDS=1 .../start-scratch.sh` and `cd .../nginx && docker compose up -d`.

- [ ] **Step 4: Commit**

```bash
git add restore-scratch.sh && git commit -m "feat(restore): phases 6-7 — platform bring-up (SKIP_APP_BUILDS) + nginx"
```

---

## Task 9: Phase 8 — re-arm host automation (restart policy, crontabs, unseal loop)

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`

- [ ] **Step 1: Add `phase8_automation`**

```bash
# ============================== PHASE 8: RE-ARM AUTOMATION ==============================
phase8_automation() {
  should_run 8 || { log "phase 8 already done, skipping"; return; }
  log "PHASE 8 — re-arm restart policy, crontabs, unseal loop"

  # Keep the cluster across host reboots.
  run "docker update --restart=unless-stopped minikube || true"

  # Reinstall the cloud crontab verbatim (CRON_TZ ordering matters). App-agent lines are
  # included only if those repos exist (they were cloned in phase 5).
  local cron_tmp="/tmp/restore-cloud-crontab.$$"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> install cloud crontab (vault-auto-unseal, cluster-autostart, reduce-node-docker-cache + app agents)"
  else
    cat > "$cron_tmp" <<'CRON'
23 */3 * * * /home/cloud/IdeaProjects/Predictonomy/ops/agent/run-cycle.sh >> /home/cloud/IdeaProjects/Predictonomy/ops/agent/logs/cron.log 2>&1

CRON_TZ=UTC
15 1 * * * /home/cloud/IdeaProjects/Predictonomy/ops/agent/check-backup.sh >> /home/cloud/IdeaProjects/Predictonomy/ops/agent/logs/cron.log 2>&1

@reboot /home/cloud/Ideaprojects/STEP0/vault-auto-unseal.sh >> /home/cloud/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1
*/5 * * * * /home/cloud/Ideaprojects/STEP0/vault-auto-unseal.sh >> /home/cloud/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1

@reboot sleep 30 && /home/cloud/Ideaprojects/STEP0/cluster-autostart.sh >> /home/cloud/Ideaprojects/STEP0/logs/cluster-autostart.log 2>&1
*/10 * * * * /home/cloud/Ideaprojects/STEP0/cluster-autostart.sh >> /home/cloud/Ideaprojects/STEP0/logs/cluster-autostart.log 2>&1

17 */3 * * * /home/cloud/IdeaProjects/IG-Trading-Microservices/ops/agent/run-cycle.sh >> /home/cloud/IdeaProjects/IG-Trading-Microservices/ops/agent/logs/cron.log 2>&1

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
```

Add `phase8_automation` to MAIN after `phase7_nginx`.

- [ ] **Step 2: Syntax + shellcheck**

Run: `bash -n restore-scratch.sh && shellcheck restore-scratch.sh || true; echo done`
Expected: parses; only accepted warnings.

- [ ] **Step 3: Verify the embedded cloud crontab matches the live one exactly**

Run: `crontab -l > /tmp/live-cron.txt; sed -n '/cat > "\$cron_tmp"/,/^CRON$/p' restore-scratch.sh | sed '1d;$d' > /tmp/plan-cron.txt; diff <(grep -vE '^\s*$' /tmp/live-cron.txt) <(grep -vE '^\s*$' /tmp/plan-cron.txt) && echo CRON_MATCH`
Expected: `CRON_MATCH` (the heredoc reproduces the current cloud crontab line-for-line, ignoring blank lines). If it differs, update the heredoc to match the live crontab.

- [ ] **Step 4: Commit**

```bash
git add restore-scratch.sh && git commit -m "feat(restore): phase 8 — restart policy, crontabs, immediate unseal loop"
```

---

## Task 10: Phase 9 — verify + handoff

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`

- [ ] **Step 1: Add `phase9_handoff`**

```bash
# ============================== PHASE 9: VERIFY + HANDOFF ==============================
phase9_handoff() {
  log "PHASE 9 — verification + handoff"
  if [ "$DRY_RUN" != 1 ]; then
    minikube status || true
    kubectl -n vault exec vault-0 -- vault status 2>/dev/null | grep -i sealed || true
    kubectl get po -A 2>/dev/null | head -30 || true
    docker compose -f /home/cloud/Ideaprojects/nginx/docker-compose.yml ls 2>/dev/null || true
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
     Registry starts EMPTY (single-disk restore) — the first build of each app
     rebuilds + re-pushes its image; transient ImagePullBackOff is expected.
  4. Re-pull ollama models (excluded from backup):  ollama pull <model>  (see Modelfile)
==================================================================
DONE
  mark_phase 9
  log "restore-scratch: ALL PHASES COMPLETE."
}
```

Replace the trailing `log "restore-scratch: reached end of implemented phases."` in MAIN with `phase9_handoff`.

- [ ] **Step 2: Syntax + shellcheck + full dry-run of all phases**

Run: `bash -n restore-scratch.sh && shellcheck restore-scratch.sh || true; ./restore-scratch.sh --dry-run --from-phase 0 2>&1 | grep -E 'PHASE [0-9]' `
Expected: parses; the dry-run prints `PHASE 0` through `PHASE 9` in order.

- [ ] **Step 3: Commit**

```bash
git add restore-scratch.sh && git commit -m "feat(restore): phase 9 — verification output + DNS/app-deploy handoff"
```

---

## Task 11: Docs cross-reference + final self-check

**Files:**
- Modify: `/home/cloud/Ideaprojects/STEP0/RESTART-RECOVERY.md`
- Modify: `/home/cloud/Ideaprojects/STEP0/architecture.md`
- Modify: `/home/cloud/Ideaprojects/STEP0/CLAUDE.md` (Key files table)

- [ ] **Step 1: Add a "Total-loss / bare-metal" row to RESTART-RECOVERY.md**

Add near the warm-vs-cold decision section:

```markdown
### Total host loss (bare-metal rebuild)
If the machine itself is gone, not just the cluster: on a fresh Ubuntu box, clone STEP0
(`git clone https://github.com/wiqram/step0.git`) and run **`./restore-scratch.sh`**. It
installs all tooling, pulls the latest GCS Coldline backup, restores Vault keys + data +
nginx proxy hosts/certs, clones every app repo, brings up the platform
(`SKIP_APP_BUILDS=1 start-scratch.sh`), re-arms cron, then PAUSES. Re-point DNS at the new
host, then run `./trigger-app-builds.sh`. Resumable: `--from-phase N`; inspect with `--dry-run`.
See `docs/superpowers/specs/2026-06-30-restore-scratch-design.md`.
```

- [ ] **Step 2: Add restore-scratch.sh to the CLAUDE.md Key files table**

Add a row:
```markdown
| `restore-scratch.sh` | **Cold disaster recovery from a bare Ubuntu box.** Installs tooling, pulls the latest GCS Coldline backup, restores Vault/nginx/data, clones repos, runs `SKIP_APP_BUILDS=1 start-scratch.sh`, re-arms cron, pauses before app deploys (run `trigger-app-builds.sh` after DNS). Resumable (`--from-phase`), inspectable (`--dry-run`). |
| `trigger-app-builds.sh` | The per-app Jenkins build triggers, extracted from `start-scratch.sh`. Run after a restore once DNS points at the host. |
```

- [ ] **Step 3: Add an architecture.md §7 note that restore inverts the backup**

Append to §7 (Off-site copy): one paragraph noting `restore-scratch.sh` is the documented inverse — pulls the newest `private-cloud-*.tgz` via interactive `gcloud auth login`, and that registry blobs (on sdb2) and ollama models are NOT in the archive so they are rebuilt/re-pulled.

- [ ] **Step 4: Self-check — spec coverage + all scripts parse + unit test green**

Run:
```bash
cd /home/cloud/Ideaprojects/STEP0
for f in restore-scratch.sh restore-lib.sh trigger-app-builds.sh start-scratch.sh; do bash -n "$f" && echo "OK $f"; done
bash tests/test-restore-lib.sh
./restore-scratch.sh --dry-run --from-phase 0 2>&1 | grep -cE 'PHASE [0-9]'
```
Expected: `OK` for all four; unit test exit 0; the phase count is `10` (phases 0–9).

- [ ] **Step 5: Commit**

```bash
git add RESTART-RECOVERY.md architecture.md CLAUDE.md
git commit -m "docs: cross-reference restore-scratch.sh cold DR path"
```

---

## Acceptance test (run on a throwaway Ubuntu VM — out of scope to execute in dev session)

1. Spin up a fresh Ubuntu VM with a GPU (or accept the GPU-driver reboot caveat).
2. `git clone https://github.com/wiqram/step0.git && cd step0`
3. Ensure GitHub auth + a Google identity with bucket read are available.
4. `./restore-scratch.sh` → complete phases 0–9 (reboot if prompted after NVIDIA install, then re-run — it resumes).
5. Verify: `minikube status` Running; `vault status` Sealed=false; `docker compose ps` NPM up; the 23 proxy hosts present in the NPM UI.
6. Point DNS at the VM, run `./trigger-app-builds.sh`, confirm each app deploys and `curl -sI https://<app-domain>` returns 200.

---

## Self-Review (completed by plan author)

- **Spec coverage:** every spec §5 phase → a task (Phase 0→T3, 1→T4, 2→T5, 3-4→T6, 5→T7, 6-7→T8, 8→T9, 9→T10); refactor (§4.1)→T1; pure logic (§4.2)→T2; docs (§10)→T11. SOPS age key gap (added to spec) → T6 step 4c. ✔
- **Placeholder scan:** no TBD/TODO; all code blocks are complete and runnable. The only `<latest>`/`<app-domain>` tokens are inside dry-run echo strings / operator-facing instructions, intentionally. ✔
- **Naming consistency:** `pick_latest_archive`, `restore_repo_manifest`, `should_run`, `mark_phase`, `phaseN_*`, `ARCHIVE_PATH`, `MARKER` used identically across tasks. ✔
- **Resumability:** every phase guarded by `should_run`/`mark_phase`; `--from-phase` overrides; `ARCHIVE_PATH` persisted to `.restore-archive` so phase 4 works on resume after phase 2. ✔
