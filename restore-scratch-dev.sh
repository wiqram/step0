#!/usr/bin/env bash
# restore-scratch-dev.sh — bootstrap the YOLO DEV BOX (vik@10.10.10.2) from a fresh
# Ubuntu install to a working `./dockerup-dev.sh` stack.
#
# Scope: developer WORKSTATION only — no minikube/K8s here (that's prod's
# restore-scratch.sh / start-scratch.sh). What this arms:
#   toolchain (docker+compose, Go+protoc plugins, node+grpc-tools, python venv,
#   sops+age, jq) -> repos + robin_stocks submodule -> env materialisation from the
#   committed vault/dev SOPS manifests -> docker prep -> dockerup-dev.sh -> verify.
#
# Design mirrors restore-scratch.sh: set -u (NOT -e: a long run must not die
# silently), numbered idempotent phases with a ratcheting marker file, --dry-run,
# --from-phase N, die()/need() for fatals, WARN-and-continue for best-effort items.
#
# Break-glass (operator must provide, everything else is scripted):
#   1. GitHub auth (SSH key or gh login) — assumed present per the dev-box setup.
#   2. Dev-box SOPS age key -> ~/.config/sops/age/keys.txt (or drop it at
#      <IG repo>/Vault-Secrets-NO-GIT-COMMIT/dev-age.key and phase 3 installs it).
#      Without it the stack still boots on *.example placeholder creds.
#   3. (optional) ~/.jenkins-deploy-urls.env — seeded from prod (STEP0/.env via
#      seed-agent-deploy-urls.sh) for `jenkins-deploy` from the dev box.
#
# Usage: ./restore-scratch-dev.sh [--dry-run] [--from-phase N]
set -u

DEV_USER="${DEV_USER:-vik}"
IDEA="$HOME/IdeaProjects"
IG_REPO="$IDEA/IG-Trading-Microservices"
IG_URL="https://github.com/wiqram/IG-Trading-Microservices.git"
IG_BRANCH="Claude-agent-update"
STEP0_REPO="$IDEA/step0"
MARKER="$HOME/.yolo-dev-restore-phase"
GO_VERSION="1.19.13"          # parity with the services' golang:1.19 images
SOPS_VERSION="3.9.4"
AGE_VERSION="1.2.1"
NODE_MAJOR="20"               # LTS; UI/userService images run node 18+

DRY_RUN=0; FROM_PHASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --from-phase) shift; FROM_PHASE="${1:-}" ;;
    *) echo "usage: $0 [--dry-run] [--from-phase N]" >&2; exit 2 ;;
  esac
  shift
done

log()  { echo "[restore-dev $(date '+%H:%M:%S')] $*"; }
die()  { echo "[restore-dev FATAL] $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required: $1"; }
run()  { if [ "$DRY_RUN" = 1 ]; then echo "DRY: $*"; else eval "$@"; fi; }

phase_done() { [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" -ge "$1" ] 2>/dev/null; }
mark_phase() {
  [ "$DRY_RUN" = 1 ] && return 0
  local cur; cur="$(cat "$MARKER" 2>/dev/null)"; [[ "$cur" =~ ^[0-9]+$ ]] || cur=-1
  [ "$1" -gt "$cur" ] && echo "$1" > "$MARKER"
}
should_run() {
  local p="$1"
  if [ -n "$FROM_PHASE" ]; then [ "$p" -ge "$FROM_PHASE" ]; return; fi
  ! phase_done "$p"
}

# idempotently append a line to a file iff absent (pure helper, unit-tested)
ensure_line() { # $1=line $2=file
  if [ "$DRY_RUN" = 1 ]; then
    grep -qxF -- "$1" "$2" 2>/dev/null || echo "DRY: append to $2: $1"
    return 0
  fi
  grep -qxF -- "$1" "$2" 2>/dev/null || echo "$1" >> "$2"
}

# ---------------------------------------------------------------- phase 0
phase0_preflight() {
  should_run 0 || { log "phase 0 already done"; return 0; }
  log "phase 0: preflight"
  [ "$(whoami)" = "$DEV_USER" ] || die "run as $DEV_USER (got $(whoami)); override with DEV_USER=<u>"
  need git; need curl
  curl -sfI https://github.com >/dev/null 2>&1 || die "github.com unreachable — network first"
  local free_gb; free_gb=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
  [ "${free_gb:-0}" -ge 30 ] || log "WARN: only ${free_gb}GB free in \$HOME — docker builds want 30GB+"
  if ! sudo -n true 2>/dev/null; then
    log "NOTE: sudo will prompt for a password during phase 1 (apt installs)"
  fi
  mark_phase 0
}

# ---------------------------------------------------------------- phase 1
phase1_toolchain() {
  should_run 1 || { log "phase 1 already done"; return 0; }
  log "phase 1: toolchain (apt, go, protoc plugins, node, sops, age)"

  run "sudo apt-get update -qq"
  run "sudo apt-get install -y docker.io docker-compose-v2 git jq curl protobuf-compiler \
       build-essential python3-venv python3-dev libxml2-dev libxslt1-dev openssl"

  # docker group (effective after re-login; phase 5 falls back to `sg docker`)
  if ! id -nG "$DEV_USER" | grep -qw docker; then
    run "sudo usermod -aG docker $DEV_USER"
    log "added $DEV_USER to the docker group (takes effect on re-login)"
  fi

  # Go (pinned) — host Go is for protoc plugins + host-side `go test`
  if ! command -v go >/dev/null 2>&1 && [ ! -x /usr/local/go/bin/go ]; then
    run "curl -sfL -o /tmp/go.tgz https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    run "sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz"
  fi
  ensure_line 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin"' "$HOME/.profile"
  export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin"

  # protoc plugins — PINNED; drift regenerates different codegen (see
  # IG repo docs: build.sh is only idempotent with exactly these)
  run "go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.28.1"
  run "go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.3.0"
  run "go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway@v2.11.3 2>/dev/null || \
       go install github.com/grpc-ecosystem/grpc-gateway/v2/cmd/protoc-gen-grpc-gateway@v2.11.3"
  run "go install github.com/grpc-ecosystem/grpc-gateway/v2/cmd/protoc-gen-openapiv2@v2.11.3"

  # Node (NodeSource LTS) + node protoc plugin
  if ! command -v node >/dev/null 2>&1; then
    run "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -"
    run "sudo apt-get install -y nodejs"
  fi
  command -v grpc_tools_node_protoc >/dev/null 2>&1 || run "sudo npm install -g grpc-tools"

  # sops + age (static binaries; no sudo needed)
  mkdir -p "$HOME/.local/bin"
  if ! command -v sops >/dev/null 2>&1; then
    run "curl -sfL -o $HOME/.local/bin/sops https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64 && chmod 755 $HOME/.local/bin/sops"
  fi
  if ! command -v age-keygen >/dev/null 2>&1; then
    run "curl -sfL -o /tmp/age.tgz https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz \
         && tar -C /tmp -xzf /tmp/age.tgz && install -m755 /tmp/age/age /tmp/age/age-keygen $HOME/.local/bin/ && rm -rf /tmp/age /tmp/age.tgz"
  fi

  if [ "$DRY_RUN" != 1 ]; then
    for t in docker jq protoc node go sops; do need "$t"; done
  fi
  mark_phase 1
}

# ---------------------------------------------------------------- phase 2
phase2_repos() {
  should_run 2 || { log "phase 2 already done"; return 0; }
  log "phase 2: repos + submodule + python venv"
  run "mkdir -p $IDEA"
  if [ ! -d "$IG_REPO/.git" ]; then
    run "git clone -b $IG_BRANCH $IG_URL $IG_REPO"
  else
    log "IG-Trading-Microservices already cloned"
  fi
  run "cd $IG_REPO && git submodule update --init robin_stocks"
  # repo venv for build.sh's python codegen (PEP-668-safe; dockerup-dev auto-uses it)
  if [ ! -x "$IG_REPO/.venv/bin/python3" ]; then
    run "python3 -m venv $IG_REPO/.venv && $IG_REPO/.venv/bin/pip install -q grpcio-tools==1.81.1"
  fi
  mark_phase 2
}

# ---------------------------------------------------------------- phase 3
phase3_env() {
  should_run 3 || { log "phase 3 already done"; return 0; }
  log "phase 3: env materialisation (SOPS manifests -> local env files)"
  local key="$HOME/.config/sops/age/keys.txt"
  if [ ! -s "$key" ]; then
    if [ -s "$IG_REPO/Vault-Secrets-NO-GIT-COMMIT/dev-age.key" ]; then
      run "mkdir -p $(dirname "$key") && install -m600 $IG_REPO/Vault-Secrets-NO-GIT-COMMIT/dev-age.key $key"
      log "installed dev age key from Vault-Secrets-NO-GIT-COMMIT/dev-age.key"
    else
      log "WARN: no dev age key at $key (break-glass item #2) — env files will fall"
      log "      back to *.example placeholders; drop the key and re-run --from-phase 3"
    fi
  fi
  run "cd $IG_REPO && ./scripts/dev-env-sync.sh --materialize" || log "WARN: dev-env-sync failed (continuing; dockerup-dev falls back to examples)"
  mark_phase 3
}

# ---------------------------------------------------------------- phase 4
phase4_docker_prep() {
  should_run 4 || { log "phase 4 already done"; return 0; }
  log "phase 4: docker prep"
  local D="docker"
  docker info >/dev/null 2>&1 || D="sg docker -c docker"
  if ! docker info >/dev/null 2>&1 && ! sg docker -c "docker info" >/dev/null 2>&1; then
    die "docker daemon unreachable even via sg — re-login (docker group) and re-run --from-phase 4"
  fi
  run "$D network inspect 5million >/dev/null 2>&1 || $D network create 5million"
  mark_phase 4
}

# ---------------------------------------------------------------- phase 5
phase5_stack() {
  should_run 5 || { log "phase 5 already done"; return 0; }
  log "phase 5: build + bring up the dev stack (dockerup-dev.sh: codegen, builds, seed, verify)"
  if docker info >/dev/null 2>&1; then
    run "cd $IG_REPO && ./dockerup-dev.sh"
  else
    run "cd $IG_REPO && sg docker -c ./dockerup-dev.sh"
  fi || die "dockerup-dev.sh failed — see its output; re-run with --from-phase 5"
  mark_phase 5
}

# ---------------------------------------------------------------- phase 6
phase6_prod_links() {
  should_run 6 || { log "phase 6 already done"; return 0; }
  log "phase 6: optional prod links (best-effort, never fatal)"
  run "mkdir -p $HOME/bin"
  if [ -f "$STEP0_REPO/devbox-jenkins-deploy.sh" ]; then
    run "install -m755 $STEP0_REPO/devbox-jenkins-deploy.sh $HOME/bin/jenkins-deploy"
    log "installed ~/bin/jenkins-deploy (needs ~/.jenkins-deploy-urls.env — break-glass item #3)"
  else
    log "WARN: step0 repo not at $STEP0_REPO — skipped jenkins-deploy install"
  fi
  [ -s "$HOME/.jenkins-deploy-urls.env" ] || log "NOTE: ~/.jenkins-deploy-urls.env missing — seed it from prod (STEP0/.env) to enable deploys"
  log "NOTE: prod kube access needs devbox-connect-prod.sh + a kubeconfig emitted on prod"
  log "      (sudo ./enable-devbox-kube-access.sh --emit-kubeconfig, then ./devbox-connect-prod.sh all <file>)"
  mark_phase 6
}

# ---------------------------------------------------------------- phase 7
phase7_verify_handoff() {
  should_run 7 || { log "phase 7 already done"; return 0; }
  log "phase 7: final verify + handoff"
  if [ "$DRY_RUN" != 1 ] && [ -x "$IG_REPO/scripts/verify-dev.sh" ]; then
    (cd "$IG_REPO" && ./scripts/verify-dev.sh) || log "WARN: verify-dev reported failures (see above)"
  fi
  cat <<'EOF'

================= restore-scratch-dev: DONE =================
Residual operator checklist (cannot be scripted):
  [ ] dev age key BACKED UP offline (losing it = re-capture secrets on an old box,
      or re-encrypt from the prod master key backup)
  [ ] re-login once so the docker group applies to interactive shells
  [ ] ~/.jenkins-deploy-urls.env seeded from prod (deploys from dev box)
  [ ] prod kubeconfig imported if kubectl access wanted (devbox-connect-prod.sh)
  [ ] Gmail OAuth token.json files (only if exercising real Gmail ingestion locally)
UI:      http://localhost:3000   (demo logins: scripts/seed/seed.py)
Gateway: http://localhost:9090/healthz
=============================================================
EOF
  mark_phase 7
}

phase0_preflight
phase1_toolchain
phase2_repos
phase3_env
phase4_docker_prep
phase5_stack
phase6_prod_links
phase7_verify_handoff
log "all phases complete"
