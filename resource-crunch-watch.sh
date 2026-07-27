#!/bin/bash
# resource-crunch-watch.sh — push a notification when the host/cluster runs out of
# headroom. Channel: `yolo-private-cloud-resource-crunch` (ntfy-lib.sh registry).
#
# WHY
# ---
# Everything on this box shares ONE node: Jenkins builds, ollama's models on the single
# RTX 3080 Ti, the yolo/predictonomy/qcguy workloads, plus IntelliJ and Chrome outside
# the cgroup. There is no second node to spill onto, so pressure shows up as a website
# getting slow or a pod being OOM-killed — with nothing to say why. This watcher names
# the resource before that happens.
#
# WHAT IT WATCHES
#   node CPU % / memory %      kubectl top node (metrics-server addon — see CLAUDE.md;
#                              prometheus-adapter cannot serve these on this node)
#   node conditions            MemoryPressure / DiskPressure / PIDPressure — the kubelet's
#                              own verdict; DiskPressure precedes image GC and evictions
#   unschedulable pods         Pending with PodScheduled=False/Unschedulable, i.e. the
#                              scheduler has already given up for want of CPU/memory/GPU
#   GPU utilisation / memory / temperature   nvidia-smi
#   CPU package temperature    coretemp hwmon, falling back to the x86_pkg_temp zone
#                              (lm-sensors is NOT installed on this host)
#   disk %                     /, /var (Jenkins + docker build churn), /mnt/minikube-backups
#
# NOISE CONTROL — the reason this is not just a set of `if` statements
#   A 5-minute cron that pushes on every breach trains you to mute the channel, and a
#   muted channel is worse than none. Three rules prevent that:
#     1. SUSTAINED: a metric must breach RC_NEED_CONSEC runs in a row (default 3 =
#        15 minutes) before it says anything. A build spike is not a crunch.
#     2. COOLDOWN: while a metric stays breached it repeats at most every RC_COOLDOWN
#        seconds (default 1h), not every 5 minutes.
#     3. RECOVERY: when a breached metric clears you get one "cleared" note, so an
#        alert never leaves you wondering whether it is still happening.
#   State lives in RC_STATE; deleting that file just re-arms everything.
#
# DELIBERATELY NOT ALERTED HERE: the cluster being down. `kubectl top` failing means
# minikube is unhealthy, which is cluster-autostart.sh's channel, not this one — so the
# cluster metrics are skipped and the HOST metrics (disk, temps, GPU) still run.
#
# GPU UTILISATION IS THE WEAKEST SIGNAL of the set: ollama pegs the GPU at 100% during
# inference and that is the machine working, not the machine struggling. Its threshold
# therefore sits at the "nothing else can get a slot" line and, like everything else,
# only speaks after 15 sustained minutes. GPU *memory* and *temperature* are the GPU
# signals that actually predict failure.
#
# Usage:
#   ./resource-crunch-watch.sh            # one sampling pass (this is what cron runs)
#   ./resource-crunch-watch.sh --status   # print every metric now; no state, no push
#   ./resource-crunch-watch.sh --dry-run  # sample + decide, print pushes instead of sending
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -r "$SELFDIR/ntfy-lib.sh" ]; then source "$SELFDIR/ntfy-lib.sh"; else
  echo "WARN: ntfy-lib.sh not found — nothing can be sent." >&2
  ntfy_push() { :; }; NTFY_TOPIC_RESOURCE_CRUNCH=""
fi

# ---- thresholds: breach is value >= threshold. All env-overridable ---------------
RC_CPU_PCT="${RC_CPU_PCT:-90}"          # node CPU (compressible — throttles, never OOM-kills)
RC_MEM_PCT="${RC_MEM_PCT:-90}"          # node memory — the hard limit on this box
RC_GPU_UTIL_PCT="${RC_GPU_UTIL_PCT:-98}"  # see the note above: a busy GPU is normal
RC_GPU_MEM_PCT="${RC_GPU_MEM_PCT:-90}"  # 12GB card; ollama already holds ~9GB at rest
RC_GPU_TEMP_C="${RC_GPU_TEMP_C:-85}"    # 3080 Ti throttles ~93C
RC_CPU_TEMP_C="${RC_CPU_TEMP_C:-90}"    # i9-12900K Tjmax 100C
RC_DISK_PCT="${RC_DISK_PCT:-90}"
RC_NEED_CONSEC="${RC_NEED_CONSEC:-3}"   # x 5-minute cron = 15 minutes sustained
RC_COOLDOWN="${RC_COOLDOWN:-3600}"      # re-notify at most hourly while still breached
RC_STATE="${RC_STATE:-$SELFDIR/logs/.resource-crunch-state}"
RC_LOG="${RC_LOG:-$SELFDIR/logs/resource-crunch-watch.log}"

# ============================ pure decision logic =================================
# Kept free of I/O so tests/test-resource-crunch-watch.sh can drive every transition
# without a cluster, a GPU or a clock. This is the part that must not be wrong: a bug
# here either floods the channel or silences it, and both look like "working".

# rc_state_get <file> <key> -> "<consec> <alerting> <last_alert_epoch>"
# Unknown key (first ever run, or state file deleted) reads as "0 0 0" = calm.
rc_state_get() {
  local f="$1" k="$2" line
  line="$(grep -F "$(printf '%s\t' "$k")" "$f" 2>/dev/null | head -1)"
  if [ -z "$line" ]; then echo "0 0 0"; return 0; fi
  echo "$line" | awk -F'\t' '{printf "%s %s %s\n", ($2==""?0:$2), ($3==""?0:$3), ($4==""?0:$4)}'
}

# rc_state_put <file> <key> <consec> <alerting> <last_alert_epoch>
# Rewrite via a temp file + mv: the cron can be killed mid-write, and a half-written
# state file would silently reset every metric's history.
rc_state_put() {
  local f="$1" k="$2" c="$3" a="$4" l="$5" tmp
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  grep -Fv "$(printf '%s\t' "$k")" "$f" 2>/dev/null >> "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$k" "$c" "$a" "$l" >> "$tmp"
  mv -f "$tmp" "$f"
}

# rc_decide <breached> <prev_consec> <prev_alerting> <prev_last> <now> <need> <cooldown>
#   -> "<verdict> <consec> <alerting> <last>"   verdict = alert | remind | recovered | silent
# The full state machine in one place:
#   breached, not yet sustained            -> silent, count up
#   breached, just reached `need`          -> alert   (the first notification)
#   breached, still alerting, past cooldown-> remind  (hourly repeat)
#   breached, still alerting, within it    -> silent
#   clear, was alerting                    -> recovered (one note, then calm)
#   clear, was calm                        -> silent
rc_decide() {
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

# rc_breached <value> <threshold> — 1 if value is a number at or above threshold.
# A non-numeric value means the probe could not read that metric (no GPU, hwmon gone,
# cluster down); that is NOT a breach — an unreadable sensor must never page.
rc_breached() {
  case "${1:-}" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  [ "$1" -ge "$2" ] && echo 1 || echo 0
}

# Sourced by the tests: stop here, before anything touches the cluster or the GPU.
[ "${RC_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

# ============================ collection ==========================================
mkdir -p "$(dirname "$RC_STATE")" 2>/dev/null
# CREATE if absent — never truncate. The file IS the sustained-breach history; wiping
# it each run would reset every counter to zero and guarantee nothing ever alerts.
[ -f "$RC_STATE" ] || : > "$RC_STATE" 2>/dev/null || true

MODE="watch"
case "${1:-}" in
  --status)  MODE="status" ;;
  --dry-run) export NTFY_DRY_RUN=1 ;;
  "") : ;;
  *) echo "unknown arg: $1 (use --status or --dry-run)" >&2; exit 2 ;;
esac

rc_log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$RC_LOG"; }

# kubectl: prefer the host binary, fall back to minikube's (same choice, and the same
# reason, as cluster-autostart.sh — it matches the cluster version and kubeconfig).
if command -v kubectl >/dev/null 2>&1; then KUBECTL="kubectl"
elif command -v minikube >/dev/null 2>&1; then KUBECTL="minikube kubectl --"
else KUBECTL=""; fi

# Each probe appends "key<TAB>value<TAB>threshold<TAB>unit<TAB>human label".
# A probe that cannot read its metric appends nothing — silence beats a fake zero.
METRICS=""
add_metric() { METRICS="${METRICS}${1}|${2}|${3}|${4}|${5}
"; }

# ---- cluster (skipped, not alerted, when the cluster is down: see header) --------
CLUSTER_OK=0
if [ -n "$KUBECTL" ] && top_out="$($KUBECTL top node --no-headers 2>/dev/null)" && [ -n "$top_out" ]; then
  CLUSTER_OK=1
  # "minikube  1523m  6%  28667Mi  46%"
  cpu_pct="$(echo "$top_out" | awk 'NR==1{gsub(/%/,"",$3); print $3}')"
  mem_pct="$(echo "$top_out" | awk 'NR==1{gsub(/%/,"",$5); print $5}')"
  add_metric "node-cpu" "$cpu_pct" "$RC_CPU_PCT" "%" "node CPU"
  add_metric "node-mem" "$mem_pct" "$RC_MEM_PCT" "%" "node memory"

  # The kubelet's own pressure verdict. Treated as a single metric: any of the three
  # being True is the same operator action (find what is eating the node).
  conds="$($KUBECTL get node -o jsonpath='{range .items[*].status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)"
  press=0; press_which=""
  for c in MemoryPressure DiskPressure PIDPressure; do
    case "$conds" in *"$c=True"*) press=1; press_which="$press_which $c" ;; esac
  done
  add_metric "node-pressure" "$press" "1" "" "kubelet pressure${press_which:+:$press_which}"

  # Pods the scheduler has already refused to place — the least ambiguous crunch
  # signal there is. Plain "Pending" is not used: that also covers image pulls.
  pending="$($KUBECTL get po -A -o json 2>/dev/null | jq '[.items[]
      | select(.status.phase=="Pending")
      | select(any(.status.conditions[]?; .type=="PodScheduled" and .status=="False" and .reason=="Unschedulable"))
    ] | length' 2>/dev/null)"
  add_metric "pods-unschedulable" "${pending:-}" "1" " pods" "unschedulable pods"
else
  rc_log "cluster metrics unavailable (kubectl top failed) — skipping; cluster health is cluster-autostart.sh's channel"
fi

# ---- GPU -------------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1 \
   && gpu="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)" \
   && [ -n "$gpu" ]; then
  gpu_util="$(echo "$gpu" | awk -F', *' '{print $1}')"
  gpu_used="$(echo "$gpu" | awk -F', *' '{print $2}')"
  gpu_total="$(echo "$gpu" | awk -F', *' '{print $3}')"
  gpu_temp="$(echo "$gpu" | awk -F', *' '{print $4}')"
  add_metric "gpu-util" "$gpu_util" "$RC_GPU_UTIL_PCT" "%" "GPU utilisation"
  if [ -n "${gpu_total:-}" ] && [ "${gpu_total:-0}" -gt 0 ] 2>/dev/null; then
    add_metric "gpu-mem" "$(( gpu_used * 100 / gpu_total ))" "$RC_GPU_MEM_PCT" "%" "GPU memory (${gpu_used}/${gpu_total} MiB)"
  fi
  add_metric "gpu-temp" "$gpu_temp" "$RC_GPU_TEMP_C" "C" "GPU temperature"
fi

# ---- CPU package temperature -----------------------------------------------------
# lm-sensors is not installed, so read the kernel interfaces directly: coretemp's
# "Package id 0" first, else the x86_pkg_temp thermal zone. Both are millidegrees.
cpu_temp=""
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$h/name" 2>/dev/null)" = "coretemp" ] || continue
  for lbl in "$h"/temp*_label; do
    [ -e "$lbl" ] || continue
    case "$(cat "$lbl" 2>/dev/null)" in "Package id 0")
      cpu_temp="$(( $(cat "${lbl%_label}_input" 2>/dev/null || echo 0) / 1000 ))" ;;
    esac
  done
done
if [ -z "$cpu_temp" ] || [ "$cpu_temp" = "0" ]; then
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ] || continue
    cpu_temp="$(( $(cat "$z/temp" 2>/dev/null || echo 0) / 1000 ))"
  done
fi
[ -n "$cpu_temp" ] && [ "$cpu_temp" != "0" ] && add_metric "cpu-temp" "$cpu_temp" "$RC_CPU_TEMP_C" "C" "CPU package temperature"

# ---- disks -----------------------------------------------------------------------
# /var is listed because Jenkins + docker build cache live there and it fills fastest
# (see reduce-node-docker-cache.sh); /mnt/minikube-backups holds the weekly archives
# AND every hostPath PV, so filling it takes data with it.
for spec in "disk-root:/" "disk-var:/var" "disk-backups:/mnt/minikube-backups"; do
  key="${spec%%:*}"; path="${spec#*:}"
  [ -d "$path" ] || continue
  pct="$(df --output=pcent "$path" 2>/dev/null | tail -1 | tr -dc '0-9')"
  [ -n "$pct" ] && add_metric "$key" "$pct" "$RC_DISK_PCT" "%" "disk $path"
done

# ============================ status mode =========================================
if [ "$MODE" = "status" ]; then
  printf '%-20s %8s %10s   %s\n' METRIC VALUE THRESHOLD STATE
  while IFS='|' read -r key val thr unit label; do
    [ -n "$key" ] || continue
    b="$(rc_breached "$val" "$thr")"
    read -r c a l <<<"$(rc_state_get "$RC_STATE" "$key")"
    printf '%-20s %8s %10s   %s (consec=%s alerting=%s) %s\n' \
      "$key" "$val$unit" "$thr$unit" \
      "$([ "$b" = 1 ] && echo BREACH || echo ok)" "$c" "$a" "$label"
  done <<<"$METRICS"
  [ "$CLUSTER_OK" = "1" ] || echo "(cluster metrics unavailable — minikube down? that is cluster-autostart.sh's alert, not this one)"
  exit 0
fi

# ============================ decide + notify =====================================
NOW="$(date +%s)"
ALERTS=""; RECOVERED=""; ALERT_KEYS=""
while IFS='|' read -r key val thr unit label; do
  [ -n "$key" ] || continue
  breached="$(rc_breached "$val" "$thr")"
  read -r consec alerting last <<<"$(rc_state_get "$RC_STATE" "$key")"
  read -r verdict n_consec n_alerting n_last <<<"$(rc_decide "$breached" "$consec" "$alerting" "$last" "$NOW" "$RC_NEED_CONSEC" "$RC_COOLDOWN")"
  rc_state_put "$RC_STATE" "$key" "$n_consec" "$n_alerting" "$n_last"
  case "$verdict" in
    alert|remind)
      # Sustained minutes are derived from the consecutive count and the cron period,
      # so the message says "for 20m" rather than the meaningless "3 samples".
      ALERTS="${ALERTS}  ${label}: ${val}${unit}  (limit ${thr}${unit}, sustained $(( n_consec * ${RC_PERIOD_MIN:-5} ))m)
"
      ALERT_KEYS="${ALERT_KEYS}${ALERT_KEYS:+, }${key} ${val}${unit}"
      rc_log "$verdict $key=$val$unit (>= $thr$unit) consec=$n_consec"
      ;;
    recovered)
      RECOVERED="${RECOVERED}  ${label}: back to ${val}${unit} (limit ${thr}${unit})
"
      rc_log "recovered $key=$val$unit"
      ;;
  esac
done <<<"$METRICS"

# One push per run, not one per metric: when the node is short of memory, several
# metrics trip together and they are all the same event.
if [ -n "$ALERTS" ]; then
  ntfy_push "$NTFY_TOPIC_RESOURCE_CRUNCH" "Resource crunch: $ALERT_KEYS" \
"$(hostname -s) is out of headroom:

${ALERTS}
Look at:  kubectl top po -A --sort-by=memory   |   nvidia-smi   |   df -h
Repeats at most hourly while this lasts; you will get a 'cleared' note when it ends." \
    "high" "fire,chart_with_upwards_trend"
fi
if [ -n "$RECOVERED" ]; then
  ntfy_push "$NTFY_TOPIC_RESOURCE_CRUNCH" "Resource crunch cleared" \
"$(hostname -s) is back under its limits:

${RECOVERED}" \
    "low" "white_check_mark,chart_with_downwards_trend"
fi
exit 0
