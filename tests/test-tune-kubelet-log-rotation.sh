#!/bin/bash
# tests/test-tune-kubelet-log-rotation.sh — the kubelet-vs-docker log-rotation tune, cluster-free.
#
# The script touches a live node through exactly two doors: `minikube kubectl --` (to read the
# value kubelet is RUNNING with, from /configz) and `minikube ssh --` (daemon.json, the kubelet
# unit, and the base64'd apply). A fake `minikube` stands in for both. Its ssh runs the command
# locally with fake `sudo`/`systemctl`, so the real in-node apply script is exercised verbatim
# against a temp config.yaml. The fake kubelet only changes its effective value on a RESTART, read
# from config.yaml at that moment — so "edited the file but never restarted" reads as not applied,
# exactly as on a real node.
#
# Why the refusals matter as much as the apply: the script can run from the */10 autostart
# watchdog, unattended. A version that restarted kubelet on an unreadable value, or "fixed" a
# value a command-line flag overrides, would restart kubelet every ten minutes forever.
#
# TKLR_SCRIPT overrides the script under test (used for the mutation checks).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="${TKLR_SCRIPT:-$REPO/tune-kubelet-log-rotation.sh}"
fail=0
assert_eq() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi; }
assert_has() { case "$1" in *"$2"*) echo "ok: $3" ;; *) echo "FAIL: $3 — output lacks [$2]:"; printf '%s\n' "$1" | sed 's/^/    /'; fail=1 ;; esac; }

# ---- pure helpers -----------------------------------------------------------------------
# shellcheck source=/dev/null
TKL_LIB_ONLY=1 source "$SCRIPT"

assert_eq "$(k8s_quantity_to_bytes 200Mi)" "209715200" "200Mi is binary"
assert_eq "$(k8s_quantity_to_bytes 10Mi)"  "10485760"  "10Mi (kubelet default) is binary"
assert_eq "$(k8s_quantity_to_bytes 100M)"  "100000000" "100M is DECIMAL in a k8s Quantity"
assert_eq "$(k8s_quantity_to_bytes 100m >/dev/null; echo $?)" "1" "lowercase m is milli in a Quantity — rejected, not guessed"
assert_eq "$(docker_size_to_bytes 100m)"   "104857600" "docker 100m is binary (go-units RAMInBytes)"
assert_eq "$(docker_size_to_bytes 100MB)"  "104857600" "docker 100MB is ALSO binary"
assert_eq "$(docker_size_to_bytes 1.5g >/dev/null; echo $?)" "1" "fractional docker size rejected, not guessed"

assert_eq "$(kubelet_log_rotation_verdict 200Mi 100m)" "ok"              "200Mi over docker 100m -> docker is the only rotator"
assert_eq "$(kubelet_log_rotation_verdict 10Mi 100m)"  "thrash"          "the prod bug: kubelet 10Mi under docker 100m"
assert_eq "$(kubelet_log_rotation_verdict 100Mi 100m)" "thrash"          "EQUAL limits still thrash (kubelet checks first)"
assert_eq "$(kubelet_log_rotation_verdict 100M 100m)"  "thrash"          "100M (decimal) is SMALLER than docker's 100m (binary)"
assert_eq "$(kubelet_log_rotation_verdict 200Mi '')"   "no-docker-limit" "docker with no max-size never rotates"
assert_eq "$(kubelet_log_rotation_verdict junk 100m)"  "unknown"         "unparseable kubelet value is unknown, not ok"

# ---- a fake node ------------------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/minikube" <<'EOF'
#!/bin/bash
case "$1" in
  kubectl)
    shift; [ "${1:-}" = -- ] && shift
    [ -f "$T/api_down" ] && exit 1
    case "$*" in
      *"get nodes"*) printf 'minikube' ;;
      *"get --raw /api/v1/nodes/minikube/proxy/configz"*)
        printf '{"kubeletconfig":{"containerLogMaxSize":"%s","containerLogMaxFiles":5}}' "$(cat "$T/effective")" ;;
      *) exit 1 ;;
    esac ;;
  ssh)
    shift; [ "${1:-}" = -- ] && shift
    bash -c "$*" ;;
  *) exit 1 ;;
esac
EOF
cat > "$TMP/bin/sudo" <<'EOF'
#!/bin/bash
exec "$@"
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
  cat) cat "$T/unit" ;;
  restart)
    echo "$2" >> "$T/restarts"
    # A broken restart: kubelet comes back on its OLD value.
    [ -f "$T/restart_breaks" ] && exit 0
    v="$(sed -n 's/^containerLogMaxSize: *//p' "$T/config.yaml" | tail -1)"
    printf '%s' "${v:-10Mi}" > "$T/effective" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/"*

# Fresh node state for each case: kubelet on the 10Mi default, docker 100m, no kubelet flag.
reset_node() {
  rm -rf "$TMP/n"; mkdir -p "$TMP/n"
  printf 'apiVersion: kubelet.config.k8s.io/v1beta1\nkind: KubeletConfiguration\ncgroupDriver: systemd\n' > "$TMP/n/config.yaml"
  printf '{"exec-opts":["native.cgroupdriver=systemd"],"log-driver":"json-file","log-opts":{"max-size":"100m"},"storage-driver":"overlay2"}\n' > "$TMP/n/daemon.json"
  printf '[Service]\nExecStart=\nExecStart=/var/lib/minikube/binaries/v1.35.1/kubelet --config=/var/lib/kubelet/config.yaml --node-ip=192.168.49.2\n' > "$TMP/n/unit"
  printf '10Mi' > "$TMP/n/effective"
  : > "$TMP/n/restarts"
}
run() {  # run <args...> ; sets OUT and RC
  OUT="$(T="$TMP/n" PATH="$TMP/bin:$PATH" KUBELET_CONFIG="$TMP/n/config.yaml" DOCKER_DAEMON_JSON="$TMP/n/daemon.json" \
         READ_TIMEOUT=0 VERIFY_TIMEOUT=2 VERIFY_INTERVAL=1 bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
restarts() { wc -l < "$TMP/n/restarts" | tr -d ' '; }

# ---- apply: the prod case -> write, restart kubelet ONLY, verify ------------------------
reset_node; cp "$TMP/n/config.yaml" "$TMP/orig.yaml"
run
assert_eq "$RC" "0" "apply on 10Mi exits 0"
assert_has "$OUT" "OK — kubelet now running with containerLogMaxSize 200Mi" "apply verifies through /configz"
assert_eq "$(grep -c '^containerLogMaxSize: 200Mi$' "$TMP/n/config.yaml")" "1" "config.yaml gains exactly one containerLogMaxSize line"
assert_eq "$(cat "$TMP/n/restarts")" "kubelet" "exactly one restart, and only of kubelet"
assert_eq "$(cmp -s "$TMP/n/config.yaml.pre-log-rotation" "$TMP/orig.yaml"; echo $?)" "0" "rollback copy is the untouched original"

# ---- idempotent: a second run changes nothing ------------------------------------------
run
assert_eq "$RC" "0" "second apply exits 0"
assert_has "$OUT" "nothing to do" "second apply is a no-op (cluster-autostart matches these words)"
assert_eq "$(restarts)" "1" "second apply does not restart kubelet again"

# ---- an existing key is replaced, not duplicated; rollback copy is not overwritten -----
reset_node; printf 'containerLogMaxSize: 10Mi\n' >> "$TMP/n/config.yaml"; cp "$TMP/n/config.yaml" "$TMP/orig2.yaml"
run
assert_eq "$RC" "0" "apply over an existing 10Mi key exits 0"
assert_eq "$(grep -c '^containerLogMaxSize:' "$TMP/n/config.yaml")" "1" "existing key replaced in place, not appended twice"
KUBELET_LOG_MAX_SIZE=300Mi run
assert_eq "$(cmp -s "$TMP/n/config.yaml.pre-log-rotation" "$TMP/orig2.yaml"; echo $?)" "0" "a later re-tune keeps the ORIGINAL rollback copy"

# ---- a restart that does not take is a FAILURE, not a success --------------------------
reset_node; touch "$TMP/n/restart_breaks"
run
assert_eq "$RC" "1" "kubelet still on 10Mi after restart -> exit 1"
assert_has "$OUT" "FAILED" "verify failure is reported"

# ---- dry-run mutates nothing ------------------------------------------------------------
reset_node; cp "$TMP/n/config.yaml" "$TMP/orig3.yaml"
run --dry-run
assert_eq "$RC" "0" "dry-run exits 0"
assert_has "$OUT" "DRY-RUN" "dry-run says what it would do"
assert_eq "$(restarts)" "0" "dry-run restarts nothing"
assert_eq "$(cmp -s "$TMP/n/config.yaml" "$TMP/orig3.yaml"; echo $?)" "0" "dry-run leaves config.yaml untouched"
assert_eq "$([ -e "$TMP/n/config.yaml.pre-log-rotation" ] && echo yes || echo no)" "no" "dry-run writes no rollback copy"

# ---- refusals: never restart kubelet for something that cannot work ---------------------
reset_node; sed -i 's|--node-ip=|--container-log-max-size=50Mi --node-ip=|' "$TMP/n/unit"
run
assert_eq "$RC" "1" "a conflicting kubelet FLAG (beats config.yaml) -> refuse"
assert_eq "$(restarts)" "0" "flag conflict restarts nothing"

reset_node
KUBELET_LOG_MAX_SIZE=100Mi run
assert_eq "$RC" "1" "wanted value not above docker's 100m -> refuse"
assert_has "$OUT" "REFUSING" "the > docker rule is enforced against the live daemon.json"
assert_eq "$(restarts)" "0" "rule refusal restarts nothing"

reset_node; touch "$TMP/n/api_down"
run
assert_eq "$RC" "2" "unreadable effective value -> exit 2 (fail closed)"
assert_eq "$(restarts)" "0" "unreadable value restarts nothing"

# ---- --status: read-only verdicts (what verify-recovery.sh maps to PASS/FAIL/WARN) ------
reset_node; run --status
assert_eq "$RC" "1" "status on the prod bug (10Mi vs 100m) -> 1 (FAIL)"
assert_has "$OUT" "THRASHING" "status names the thrash"
reset_node; printf '200Mi' > "$TMP/n/effective"; run --status
assert_eq "$RC" "0" "status on 200Mi vs 100m -> 0 (PASS)"
reset_node; printf '300Mi' > "$TMP/n/effective"; run --status
assert_eq "$RC" "3" "status on a safe but different value -> 3 (WARN)"
reset_node; printf '200Mi' > "$TMP/n/effective"; printf '{"log-driver":"json-file"}\n' > "$TMP/n/daemon.json"; run --status
assert_eq "$RC" "1" "status with docker max-size removed -> 1 (FAIL)"
reset_node; touch "$TMP/n/api_down"; run --status
assert_eq "$RC" "2" "status with the API down -> 2 (WARN, not PASS)"
reset_node; cp "$TMP/n/config.yaml" "$TMP/orig4.yaml"; run --status
assert_eq "$(restarts)" "0" "status restarts nothing"
assert_eq "$(cmp -s "$TMP/n/config.yaml" "$TMP/orig4.yaml"; echo $?)" "0" "status leaves config.yaml untouched"

# ---- the callers still call it (a tune nobody runs fixes nothing) ----------------------
assert_eq "$(grep -c 'tune-kubelet-log-rotation.sh"' "$REPO/start-scratch.sh")" "1" "start-scratch.sh calls the tune"
assert_eq "$(grep -c 'tune-kubelet-log-rotation.sh"' "$REPO/restart-minikube.sh")" "1" "restart-minikube.sh calls the tune"
assert_eq "$(grep -c 'self_heal_kubelet_log_rotation;' "$REPO/cluster-autostart.sh")" "2" "cluster-autostart.sh calls it on both healthy exits"
assert_eq "$(grep -c 'tune-kubelet-log-rotation.sh" --status' "$REPO/verify-recovery.sh")" "1" "verify-recovery.sh checks it read-only"
for f in start-scratch.sh restart-minikube.sh; do
  assert_eq "$(grep -v '^\s*#' "$REPO/$f" | grep 'minikube start ' | grep -c -- '--extra-config=kubelet.container-log-max-size=200Mi')" "1" "$f active start line carries the 200Mi flag"
done

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
