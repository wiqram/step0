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

# Trigger one app's Jenkins job using the assembled URL (handles build vs
# buildWithParameters per jenkins-jobs.manifest). Best-effort.
trigger() {
  echo "building $1"
  curl -X POST "$("$SELFDIR/jenkins-deploy-url.sh" "$1")"
}

trigger qcguy
trigger predictonomy
trigger bestrentaladmin
trigger dyingpaleblue
trigger ollama

echo "building yolo pipeline but before that sleeping for 1 min"
sleep 1m
trigger yolo

echo "trigger-app-builds: all app build jobs triggered."
