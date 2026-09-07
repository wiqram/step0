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

APPS="qcguy predictonomy bestrentaladmin dyingpaleblue ollama yolo robin_stocks"
usage() { echo "usage: jenkins-verify <app> [--build N] [--commit SHA] [--wait] [--since]  (apps: $APPS)" >&2; exit 2; }

app="${1:-}"; [ -n "$app" ] || usage; shift || true
case "$app" in
  qcguy)           job=qcguy;                 repo=qcguy ;;
  predictonomy)    job=predictonomy;          repo=predictonomy ;;
  bestrentaladmin) job=bestrentaladmin;       repo=bestrentaladmin ;;
  dyingpaleblue)   job=dyingpaleblue;         repo=dyingpaleblue ;;
  ollama)          job=ollama;                repo=ollama ;;
  yolo)            job=trading-microservices; repo=ig-trading-microservices ;;
  robin_stocks)    job=robin_stocks;          repo=robin_stocks ;;   # own job, own rollout, downstream of every parent build
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
  echo "jenkins-verify: that is the number your next trigger should produce." >&2
  echo "  After  jenkins-deploy $app,  verify it with:" >&2
  echo "    jenkins-verify $app --build <that number> --commit HEAD --wait" >&2
  echo "  Passing it back with --build is REQUIRED: without it this tool resolves the" >&2
  echo "  job's latest build, which right after a trigger is still the PREVIOUS one." >&2
  exit 0
fi

explicit_build=1
t0=$(python3 -c 'import time;print(int(time.time()*1000))')
if [ -z "$build" ] && [ -n "${JENKINS_VERIFY_FIXTURE:-}" ]; then build=0; explicit_build=0; fi
if [ -z "$build" ]; then
  explicit_build=0
  # A trigger that has been ACCEPTED but not STARTED has no build object yet, so the
  # job's lastBuild is still the previous build — failure mode 1 from this tool's own
  # header, reached from inside the tool. With --wait, sit through the queue and follow
  # the build that actually starts.
  qtries=0
  while : ; do
    js0=$(curl -s "$J/job/$job/api/json?tree=inQueue,nextBuildNumber,lastBuild%5Bnumber,building%5D")
    inq=$(printf '%s' "$js0" | python3 -c 'import sys,json;print("1" if json.load(sys.stdin).get("inQueue") else "0")')
    build=$(printf '%s' "$js0" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("lastBuild");print(d["number"] if d else "")')
    bldg=$(printf '%s' "$js0" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("lastBuild") or {};print("1" if d.get("building") else "0")')
    if [ "$dowait" = 1 ] && { [ "$inq" = 1 ] || [ "$bldg" = 1 ]; }; then
      qtries=$((qtries+1)); [ "$qtries" -gt 180 ] && { echo "jenkins-verify: still queued/building after ~30min" >&2; break; }
      sleep 10; continue
    fi
    if [ "$dowait" != 1 ] && [ "$inq" = 1 ]; then
      echo "jenkins-verify: VERDICT: UNKNOWN — a build of '$job' is QUEUED and has not started."
      echo "  The latest build object (#$build) is therefore NOT the one you just triggered."
      echo "  Re-run with --wait, or name it: jenkins-verify $app --build <n> --commit ... "
      exit 1
    fi
    break
  done
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

# A build that had already FINISHED before this command started cannot be one this
# command's caller just triggered. Answering about it is how "NOT DEPLOYED" gets said
# about the previous build -- and, pointed the other way, how an older SUCCESS that
# happens to contain your commit reads as DEPLOYED while your real build is still running.
# Only refuse when the build was not named explicitly: --build N means "I mean THIS one".
if [ "$explicit_build" = 0 ]; then
  ended=$(printf '%s' "$js" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("building"): print(0)
else:
    ts, du = d.get("timestamp"), d.get("duration")
    print((ts + du) if isinstance(ts, int) and isinstance(du, int) else 0)
')
  if [ "${ended:-0}" -gt 0 ] && [ "$ended" -lt "$t0" ]; then
    echo "  VERDICT: UNKNOWN — build #$build finished before this check started, so it"
    echo "  cannot be a build you just triggered. This tool will not judge your deploy"
    echo "  by a build that predates the question."
    echo "  Name the build you mean:  jenkins-verify $app --build <n> --commit $commit"
    echo "  (jenkins-verify $app --since, run BEFORE triggering, prints that number.)"
    exit 1
  fi
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "  --commit must run inside the project's git repo" >&2; exit 1; }
me=$(git rev-parse --verify "$commit^{commit}" 2>/dev/null) || { echo "  cannot resolve '$commit' in this repo" >&2; exit 1; }

if [ -z "$shas" ]; then
  echo "  VERDICT: UNKNOWN — no checkout of '$repo' found in build #$build."
  echo "  (An empty sha would otherwise print exactly like a mismatch — the vacuous check.)"
  exit 1
fi

total=0; yes=0; missing=0; unrelated=0
for s in $shas; do
  total=$((total+1))
  if git cat-file -e "${s}^{commit}" 2>/dev/null; then
    # A commit sharing NO history with the built revision is from a DIFFERENT REPO --
    # easy to hit here, because a parent repo with a submodule remote configured can
    # resolve the submodule's shas locally. Without this, such a commit reports a
    # confident "NOT DEPLOYED (the build predates it)", which is the exact class of
    # wrong-but-well-formed answer this tool exists to prevent.
    if ! git merge-base "$me" "$s" >/dev/null 2>&1; then unrelated=$((unrelated+1)); continue; fi
    if git merge-base --is-ancestor "$me" "$s" 2>/dev/null; then yes=$((yes+1)); fi
  else
    missing=$((missing+1))
    echo "  note: built sha $(printf '%.12s' "$s") is not in your clone — run 'git fetch' and retry"
  fi
done

if [ "$unrelated" -gt 0 ] && [ "$unrelated" -eq "$total" ]; then
  echo "  VERDICT: UNKNOWN — $(printf '%.12s' "$me") shares no history with anything job '$job' builds."
  echo "  That commit belongs to a different repository. Did you mean a different app?"
  echo "  (a submodule commit can resolve here while belonging to another repo's history)"
  exit 1
fi
echo "  commit $(printf '%.12s' "$me") is an ancestor of $yes of $total checkout(s)"
[ "$unrelated" -gt 0 ] && { echo "  VERDICT: UNKNOWN — $unrelated checkout(s) share no history with your commit"; exit 1; }
[ "$missing" -gt 0 ] && { echo "  VERDICT: UNKNOWN — $missing built sha(s) unfetched"; exit 1; }
if   [ "$yes" -eq "$total" ]; then echo "  VERDICT: DEPLOYED"; exit 0
elif [ "$yes" -eq 0 ];        then echo "  VERDICT: NOT DEPLOYED — build #$build predates your commit"; exit 1
else echo "  VERDICT: PARTIAL — stages built different revisions (a push landed mid-build); re-deploy"; exit 1
fi
