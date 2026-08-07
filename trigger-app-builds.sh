#!/bin/bash
####################################
#
# trigger-app-builds.sh — fire each app's Jenkins deploy job, ONE AT A TIME.
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
#
##### WHY THIS IS THROTTLED — original reason (2026-07-29), and what changed ########
# ORIGINALLY AN IO WALL. This script used to POST all five jobs back-to-back (then yolo
# after a flat 60s). On a ONE-NODE cluster that means ~6 concurrent Jenkins agents doing
# git clone + docker build + docker push, WHILE the resulting rollouts create ~15 pods
# that each need overlay2 layer setup — all funnelled into /var/lib/docker on sda7, an
# ageing Samsung 840 SATA SSD shared with /.
#
# Measured during exactly that stampede: sda pinned at 95-99% util, ~180ms write-await,
# ~150ms flush-await, /proc/pressure/io "full" ~48% — while the CPU was 88% IDLE and
# 53Gi of RAM sat free. Purely an IO wall. Container creation then outran cri-dockerd's
# 2m deadline and every pod fell into the timeout -> orphan -> "container name already
# in use" -> CreateContainerError retry loop (see tune-cri-dockerd-timeout.sh for the
# full mechanism). Nothing came up.
#
##### THAT DISK IS GONE (2026-08-07) ###############################################
# The box is now an i9-12900K / DDR5 / 4TB Predator GM9000 NVMe, and /var/lib/docker is
# its own NVMe partition (nvme0n1p5). Measured on THIS hardware during a live build:
#
#   /proc/pressure/io "full"   0.09%   (the wait_for_io_calm threshold is 20%)
#   nvme0n1 util               6.1%    (was 95-99%)
#   write-await                ~3ms    (was ~180ms)
#   4K synchronous write       0.96ms  (was 29.6ms on the WD10EZEX)
#
# Six of those concurrently would not come close to the wall, and the cri-dockerd timeout
# cascade above was IO-driven, so it is largely designed out. The ORIGINAL justification
# for this throttle no longer holds.
#
##### BUT THE BOTTLENECK MOVED, IT DID NOT VANISH ##################################
# The constraint is now MEMORY, and it is not visible in a freshly-restored cluster.
# The node has ~47Gi allocatable with kubelet eviction-hard memory.available<1Gi. Right
# after a platform bring-up that reads as 6% requested — because NO apps are deployed
# yet. THROTTLE=0 means ~6 Jenkins agents plus ~15 simultaneous pod rollouts against
# that ceiling. This host also runs 76GiB, not the 96GB design point (see start-scratch's
# own sizing warning), so the full app set is already tight at 51Gi.
#
# Trading an IO wall for an OOM-kill wall would be a bad deal: eviction is harder to
# diagnose than slow disk, and it takes down running apps rather than just delaying new
# ones. Before flipping this off, measure STEADY-STATE memory with every app deployed:
#
#   kubectl describe node minikube | sed -n '/Allocated resources/,/Events/p'
#   free -g ; cat /proc/pressure/memory
#
# If that leaves >20Gi headroom (near-certain once the third RAM stick is in), THROTTLE=0
# is justified. Cost of keeping it: builds run serially — ~40 min total at current
# durations (bestrentaladmin alone is ~19 min, the rest 2.4-7.8) against ~20 min
# unthrottled. That is a DR-day cost, not a daily one.
#
# So: deploy one app, wait for its Jenkins build to finish, wait for the disk to go
# quiet, then start the next.
#
# Escape hatch: THROTTLE=0 restores the old fire-everything-at-once behaviour verbatim.
####################################################################################

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${JENKINS_DEPLOY_MANIFEST:-$SELFDIR/jenkins-jobs.manifest}"
ENV_FILE="${JENKINS_DEPLOY_ENV:-$SELFDIR/.env}"

THROTTLE="${THROTTLE:-1}"                         # 0 = legacy, fire everything at once
JENKINS_HOST="${JENKINS_HOST:-jenkins.traderyolo.com}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"              # seconds between polls
BUILD_WAIT_TIMEOUT="${BUILD_WAIT_TIMEOUT:-2400}"  # 40m, then stop waiting and move on
QUEUE_WAIT="${QUEUE_WAIT:-180}"                   # 3m for the POST to produce a new build
IO_CALM_TIMEOUT="${IO_CALM_TIMEOUT:-900}"         # 15m max spent waiting for the disk
IO_PRESSURE_MAX="${IO_PRESSURE_MAX:-20}"          # /proc/pressure/io "full avg10" ceiling

# Read once for the API polling below. trigger() still goes through
# jenkins-deploy-url.sh (which embeds the cred in the URL); here we use curl -u so the
# credential never lands in a URL we might echo.
JENKINS_CRED_VALUE="$(grep -E '^JENKINS_CRED=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )"

# Jenkins job name for <app>, per the manifest (app name != job name for yolo).
job_for() { awk -v a="$1" '!/^#/ && $1==a {print $2; exit}' "$MANIFEST" 2>/dev/null; }

# japi <job> <tree> — lastBuild JSON, empty string on any failure (never fatal).
japi() {
  [ -n "$JENKINS_CRED_VALUE" ] || return 0
  curl -sf --max-time 15 -u "$JENKINS_CRED_VALUE" \
    "https://$JENKINS_HOST/job/$1/lastBuild/api/json?tree=$2" 2>/dev/null
}

# Build number currently reported as lastBuild, or 0 if the job has never run.
last_build_num() {
  local n
  n="$(japi "$1" number | grep -oE '"number":[0-9]+' | cut -d: -f2)"
  echo "${n:-0}"
}

# Share of the last 10s in which EVERY task was stalled on IO. The single best signal
# for "the disk is the bottleneck right now" — and the exact condition that makes
# docker's CreateContainer blow past cri-dockerd's deadline.
io_full_avg10() { awk -F'[= ]' '/^full/{print $3}' /proc/pressure/io 2>/dev/null; }

# Block until <job> has a build NEWER than <baseline> that has stopped building.
# Always returns 0 — a stuck job must not strand the apps queued behind it.
#
# Two separate deadlines on purpose. trigger() posts with a bare curl and cannot tell
# a queued build from a rejected one, so if the POST silently failed we must NOT sit
# here for the full build timeout: QUEUE_WAIT bounds "did a new build ever appear",
# BUILD_WAIT_TIMEOUT bounds "how long may that build run".
wait_for_build() {
  local job="$1" baseline="$2"
  local deadline=$(( $(date +%s) + BUILD_WAIT_TIMEOUT ))
  local queue_deadline=$(( $(date +%s) + QUEUE_WAIT ))
  local started=0 json num building result
  echo "  waiting for $job build to finish (baseline #$baseline)..."
  while [ "$(date +%s)" -lt "$deadline" ]; do
    json="$(japi "$job" 'number,building,result')"
    num="$(printf '%s' "$json"      | grep -oE '"number":[0-9]+'         | cut -d: -f2)"
    building="$(printf '%s' "$json" | grep -oE '"building":(true|false)' | cut -d: -f2)"

    # A build can start AND finish inside one poll interval, so latch "started" first
    # and test completion in the same pass.
    if [ -n "$num" ] && [ "$num" -gt "$baseline" ]; then started=1; fi
    if [ "$started" -eq 1 ] && [ "$building" = "false" ]; then
      result="$(printf '%s' "$json" | grep -oE '"result":"[A-Z]+"' | cut -d: -f2 | tr -d '"')"
      echo "  $job #$num finished: ${result:-UNKNOWN}"
      return 0
    fi
    if [ "$started" -eq 0 ] && [ "$(date +%s)" -ge "$queue_deadline" ]; then
      echo "  WARN: no new $job build within ${QUEUE_WAIT}s — trigger may have failed; moving on."
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  echo "  WARN: $job still not finished after ${BUILD_WAIT_TIMEOUT}s — moving on anyway."
  return 0
}

# Block until the disk stops being the bottleneck (two consecutive calm samples).
# Always returns 0.
wait_for_io_calm() {
  local deadline=$(( $(date +%s) + IO_CALM_TIMEOUT )) quiet=0 p
  [ -r /proc/pressure/io ] || return 0   # kernel without PSI — skip the gate entirely
  while [ "$(date +%s)" -lt "$deadline" ]; do
    p="$(io_full_avg10)"
    if [ -n "$p" ] && awk -v v="$p" -v m="$IO_PRESSURE_MAX" 'BEGIN{exit !(v<m)}'; then
      quiet=$(( quiet + 1 ))
      if [ "$quiet" -ge 2 ]; then
        echo "  disk calm (io pressure ${p}% < ${IO_PRESSURE_MAX}%)"
        return 0
      fi
    else
      quiet=0
    fi
    sleep "$POLL_INTERVAL"
  done
  echo "  WARN: disk still busy after ${IO_CALM_TIMEOUT}s — moving on anyway."
  return 0
}

# Trigger one app's Jenkins job using the assembled URL (handles build vs
# buildWithParameters per jenkins-jobs.manifest). Best-effort.
trigger() {
  echo "building $1"
  curl -X POST "$("$SELFDIR/jenkins-deploy-url.sh" "$1")"
}

# Trigger <app> and, when throttled, wait for it to land before returning.
deploy() {
  local app="$1" job baseline
  job="$(job_for "$app")"

  # No throttle, no manifest entry, or no credential to poll with -> legacy behaviour.
  if [ "$THROTTLE" = "0" ] || [ -z "$job" ] || [ -z "$JENKINS_CRED_VALUE" ]; then
    trigger "$app"
    return 0
  fi

  baseline="$(last_build_num "$job")"
  trigger "$app"
  wait_for_build "$job" "$baseline"
  wait_for_io_calm
}

if [ "$THROTTLE" = "0" ]; then
  echo "trigger-app-builds: THROTTLE=0 — firing all jobs at once (legacy behaviour)."
else
  echo "trigger-app-builds: throttled — one app at a time, waiting for build + disk."
fi

# The deploy list comes from the MANIFEST, in file order — not from a literal list here.
# Until 2026-08-07 this loop named the six apps directly while jenkins-jobs.manifest only
# supplied the app->job mapping, so adding a row to the manifest deployed NOTHING and the
# two could drift apart silently. That is how qcx and prop-investech ended up with working
# Jenkins jobs that no bootstrap or DR run ever triggered. One source of truth now.
APPS="$(awk '!/^#/ && NF>=4 {print $1}' "$MANIFEST" 2>/dev/null)"
[ -n "$APPS" ] || { echo "trigger-app-builds: no usable rows in $MANIFEST — nothing to deploy." >&2; exit 1; }
echo "trigger-app-builds: deploying in manifest order: $(echo "$APPS" | tr '\n' ' ')"

for app in $APPS; do
  # The legacy path kept its flat 60s pause before the parameterised yolo pipeline; the
  # throttled path already waits on the real signal, so it needs no fixed sleep.
  if [ "$THROTTLE" = "0" ] && [ "$app" = "yolo" ]; then
    echo "building yolo pipeline but before that sleeping for 1 min"
    sleep 1m
  fi
  deploy "$app"
done

echo "trigger-app-builds: all app build jobs triggered."
