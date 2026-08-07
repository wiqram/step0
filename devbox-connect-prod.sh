#!/bin/bash
# devbox-connect-prod.sh — set up the DEV box's access to the prod minikube API over 10GbE.
#
# RUN THIS ON THE DEV BOX (vik@10.10.10.2), not on the prod host. It is the from-scratch
# counterpart to STEP0's enable-devbox-kube-access.sh (which runs on prod). Together they give
# the dev box `kubectl` + IntelliJ Services access to the prod Kubernetes API (172.16.238.2:8443).
# API-only — no registry/NodePort. See architecture.md §3 "Dev box <-> prod cluster over 10GbE".
#
# It does two idempotent things:
#   1. route     — persistent NetworkManager route API_IP/32 via the 10GbE gateway, so API
#                  traffic goes over the 10GbE link instead of the LAN gateway.
#   2. kubeconfig — merge a prod kubeconfig (produced on prod by
#                  `enable-devbox-kube-access.sh --emit-kubeconfig`) into ~/.kube/config as the
#                  `prod-minikube` context, coexisting with any local `minikube` context.
#
# PREREQ (on prod, once): `sudo enable-devbox-kube-access.sh --install` (firewall + systemd),
# then `enable-devbox-kube-access.sh --emit-kubeconfig /home/cloud/prod-minikube.kubeconfig` and
# copy that file to this box (scp/USB) — pass its path below.
#
# USAGE (on the dev box):
#   ./devbox-connect-prod.sh route                      # add the persistent 10GbE route (needs sudo)
#   ./devbox-connect-prod.sh kubeconfig <file>          # merge prod kubeconfig as 'prod-minikube'
#   ./devbox-connect-prod.sh all <file>                 # both of the above
#   ./devbox-connect-prod.sh test                       # verify: route + kubectl get ns
#   sudo ./devbox-connect-prod.sh install-unit          # install+enable the boot health-check unit
#   ./devbox-connect-prod.sh boot-check                 # what that unit runs (self-heal route + kube check)
#   sudo ./devbox-connect-prod.sh uninstall-unit        # remove the boot unit
set -eu

API_IP="${API_IP:-172.16.238.2}"     # prod kube API (on the 5million docker bridge)
GW="${GW:-10.10.10.1}"               # prod end of the 10GbE /30 link
CTX="${CTX:-prod-minikube}"          # kube context name on this box
WAIT_SECS="${WAIT_SECS:-60}"         # boot-check: how long to wait for the prod API to answer (manual runs)
BOOT_WAIT_SECS="${BOOT_WAIT_SECS:-10}"  # SAME wait but for the installed unit — kept SHORT on purpose:
                                     # multi-user.target orders after this oneshot, so a long wait here
                                     # would stall the boot/login by that long whenever prod is down.
                                     # Access itself doesn't depend on this (NM route + kubeconfig are
                                     # independent) — the wait only makes the health-check log meaningful.
OLLAMA_ADDR="${OLLAMA_ADDR:-10.10.10.2:11434}"  # dev ollama endpoint prod yolo consumes (10GbE IP)
UNIT_NAME="devbox-connect-prod.service"

# Run privileged nmcli directly when we're already root (systemd unit), else via sudo (interactive).
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo"

# Find the NetworkManager connection whose device owns an address on the same /30 as $GW,
# so the route is pinned to the 10GbE NIC regardless of its name (eno1 here, may differ).
nm_conn_for_gw() {
  local devif
  devif="$(ip -o -f inet route get "$GW" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
  [ -n "$devif" ] || { echo "cannot find interface toward $GW (is the 10GbE link up?)" >&2; return 1; }
  nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$devif" '$2==d{print $1; exit}'
}

do_route() {
  local conn; conn="$(nm_conn_for_gw)"
  [ -n "$conn" ] || { echo "no active NM connection on the 10GbE interface" >&2; exit 1; }
  echo "adding route $API_IP/32 via $GW to NM connection \"$conn\" ..."
  $SUDO nmcli connection modify "$conn" +ipv4.routes "$API_IP/32 $GW"
  $SUDO nmcli connection up "$conn" >/dev/null
  ip route get "$API_IP"
}

do_kubeconfig() {
  local src="${1:?usage: devbox-connect-prod.sh kubeconfig <file>}"
  [ -f "$src" ] || { echo "kubeconfig file not found: $src" >&2; exit 1; }
  # The emitted file already renames cluster/user/context to prod-minikube, so a flatten-merge
  # is collision-free with any local 'minikube' context.
  mkdir -p ~/.kube && chmod 700 ~/.kube

  # Remember the developer's current context before merging — see the restore below.
  local prev=""
  [ -f "$HOME/.kube/config" ] && prev="$(kubectl config current-context 2>/dev/null || true)"

  # ⚠️ ORDER MATTERS: on conflicting keys the FIRST file in KUBECONFIG wins, so $src must come
  # first for a RE-emitted kubeconfig to actually replace the old one. This was reversed until
  # 2026-08-07, which made re-emitting a silent no-op: when something recreates ~/.minikube (a
  # fresh OS install or minikube-delete-and-upgrade.sh — NOT a plain rebuild) and so regenerates the
  # CA, the stale (now invalid) certificate-authority-data in ~/.kube/config survived the merge
  # and kubectl/IntelliJ kept failing `x509: certificate signed by unknown authority` — while the
  # command reported "merged" and `get-contexts` listed prod-minikube, so it looked done.
  local tmp; tmp="$(mktemp)"        # mktemp is 0600: this file holds cluster-admin certs
  KUBECONFIG="$src:$HOME/.kube/config" kubectl config view --flatten > "$tmp"
  mv "$tmp" ~/.kube/config && chmod 600 ~/.kube/config

  # $src carries `current-context: prod-minikube` and now wins the merge, which would silently
  # point every bare `kubectl` on this box at PROD with a system:masters credential. Put it back.
  if [ -n "$prev" ] && [ "$prev" != "$CTX" ]; then
    kubectl config use-context "$prev" >/dev/null 2>&1 \
      && echo "kept current-context on '$prev' — use 'kubectl --context $CTX ...' for prod"
  fi

  echo "merged $src into ~/.kube/config"; kubectl config get-contexts
}

do_test() {
  echo "=== route to $API_IP (expect via $GW) ==="; ip route get "$API_IP"
  echo "=== kubectl --context $CTX get ns ==="; kubectl --context "$CTX" get ns
}

# ---------------------------------------------------------------------------
# Boot health check — what the systemd unit runs on every boot. It is advisory:
# it self-heals the 10GbE route if NM didn't (re)apply it, waits for the prod
# API to answer, then logs a `kubectl get ns` result to the journal. It never
# fails the boot (exit 0) when prod is simply down/unreachable — that's a
# prod-side condition the dev box can't fix.
# ---------------------------------------------------------------------------
do_boot_check() {
  # The kube check runs as the human user (their ~/.kube/config); baked in at install time.
  local user home; user="${DEVBOX_USER:-${SUDO_USER:-$USER}}"
  home="$(getent passwd "$user" | cut -d: -f6)"; [ -n "$home" ] || home="$HOME"
  echo "[devbox-connect-prod] boot check: API=$API_IP GW=$GW ctx=$CTX user=$user"

  # 1. Self-heal the route. NM autoconnect normally re-applies the profile route
  #    at boot; only touch nmcli (which bounces the link) if it's actually missing.
  if ip route get "$API_IP" 2>/dev/null | grep -q "via $GW"; then
    echo "[devbox-connect-prod] route to $API_IP via $GW present"
  else
    echo "[devbox-connect-prod] route missing — re-asserting via NM"
    ( do_route ) || echo "[devbox-connect-prod] WARN: could not add route"
  fi

  # 2. ollama availability for prod yolo — the dev box serves its models on the
  #    10GbE IP so prod's yolo can consume them. ollama.service (enabled, binds
  #    $OLLAMA_ADDR) owns starting it; here we only verify + log. Runs regardless
  #    of prod being up, since it's the dev's own listener.
  local ohost="${OLLAMA_ADDR%:*}" oport="${OLLAMA_ADDR##*:}"
  if timeout 3 bash -c "exec 3<>/dev/tcp/$ohost/$oport" 2>/dev/null; then
    local nmodels="?"
    command -v curl >/dev/null && \
      nmodels="$(curl -sf -m3 "http://$OLLAMA_ADDR/api/tags" 2>/dev/null | grep -o '"model"' | wc -l)"
    echo "[devbox-connect-prod] OK: ollama serving on $OLLAMA_ADDR for prod yolo ($nmodels models)"
  else
    echo "[devbox-connect-prod] WARN: ollama not listening on $OLLAMA_ADDR —" \
         "prod yolo won't get dev models (is ollama.service up and bound to the 10GbE IP?)"
  fi

  # 3. Wait for the prod end to actually answer on the API port.
  local i ok=0
  for ((i=0; i<WAIT_SECS; i++)); do
    if timeout 2 bash -c "exec 3<>/dev/tcp/$API_IP/8443" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" != 1 ]; then
    echo "[devbox-connect-prod] WARN: $API_IP:8443 unreachable after ${WAIT_SECS}s" \
         "(prod host down, 10GbE link, or prod DOCKER-USER rules) — advisory, not failing boot"
    return 0
  fi
  echo "[devbox-connect-prod] API port reachable; verifying kube access"

  # 4. kube health check as the human user, so it uses their ~/.kube/config.
  if [ "$(id -u)" = 0 ] && [ "$user" != root ]; then
    if runuser -u "$user" -- env HOME="$home" kubectl --context "$CTX" get ns >/dev/null 2>&1; then
      echo "[devbox-connect-prod] OK: kubectl --context $CTX get ns succeeded"
    else
      echo "[devbox-connect-prod] WARN: port open but kubectl --context $CTX get ns failed (auth/kubeconfig?)"
    fi
  else
    kubectl --context "$CTX" get ns >/dev/null 2>&1 \
      && echo "[devbox-connect-prod] OK: kubectl --context $CTX get ns succeeded" \
      || echo "[devbox-connect-prod] WARN: kubectl --context $CTX get ns failed"
  fi
}

do_install_unit() {
  [ "$(id -u)" = 0 ] || { echo "install-unit needs root: sudo $0 install-unit" >&2; exit 1; }
  local self user dir; self="$(readlink -f "$0")"; user="${SUDO_USER:-root}"; dir="$(dirname "$self")"
  local unit="/etc/systemd/system/$UNIT_NAME"
  echo "writing $unit (runs '$self boot-check' on boot, kube check as user '$user') ..."
  cat > "$unit" <<EOF
[Unit]
Description=Dev box -> prod minikube API access + dev ollama availability (10GbE route self-heal + health check)
Documentation=file://$dir/architecture.md
After=network-online.target NetworkManager.service ollama.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# multi-user.target waits for this oneshot, so bound the runtime: a short prod-wait keeps
# boot fast when prod is down, and TimeoutStartSec is a hard backstop against any hang
# (e.g. kubectl). boot-check always exits 0 (advisory), so the unit never enters 'failed'.
TimeoutStartSec=45
Environment=DEVBOX_USER=$user
Environment=API_IP=$API_IP
Environment=GW=$GW
Environment=CTX=$CTX
Environment=WAIT_SECS=$BOOT_WAIT_SECS
ExecStart=$self boot-check

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$unit"
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null
  echo "enabled $UNIT_NAME (runs at every boot)"
  echo "try it now:  sudo systemctl start $UNIT_NAME && journalctl -u $UNIT_NAME -n 20 --no-pager"
}

do_uninstall_unit() {
  [ "$(id -u)" = 0 ] || { echo "uninstall-unit needs root: sudo $0 uninstall-unit" >&2; exit 1; }
  systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT_NAME"
  systemctl daemon-reload
  echo "removed $UNIT_NAME"
}

case "${1:-}" in
  route)          do_route ;;
  kubeconfig)     do_kubeconfig "${2:-}" ;;
  all)            do_route; do_kubeconfig "${2:-}" ;;
  test)           do_test ;;
  boot-check)     do_boot_check ;;
  install-unit)   do_install_unit ;;
  uninstall-unit) do_uninstall_unit ;;
  *) echo "usage: $0 {route|kubeconfig <file>|all <file>|test|boot-check|install-unit|uninstall-unit}" >&2; exit 1 ;;
esac
