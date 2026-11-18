#!/bin/bash
# tests/test-restore-lib.sh — unit tests for restore-lib.sh pure functions.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../restore-lib.sh"
fail=0
assert_eq() { # $1=actual $2=expected $3=label
  if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi
}

# pick_latest_archive: newest by MM-DD-YY embedded in filename, NOT lexical.
sample=$(cat <<'EOF'
gs://private_cloud_backup/private-cloud-10-06-25.tgz
gs://private_cloud_backup/private-cloud-03-09-26.tgz
gs://private_cloud_backup/private-cloud-06-29-26.tgz
gs://private_cloud_backup/private-cloud-06-16-26.tgz
gs://private_cloud_backup/some-unrelated-object.txt
EOF
)
got=$(printf '%s\n' "$sample" | pick_latest_archive)
assert_eq "$got" "gs://private_cloud_backup/private-cloud-06-29-26.tgz" "pick_latest_archive picks newest by date"

# Year rollover: 01-05-27 (2027) must beat 12-31-26 (2026) despite lexical order.
roll=$(printf '%s\n' \
  "gs://b/private-cloud-12-31-26.tgz" \
  "gs://b/private-cloud-01-05-27.tgz" | pick_latest_archive)
assert_eq "$roll" "gs://b/private-cloud-01-05-27.tgz" "pick_latest_archive handles year rollover"

# manifest: 14 repos. The branches are what each repo's JENKINS JOB deploys (verified against the
# job configs in 0c01802), not whatever is checked out locally — update both together.
n=$(restore_repo_manifest | grep -c 'github.com/wiqram/')
assert_eq "$n" "14" "manifest lists 14 repos"
branch_of() { restore_repo_manifest | awk -v r="/$1 " 'index($0, r) {print $3}'; }
# spot-check the non-`main` branches: a stale one clones, builds and deploys but is missing what prod runs.
assert_eq "$(branch_of ollama)" "Claude-agent-update" "ollama pinned to its deploy branch"
assert_eq "$(branch_of Predictonomy)" "Claude-agent-updates" "Predictonomy pinned to its deploy branch (not master)"
assert_eq "$(branch_of IG-Trading-Microservices)" "Claude-agent-update" "IG-Trading-Microservices pinned to its deploy branch"
assert_eq "$(branch_of dyingpaleblue)" "main" "dyingpaleblue on main (feature branch merged)"
# the QUIET failure: a live site absent from the list is never cloned (aisucks/propinvestech, 2026-08-18)
assert_eq "$(branch_of aisucks)" "main" "aisucks present in manifest"
assert_eq "$(branch_of propinvestech)" "main" "propinvestech present in manifest"

exit $fail
