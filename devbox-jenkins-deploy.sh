#!/bin/bash
# devbox-jenkins-deploy.sh — fire an app's Jenkins deploy job on prod FROM THE DEV BOX.
#
# RUN THIS ON THE DEV BOX (vik@10.10.10.2); installed there as ~/bin/jenkins-deploy.
# Master copy lives in the STEP0 repo (same pattern as devbox-connect-prod.sh). To
# (re)install after a change:  scp devbox-jenkins-deploy.sh vik@10.10.10.2:bin/jenkins-deploy
#
# Goes to https://jenkins.traderyolo.com through NPM like any public client (prod runs
# no sshd; the 10GbE link is kube-API-only). Credential comes from the seeded
# ~/.jenkins-deploy-urls.env (JENKINS_CRED=user:api-token, chmod 600) — see
# docs/architecture.md §3 "Triggering Jenkins deploys from the dev box" for the re-seed line.
#
# App → job/endpoint/build-token mapping mirrors STEP0/jenkins-jobs.manifest; keep the
# two in sync when adding an app.
#
# USAGE:
#   jenkins-deploy <app>            # trigger the deploy (expects HTTP 201 = queued)
#   jenkins-deploy <app> --dry-run  # print the job path only (never prints the credential)
set -eu

APPS="qcguy predictonomy bestrentaladmin dyingpaleblue ollama yolo"
usage() { echo "usage: jenkins-deploy <app> [--dry-run]   (apps: $APPS)" >&2; exit 2; }

app="${1:-}"; [ -n "$app" ] || usage
case "$app" in
  qcguy)            job=qcguy;                 endpoint=build;                token=qcguy ;;
  predictonomy)     job=predictonomy;          endpoint=build;                token=predict ;;
  bestrentaladmin)  job=bestrentaladmin;       endpoint=build;                token=best ;;
  dyingpaleblue)    job=dyingpaleblue;         endpoint=build;                token=dying ;;
  ollama)           job=ollama;                endpoint=build;                token=ollama ;;
  yolo)             job=trading-microservices; endpoint=buildWithParameters;  token=yolo ;;  # parameterised; no params = job defaults
  *) echo "jenkins-deploy: unknown app '$app'" >&2; usage ;;
esac

path="job/$job/$endpoint?token=$token"
if [ "${2:-}" = "--dry-run" ]; then echo "would POST https://jenkins.traderyolo.com/$path"; exit 0; fi

ENV_FILE="${JENKINS_DEPLOY_ENV:-$HOME/.jenkins-deploy-urls.env}"
# shellcheck disable=SC1090
. "$ENV_FILE"
[ -n "${JENKINS_CRED:-}" ] || { echo "jenkins-deploy: JENKINS_CRED not set (source $ENV_FILE — re-seed from prod STEP0/.env)" >&2; exit 1; }

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://$JENKINS_CRED@jenkins.traderyolo.com/$path")"
if [ "$code" = "201" ]; then
  echo "jenkins-deploy: $app queued (HTTP 201) — watch https://jenkins.traderyolo.com/job/$job/"
else
  echo "jenkins-deploy: $app FAILED (HTTP $code)" >&2; exit 1
fi
