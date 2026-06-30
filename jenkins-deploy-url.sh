#!/bin/bash
# jenkins-deploy-url.sh <app> — print the Jenkins remote-build-trigger URL for <app>,
# assembled from the central credential (STEP0/.env JENKINS_CRED) + jenkins-jobs.manifest.
# Prints ONLY the URL to stdout (for capture into $JENKINS_DEPLOY_URL); never logs it.
# Rotation-proof: the token lives once in .env, so a rotation needs no per-repo edits.
set -eu
app="${1:-}"
[ -n "$app" ] || { echo "usage: $0 <app>" >&2; exit 2; }
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${JENKINS_DEPLOY_ENV:-$SELFDIR/.env}"
MANIFEST="${JENKINS_DEPLOY_MANIFEST:-$SELFDIR/jenkins-jobs.manifest}"
cred="$(grep -E '^JENKINS_CRED=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )"
[ -n "$cred" ] || { echo "jenkins-deploy-url: JENKINS_CRED not found in $ENV_FILE" >&2; exit 1; }
read -r _ job endpoint token < <(awk -v a="$app" '!/^#/ && $1==a {print; exit}' "$MANIFEST" 2>/dev/null)
[ -n "${job:-}" ] && [ -n "${endpoint:-}" ] && [ -n "${token:-}" ] || { echo "jenkins-deploy-url: no manifest entry for '$app'" >&2; exit 1; }
printf 'https://%s@jenkins.traderyolo.com/job/%s/%s?token=%s\n' "$cred" "$job" "$endpoint" "$token"
