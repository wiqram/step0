#!/bin/bash
# Unit test for devbox-jenkins-verify.sh — verdict logic only, no live Jenkins.
#
# The fixture JSON reproduces the SHAPE of a real response, captured from
# trading-microservices #2157 and predictonomy #256: `actions[]` entries of
# _class hudson.plugins.git.util.BuildData, each with `remoteUrls` and a
# `lastBuiltRevision.SHA1`. That build genuinely had FOUR checkouts — the app repo
# three times (one per stage, at three different revisions) plus wiqram/vault.git.
# Only the SHA1s are substituted, for commits this test creates, so the ancestry
# assertions are real git ancestry rather than string matching.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../devbox-jenkins-verify.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
ok(){ echo "ok: $1"; }
no(){ echo "FAIL: $1"; fail=1; }

# --- a repo with a known chain: c1 -> c2 -> c3 ------------------------------
repo="$tmp/repo"; mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
for n in 1 2 3; do
  echo "$n" > "$repo/f"; git -C "$repo" add f
  git -C "$repo" commit -q -m "c$n"
  eval "c$n=$(git -C "$repo" rev-parse HEAD)"
done

fixture() { # $1..$n = SHA1s for the app repo; always appends a vault checkout
  { printf '{"building":false,"result":"SUCCESS","actions":['
    sep=""
    for s in "$@"; do
      printf '%s{"_class":"hudson.plugins.git.util.BuildData","remoteUrls":["https://github.com/wiqram/IG-Trading-Microservices.git"],"lastBuiltRevision":{"SHA1":"%s","branch":[{"SHA1":"%s","name":"refs/remotes/origin/Claude-agent-update"}]}}' "$sep" "$s" "$s"
      sep=","
    done
    # the second repo every job on this Jenkins also builds — must never be ancestry-checked
    printf '%s{"_class":"hudson.plugins.git.util.BuildData","remoteUrls":["https://github.com/wiqram/vault.git"],"lastBuiltRevision":{"SHA1":"d91b86cbe70f1111111111111111111111111111","branch":[{"SHA1":"d91b86cbe70f1111111111111111111111111111","name":"main"}]}}' "$sep"
    printf ']}'
  } > "$tmp/j.json"
}

run(){ ( cd "$repo" && JENKINS_VERIFY_FIXTURE="$tmp/j.json" bash "$SCRIPT" yolo --commit "$1" 2>/dev/null ); }

# --- all stages contain the commit -> DEPLOYED ------------------------------
fixture "$c3" "$c3" "$c3"
out="$(run "$c1")"; rc=$?
case "$out" in *"VERDICT: DEPLOYED"*) [ $rc -eq 0 ] && ok "deployed (exit 0)" || no "deployed but exit $rc";; *) no "expected DEPLOYED, got: $out";; esac

# --- build predates the commit -> NOT DEPLOYED ------------------------------
fixture "$c1" "$c1" "$c1"
out="$(run "$c3")"; rc=$?
case "$out" in *"VERDICT: NOT DEPLOYED"*) [ $rc -ne 0 ] && ok "not deployed (non-zero exit)" || no "not-deployed but exit 0";; *) no "expected NOT DEPLOYED, got: $out";; esac

# --- a push landed mid-build: stages differ -> PARTIAL -----------------------
# The third verdict is the one that reports SUCCESS while half the change is live.
fixture "$c1" "$c3" "$c3"
out="$(run "$c2")"; rc=$?
case "$out" in *"VERDICT: PARTIAL"*) [ $rc -ne 0 ] && ok "partial (non-zero exit)" || no "partial but exit 0";; *) no "expected PARTIAL, got: $out";; esac

# --- the other repo is never mistaken for yours -----------------------------
# Only the vault checkout is present, so there is no checkout of the caller's repo:
# the honest answer is UNKNOWN, never a verdict derived from another project's sha.
{ printf '{"building":false,"result":"SUCCESS","actions":[{"_class":"hudson.plugins.git.util.BuildData","remoteUrls":["https://github.com/wiqram/vault.git"],"lastBuiltRevision":{"SHA1":"d91b86cbe70f1111111111111111111111111111","branch":[{"SHA1":"d91b86cbe70f1111111111111111111111111111","name":"main"}]}}]}'; } > "$tmp/j.json"
out="$(run "$c1")"; rc=$?
case "$out" in *"VERDICT: UNKNOWN"*) [ $rc -ne 0 ] && ok "unknown when no checkout of this repo (non-zero exit)" || no "unknown but exit 0";; *) no "expected UNKNOWN, got: $out";; esac

# --- a built sha absent from the clone is UNKNOWN, never NOT DEPLOYED --------
# Distinguishing "your commit is not in it" from "I could not look" is the point.
fixture "0123456789abcdef0123456789abcdef01234567"
out="$(run "$c1")"; rc=$?
case "$out" in *"VERDICT: UNKNOWN"*) [ $rc -ne 0 ] && ok "unfetched built sha -> UNKNOWN, not a false negative" || no "unknown but exit 0";; *) no "expected UNKNOWN for unfetched sha, got: $out";; esac

# --- a commit from ANOTHER repo is UNKNOWN, never NOT DEPLOYED ---------------
# Real case: the yolo job's app repo has a submodule whose remote is configured in the
# parent clone, so a submodule sha RESOLVES locally while belonging to a different
# history. Before this guard the tool reported a confident
# "NOT DEPLOYED — the build predates your commit", which is false in the worst way:
# it names a cause. An unrelated history shares no merge-base, which is the discriminant.
git -C "$repo" checkout -q --orphan other
echo x > "$repo/g"; git -C "$repo" add g; git -C "$repo" commit -q -m "unrelated"
foreign=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q master 2>/dev/null || git -C "$repo" checkout -q -
fixture "$c1" "$c2" "$c3"
out="$(run "$foreign")"; rc=$?
case "$out" in
  *"VERDICT: UNKNOWN"*) [ $rc -ne 0 ] && ok "foreign-repo commit -> UNKNOWN, not a false NOT DEPLOYED" || no "unknown but exit 0" ;;
  *"NOT DEPLOYED"*)     no "REGRESSION: a foreign commit reported NOT DEPLOYED (the defect this guards)" ;;
  *)                    no "expected UNKNOWN for a foreign commit, got: $out" ;;
esac

# --- a build that FINISHED BEFORE the check started is UNKNOWN ---------------
# Observed live: `--since` then deploy then `--commit HEAD --wait` inspected the
# PREVIOUS build and said "NOT DEPLOYED — build #124 predates your commit". The queued
# build had no build object yet, so the job's latest build was still the old one. The
# same resolution pointed the other way returns DEPLOYED about a build that is not yours,
# which is the dangerous direction. A build that ended before we started asking cannot be
# the one the caller just triggered.
stale() { # build a fixture that finished an hour ago
  ts=$(( ($(date +%s) - 3600) * 1000 ))
  { printf '{"building":false,"result":"SUCCESS","timestamp":%s,"duration":1000,"actions":[' "$ts"
    printf '{"_class":"hudson.plugins.git.util.BuildData","remoteUrls":["https://github.com/wiqram/IG-Trading-Microservices.git"],"lastBuiltRevision":{"SHA1":"%s","branch":[{"SHA1":"%s","name":"b"}]}}' "$1" "$1"
    printf ']}'
  } > "$tmp/j.json"
}
stale "$c3"
out="$(run "$c1")"; rc=$?     # c1 IS in c3: without the guard this returns DEPLOYED
case "$out" in
  *"VERDICT: UNKNOWN"*) [ $rc -ne 0 ] && ok "build older than the question -> UNKNOWN" || no "unknown but exit 0" ;;
  *"VERDICT: DEPLOYED"*) no "REGRESSION: judged the deploy by a build that predates the question" ;;
  *) no "expected UNKNOWN for a stale build, got: $out" ;;
esac

# --- a FAILED build is never DEPLOYED, however good the ancestry -------------
# Observed live: `--build 2158 --commit <sha>` printed `status: FAILURE`, then
# `VERDICT: DEPLOYED`, because the commit WAS in the tree that build checked out.
# #2158 failed at Build App Images; nothing reached prod. Ancestry answers "was my
# commit in the tree the build READ", never "did it ship" — the result gates the verdict.
failed_build() {
  { printf '{"building":false,"result":"FAILURE","actions":['
    printf '{"_class":"hudson.plugins.git.util.BuildData","remoteUrls":["https://github.com/wiqram/IG-Trading-Microservices.git"],"lastBuiltRevision":{"SHA1":"%s","branch":[{"SHA1":"%s","name":"b"}]}}' "$1" "$1"
    printf ']}'
  } > "$tmp/j.json"
}
failed_build "$c3"
out="$(run "$c1")"; rc=$?     # c1 IS an ancestor of c3 — ancestry alone would say DEPLOYED
case "$out" in
  *"VERDICT: DEPLOYED"*) no "REGRESSION: called a FAILED build DEPLOYED (the false green)" ;;
  *"VERDICT: NOT DEPLOYED"*) [ $rc -ne 0 ] && ok "FAILURE build -> NOT DEPLOYED despite good ancestry" || no "right verdict, exit 0" ;;
  *"VERDICT: UNKNOWN"*) [ $rc -ne 0 ] && ok "FAILURE build -> refused a deployed verdict" || no "right verdict, exit 0" ;;
  *) no "expected a non-DEPLOYED verdict for a FAILED build, got: $out" ;;
esac

exit $fail
