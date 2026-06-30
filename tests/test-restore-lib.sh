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

# manifest: 12 repos; spot-check the feature branch.
n=$(restore_repo_manifest | grep -c 'github.com/wiqram/')
assert_eq "$n" "12" "manifest lists 12 repos"
dpb=$(restore_repo_manifest | awk '/dyingpaleblue/{print $3}')
assert_eq "$dpb" "fix-migrate-postgres-readiness" "dyingpaleblue pinned to feature branch"

exit $fail
