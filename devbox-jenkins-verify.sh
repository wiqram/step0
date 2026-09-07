#!/bin/bash
# jenkins-verify — answer "did MY commit actually deploy?" for a dev-box Jenkins job.
#
# WHY THIS EXISTS. Three real failure modes, all observed on this box, all of which
# produce a confident GREEN answer rather than an error:
#
#   1. `lastBuild` immediately after triggering can still be the PREVIOUS build —
#      already finished, already SUCCESS. Polling it reports a deploy that never
#      happened. Pin a build NUMBER and poll that one.
#   2. SUCCESS says nothing about WHICH revision was built. A build triggered after
#      your push can still have checked out the commit before yours.
#   3. A build has SEVERAL SCM checkouts. Every job here also checks out
#      wiqram/vault.git (pinned to a BRANCH, so it moves between builds without
#      appearing in any diff), and the yolo job checks out the app repo once per
#      stage. Taking "the" lastBuiltRevision picks the wrong repo about half the
#      time, and a push landing mid-build leaves stages on different shas — a
#      PARTIAL deploy that still reports SUCCESS.
#
# USAGE
#   jenkins-verify <app> --since              # print nextBuildNumber — pin BEFORE deploying
#   jenkins-verify <app>                      # status + revisions of the latest build
#   jenkins-verify <app> --build 2157         # ... of one specific build
#   jenkins-verify <app> --commit HEAD        # did that commit deploy? (run inside the repo)
#   jenkins-verify <app> --commit HEAD --wait # poll to completion, then check
#
# Exit: 0 = DEPLOYED (or plain status), 1 = NOT DEPLOYED / PARTIAL / UNKNOWN.
# Never prints the credential.
set -eu

APPS="qcguy predictonomy bestrentaladmin dyingpaleblue ollama yolo"
usage() { echo "usage: jenkins-verify <app> [--build N] [--commit SHA] [--wait] [--since]  (apps: $APPS)" >&2; exit 2; }

app="${1:-}"; [ -n "$app" ] || usage; shift || true
case "$app" in
  qcguy)           job=qcguy;                 repo=qcguy ;;
  predictonomy)    job=predictonomy;          repo=predictonomy ;;
  bestrentaladmin) job=bestrentaladmin;       repo=bestrentaladmin ;;
  dyingpaleblue)   job=dyingpaleblue;         repo=dyingpaleblue ;;
  ollama)          job=ollama;                repo=ollama ;;
  yolo)            job=trading-microservices; repo=ig-trading-microservices ;;
  *) echo "jenkins-verify: unknown app '$app'" >&2; usage ;;
esac

build=""; commit=""; dowait=0; since=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build)  build="${2:?--build needs a number}"; shift 2 ;;
    --commit) commit="${2:?--commit needs a rev}";  shift 2 ;;
    --wait)   dowait=1; shift ;;
    --since)  since=1;  shift ;;
    *) echo "jenkins-verify: unknown option '$1'" >&2; usage ;;
  esac
done

ENV_FILE="${JENKINS_DEPLOY_ENV:-$HOME/.jenkins-deploy-urls.env}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE" || true
[ -n "${JENKINS_CRED:-}" ] || [ -n "${JENKINS_VERIFY_FIXTURE:-}" ] || { echo "jenkins-verify: JENKINS_CRED not set (source $ENV_FILE)" >&2; exit 1; }
J="https://$JENKINS_CRED@jenkins.traderyolo.com"

if [ "$since" = 1 ]; then
  curl -s "$J/job/$job/api/json?tree=nextBuildNumber" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["nextBuildNumber"])'
  echo "jenkins-verify: pin that number BEFORE triggering; verify THAT build, not lastBuild." >&2
  exit 0
fi

if [ -z "$build" ] && [ -n "${JENKINS_VERIFY_FIXTURE:-}" ]; then build=0; fi
if [ -z "$build" ]; then
  build=$(curl -s "$J/job/$job/api/json?tree=lastBuild%5Bnumber%5D" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin).get("lastBuild");print(d["number"] if d else "")')
  [ -n "$build" ] || { echo "jenkins-verify: $job has no builds" >&2; exit 1; }
fi

# JENKINS_VERIFY_FIXTURE lets tests drive the verdict logic offline with a captured
# build response; unset in normal use, so the live path is the default path.
fetch() {
  if [ -n "${JENKINS_VERIFY_FIXTURE:-}" ]; then cat "$JENKINS_VERIFY_FIXTURE"
  else curl -s "$J/job/$job/$build/api/json"; fi
}

js=$(fetch)
printf '%s' "$js" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null || {
  echo "jenkins-verify: build #$build not readable. Jenkins keeps only the last ~10 builds —" >&2
  echo "  a 404 here is RETENTION, not a failed build, and makes the claim unfalsifiable." >&2
  exit 1; }

if [ "$dowait" = 1 ]; then
  n=0
  while printf '%s' "$js" | python3 -c 'import sys,json;sys.exit(0 if json.load(sys.stdin).get("building") else 1)'; do
    n=$((n+1)); [ "$n" -gt 120 ] && { echo "jenkins-verify: still building after ~20min; not waiting further" >&2; break; }
    sleep 10; js=$(fetch)
  done
fi

# One pass: print the human summary, and emit this project's shas on fd 3.
shas=$(printf '%s' "$js" | REPO="$repo" python3 -c '
import sys, json, os
repo = os.environ["REPO"]
d = json.load(sys.stdin)
status = "building" if d.get("building") else (d.get("result") or "UNKNOWN")
mine, other = [], []
for a in d.get("actions", []):
    r = a.get("lastBuiltRevision")
    if not r:
        continue
    url = (a.get("remoteUrls") or ["?"])[0]
    sha = r.get("SHA1") or ""
    br  = ",".join(b.get("name", "") for b in r.get("branch", []))
    (mine if repo in url.lower() else other).append((url, sha, br))
err = sys.stderr
print("  status: %s" % status, file=err)
print("  checkouts of THIS project: %d" % len(mine), file=err)
for _, s, b in mine:
    print("    %s  %s" % (s[:12], b), file=err)
for u, s, b in other:
    print("    [other repo, NOT yours — never ancestry-check this] %s  %s  %s" % (s[:12], b, u), file=err)
print("\n".join(s for _, s, _ in mine if s))
')

echo "$job #$build"
[ -n "$commit" ] || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || { echo "  --commit must run inside the project's git repo" >&2; exit 1; }
me=$(git rev-parse --verify "$commit^{commit}" 2>/dev/null) || { echo "  cannot resolve '$commit' in this repo" >&2; exit 1; }

if [ -z "$shas" ]; then
  echo "  VERDICT: UNKNOWN — no checkout of '$repo' found in build #$build."
  echo "  (An empty sha would otherwise print exactly like a mismatch — the vacuous check.)"
  exit 1
fi

total=0; yes=0; missing=0
for s in $shas; do
  total=$((total+1))
  if git cat-file -e "${s}^{commit}" 2>/dev/null; then
    if git merge-base --is-ancestor "$me" "$s" 2>/dev/null; then yes=$((yes+1)); fi
  else
    missing=$((missing+1))
    echo "  note: built sha $(printf '%.12s' "$s") is not in your clone — run 'git fetch' and retry"
  fi
done

echo "  commit $(printf '%.12s' "$me") is an ancestor of $yes of $total checkout(s)"
[ "$missing" -gt 0 ] && { echo "  VERDICT: UNKNOWN — $missing built sha(s) unfetched"; exit 1; }
if   [ "$yes" -eq "$total" ]; then echo "  VERDICT: DEPLOYED"; exit 0
elif [ "$yes" -eq 0 ];        then echo "  VERDICT: NOT DEPLOYED — build #$build predates your commit"; exit 1
else echo "  VERDICT: PARTIAL — stages built different revisions (a push landed mid-build); re-deploy"; exit 1
fi
