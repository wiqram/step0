#!/bin/bash
# install-cron.sh — install the canonical crontabs (cron/cloud-crontab + cron/root-crontab).
#
# SINGLE SOURCE OF TRUTH FOR BOTH HOST CRONTABS:
#   cron/cloud-crontab  -> the cloud user. STEP0 automation (vault-auto-unseal,
#                          cluster-autostart, reduce-node-docker-cache, alerting-pipeline-watch,
#                          prune-registry) + the per-project autonomous agents
#                          (predictonomy, yolo, dyingpaleblue).
#   cron/root-crontab   -> root. The weekly DR backup ONLY (backup-minikube-mnt.sh needs to
#                          read 0700 per-container datastore dirs and 0600 SMB creds, and tar
#                          only records true numeric owners when it runs as root).
#
# Edit the committed file and run this — do NOT `crontab -e` / `sudo crontab -e` directly —
# so the schedule never drifts from what a bare-metal restore will reproduce.
# restore-scratch.sh runs this during a rebuild (host-level setup); on the existing host, run
# it by hand after editing. (start-scratch.sh is platform bring-up only and does NOT touch the
# host crontabs.) Agents stay DISARMED until AGENT_PERMISSION_MODE is set in their .env.
#
# 2026-08-08: root's crontab was brought under the same treatment. It had lived only in the
# live crontab and as a duplicated string literal in restore-scratch.sh phase 8 — nothing to
# diff against, two copies to drift. The job it schedules is the platform's only off-disk
# insurance (the nightly DB snapshots sit on the same partition as the live stores), so it is
# the last line that should be reproduced from memory. See cron/root-crontab's header.
#
# USAGE:
#   ./install-cron.sh              # install both (prompts for sudo if a terminal is available)
#   ./install-cron.sh --cloud      # cloud crontab only (no sudo needed)
#   ./install-cron.sh --root       # root crontab only
#   ./install-cron.sh --status     # print both live crontabs vs the canonical files; installs nothing
set -eu
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANON_CLOUD="$SELFDIR/cron/cloud-crontab"
CANON_ROOT="$SELFDIR/cron/root-crontab"

# Read the CLOUD user's crontab explicitly. Under sudo a bare `crontab -l` reads ROOT's —
# the same trap verify-recovery.sh documents at length. Never reintroduce a bare `crontab -l`.
cloud_crontab_l() {
  if [ "$(id -u)" -eq 0 ]; then crontab -u "${SUDO_USER:-cloud}" -l 2>/dev/null
  else crontab -l 2>/dev/null; fi
}
sched_lines() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$@" 2>/dev/null || true; }

install_cloud() {
  [ -f "$CANON_CLOUD" ] || { echo "install-cron: $CANON_CLOUD missing" >&2; exit 1; }
  # Ensure the log dirs the cron redirects write to exist (best-effort; some may be absent on a
  # box where a given app repo isn't cloned yet — cron just logs an error for those lines).
  mkdir -p "$SELFDIR/logs" \
    /home/cloud/IdeaProjects/Predictonomy/ops/agent/logs \
    /home/cloud/IdeaProjects/IG-Trading-Microservices/ops/agent/logs \
    /home/cloud/IdeaProjects/dyingpaleblue/ops/agent/logs 2>/dev/null || true
  if [ "$(id -u)" -eq 0 ]; then crontab -u "${SUDO_USER:-cloud}" "$CANON_CLOUD"
  else crontab "$CANON_CLOUD"; fi
  echo "install-cron: cloud crontab installed from $CANON_CLOUD"
}

install_root() {
  [ -f "$CANON_ROOT" ] || { echo "install-cron: $CANON_ROOT missing" >&2; exit 1; }
  # /var/log/minikube-backup.log is the redirect target of the one line in there. cron does
  # not create it, and a root job that cannot open its log still runs — it just loses every
  # word of its output, which is exactly the job whose output you want after a bad week.
  if [ "$(id -u)" -eq 0 ]; then
    touch /var/log/minikube-backup.log 2>/dev/null || true
    crontab -u root "$CANON_ROOT"
  else
    sudo touch /var/log/minikube-backup.log 2>/dev/null || true
    sudo crontab -u root "$CANON_ROOT"
  fi
  echo "install-cron: ROOT crontab installed from $CANON_ROOT (weekly DR backup)"
}

status() {
  echo "== cloud crontab vs $CANON_CLOUD =="
  if diff -u <(sched_lines <(cloud_crontab_l)) <(sched_lines "$CANON_CLOUD"); then
    echo "  IN SYNC"
  else
    echo "  DRIFTED — reconcile (see verify-recovery.sh) or re-run: $0 --cloud"
  fi
  echo
  echo "== root crontab vs $CANON_ROOT =="
  # Only root can read root's crontab. Don't prompt for a password from a status command.
  if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    if diff -u <(sched_lines <(sudo crontab -u root -l 2>/dev/null)) <(sched_lines "$CANON_ROOT"); then
      echo "  IN SYNC"
    else
      echo "  DRIFTED — reconcile or re-run: sudo $0 --root"
    fi
  else
    echo "  (skipped — needs root; re-run as: sudo $0 --status)"
  fi
}

case "${1:-}" in
  --cloud)  install_cloud ;;
  --root)   install_root ;;
  --status) status ;;
  "")       install_cloud; install_root ;;
  *) echo "usage: $0 [--cloud|--root|--status]" >&2; exit 1 ;;
esac
