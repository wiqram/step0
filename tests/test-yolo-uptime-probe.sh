#!/bin/bash
# tests/test-yolo-uptime-probe.sh — the probe's own glue, network-free.
#
# The sustained/cooldown/recovery state machine is deliberately NOT re-tested here:
# yolo-uptime-probe.sh sources it from alerting-pipeline-watch.sh (AP_LIB_ONLY seam),
# and tests/test-alerting-pipeline-watch.sh already drives every transition. What THIS
# file owns is the part that is new: up_http_probe's verdicts (2xx, non-2xx, refused
# connection, body-substring check) against a local throwaway HTTP server — because a
# probe that misreads "down" as "up" silences the channel, and one that misreads "up"
# as "down" floods it, and both look like "working" until the night it matters.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fail=0
assert_eq() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi; }

# UP_LIB_ONLY stops the script before it touches the real endpoints or state file.
# shellcheck source=/dev/null
UP_LIB_ONLY=1 source "$REPO/yolo-uptime-probe.sh"

# ---- a local server serving a known body ----------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; kill "$SRV_PID" 2>/dev/null' EXIT
printf '{"state":"open","exchange":"XNYS"}' > "$TMP/session"
PORT=$(( (RANDOM % 20000) + 20000 ))
( cd "$TMP" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SRV_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/session" && break; sleep 0.1; done

# ---- up_http_probe verdicts ------------------------------------------------------
assert_eq "$(up_http_probe "http://127.0.0.1:$PORT/session")"                       "1" "2xx with no body requirement reads UP"
assert_eq "$(up_http_probe "http://127.0.0.1:$PORT/session" '"state"')"             "1" "2xx with required substring reads UP"
assert_eq "$(up_http_probe "http://127.0.0.1:$PORT/session" '"never-here"')"        "0" "2xx MISSING the required substring reads DOWN (dead backend behind a live proxy)"
assert_eq "$(up_http_probe "http://127.0.0.1:$PORT/no-such-path")"                  "0" "404 reads DOWN"
assert_eq "$(UP_HTTP_TIMEOUT=2 up_http_probe "http://127.0.0.1:1/refused")"         "0" "refused connection reads DOWN"

# ---- the sourced machine is actually present (the reuse this script depends on) --
read -r v _ _ _ <<<"$(ap_decide 1 2 0 0 12345 3 3600)"
assert_eq "$v" "alert" "ap_decide sourced from alerting-pipeline-watch.sh and functional"

# ---- the channel is registered (the yolo-grafana lesson: live but unregistered) --
# shellcheck source=/dev/null
source "$REPO/ntfy-lib.sh"
if ntfy_topic_valid "$NTFY_TOPIC_UPTIME"; then echo "ok: NTFY_TOPIC_UPTIME registered"; else echo "FAIL: NTFY_TOPIC_UPTIME not in NTFY_TOPICS"; fail=1; fi

[ "$fail" = "0" ] && echo "ALL OK" || echo "FAILURES PRESENT"
exit "$fail"
