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
set -eu

API_IP="${API_IP:-172.16.238.2}"     # prod kube API (on the 5million docker bridge)
GW="${GW:-10.10.10.1}"               # prod end of the 10GbE /30 link
CTX="${CTX:-prod-minikube}"          # kube context name on this box

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
  sudo nmcli connection modify "$conn" +ipv4.routes "$API_IP/32 $GW"
  sudo nmcli connection up "$conn" >/dev/null
  ip route get "$API_IP"
}

do_kubeconfig() {
  local src="${1:?usage: devbox-connect-prod.sh kubeconfig <file>}"
  [ -f "$src" ] || { echo "kubeconfig file not found: $src" >&2; exit 1; }
  # The emitted file already renames cluster/user/context to prod-minikube, so a flatten-merge
  # is collision-free with any local 'minikube' context.
  mkdir -p ~/.kube && chmod 700 ~/.kube
  KUBECONFIG="$HOME/.kube/config:$src" kubectl config view --flatten > /tmp/.kubemerge.$$
  mv /tmp/.kubemerge.$$ ~/.kube/config && chmod 600 ~/.kube/config
  echo "merged $src into ~/.kube/config"; kubectl config get-contexts
}

do_test() {
  echo "=== route to $API_IP (expect via $GW) ==="; ip route get "$API_IP"
  echo "=== kubectl --context $CTX get ns ==="; kubectl --context "$CTX" get ns
}

case "${1:-}" in
  route)      do_route ;;
  kubeconfig) do_kubeconfig "${2:-}" ;;
  all)        do_route; do_kubeconfig "${2:-}" ;;
  test)       do_test ;;
  *) echo "usage: $0 {route|kubeconfig <file>|all <file>|test}" >&2; exit 1 ;;
esac
