#!/bin/bash
####################################
#
# tune-kubelet-log-rotation.sh — keep kubelet's container-log rotation limit ABOVE docker's.
#
####################################
# WHY THIS EXISTS (2026-09-14)
#
# Symptom: every yolo app log line was stored in Loki 2-3 times, and promtail's pushes were
# being 400'd by Loki with "entry too far behind". Proven on the prod node that day:
#
#   * The node runs k8s v1.35.1 on the docker runtime via cri-dockerd, so
#     /var/log/pods/<ns>_<pod>_<uid>/<container>/0.log is a SYMLINK to
#     /var/lib/docker/containers/<id>/<id>-json.log.
#   * docker ROTATES that json.log: minikube writes /etc/docker/daemon.json on every
#     `minikube start` with log-driver json-file, "max-size":"100m" and no max-file
#     (hardcoded in minikube pkg/minikube/cruntime/docker.go configureDocker).
#   * kubelet ALSO rotates it: nothing set containerLogMaxSize, so kubelet runs with its
#     defaults 10Mi / 5 files (k8s pkg/kubelet/apis/config/v1beta1/defaults.go).
#
#   Two rotators, and the wrong one fires first. kubelet's container-log manager sees a
#   0.log over 10Mi and "rotates" it by RENAMING THE SYMLINK to 0.log.<timestamp>; cri-dockerd
#   then recreates 0.log pointing at the SAME, still-large json.log. Nothing shrank, so ~5-7
#   minutes later kubelet does it again — for every pod whose log is over 10Mi.
#
#   promtail is behaving correctly: a recreated symlink is a new file, so it re-reads it from
#   offset 0. Loki accepts the part of that re-read that is under an hour old — stored AGAIN,
#   hence 2-3 copies of every line — and rejects the rest as "entry too far behind".
#
# Fix: make kubelet's limit LARGER than docker's, so kubelet never rotates and docker is the
# only rotator. With max-file unset (=1) docker starts the SAME json.log path over from empty at
# 100m (moby daemon/logger/loggerutils/logfile.go keeps no .1 copy for maxFiles<2) — the 0.log
# symlink is untouched and promtail follows the fresh, empty file. No re-read, no duplicates.
# (Honest caveat, out of scope here: whatever promtail had not yet shipped from the old contents
# at that instant is lost; with promtail's ~1s lag that is at most a second of lines per 100MB.)
#
# Chosen value: 200Mi. The rule is "kubelet limit > docker max-size" (100m = 100 MiB — docker's
# go-units sizes are binary), and 2x gives a clear margin. This script REFUSES to apply a value
# that is not strictly larger than the node's live daemon.json max-size, so the number cannot
# quietly drift back under docker's.
#
# WHY A NODE TUNE AND NOT JUST THE FLAG. start-scratch.sh and restart-minikube.sh now pass
# --extra-config=kubelet.container-log-max-size=200Mi, which covers any cluster CREATED from
# now on. It does not cover the running one, and minikube's own code is why (read from minikube
# master 2026-09-14; re-check these after a minikube upgrade):
#
#   (a) ExtraOptions persist in the profile (~/.minikube/profiles/minikube/config.json —
#       KubernetesConfig.ExtraOptions, saved by config.SaveProfile/config.Write in
#       pkg/minikube/node/start.go), and a bare `minikube start` on an existing profile reuses
#       them: updateExistingConfigFromFlags (cmd/minikube/cmd/start_flags.go) starts from
#       `cc := *existing`. The live cluster's stored set predates this flag, so
#       cluster-autostart.sh's bare `minikube start --driver=docker` can never add it.
#   (b) Passing --extra-config on an existing cluster REPLACES the stored set, it does not
#       merge: `if cmd.Flags().Changed("extra-config") { cc.KubernetesConfig.ExtraOptions =
#       getExtraOptions() }`, and getExtraOptions returns only this invocation's flags. So
#       `minikube start --extra-config=kubelet.container-log-max-size=200Mi` on its own would
#       silently DROP system-reserved, kube-reserved, eviction-hard and the webhook flags.
#       Never do that. (restart-minikube.sh/start-scratch.sh are safe: they pass the full set.)
#   (c) This option is not one minikube writes into kubelet's config file.
#       container-log-max-size is not in bsutil.kubeletConfigParams (bsutil/kubelet.go), so it
#       becomes a kubelet COMMAND-LINE FLAG in /etc/systemd/system/kubelet.service.d/10-kubeadm.conf,
#       which UpdateNode (bootstrapper/kubeadm/kubeadm.go) regenerates from the profile on
#       EVERY start — a hand edit there is lost every time. /var/lib/kubelet/config.yaml, by
#       contrast, is written only by `kubeadm init phase kubelet-start`: on a cold init, or when
#       restartPrimaryControlPlane finds kubeadm.yaml drift. A no-drift warm start leaves it
#       alone. So a config.yaml edit survives ordinary starts and reboots, but NOT a drift
#       reconfigure (e.g. a k8s version change) — hence re-applying after every start.
#   Also: `minikube start` on a running cluster restarts dockerd inside the node
#   (cruntime Docker.Enable -> restartServiceWithExpoRetry("docker")), which bounces every pod.
#   It is not a way to apply anything live. This script restarts ONLY kubelet.
#
# So this script sets containerLogMaxSize in /var/lib/kubelet/config.yaml and restarts kubelet,
# and ONLY when the value kubelet is actually running with (read from the kubelet's own /configz
# through the API server, not grepped from a file) differs. Kubelet flags take precedence over
# the config file (k8s cmd/kubelet/app/server.go kubeletConfigFlagPrecedence), so on a cluster
# created with the new flag the effective value is already 200Mi and this is a no-op; if a flag
# with a DIFFERENT value is present, editing the file cannot win and the script says so and
# exits non-zero instead of restarting kubelet for nothing.
#
# Why config.yaml and not an ExecStart drop-in like tune-cri-dockerd-timeout.sh: a
# 20-*.conf for kubelet would have to restate the whole ExecStart — freezing the versioned
# binary path (/var/lib/minikube/binaries/<k8s-version>/kubelet) and --node-ip at write time.
# The next minikube upgrade rewrites 10-kubeadm.conf and the stale drop-in would override it.
# cri-dockerd tolerates that trick because its ExecStart is version-free; kubelet's is not.
# (kubelet's --config-dir drop-in mechanism is not usable either: minikube does not pass it.)
#
# Restarting kubelet under cri-dockerd does NOT restart containers — dockerd owns them and
# keeps them running; kubelet re-syncs on start. Never restart docker or cri-dockerd for this.
#
# The profile heals itself without a hand edit to config.json: the next time the cluster is
# started FROM STOPPED by restart-minikube.sh or start-scratch.sh, their full flag set replaces
# the stored ExtraOptions per (b), after which even a bare `minikube start` carries it per (a).
#
# Idempotent: writes + restarts only when the effective value is not the wanted one, so it is
# safe to call on every bring-up and from the */10 cluster-autostart.sh watchdog (which is what
# makes a regression — e.g. a drift reconfigure regenerating config.yaml — self-repairing).
# Does NOT survive `minikube delete`; a recreated cluster gets the flag from the start line.
#
# Callers: start-scratch.sh + restart-minikube.sh (after `minikube start`, next to
# tune-cri-dockerd-timeout.sh), cluster-autostart.sh (healthy and reconciled exits),
# verify-recovery.sh (--status, read-only).
#
# Usage:  ./tune-kubelet-log-rotation.sh             # apply the default 200Mi if not in effect
#         ./tune-kubelet-log-rotation.sh --status    # read-only report; exit 0 compliant,
#                                                    #   1 kubelet limit NOT > docker (thrashing),
#                                                    #   2 could not read, 3 safe but not the wanted value
#         ./tune-kubelet-log-rotation.sh --dry-run   # everything short of writing/restarting
#         KUBELET_LOG_MAX_SIZE=300Mi ./tune-kubelet-log-rotation.sh
#
# Rollback (in-node): the first apply keeps the untouched file as config.yaml.pre-log-rotation.
#   minikube ssh -- 'sudo cp -p /var/lib/kubelet/config.yaml.pre-log-rotation /var/lib/kubelet/config.yaml && sudo systemctl restart kubelet'

KUBELET_LOG_MAX_SIZE="${KUBELET_LOG_MAX_SIZE:-200Mi}"
# In-NODE paths (read/written through `minikube ssh`). Overridable for the offline tests.
KUBELET_CONFIG="${KUBELET_CONFIG:-/var/lib/kubelet/config.yaml}"
DOCKER_DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
# `minikube kubectl --` matches the cluster's kubectl version and minikube's kubeconfig, and
# works from cron — same access model as cluster-autostart.sh. Word-split on purpose.
KUBECTL="${KUBECTL:-minikube kubectl --}"
# The node proxy answers 5xx for a few seconds while kubelet restarts; one immediate read
# would fail a perfectly healthy apply, so the verify polls.
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-90}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-3}"
# A zero interval with a non-zero timeout would never advance the clock below.
[ "$VERIFY_INTERVAL" -ge 1 ] 2>/dev/null || VERIFY_INTERVAL=1

# ---------------------------------------------------------------------------------------
# Pure helpers. TKL_LIB_ONLY=1 stops after these (the tests drive them directly).
# ---------------------------------------------------------------------------------------

# k8s resource.Quantity -> bytes. Binary suffixes Ki/Mi/Gi/Ti are 1024-based, decimal k/M/G/T
# are 1000-based. Lowercase `m` is MILLI in a Quantity (not mega) and is meaningless for a
# file size, so it is rejected rather than guessed. Prints nothing + returns 1 when unparseable.
k8s_quantity_to_bytes() {
  local q="${1:-}" n u
  [[ "$q" =~ ^([0-9]+)(Ki|Mi|Gi|Ti|k|M|G|T)?$ ]] || return 1
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  case "$u" in
    "")  echo "$n" ;;
    Ki)  echo $(( n * 1024 )) ;;
    Mi)  echo $(( n * 1024 * 1024 )) ;;
    Gi)  echo $(( n * 1024 * 1024 * 1024 )) ;;
    Ti)  echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
    k)   echo $(( n * 1000 )) ;;
    M)   echo $(( n * 1000 * 1000 )) ;;
    G)   echo $(( n * 1000 * 1000 * 1000 )) ;;
    T)   echo $(( n * 1000 * 1000 * 1000 * 1000 )) ;;
  esac
}

# docker log-opt max-size -> bytes. docker parses it with go-units RAMInBytes: case-insensitive,
# optional "i"/"b", and ALWAYS binary — "100m" and "100MB" are both 100 MiB. Integers only
# here; anything fancier (e.g. "1.5g") returns 1 and is reported as unreadable, not guessed.
docker_size_to_bytes() {
  local s n u
  s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$s" =~ ^([0-9]+)\ ?([kmgt])?i?b?$ ]] || return 1
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  case "$u" in
    "") echo "$n" ;;
    k)  echo $(( n * 1024 )) ;;
    m)  echo $(( n * 1024 * 1024 )) ;;
    g)  echo $(( n * 1024 * 1024 * 1024 )) ;;
    t)  echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
  esac
}

# $1 = kubelet containerLogMaxSize (Quantity), $2 = docker max-size ("" = none set).
# Prints one word:
#   ok               kubelet limit is strictly larger than docker's -> docker is the only rotator
#   thrash           kubelet limit <= docker's -> kubelet renames the symlink over and over
#   no-docker-limit  docker never rotates, so ANY kubelet limit is eventually exceeded and thrashes
#   unknown          one of the two values could not be parsed
kubelet_log_rotation_verdict() {
  local kb db
  kb="$(k8s_quantity_to_bytes "${1:-}")" || { echo unknown; return 0; }
  if [ -z "${2:-}" ]; then echo no-docker-limit; return 0; fi
  db="$(docker_size_to_bytes "$2")" || { echo unknown; return 0; }
  # Strictly greater: at EQUAL limits kubelet checks first and still wins the race.
  if [ "$kb" -gt "$db" ]; then echo ok; else echo thrash; fi
}

# Sourced for the helpers only: stop here, and before `set -eu`, so sourcing does not change
# the caller's shell options.
[ "${TKL_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null
set -eu

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------
MODE=apply
case "${1:-}" in
  "")        ;;
  --status)  MODE=status ;;
  --dry-run) MODE=dry-run ;;
  -h|--help) sed -n '/^# Usage:/,/^# Rollback/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)         echo "usage: $0 [--status|--dry-run]" >&2; exit 2 ;;
esac

say() { echo "tune-kubelet-log-rotation: $*"; }

command -v minikube >/dev/null || { say "minikube not on PATH" >&2; exit 2; }

WANT_BYTES="$(k8s_quantity_to_bytes "$KUBELET_LOG_MAX_SIZE")" \
  || { say "KUBELET_LOG_MAX_SIZE='$KUBELET_LOG_MAX_SIZE' is not a byte Quantity like 200Mi" >&2; exit 2; }

# Effective value, from the kubelet itself. Fails closed: an unreadable value is never treated
# as "different", so nothing is ever restarted on an unknown.
read_effective() {
  local node raw
  node="$($KUBECTL get nodes -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null)" || return 1
  [ -n "$node" ] || return 1
  raw="$($KUBECTL get --raw "/api/v1/nodes/$node/proxy/configz" 2>/dev/null)" || return 1
  printf '%s' "$raw" | grep -o '"containerLogMaxSize": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# docker's max-size from the node's daemon.json. Empty output = no max-size set. Exit 1 = could
# not read the file at all (which is different, and must not be reported as "no limit").
read_docker_max() {
  local raw
  raw="$(minikube ssh -- "sudo cat $DOCKER_DAEMON_JSON" 2>/dev/null | tr -d '\r')" || return 1
  printf '%s' "$raw" | grep -q '[{]' || return 1
  printf '%s' "$raw" | grep -o '"max-size": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# Right after a `minikube start` the node proxy can answer 5xx for a few seconds, so poll briefly
# instead of reporting a healthy cluster as unreadable.
READ_TIMEOUT="${READ_TIMEOUT:-30}"
read_waited=0
while :; do
  cur="$(read_effective)" || cur=""
  [ -n "$cur" ] && break
  [ "$read_waited" -ge "$READ_TIMEOUT" ] && break
  sleep "$VERIFY_INTERVAL"; read_waited=$(( read_waited + VERIFY_INTERVAL ))
done
if docker_max="$(read_docker_max)"; then docker_read=1; else docker_max=""; docker_read=0; fi

echo "tune-kubelet-log-rotation:"
echo "  kubelet containerLogMaxSize (effective, /configz) : ${cur:-<unreadable>}"
if [ "$docker_read" = 1 ]; then
  echo "  docker json-file max-size (node daemon.json)     : ${docker_max:-<not set — docker never rotates>}"
else
  echo "  docker json-file max-size (node daemon.json)     : <unreadable>"
fi
echo "  wanted                                           : $KUBELET_LOG_MAX_SIZE"

if [ "$MODE" = status ]; then
  if [ -z "$cur" ] || [ "$docker_read" = 0 ]; then
    say "UNKNOWN — could not read both values (cluster down? API proxy not ready?)"; exit 2
  fi
  v="$(kubelet_log_rotation_verdict "$cur" "$docker_max")"
  case "$v" in
    ok)
      if [ "$(k8s_quantity_to_bytes "$cur")" = "$WANT_BYTES" ]; then
        say "OK — kubelet $cur > docker $docker_max, so only docker rotates"; exit 0
      fi
      say "SAFE BUT NOT THE WANTED VALUE — kubelet $cur > docker $docker_max, wanted $KUBELET_LOG_MAX_SIZE"; exit 3 ;;
    thrash)
      say "THRASHING — kubelet limit $cur is NOT larger than docker's $docker_max: kubelet renames the 0.log symlink, promtail re-reads the whole file, Loki stores lines 2-3x. Fix: $0"; exit 1 ;;
    no-docker-limit)
      say "THRASHING — docker has no max-size, so the json.log grows until kubelet's $cur and kubelet rotates the symlink forever. daemon.json is minikube's (rewritten every start); find out what removed it"; exit 1 ;;
    *)
      say "UNKNOWN — could not parse '$cur' / '$docker_max'"; exit 2 ;;
  esac
fi

# ---- apply / dry-run ------------------------------------------------------------------
# The rule this whole script exists for, checked against the LIVE node rather than assumed.
if [ "$docker_read" = 1 ]; then
  case "$(kubelet_log_rotation_verdict "$KUBELET_LOG_MAX_SIZE" "$docker_max")" in
    ok) ;;
    thrash)
      say "REFUSING — wanted $KUBELET_LOG_MAX_SIZE is not larger than docker's max-size $docker_max; applying it would keep kubelet rotating the symlink. Pick a bigger KUBELET_LOG_MAX_SIZE." >&2
      exit 1 ;;
    no-docker-limit)
      say "WARN — docker has no max-size in $DOCKER_DAEMON_JSON; no kubelet limit can fully stop the thrash, applying $KUBELET_LOG_MAX_SIZE anyway (still far better than 10Mi)" >&2 ;;
    *)
      say "REFUSING — could not parse docker max-size '$docker_max' to compare against" >&2; exit 1 ;;
  esac
else
  # daemon.json unreadable while the API answers is odd but not a reason to leave kubelet on
  # 10Mi: every minikube writes 100m there, and 200Mi is larger than that.
  say "WARN — could not read $DOCKER_DAEMON_JSON in the node; cannot re-check the > docker rule this run" >&2
fi

if [ -z "$cur" ]; then
  say "cannot read kubelet's effective containerLogMaxSize (cluster down? API proxy not ready?) — changing nothing" >&2
  exit 2
fi

if [ "$(k8s_quantity_to_bytes "$cur" || echo x)" = "$WANT_BYTES" ]; then
  # cluster-autostart.sh matches the words "nothing to do" to keep its */10 log quiet — keep them.
  say "kubelet already running with containerLogMaxSize $cur — nothing to do"
  exit 0
fi

# A kubelet command-line flag beats config.yaml (see header), so if one is set to something
# else, editing the file and restarting kubelet changes nothing. Say where the value really
# comes from instead of restarting kubelet in a loop.
flag="$(minikube ssh -- "systemctl cat kubelet 2>/dev/null" 2>/dev/null | tr -d '\r' \
         | grep -o -- '--container-log-max-size=[^ ]*' | tail -1 || true)"
if [ -n "$flag" ]; then
  say "kubelet is started with $flag (from the minikube profile's ExtraOptions, via 10-kubeadm.conf), which overrides $KUBELET_CONFIG — refusing to edit a file that cannot win. Change the flag with a FULL-flag-set start (restart-minikube.sh / start-scratch.sh) instead." >&2
  exit 1
fi

if [ "$MODE" = dry-run ]; then
  say "DRY-RUN — would set 'containerLogMaxSize: $KUBELET_LOG_MAX_SIZE' in $KUBELET_CONFIG (effective now: $cur), then restart kubelet (containers keep running) and verify via /configz"
  exit 0
fi

# Built here, run inside the node as root. Values are validated above (WANT matched the
# Quantity regex), so they are safe to bake into sed.
remote_script="$(cat <<REMOTE
set -eu
cfg="$KUBELET_CONFIG"
want="$KUBELET_LOG_MAX_SIZE"
[ -f "\$cfg" ] || { echo "\$cfg not found" >&2; exit 1; }
# Keep the ORIGINAL once — later runs must not overwrite the rollback copy with an already-tuned file.
[ -e "\$cfg.pre-log-rotation" ] || cp -p "\$cfg" "\$cfg.pre-log-rotation"
if grep -q '^containerLogMaxSize:' "\$cfg"; then
  sed -i "s/^containerLogMaxSize:.*/containerLogMaxSize: \$want/" "\$cfg"
else
  # Top-level key appended at column 0; make sure the file ends in a newline first.
  [ -z "\$(tail -c1 "\$cfg")" ] || echo >> "\$cfg"
  echo "containerLogMaxSize: \$want" >> "\$cfg"
fi
grep -qx "containerLogMaxSize: \$want" "\$cfg" || { echo "write to \$cfg did not take" >&2; exit 1; }
# kubelet only. dockerd owns the containers and keeps them running; kubelet re-syncs on start.
systemctl restart kubelet
echo "applied: containerLogMaxSize: \$want (kubelet restarted)"
REMOTE
)"

# base64 over the wire so no quoting in the script above can be mangled by the ssh/shell layers.
minikube ssh -- "echo $(printf '%s' "$remote_script" | base64 -w0) | base64 -d | sudo bash"

say "verifying via /configz (up to ${VERIFY_TIMEOUT}s)..."
waited=0
while :; do
  now="$(read_effective)" || now=""
  if [ -n "$now" ] && [ "$(k8s_quantity_to_bytes "$now" || echo x)" = "$WANT_BYTES" ]; then
    say "OK — kubelet now running with containerLogMaxSize $now"
    exit 0
  fi
  if [ "$waited" -ge "$VERIFY_TIMEOUT" ]; then
    say "FAILED — after ${VERIFY_TIMEOUT}s kubelet reports containerLogMaxSize '${now:-<unreadable>}', wanted $KUBELET_LOG_MAX_SIZE. Check: minikube ssh -- 'systemctl status kubelet; sudo grep containerLogMaxSize $KUBELET_CONFIG'. Rollback: see the header." >&2
    exit 1
  fi
  sleep "$VERIFY_INTERVAL"
  waited=$(( waited + VERIFY_INTERVAL ))
done
