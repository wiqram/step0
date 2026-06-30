#!/bin/bash
# seed-agent-deploy-urls.sh — write a SECRET-FREE pointer into each autonomous agent's
# sourced config so it assembles JENKINS_DEPLOY_URL fresh from the central credential:
#   JENKINS_DEPLOY_URL="$(STEP0/jenkins-deploy-url.sh <app>)"
# Replaces only the JENKINS_DEPLOY_URL line (preserves AGENT_PERMISSION_MODE/NTFY_URL/comments);
# creates the file if absent. Idempotent. Run it to (a) fix stale baked URLs now and (b) re-arm
# agents after a restore. Agents stay DISARMED until the operator sets AGENT_PERMISSION_MODE.
set -eu
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SELFDIR/jenkins-deploy-url.sh"
seed_one() {
  local app="$1" target="$2"
  local pointer="JENKINS_DEPLOY_URL=\"\$($HELPER $app)\""
  mkdir -p "$(dirname "$target")"
  local tmp; tmp="$(mktemp)"
  if [ -f "$target" ]; then grep -v '^JENKINS_DEPLOY_URL=' "$target" > "$tmp" || true; fi
  printf '%s\n' "$pointer" >> "$tmp"
  mv "$tmp" "$target"; chmod 600 "$target"
  echo "  seeded $app -> ${target/#$HOME/\~}"
}
seed_one yolo          "/home/cloud/IdeaProjects/IG-Trading-Microservices/Vault-Secrets-NO-GIT-COMMIT/jenkins-deploy-url.txt"
seed_one predictonomy  "/home/cloud/IdeaProjects/Predictonomy/.env"
seed_one dyingpaleblue "/home/cloud/IdeaProjects/dyingpaleblue/.env"
echo "seed-agent-deploy-urls: done (agents stay disarmed until AGENT_PERMISSION_MODE is set)."
