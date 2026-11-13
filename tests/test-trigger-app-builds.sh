#!/bin/bash
# tests/test-trigger-app-builds.sh — the FOLLOW-ON handling, network-free.
#
# What this pins is the 2026-10-16 robinstocks gap: robin_stocks is fired BY JENKINS only
# after a SUCCESSFUL trading-microservices build, the cold-boot yolo build came back
# UNSTABLE, and robinstocks then stayed absent for 28 days. So: an UNSTABLE upstream with
# no follow-on since MUST fire it; a follow-on Jenkins already ran/queued must NOT be fired
# twice; a FAILED upstream must not have the follow-on stacked on top; and the follow-on
# must run once, after the normal loop — never inside it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fail=0
assert_eq() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# robinstocks deliberately listed BEFORE yolo: only the follow-on handling puts it after.
printf 'qcguy qcguy build qcguy\nrobinstocks robin_stocks build robinstocks\nyolo trading-microservices buildWithParameters yolo\n' > "$TMP/manifest"

# ---- followon_verdict: the pure decision -----------------------------------------
# shellcheck source=/dev/null
JENKINS_DEPLOY_MANIFEST="$TMP/manifest" JENKINS_DEPLOY_ENV="$TMP/none" TAB_LIB_ONLY=1 source "$REPO/trigger-app-builds.sh"
assert_eq "$(followon_verdict UNSTABLE 2000 false 1000)" "trigger" "UNSTABLE upstream, follow-on older -> trigger (the 10-16 case)"
assert_eq "$(followon_verdict SUCCESS  2000 false 1000)" "trigger" "SUCCESS upstream but Jenkins never fired it -> trigger"
assert_eq "$(followon_verdict SUCCESS  2000 true  1000)" "fired"   "follow-on already queued -> do not double-fire"
assert_eq "$(followon_verdict SUCCESS  2000 false 3000)" "fired"   "follow-on started after upstream -> do not double-fire"
assert_eq "$(followon_verdict UNSTABLE 2000 false 0)"    "trigger" "follow-on never built -> trigger"
assert_eq "$(followon_verdict FAILURE  2000 false 1000)" "skip"    "FAILED upstream -> skip, never stack on it"
assert_eq "$(followon_verdict ABORTED  2000 false 1000)" "skip"    "ABORTED upstream -> skip"
assert_eq "$(followon_verdict ""       0    false 0)"    "skip"    "upstream with no result -> skip"

# ---- ensure_followon with Jenkins stubbed out ------------------------------------
JENKINS_CRED_VALUE="stub"; POLL_INTERVAL=0; FOLLOWON_GRACE=0
DEPLOYED=""
deploy() { DEPLOYED="${DEPLOYED}$1 "; }
run_case() {  # <upstream result> <follow-on inQueue> <follow-on ts>
  UP_RES="$1"; FO_Q="$2"; FO_TS="$3"; DEPLOYED=""
  japi() { printf '{"number":2443,"building":false,"result":"%s","timestamp":2000}' "$UP_RES"; }
  jjob() { printf '{"inQueue":%s,"lastBuild":{"timestamp":%s}}' "$FO_Q" "$FO_TS"; }
  ensure_followon robinstocks yolo >/dev/null
  echo "${DEPLOYED% }"
}
assert_eq "$(run_case UNSTABLE false 1000)" "robinstocks" "ensure_followon fires robin_stocks after an UNSTABLE yolo"
assert_eq "$(run_case SUCCESS  true  1000)" ""            "ensure_followon leaves an already-queued follow-on alone"
assert_eq "$(run_case FAILURE  false 1000)" ""            "ensure_followon does not fire on a FAILED yolo"

# ---- the loop: follow-on excluded from it, run once, after it --------------------
# No credential -> deploy() takes the legacy path (trigger only); jenkins-deploy-url.sh
# then fails locally, so nothing reaches the network. We only read the "building" order.
out="$(JENKINS_DEPLOY_MANIFEST="$TMP/manifest" JENKINS_DEPLOY_ENV="$TMP/none" THROTTLE=1 \
        bash "$REPO/trigger-app-builds.sh" 2>/dev/null | grep '^building ' | tr '\n' ' ')"
assert_eq "$out" "building qcguy building yolo building robinstocks " "robinstocks deployed exactly once, after yolo"

[ "$fail" = "0" ] && echo "ALL OK" || echo "FAILURES PRESENT"
exit "$fail"
