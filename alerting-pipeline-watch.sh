#!/bin/bash
# alerting-pipeline-watch.sh — assert that the ALERTING PIPELINE ITSELF is alive.
# Channel: `yolo-private-cloud-resource-crunch` (ntfy-lib.sh registry).
#
# WHY THIS EXISTS (and why it is not the resource watcher it used to be)
# ---------------------------------------------------------------------
# Until 2026-08-04 this file was resource-crunch-watch.sh: a */5 cron that read node
# CPU/memory, GPU, temperatures and disks itself and pushed when they breached.
# All of that moved into Alertmanager, which now carries 138 kube-prometheus rules plus
# manifests/platform-hardware-prometheusRule.yaml for this box's sensors, and notifies
# ntfy directly. Keeping both would have meant two notifications for every condition.
#
# But moving alerting INTO the cluster creates a hole that cannot be closed from inside
# it: if Prometheus stops evaluating, or Alertmanager stops delivering, the symptom is
# SILENCE — which is indistinguishable from a healthy machine. Alertmanager cannot page
# you about being down; that is the one alert it structurally cannot send.
#
# So this script keeps its cron slot and its independence, and changes what it watches.
# It is the only alerting on this box that runs OUTSIDE the cluster, which is exactly
# what makes it able to speak when the cluster is the thing that broke.
#
# WHAT IT WATCHES
#   prometheus-down     Prometheus /-/healthy over the NodePort. No Prometheus = no rule
#                       evaluation = every one of those 138 rules is silently inert.
#   alertmanager-down   Alertmanager /-/healthy. Rules can fire perfectly and still reach
#                       nobody if the router is gone.
#   watchdog-missing    the `Watchdog` alert present AND firing. This is the strong check:
#                       a process can answer /-/healthy while its rule evaluation is
#                       wedged. Watchdog is kube-prometheus's always-firing rule, so its
#                       ABSENCE proves the pipeline stopped evaluating. (It is deliberately
#                       routed to a no-op receiver in alertmanager-secret.yaml — forwarding
#                       an always-firing alert to ntfy would just train you to mute it.)
#   notify-failures     alertmanager_notifications_failed_total rising over 15m. Catches
#                       the case where everything is up and the ntfy webhook itself is
#                       failing — DNS, egress, a typo'd topic.
#
# WHAT IT DELIBERATELY DOES NOT WATCH
#   Resource pressure of any kind. CPU/GPU temperature, node CPU/memory, disk, kubelet
#   conditions and unschedulable pods are ALL Alertmanager's job now. Re-adding any of
#   them here re-creates the duplicate-notification problem this split exists to avoid.
#   The cluster being down is likewise not this channel — that is cluster-autostart.sh's.
#
# NOISE CONTROL — unchanged, and the reason this is not a set of `if` statements.
#   A 5-minute cron that pushes on every breach trains you to mute the channel, and a
#   muted channel is worse than none. Three rules prevent that:
#     1. SUSTAINED: a probe must fail AP_NEED_CONSEC runs in a row (default 3 =
#        15 minutes) before it says anything. A rollout restart is not an outage.
#     2. COOLDOWN: while a probe stays failed it repeats at most every AP_COOLDOWN
#        seconds (default 1h), not every 5 minutes.
#     3. RECOVERY: when a failed probe clears you get one "cleared" note, so an alert
#        never leaves you wondering whether it is still happening.
#   State lives in AP_STATE; deleting that file just re-arms everything.
#
# A PROBE THAT CANNOT RUN SAYS NOTHING. If Prometheus is unreachable, watchdog-missing
# and notify-failures are SKIPPED rather than reported as failures — prometheus-down
# already covers it, and stacking three alerts on one cause is noise.
#
# Usage:
#   ./alerting-pipeline-watch.sh            # one sampling pass (this is what cron runs)
#   ./alerting-pipeline-watch.sh --status   # print every probe now; no state, no push
#   ./alerting-pipeline-watch.sh --dry-run  # sample + decide, print pushes instead of sending
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -r "$SELFDIR/ntfy-lib.sh" ]; then source "$SELFDIR/ntfy-lib.sh"; else
  echo "WARN: ntfy-lib.sh not found — nothing can be sent." >&2
  ntfy_push() { :; }; NTFY_TOPIC_RESOURCE_CRUNCH=""
fi

# ---- endpoints + knobs: breach is value >= threshold. All env-overridable ---------
# Reached over the NODE PORT on the fixed cluster IP (CLAUDE.md: minikube node
# 172.16.238.2), not the ClusterIP: this runs on the host, outside the cluster network,
# which is the entire point of the script.
AP_PROM_URL="${AP_PROM_URL:-http://172.16.238.2:30339}"
AP_ALERTMANAGER_URL="${AP_ALERTMANAGER_URL:-http://172.16.238.2:30333}"
AP_HTTP_TIMEOUT="${AP_HTTP_TIMEOUT:-10}"
AP_NOTIFY_FAIL_WINDOW="${AP_NOTIFY_FAIL_WINDOW:-15m}"
AP_NEED_CONSEC="${AP_NEED_CONSEC:-3}"   # x 5-minute cron = 15 minutes sustained
AP_COOLDOWN="${AP_COOLDOWN:-3600}"      # re-notify at most hourly while still breached
AP_PERIOD_MIN="${AP_PERIOD_MIN:-5}"     # the cron period, for "sustained Nm" in messages
AP_STATE="${AP_STATE:-$SELFDIR/logs/.alerting-pipeline-state}"
AP_LOG="${AP_LOG:-$SELFDIR/logs/alerting-pipeline-watch.log}"

# ============================ pure decision logic =================================
# Kept free of I/O so tests/test-alerting-pipeline-watch.sh can drive every transition
# without a cluster or a clock. This is the part that must not be wrong: a bug here
# either floods the channel or silences it, and both look like "working".

# ap_state_get <file> <key> -> "<consec> <alerting> <last_alert_epoch>"
# Unknown key (first ever run, or state file deleted) reads as "0 0 0" = calm.
ap_state_get() {
  local f="$1" k="$2" line
  line="$(grep -F "$(printf '%s\t' "$k")" "$f" 2>/dev/null | head -1)"
  if [ -z "$line" ]; then echo "0 0 0"; return 0; fi
  echo "$line" | awk -F'\t' '{printf "%s %s %s\n", ($2==""?0:$2), ($3==""?0:$3), ($4==""?0:$4)}'
}

# ap_state_put <file> <key> <consec> <alerting> <last_alert_epoch>
# Rewrite via a temp file + mv: the cron can be killed mid-write, and a half-written
# state file would silently reset every probe's history.
ap_state_put() {
  local f="$1" k="$2" c="$3" a="$4" l="$5" tmp
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  grep -Fv "$(printf '%s\t' "$k")" "$f" 2>/dev/null >> "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$k" "$c" "$a" "$l" >> "$tmp"
  mv -f "$tmp" "$f"
}

# ap_decide <breached> <prev_consec> <prev_alerting> <prev_last> <now> <need> <cooldown>
#   -> "<verdict> <consec> <alerting> <last>"   verdict = alert | remind | recovered | silent
# The full state machine in one place:
#   breached, not yet sustained            -> silent, count up
#   breached, just reached `need`          -> alert   (the first notification)
#   breached, still alerting, past cooldown-> remind  (hourly repeat)
#   breached, still alerting, within it    -> silent
#   clear, was alerting                    -> recovered (one note, then calm)
#   clear, was calm                        -> silent
ap_decide() {
  local breached="$1" consec="$2" alerting="$3" last="$4" now="$5" need="$6" cooldown="$7"
  if [ "$breached" = "1" ]; then
    consec=$((consec + 1))
    if [ "$consec" -ge "$need" ]; then
      if [ "$alerting" != "1" ]; then
        echo "alert $consec 1 $now"
      elif [ $((now - last)) -ge "$cooldown" ]; then
        echo "remind $consec 1 $now"
      else
        echo "silent $consec 1 $last"
      fi
    else
      echo "silent $consec $alerting $last"
    fi
  else
    if [ "$alerting" = "1" ]; then
      echo "recovered 0 0 $last"
    else
      echo "silent 0 0 $last"
    fi
  fi
}

# ap_breached <value> <threshold> — 1 if value is a number at or above threshold.
# A non-numeric value means the probe could not produce a reading; that is NOT a breach.
# An unreadable probe must never page — the probes that CAN read cover the same outage.
ap_breached() {
  case "${1:-}" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$1" -ge "$2" ] && echo 1 || echo 0
}

# Sourced by the tests: stop here, before anything touches the network.
[ "${AP_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

# ============================ collection ==========================================
mkdir -p "$(dirname "$AP_STATE")" 2>/dev/null
# CREATE if absent — never truncate. The file IS the sustained-failure history; wiping
# it each run would reset every counter to zero and guarantee nothing ever alerts.
[ -f "$AP_STATE" ] || : > "$AP_STATE" 2>/dev/null || true

MODE="watch"
case "${1:-}" in
  --status)  MODE="status" ;;
  --dry-run) export NTFY_DRY_RUN=1 ;;
  "") : ;;
  *) echo "unknown arg: $1 (use --status or --dry-run)" >&2; exit 2 ;;
esac

ap_log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$AP_LOG"; }

# Each probe appends "key|value|threshold|unit|human label".
# A probe that cannot read its metric appends nothing — silence beats a fake zero.
METRICS=""
add_metric() { METRICS="${METRICS}${1}|${2}|${3}|${4}|${5}
"; }

# ap_http_ok <url> — 1 if the endpoint answered 2xx, 0 otherwise. Never fails the script.
ap_http_ok() {
  local code
  code="$(curl -s -o /dev/null -m "$AP_HTTP_TIMEOUT" -w '%{http_code}' "$1" 2>/dev/null)" || code="000"
  case "$code" in 2*) echo 1 ;; *) echo 0 ;; esac
}

# ap_promq <query> — scalar result of an instant query, or "" when unavailable.
# "" propagates to ap_breached as "not a breach", which is the intended behaviour for a
# probe that could not run.
ap_promq() {
  curl -s -m "$AP_HTTP_TIMEOUT" --get "$AP_PROM_URL/api/v1/query" \
       --data-urlencode "query=$1" 2>/dev/null \
    | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    r=d.get("data",{}).get("result",[])
    print(r[0]["value"][1] if r and d.get("status")=="success" else "")
except Exception:
    print("")' 2>/dev/null
}

# ---- 1. Prometheus reachable ------------------------------------------------------
PROM_UP="$(ap_http_ok "$AP_PROM_URL/-/healthy")"
add_metric "prometheus-down" "$([ "$PROM_UP" = "1" ] && echo 0 || echo 1)" 1 "" \
  "Prometheus unreachable ($AP_PROM_URL)"

# ---- 2. Alertmanager reachable ----------------------------------------------------
AM_UP="$(ap_http_ok "$AP_ALERTMANAGER_URL/-/healthy")"
add_metric "alertmanager-down" "$([ "$AM_UP" = "1" ] && echo 0 || echo 1)" 1 "" \
  "Alertmanager unreachable ($AP_ALERTMANAGER_URL)"

# ---- 3 + 4. Prometheus-derived probes ---------------------------------------------
# Skipped entirely when Prometheus is down: prometheus-down already says so, and three
# alerts describing one outage is exactly the noise this script is built to avoid.
if [ "$PROM_UP" = "1" ]; then
  # Watchdog: kube-prometheus's always-firing rule. Present => rules are evaluating.
  WD="$(ap_promq 'count(ALERTS{alertname="Watchdog",alertstate="firing"})')"
  case "$WD" in
    ''|*[!0-9.]*) : ;;                      # query failed — say nothing
    *) add_metric "watchdog-missing" "$(awk -v v="$WD" 'BEGIN{print (v+0>=1)?0:1}')" 1 "" \
         "Watchdog alert not firing (rule evaluation has stopped)" ;;
  esac

  # Delivery failures: everything up, but the ntfy webhook itself erroring.
  NF="$(ap_promq "sum(increase(alertmanager_notifications_failed_total[$AP_NOTIFY_FAIL_WINDOW]))")"
  case "$NF" in
    ''|*[!0-9.eE+-]*) : ;;                  # query failed — say nothing
    *) add_metric "notify-failures" "$(awk -v v="$NF" 'BEGIN{printf "%d", (v+0<0?0:v+0)}')" 1 "" \
         "Alertmanager notification failures in ${AP_NOTIFY_FAIL_WINDOW}" ;;
  esac
fi

# ---- --status: print everything and stop -----------------------------------------
# Mutates nothing and sends nothing, so it is safe to run at any time during triage.
if [ "$MODE" = "status" ]; then
  printf '%-20s %-8s %-8s %s\n' "PROBE" "VALUE" "LIMIT" "MEANING"
  while IFS='|' read -r key val thr unit label; do
    [ -n "$key" ] || continue
    printf '%-20s %-8s %-8s %s\n' "$key" "${val}${unit}" "${thr}${unit}" "$label"
  done <<<"$METRICS"
  exit 0
fi

# ============================ decide + notify =====================================
NOW="$(date +%s)"
ALERTS=""; RECOVERED=""; ALERT_KEYS=""
while IFS='|' read -r key val thr unit label; do
  [ -n "$key" ] || continue
  breached="$(ap_breached "$val" "$thr")"
  read -r consec alerting last <<<"$(ap_state_get "$AP_STATE" "$key")"
  read -r verdict n_consec n_alerting n_last <<<"$(ap_decide "$breached" "$consec" "$alerting" "$last" "$NOW" "$AP_NEED_CONSEC" "$AP_COOLDOWN")"
  ap_state_put "$AP_STATE" "$key" "$n_consec" "$n_alerting" "$n_last"
  case "$verdict" in
    alert|remind)
      # Sustained minutes are derived from the consecutive count and the cron period,
      # so the message says "for 20m" rather than the meaningless "3 samples".
      ALERTS="${ALERTS}  ${label}  (sustained $(( n_consec * AP_PERIOD_MIN ))m)
"
      ALERT_KEYS="${ALERT_KEYS}${ALERT_KEYS:+, }${key}"
      ap_log "$verdict $key=$val (>= $thr) consec=$n_consec"
      ;;
    recovered)
      RECOVERED="${RECOVERED}  ${label}: recovered
"
      ap_log "recovered $key"
      ;;
  esac
done <<<"$METRICS"

# One push per run, not one per probe: when the cluster goes down several probes trip
# together and they are all the same event.
if [ -n "$ALERTS" ]; then
  ntfy_push "$NTFY_TOPIC_RESOURCE_CRUNCH" "Alerting pipeline broken: $ALERT_KEYS" \
"$(hostname -s): the alerting pipeline is not working, so OTHER alerts may be silently lost.

${ALERTS}
While this lasts, treat silence as unknown rather than healthy.
Look at:  kubectl -n monitoring get po   |   ./alerting-pipeline-watch.sh --status
Repeats at most hourly; you will get a 'cleared' note when it ends." \
    "high" "rotating_light,mute"
fi
if [ -n "$RECOVERED" ]; then
  ntfy_push "$NTFY_TOPIC_RESOURCE_CRUNCH" "Alerting pipeline restored" \
"$(hostname -s): the alerting pipeline is working again.

${RECOVERED}" \
    "low" "white_check_mark"
fi
exit 0
