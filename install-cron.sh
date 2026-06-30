#!/bin/bash
# install-cron.sh — install the canonical cloud crontab (cron/cloud-crontab) for the cloud user.
# SINGLE SOURCE OF TRUTH for the cloud user's crontab: STEP0 automation (vault-auto-unseal,
# cluster-autostart, reduce-node-docker-cache) + the per-project autonomous agents
# (predictonomy, yolo, dyingpaleblue). Edit cron/cloud-crontab (committed) and run this — do NOT
# `crontab -e` directly — so start-scratch.sh and restore-scratch.sh reproduce the exact schedule
# on a fresh setup (no drift). Agents stay DISARMED until AGENT_PERMISSION_MODE is set in their .env.
set -eu
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON="$SELFDIR/cron/cloud-crontab"
[ -f "$CANON" ] || { echo "install-cron: $CANON missing" >&2; exit 1; }
# Ensure the log dirs the cron redirects write to exist (best-effort; some may be absent on a box
# where a given app repo isn't cloned yet — cron just logs an error for those lines).
mkdir -p "$SELFDIR/logs" \
  /home/cloud/IdeaProjects/Predictonomy/ops/agent/logs \
  /home/cloud/IdeaProjects/IG-Trading-Microservices/ops/agent/logs \
  /home/cloud/IdeaProjects/dyingpaleblue/ops/agent/logs 2>/dev/null || true
crontab "$CANON"
echo "install-cron: cloud crontab installed from $CANON"
