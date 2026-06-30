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
# The Jenkins API credential (user:token) is read from the gitignored STEP0/.env
# (key JENKINS_CRED), NOT hardcoded here — same pattern cluster-autostart.sh uses for
# NTFY_URL. .env is captured by backup-minikube-mnt.sh (STEP0 is tarred whole) and
# restored by restore-scratch.sh, so a from-scratch restore has it ready. Rotating the
# token value itself is tracked in plan.md P0 #1.
#
# Requires: jenkins.traderyolo.com reachable (NPM + DNS up).
# NOTE: best-effort, NOT set -e — a single unreachable job must not abort the rest.

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Read JENKINS_CRED from env, else from the gitignored .env (strip surrounding quotes).
JENKINS_CRED="${JENKINS_CRED:-$(grep -E '^JENKINS_CRED=' "$SELFDIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )}"
if [ -z "${JENKINS_CRED:-}" ]; then
  echo "trigger-app-builds: JENKINS_CRED not set — add 'JENKINS_CRED=user:token' to $SELFDIR/.env" >&2
  exit 1
fi
JENKINS="https://${JENKINS_CRED}@jenkins.traderyolo.com"

echo "building qcguy"
curl -X POST "$JENKINS/job/qcguy/build?token=qcguy"

echo "building predictonomy"
curl -X POST "$JENKINS/job/predictonomy/build?token=predict"

echo "building bestrentaladmin"
curl -X POST "$JENKINS/job/bestrentaladmin/build?token=best"

echo "building dyingpaleblue"
curl -X POST "$JENKINS/job/dyingpaleblue/build?token=dying"

echo "building ollama"
curl -X POST "$JENKINS/job/ollama/build?token=ollama"

echo "building yolo pipeline but before that sleeping for 1 min"
sleep 1m
# trading-microservices is a PARAMETERISED job (RUN_SIGNAL_EVAL/DEPLOY_STAGING), so a plain
# /build returns HTTP 400 — it must be triggered via /buildWithParameters (uses defaults).
curl -X POST "$JENKINS/job/trading-microservices/buildWithParameters?token=yolo"

echo "trigger-app-builds: all app build jobs triggered."
