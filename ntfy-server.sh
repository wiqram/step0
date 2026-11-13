#!/bin/bash
# ntfy-server.sh — run and maintain the platform's SELF-HOSTED ntfy server (2026-11-13).
#
# WHY: ntfy.sh's anonymous tier allows 250 messages/day PER SOURCE IP, shared by every
# publisher on this box. On 2026-11-13 the quota was gone by 09:34Z and every alert after
# that was dropped (HTTP 429, code 42908). See ntfy/server.yml for the full reasoning and
# ntfy/docker-compose.yml for why this is a host container, not a cluster workload.
#
# WHAT IT OWNS (all idempotent; safe to re-run any time):
#   * the container (docker compose up -d), data at /mnt/minikube-mnt/ntfy (DR-swept)
#   * users + ACLs in ntfy's auth DB:
#       $NTFY_PHONE_USER (default "phone"; operator chose "private-cloud")
#                     read-only  yolo-*                       (the operator's iPhone app)
#       step0         read-write yolo-*                       (ntfy-lib.sh publishers + probes)
#       alertmanager  write-only yolo-private-cloud-platform  (kube-prometheus webhook)
#       yolo          write-only yolo-*                       (yolo apps / Grafana, via Vault)
#   * credentials, generated once and kept in STEP0/.env (gitignored, mode 600, swept by the
#     weekly DR archive): NTFY_SELF_URL, NTFY_PHONE_USER, NTFY_PHONE_PASSWORD,
#     NTFY_TOKEN_STEP0, NTFY_TOKEN_ALERTMANAGER, NTFY_TOKEN_YOLO. .env is the source of truth
#     for the phone password (re-applied on every run); a token is kept while ntfy still
#     knows it and re-issued (and .env updated) only if ntfy lost it.
#   * the yolo token in Vault at kv/ntfy/yolo {url, internal_url, token}  (STEP0-owned path — NOT kv/yolo/*, which the
#     yolo pipeline's vault-sync reconciles from yolo's own sops files)
#   * the Kubernetes Secret monitoring/alertmanager-ntfy-token (Alertmanager reads it via
#     credentials_file). Created by --k8s-secret, which start-scratch.sh calls AFTER
#     manifests/setup and BEFORE manifests/ — the Alertmanager CR mounts it, so if it is
#     missing on a cold boot alertmanager-main-0 sits in ContainerCreating.
#
# NEVER prints a credential. To read one: grep NTFY_PHONE_PASSWORD ~/Ideaprojects/STEP0/.env
# To change the reader login: edit NTFY_PHONE_USER / NTFY_PHONE_PASSWORD in .env (single-quote a
# password containing $ or !), then ./ntfy-server.sh --ensure.
#
# Usage:
#   ./ntfy-server.sh --install      # container + users/tokens/ACLs + Vault + k8s Secret
#   ./ntfy-server.sh --ensure       # same, quietly (start-scratch / restore-scratch)
#   ./ntfy-server.sh --k8s-secret   # only (re)create monitoring/alertmanager-ntfy-token
#   ./ntfy-server.sh --status       # read-only: container, health, users, .env keys present
set -uo pipefail
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SELFDIR/.env}"
COMPOSE="$SELFDIR/ntfy/docker-compose.yml"
DATA_DIR="${NTFY_DATA_DIR:-/mnt/minikube-mnt/ntfy}"
CONTAINER=ntfy
BASE_URL="https://ntfy.traderyolo.com"
INTERNAL_URL="http://172.16.238.12"   # fixed IP in ntfy/docker-compose.yml
KEYS_FILE="${VAULT_KEYS_FILE:-$HOME/.vault/cluster-keys.json}"

info() { echo "ntfy-server: $*"; }
warn() { echo "ntfy-server: WARN: $*" >&2; }

# Same .env reader the other STEP0 scripts use: tolerate quotes, keep '=' in the value.
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"''; }
# Set KEY=VALUE in .env in place (append if absent), keeping the file mode 600. Values are
# token/password-safe (no newlines, no quotes), so a plain line replace is enough.
env_set() {
  local k="$1" v="$2" tmp
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  grep -vE "^$k=" "$ENV_FILE" > "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
}
nt() { docker exec "$CONTAINER" ntfy "$@"; }
genpass() { head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 28; }

up() {
  # Container root writes here; a plain mkdir is enough (no per-UID datastore rules).
  mkdir -p "$DATA_DIR" 2>/dev/null || sudo -n mkdir -p "$DATA_DIR"
  docker compose -f "$COMPOSE" up -d >/dev/null 2>&1 || { warn "docker compose up failed"; return 1; }
  local i
  for i in $(seq 1 30); do
    docker exec "$CONTAINER" wget -q -O- http://localhost:80/v1/health 2>/dev/null | grep -q '"healthy":true' && return 0
    sleep 2
  done
  warn "container started but /v1/health never reported healthy"; return 1
}

ensure_user() {  # <name> <password>
  if nt user list 2>/dev/null | grep -qE "^user $1 "; then
    NTFY_PASSWORD="$2" docker exec -e NTFY_PASSWORD "$CONTAINER" ntfy user change-pass "$1" >/dev/null 2>&1
  else
    NTFY_PASSWORD="$2" docker exec -e NTFY_PASSWORD "$CONTAINER" ntfy user add --role=user "$1" >/dev/null 2>&1 \
      && info "user $1 created"
  fi
}

ensure_token() {  # <user> <ENV_KEY> — keep the .env token if ntfy still knows it, else issue one
  local user="$1" key="$2" cur new
  cur="$(env_val "$key")"
  if [ -n "$cur" ] && nt token list "$user" 2>/dev/null | grep -q -- "$cur"; then return 0; fi
  new="$(nt token add --label "platform ($key)" "$user" 2>/dev/null | grep -oE 'tk_[A-Za-z0-9]+' | head -1)"
  if [ -n "$new" ]; then env_set "$key" "$new"; info "issued token for $user -> .env $key"; else warn "could not issue a token for $user"; fi
}

ensure_auth() {
  # The reader account's NAME and PASSWORD are both operator-settable in .env (the operator
  # renamed it 2026-11-13). .env is the source of truth: re-applied on every run. If the name
  # changes, the previously-configured reader is removed so no stale login lingers.
  local pw puser old
  pw="$(env_val NTFY_PHONE_PASSWORD)"
  [ -n "$pw" ] || { pw="$(genpass)"; env_set NTFY_PHONE_PASSWORD "$pw"; info "generated the phone password -> .env NTFY_PHONE_PASSWORD"; }
  puser="$(env_val NTFY_PHONE_USER)"; puser="${puser:-phone}"
  env_set NTFY_SELF_URL "$BASE_URL"
  ensure_user "$puser" "$pw"
  nt access "$puser" 'yolo-*' read-only >/dev/null 2>&1
  for old in $(nt user list 2>/dev/null | grep -oE '^user [a-z0-9_.-]+' | awk '{print $2}'); do
    case "$old" in "$puser"|step0|alertmanager|yolo|'*') ;; *) nt user del "$old" >/dev/null 2>&1 && info "removed stale reader user $old" ;; esac
  done
  # Publishers authenticate with tokens only, but ntfy needs a password on the account:
  # a random throwaway nobody stores is the right value.
  ensure_user step0 "$(genpass)"; ensure_user alertmanager "$(genpass)"; ensure_user yolo "$(genpass)"
  nt access step0        'yolo-*'                      read-write >/dev/null 2>&1
  nt access alertmanager 'yolo-private-cloud-platform' write-only >/dev/null 2>&1
  nt access yolo         'yolo-*'                      write-only >/dev/null 2>&1
  ensure_token step0        NTFY_TOKEN_STEP0
  ensure_token alertmanager NTFY_TOKEN_ALERTMANAGER
  ensure_token yolo         NTFY_TOKEN_YOLO
}

# kv/ntfy/yolo {url, token} for the yolo side to template in. Best-effort: Vault may be
# sealed or the cluster down; the next --ensure (start-scratch) catches up.
sync_vault() {
  local st root tok
  st="$(kubectl exec vault-0 -n vault -- vault status -format=json 2>/dev/null)"
  printf '%s' "$st" | jq -e '.sealed == false' >/dev/null 2>&1 || { warn "Vault unreachable or sealed — kv/ntfy/yolo not written (re-run --ensure later)"; return 0; }
  root="$(jq -r '.root_token // empty' "$KEYS_FILE" 2>/dev/null)"; [ -n "$root" ] || { warn "no Vault root token in $KEYS_FILE"; return 0; }
  kubectl exec -i vault-0 -n vault -- vault login - <<< "$root" >/dev/null 2>&1 || { warn "vault login failed"; return 0; }
  tok="$(env_val NTFY_TOKEN_YOLO)"; [ -n "$tok" ] || return 0
  # Fields: url (public, phone-facing), internal_url (the container's fixed address — what an
  # in-cluster publisher should use, so delivery does not depend on NPM/DNS), token.
  if [ "$(kubectl exec vault-0 -n vault -- vault kv get -field=token kv/ntfy/yolo 2>/dev/null)" != "$tok" ] \
     || [ "$(kubectl exec vault-0 -n vault -- vault kv get -field=internal_url kv/ntfy/yolo 2>/dev/null)" != "$INTERNAL_URL" ]; then
    kubectl exec -i vault-0 -n vault -- sh -c 'read -r t; vault kv put kv/ntfy/yolo url="'"$BASE_URL"'" internal_url="'"$INTERNAL_URL"'" token="$t" >/dev/null' <<< "$tok" \
      && info "Vault kv/ntfy/yolo updated" || warn "could not write kv/ntfy/yolo"
  fi
}

# monitoring/alertmanager-ntfy-token — mounted by the Alertmanager CR (secrets:) and read
# via credentials_file, so the token never appears in the committed alertmanager-secret.yaml.
k8s_secret() {
  local tok; tok="$(env_val NTFY_TOKEN_ALERTMANAGER)"
  [ -n "$tok" ] || { warn "no NTFY_TOKEN_ALERTMANAGER in .env — run --install first"; return 0; }
  kubectl get ns monitoring >/dev/null 2>&1 || { warn "namespace monitoring absent — Secret not created"; return 0; }
  kubectl -n monitoring create secret generic alertmanager-ntfy-token --from-file=token=<(printf '%s' "$tok") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
    && info "Secret monitoring/alertmanager-ntfy-token in place" || warn "could not apply monitoring/alertmanager-ntfy-token"
}

status() {
  echo "container: $(docker inspect -f '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} ip={{(index .NetworkSettings.Networks "5million").IPAddress}}' "$CONTAINER" 2>/dev/null || echo absent)"
  echo "health:    $(docker exec "$CONTAINER" wget -q -O- http://localhost:80/v1/health 2>/dev/null || echo unreachable)"
  echo "users:     $(nt user list 2>/dev/null | grep -oE '^user [a-z0-9]+' | awk '{print $2}' | tr '\n' ' ')"
  local k; for k in NTFY_SELF_URL NTFY_PHONE_USER NTFY_PHONE_PASSWORD NTFY_TOKEN_STEP0 NTFY_TOKEN_ALERTMANAGER NTFY_TOKEN_YOLO; do
    printf '.env %-24s %s\n' "$k" "$([ -n "$(env_val "$k")" ] && echo present || echo MISSING)"; done
  echo "k8s secret: $(kubectl -n monitoring get secret alertmanager-ntfy-token -o name 2>/dev/null || echo absent)"
  echo "public:    $(curl -s -m 10 -o /dev/null -w '%{http_code}' "$BASE_URL/v1/health" 2>/dev/null) ($BASE_URL/v1/health)"
}

case "${1:-}" in
  --install|--ensure) up && ensure_auth && sync_vault && k8s_secret ;;
  --k8s-secret)       k8s_secret ;;
  --status)           status ;;
  *) echo "usage: $0 --install | --ensure | --k8s-secret | --status" >&2; exit 2 ;;
esac
