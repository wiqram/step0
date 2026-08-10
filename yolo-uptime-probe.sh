#!/bin/bash
# yolo-uptime-probe.sh — probe YOLO's PUBLIC serving path from OUTSIDE the cluster.
# Channel: `yolo-public-uptime` (ntfy-lib.sh registry).
#
# WHY THIS EXISTS (yolo post-mortem, 2026-08-03 → 08-07)
# ------------------------------------------------------
# The yolo app's alerting lives INSIDE the cluster: promtail → Loki → Grafana rules
# (the yolo repo's grafana-alerting-yolo ConfigMap) → ntfy. On 08-03 that pipeline
# died WITH the thing it was watching — Loki stopped ingesting (even its own logs),
# 21 of the 27 rules map NoData→OK, and Grafana was in the same blast radius — so a
# four-day outage that hid a real product failure (the AI expert publishing nothing)
# paged nobody. alerting-pipeline-watch.sh cannot see this either: it watches the
# kube-prometheus pipeline (Prometheus/Alertmanager), not yolo's separate Loki stack
# and not yolo's public serving path.
#
# This probe watches what a FOLLOWER experiences, from the host:
#   ui-down    https://www.traderyolo.com/ answers 2xx  (nginx-proxy-manager → UI)
#   api-down   https://swagger.traderyolo.com/v1/market/session?exchange=XNYS
#              answers 2xx AND carries `"state"` — one request that exercises the
#              full serving depth: NPM → NodePort → api-gateway → robinstocks →
#              quant-mongo. If that chain answers, the platform is serving; if it
#              does not for 15 sustained minutes, no in-cluster monitor can be
#              trusted to say so, and this script is what still speaks.
#
# VANTAGE, honestly stated: this runs on the prod HOST, outside the cluster but
# inside the box — it covers cluster/minikube death (the observed 08-03 mode) and
# NPM death, not the box itself dying. The same script installs unchanged on the
# dev box (vik@10.10.10.2) for box-death coverage; a hosted uptime service is the
# fully-external layer if that is ever wanted.
#
# REUSE, deliberately: the sustained/cooldown/recovery state machine is SOURCED from
# alerting-pipeline-watch.sh via its AP_LIB_ONLY seam (the same one its tests use).
# That machine is the part a notifier must not get wrong — wrong one way it floods
# the channel until muted, wrong the other it never speaks — and it is already
# tested; a second copy here would just be a second place for the same bug.
#   1. SUSTAINED: a probe must fail UP_NEED_CONSEC runs in a row (default 3 = 15
#      minutes at the */5 cron) before it says anything.
#   2. COOLDOWN: while it stays failed it repeats at most every UP_COOLDOWN s (1h).
#   3. RECOVERY: one "cleared" note when it comes back.
#   State lives in UP_STATE; deleting that file just re-arms everything.
#
# Usage:
#   ./yolo-uptime-probe.sh             # one sampling pass (this is what cron runs)
#   ./yolo-uptime-probe.sh --status    # print every probe now; no state, no push
#   ./yolo-uptime-probe.sh --dry-run   # sample + decide, print pushes instead of sending
#   ./yolo-uptime-probe.sh --selftest  # prove the gate CAN fail (weekly cron; pushes
#                                      # only when the selftest itself fails)
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -r "$SELFDIR/ntfy-lib.sh" ]; then source "$SELFDIR/ntfy-lib.sh"; else
  echo "WARN: ntfy-lib.sh not found — nothing can be sent." >&2
  ntfy_push() { :; }; NTFY_TOPIC_UPTIME=""
fi
# The tested state machine (ap_state_get / ap_state_put / ap_decide / ap_breached).
# shellcheck source=/dev/null
AP_LIB_ONLY=1 source "$SELFDIR/alerting-pipeline-watch.sh"

# ---- endpoints + knobs; all env-overridable --------------------------------------
UP_UI_URL="${UP_UI_URL:-https://www.traderyolo.com/}"
UP_API_URL="${UP_API_URL:-https://swagger.traderyolo.com/v1/market/session?exchange=XNYS}"
UP_API_MUST_CONTAIN="${UP_API_MUST_CONTAIN:-\"state\"}"
UP_HTTP_TIMEOUT="${UP_HTTP_TIMEOUT:-15}"
UP_NEED_CONSEC="${UP_NEED_CONSEC:-3}"   # x 5-minute cron = 15 minutes sustained
UP_COOLDOWN="${UP_COOLDOWN:-3600}"      # re-notify at most hourly while still down
UP_PERIOD_MIN="${UP_PERIOD_MIN:-5}"     # the cron period, for "sustained Nm" in messages
UP_STATE="${UP_STATE:-$SELFDIR/logs/.yolo-uptime-state}"
UP_LOG="${UP_LOG:-$SELFDIR/logs/yolo-uptime-probe.log}"

# up_http_probe <url> [must_contain] -> 1 if the endpoint answered 2xx (and, when
# given, the body contains must_contain), else 0. Never fails the script. The body
# check is what turns "nginx answered something" into "the serving chain answered":
# a 200 error shell from a dead backend does not carry the API's own field.
up_http_probe() {
  local url="$1" must="${2:-}" body code
  body="$(curl -sS -m "$UP_HTTP_TIMEOUT" -w '\n%{http_code}' "$url" 2>/dev/null)" || { echo 0; return 0; }
  code="${body##*$'\n'}"
  case "$code" in 2*) : ;; *) echo 0; return 0 ;; esac
  if [ -n "$must" ]; then
    case "$body" in *"$must"*) : ;; *) echo 0; return 0 ;; esac
  fi
  echo 1
}

# Sourced by the tests: stop here, before anything touches the network.
[ "${UP_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

mkdir -p "$(dirname "$UP_STATE")" 2>/dev/null
[ -f "$UP_STATE" ] || : > "$UP_STATE" 2>/dev/null || true

MODE="watch"
case "${1:-}" in
  --status)   MODE="status" ;;
  --dry-run)  export NTFY_DRY_RUN=1 ;;
  --selftest) MODE="selftest" ;;
  "") : ;;
  *) echo "unknown arg: $1 (use --status, --dry-run or --selftest)" >&2; exit 2 ;;
esac

up_log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$UP_LOG"; }

# ---- --selftest: prove the gate can fail (a gate nobody has proven can fail is
# not a gate). Network half: a guaranteed-missing path on the real host must read
# DOWN, and the real API must read UP. Machine half: drive a synthetic probe
# through fail->alert->cooldown->recover in a throwaway state file. Pushes to the
# channel ONLY when the selftest itself fails — a weekly "still fine" note would
# train the reader to skim past the one that matters.
if [ "$MODE" = "selftest" ]; then
  rc=0
  [ "$(up_http_probe "${UP_UI_URL%/}/definitely-not-here-uptime-selftest")" = "0" ] \
    || { echo "SELFTEST FAIL: missing path did not read DOWN"; rc=1; }
  [ "$(up_http_probe "$UP_API_URL" "$UP_API_MUST_CONTAIN")" = "1" ] \
    || { echo "SELFTEST FAIL: real API did not read UP (is this an outage instead?)"; rc=1; }
  [ "$(up_http_probe "$UP_API_URL" '"field-that-never-appears"')" = "0" ] \
    || { echo "SELFTEST FAIL: body check did not reject a wrong body"; rc=1; }
  NOW_T=1000000
  read -r v _ _ _ <<<"$(ap_decide 1 0 0 0 "$NOW_T" 3 3600)";                    [ "$v" = "silent" ] || { echo "SELFTEST FAIL: first failure alerted early"; rc=1; }
  read -r v _ _ _ <<<"$(ap_decide 1 2 0 0 "$NOW_T" 3 3600)";                    [ "$v" = "alert" ]  || { echo "SELFTEST FAIL: sustained failure did not alert"; rc=1; }
  read -r v _ _ _ <<<"$(ap_decide 1 3 1 "$NOW_T" $((NOW_T+60)) 3 3600)";        [ "$v" = "silent" ] || { echo "SELFTEST FAIL: cooldown did not hold"; rc=1; }
  read -r v _ _ _ <<<"$(ap_decide 0 3 1 "$NOW_T" $((NOW_T+120)) 3 3600)";       [ "$v" = "recovered" ] || { echo "SELFTEST FAIL: recovery note missing"; rc=1; }
  if [ "$rc" != "0" ]; then
    ntfy_push "$NTFY_TOPIC_UPTIME" "yolo uptime probe SELFTEST FAILED" \
      "The probe on $(hostname) can no longer prove it detects an outage. Run ./yolo-uptime-probe.sh --selftest by hand." \
      high "warning"
    up_log "selftest FAILED"
  else
    echo "selftest OK"
    up_log "selftest OK"
  fi
  exit "$rc"
fi

# ---- collection ------------------------------------------------------------------
# Each probe appends "key|value|threshold|unit|human label"; value 1 = DOWN.
METRICS=""
add_metric() { METRICS="${METRICS}${1}|${2}|${3}|${4}|${5}
"; }

UI_UP="$(up_http_probe "$UP_UI_URL")"
add_metric "ui-down" "$([ "$UI_UP" = "1" ] && echo 0 || echo 1)" 1 "" \
  "YOLO public UI unreachable ($UP_UI_URL)"

API_UP="$(up_http_probe "$UP_API_URL" "$UP_API_MUST_CONTAIN")"
add_metric "api-down" "$([ "$API_UP" = "1" ] && echo 0 || echo 1)" 1 "" \
  "YOLO API serving chain broken ($UP_API_URL — NPM->edge->robinstocks->quant-mongo)"

# ---- --status: print everything and stop -----------------------------------------
if [ "$MODE" = "status" ]; then
  printf '%-10s %-6s %s\n' "PROBE" "DOWN?" "MEANING"
  while IFS='|' read -r key val thr unit label; do
    [ -n "$key" ] || continue
    printf '%-10s %-6s %s\n' "$key" "$val" "$label"
  done <<<"$METRICS"
  exit 0
fi

# ---- decide + notify (same aggregation shape as alerting-pipeline-watch.sh) ------
NOW="$(date +%s)"
ALERTS=""; RECOVERED=""; ALERT_KEYS=""
while IFS='|' read -r key val thr unit label; do
  [ -n "$key" ] || continue
  breached="$(ap_breached "$val" "$thr")"
  read -r consec alerting last <<<"$(ap_state_get "$UP_STATE" "$key")"
  read -r verdict n_consec n_alerting n_last <<<"$(ap_decide "$breached" "$consec" "$alerting" "$last" "$NOW" "$UP_NEED_CONSEC" "$UP_COOLDOWN")"
  ap_state_put "$UP_STATE" "$key" "$n_consec" "$n_alerting" "$n_last"
  case "$verdict" in
    alert|remind)
      ALERTS="${ALERTS}  ${label}  (sustained $(( n_consec * UP_PERIOD_MIN ))m)
"
      ALERT_KEYS="${ALERT_KEYS}${ALERT_KEYS:+, }${key}"
      up_log "$verdict $key consec=$n_consec"
      ;;
    recovered)
      RECOVERED="${RECOVERED}  ${label}
"
      up_log "recovered $key"
      ;;
  esac
done <<<"$METRICS"

if [ -n "$ALERTS" ]; then
  ntfy_push "$NTFY_TOPIC_UPTIME" "YOLO public serving DOWN ($ALERT_KEYS)" \
    "Probed from $(hostname), outside the cluster — in-cluster alerting may be blind right now (that is why this probe exists; see the 08-03 post-mortem).
$ALERTS
Triage: RESTART-RECOVERY.md; kubectl --context minikube -n yolo get pods; NPM at 172.16.238.10:81." \
    high "rotating_light"
fi
if [ -n "$RECOVERED" ]; then
  ntfy_push "$NTFY_TOPIC_UPTIME" "YOLO public serving recovered" "$RECOVERED" default "white_check_mark"
fi
exit 0
