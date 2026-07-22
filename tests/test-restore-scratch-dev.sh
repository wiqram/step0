#!/bin/bash
# tests/test-restore-scratch-dev.sh — checks for restore-scratch-dev.sh:
# syntax, ensure_line idempotency (pure helper), and a full --dry-run (must
# complete with exit 0 and mutate nothing: no marker file, no ~/.profile write).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../restore-scratch-dev.sh"
fail=0
assert_eq() { # $1=actual $2=expected $3=label
  if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 — got [$1] want [$2]"; fail=1; fi
}

# 1) bash syntax
bash -n "$SCRIPT" && echo "ok: bash -n" || { echo "FAIL: bash -n"; fail=1; }

# 2) ensure_line: appends once, never duplicates (extract the helper by sourcing
#    with phases stubbed out — the script only defines functions until the phase
#    calls at the bottom, so run it in extraction mode via sed to the marker).
tmp="$(mktemp -d)"
(
  DRY_RUN=0
  # shellcheck disable=SC1090
  source <(sed -n '/^ensure_line()/,/^}/p' "$SCRIPT")
  f="$tmp/profile"
  ensure_line 'export PATH="$PATH:/x"' "$f"
  ensure_line 'export PATH="$PATH:/x"' "$f"
  echo "$(grep -c 'PATH' "$f")" > "$tmp/count"
)
assert_eq "$(cat "$tmp/count")" "1" "ensure_line is idempotent"

# 3) --dry-run: exits 0, writes no marker, leaves ~/.profile untouched.
marker="$HOME/.yolo-dev-restore-phase"
marker_before="$(cat "$marker" 2>/dev/null || echo ABSENT)"
profile_hash_before="$(md5sum "$HOME/.profile" 2>/dev/null | cut -d' ' -f1)"
if FROM_PHASE_OUT="$(bash "$SCRIPT" --dry-run --from-phase 0 2>&1)"; then
  echo "ok: --dry-run exits 0"
else
  echo "FAIL: --dry-run exited nonzero"; echo "$FROM_PHASE_OUT" | tail -5; fail=1
fi
assert_eq "$(cat "$marker" 2>/dev/null || echo ABSENT)" "$marker_before" "dry-run leaves phase marker untouched"
assert_eq "$(md5sum "$HOME/.profile" 2>/dev/null | cut -d' ' -f1)" "$profile_hash_before" "dry-run leaves ~/.profile untouched"

rm -rf "$tmp"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
