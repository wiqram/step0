#!/bin/bash
# Unit test for jenkins-deploy-url.sh (overridable env + manifest, no live Jenkins).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../jenkins-deploy-url.sh"
tmp="$(mktemp -d)"
printf 'JENKINS_CRED=user:tok123\n' > "$tmp/.env"
printf 'yolo trading-microservices buildWithParameters yolo\npredictonomy predictonomy build predict\n' > "$tmp/m"
run(){ JENKINS_DEPLOY_ENV="$tmp/.env" JENKINS_DEPLOY_MANIFEST="$tmp/m" bash "$SCRIPT" "$1" 2>/dev/null; }
fail=0
[ "$(run yolo)" = "https://user:tok123@jenkins.traderyolo.com/job/trading-microservices/buildWithParameters?token=yolo" ] && echo "ok: yolo" || { echo "FAIL yolo: [$(run yolo)]"; fail=1; }
[ "$(run predictonomy)" = "https://user:tok123@jenkins.traderyolo.com/job/predictonomy/build?token=predict" ] && echo "ok: predictonomy" || { echo "FAIL predictonomy"; fail=1; }
run nope >/dev/null 2>&1 && { echo "FAIL: unknown app should error"; fail=1; } || echo "ok: unknown app errors"
JENKINS_DEPLOY_ENV="$tmp/none" JENKINS_DEPLOY_MANIFEST="$tmp/m" bash "$SCRIPT" yolo >/dev/null 2>&1 && { echo "FAIL: missing cred should error"; fail=1; } || echo "ok: missing cred errors"
rm -rf "$tmp"; exit $fail
