#!/bin/bash
#
# devbox-metrics.sh — stand up the DEV BOX's metrics endpoint so prod Prometheus
# can scrape it over the 10GbE link.
#
# RUN THIS ON THE DEV BOX (vik@10.10.10.2), not on prod. It is the counterpart of
# devbox-connect-prod.sh: that one gives the dev box access to the prod cluster,
# this one gives the prod cluster visibility of the dev box.
#
##### WHY IT IS SHAPED LIKE THIS ####################################################
#
# The dev box is NOT in the cluster, so none of the usual machinery applies: no
# DaemonSet, no ServiceMonitor, no kube-state-metrics. It is a plain host that has to
# expose a Prometheus endpoint on the 10GbE address and be scraped as a static target.
#
# ⚠️ NO SUDO ANYWHERE. `vik` has sudo but NOT passwordless sudo, so an unattended
# install cannot use it. Everything here therefore runs as the user:
#   * node-exporter runs as a CONTAINER (vik is in the `docker` group), not the
#     `prometheus-node-exporter` apt package, which would need root to install and a
#     systemd unit to enable. `--restart unless-stopped` gives boot persistence for
#     free, because docker.service is already enabled.
#   * GPU metrics come from a TEXTFILE collector fed by `nvidia-smi`, not from DCGM.
#     A containerised GPU exporter needs nvidia-container-toolkit, which is NOT
#     installed here (`docker info` lists only runc; `docker run --gpus all` fails)
#     and installing it needs root. nvidia-smi is already on the box and needs none.
#   * The cron entry is a USER crontab, which needs no root either.
#
# WHY BIND TO 10.10.10.2 AND NOT 0.0.0.0. node-exporter has no authentication. The
# dev box also has a LAN address (192.168.50.161); binding to the /30 point-to-point
# 10GbE address means the endpoint is reachable from prod and from nothing else on
# the house LAN. Same reasoning as SEC-LOKI-NODEPORT in the prod repo — narrow the
# reachability rather than add a credential nothing else in the path speaks.
#
# ⚠️ THE DEV BOX IS A DUAL-BOOT WORKSTATION AND IS LEGITIMATELY OFF A LOT (it boots
# Windows too). So its scrape target is EXPECTED to be down, and kube-prometheus's
# TargetDown rule would page for it every time. Prod therefore routes TargetDown for
# this job to the `null` receiver — the same pattern already used for
# KubeSchedulerDown/KubeControllerManagerDown. See kube-prometheus
# manifests/alertmanager-secret.yaml. Do not "fix" the dashboard's gaps: they are the
# machine being off, and the Online/Offline panel says so.
#
# Usage (on the dev box):
#   ./devbox-metrics.sh --install     # containers + textfile writer + user cron
#   ./devbox-metrics.sh --status      # read-only: what is running, what is exported
#   ./devbox-metrics.sh --uninstall   # remove containers, cron and the state dir
#
# NOT set -e: this is best-effort plumbing. A failed GPU probe must not stop
# node-exporter from serving CPU/memory/disk/temperature.
####################################################################################

NE_IMAGE="${NE_IMAGE:-quay.io/prometheus/node-exporter:v1.11.1}"   # matches prod's DaemonSet
NE_NAME="devbox-node-exporter"
BIND_ADDR="${BIND_ADDR:-10.10.10.2}"
BIND_PORT="${BIND_PORT:-9100}"
STATE_DIR="${STATE_DIR:-$HOME/devbox-monitoring}"
TEXTFILE_DIR="$STATE_DIR/textfile"
WRITER="$STATE_DIR/write-textfile-metrics.sh"

MODE="${1:---status}"

info() { echo "devbox-metrics: $*"; }
warn() { echo "devbox-metrics: WARN: $*" >&2; }

# ---------------------------------------------------------------- the writer ------
# Emitted as its own file so cron can run it without this script being present, and
# so `--status` can show exactly what is being exported.
write_writer() {
  mkdir -p "$TEXTFILE_DIR"
  cat > "$WRITER" <<'WRITER_EOF'
#!/bin/bash
# Written by STEP0/devbox-metrics.sh. Emits the ONLY thing node-exporter cannot
# collect itself on this box: the GPU (no DCGM here). Everything else the dashboard
# shows — CPU, memory, disk, network, CPU/NVMe temperatures — comes from
# node-exporter's own collectors.
#
# Writes to a .tmp then renames: node-exporter reads this directory on every scrape,
# and a rename is atomic, so a scrape can never observe a half-written file.
TEXTFILE_DIR="$(dirname "$0")/textfile"
OUT="$TEXTFILE_DIR/devbox.prom"
TMP="$OUT.$$.tmp"
mkdir -p "$TEXTFILE_DIR"

{
  # --- GPU (nvidia-smi; no DCGM here) ------------------------------------------
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "# HELP devbox_gpu_utilization_percent GPU SM utilisation."
    echo "# TYPE devbox_gpu_utilization_percent gauge"
    echo "# HELP devbox_gpu_memory_used_bytes GPU framebuffer in use."
    echo "# TYPE devbox_gpu_memory_used_bytes gauge"
    echo "# HELP devbox_gpu_memory_total_bytes GPU framebuffer total."
    echo "# TYPE devbox_gpu_memory_total_bytes gauge"
    echo "# HELP devbox_gpu_temperature_celsius GPU core temperature."
    echo "# TYPE devbox_gpu_temperature_celsius gauge"
    echo "# HELP devbox_gpu_power_watts GPU board power draw."
    echo "# TYPE devbox_gpu_power_watts gauge"
    # MiB -> bytes here rather than in PromQL so the dashboard can just use `bytes`.
    nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
               --format=csv,noheader,nounits 2>/dev/null \
    | while IFS=, read -r idx name util used total temp power; do
        name="$(echo "$name" | sed 's/^ *//; s/ *$//')"
        idx="$(echo "$idx" | tr -d ' ')"
        L="{gpu=\"$idx\",name=\"$name\"}"
        echo "devbox_gpu_utilization_percent$L $(echo "$util" | tr -d ' ')"
        echo "devbox_gpu_memory_used_bytes$L $(( $(echo "$used" | tr -d ' ') * 1048576 ))"
        echo "devbox_gpu_memory_total_bytes$L $(( $(echo "$total" | tr -d ' ') * 1048576 ))"
        echo "devbox_gpu_temperature_celsius$L $(echo "$temp" | tr -d ' ')"
        echo "devbox_gpu_power_watts$L $(echo "$power" | tr -d ' ')"
      done
  fi

  # Deliberately NOTHING about docker/containers here. The ask is the usual host
  # indicators — CPU, memory, disk, temperatures, GPU — and node-exporter already
  # covers all of those except the GPU. Per-container stats would mean either
  # cAdvisor (a second always-on container on a workstation) or a `docker stats`
  # call on every write, for a breakdown nobody asked for.

  echo "# HELP devbox_textfile_last_write_timestamp_seconds When this file was last written."
  echo "# TYPE devbox_textfile_last_write_timestamp_seconds gauge"
  echo "devbox_textfile_last_write_timestamp_seconds $(date +%s)"
} > "$TMP" 2>/dev/null

mv -f "$TMP" "$OUT"
WRITER_EOF
  chmod +x "$WRITER"
}

# ---------------------------------------------------------------------- status ----
if [ "$MODE" = "--status" ]; then
  if docker ps --filter "name=^${NE_NAME}$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
    info "container $NE_NAME: $(docker ps --filter "name=^${NE_NAME}$" --format '{{.Status}}')"
  else
    info "container $NE_NAME: NOT running"
  fi
  if curl -sf -m 5 "http://${BIND_ADDR}:${BIND_PORT}/metrics" >/dev/null 2>&1; then
    n="$(curl -s -m 5 "http://${BIND_ADDR}:${BIND_PORT}/metrics" | grep -c '^[a-z]')"
    info "endpoint http://${BIND_ADDR}:${BIND_PORT}/metrics: serving ($n series lines)"
  else
    info "endpoint http://${BIND_ADDR}:${BIND_PORT}/metrics: NOT reachable"
  fi
  if [ -f "$TEXTFILE_DIR/devbox.prom" ]; then
    info "textfile: $(grep -c '^devbox_' "$TEXTFILE_DIR/devbox.prom") devbox_* samples, written $(date -r "$TEXTFILE_DIR/devbox.prom" '+%Y-%m-%d %H:%M:%S')"
  else
    info "textfile: $TEXTFILE_DIR/devbox.prom ABSENT"
  fi
  crontab -l 2>/dev/null | grep -q "write-textfile-metrics.sh" \
    && info "cron: user crontab entry present" \
    || info "cron: NO user crontab entry"
  exit 0
fi

# ------------------------------------------------------------------- uninstall ----
if [ "$MODE" = "--uninstall" ]; then
  docker rm -f "$NE_NAME" >/dev/null 2>&1 && info "removed container $NE_NAME"
  crontab -l 2>/dev/null | grep -v "write-textfile-metrics.sh" | crontab - 2>/dev/null \
    && info "removed cron entry"
  rm -rf "$STATE_DIR" && info "removed $STATE_DIR"
  info "done. Remember to remove the prod-side ScrapeConfig + Alertmanager route."
  exit 0
fi

if [ "$MODE" != "--install" ]; then
  echo "usage: $(basename "$0") [--install|--status|--uninstall]" >&2
  exit 2
fi

# --------------------------------------------------------------------- install ----
if ! docker info >/dev/null 2>&1; then
  warn "cannot talk to the docker daemon as $(id -un). Is this user in the docker group?"
  exit 1
fi

write_writer
info "wrote $WRITER"
"$WRITER" && info "primed $TEXTFILE_DIR/devbox.prom"

docker rm -f "$NE_NAME" >/dev/null 2>&1
# --net=host: node-exporter must see the host's real interfaces, and it is how the
#   listen address can be pinned to the 10GbE IP.
# --pid=host + --path.rootfs=/host: the documented upstream invocation; without them
#   the process/filesystem collectors describe the CONTAINER, not the machine.
if docker run -d \
     --name "$NE_NAME" \
     --restart unless-stopped \
     --net=host \
     --pid=host \
     -v /:/host:ro,rslave \
     -v "$TEXTFILE_DIR:/textfile:ro" \
     "$NE_IMAGE" \
     --path.rootfs=/host \
     --web.listen-address="${BIND_ADDR}:${BIND_PORT}" \
     --collector.textfile.directory=/textfile >/dev/null 2>&1; then
  info "started $NE_NAME on ${BIND_ADDR}:${BIND_PORT}"
else
  warn "failed to start $NE_NAME"; docker logs "$NE_NAME" 2>&1 | tail -5; exit 1
fi

# Every minute, matching node-exporter's usefulness for a 30s scrape without making
# `docker stats` (which takes a second or two) run continuously.
CRON_LINE="* * * * * $WRITER >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "write-textfile-metrics.sh"; echo "$CRON_LINE" ) | crontab -
info "installed user cron: $CRON_LINE"

sleep 3
if curl -sf -m 5 "http://${BIND_ADDR}:${BIND_PORT}/metrics" >/dev/null 2>&1; then
  info "endpoint is serving. Prod scrapes this via kube-prometheus ScrapeConfig 'devbox'."
else
  warn "endpoint not answering yet; check: docker logs $NE_NAME"
fi
exit 0
