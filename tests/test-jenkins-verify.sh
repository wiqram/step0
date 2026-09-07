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

exit $fail
