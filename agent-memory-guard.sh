#!/bin/bash
####################################
#
# Keep runaway Claude agents from freezing the host (2026-11-18).
#
####################################
#
# WHY: 2026-11-18 18:03 a review subagent ran a mutation test (MAX_LEGS=10**9) in an
# UNLIMITED `docker run`; one python grew to ~46 GiB (24 resident + 22 swapped), swap hit
# 0 free, the kernel OOM killer shot the k8s pods (kubelet sets oom_score_adj ~1000) while the
# offender (adj 0) lived, systemd-oomd killed IntelliJ, and the box froze 12 min -> hard reset.
# `docker run` containers live in system.slice, OUTSIDE IntelliJ's scope, so a scope cap alone
# would NOT have stopped it. Two layers, both needed (mirrors the dev box's 2026-11-18 fix):
#   1. IDE scope  — MemoryMax/MemorySwapMax on snap.intellij-idea.intellij-idea-*.scope (every
#                   Claude agent, go build, vitest, chrome IntelliJ launches) + ManagedOOMPreference=avoid
#                   on it and gnome-shell, so oomd doesn't kill the desktop; at MemoryMax the kernel
#                   kills the single largest process INSIDE the scope. No MemoryHigh on purpose
#                   (sustained throttling pressure would make oomd kill the whole IDE).
#   2. docker shim — ~/.local/bin/docker (first on agents' PATH) adds --memory=8g --memory-swap=8g
#                   to `docker run|create` that has none, so a runaway dies ALONE in its own
#                   cgroup (exit 137). Fail-open; skips minikube/privileged/GPU containers.
#                   AGENT_DOCKER_MEM=16g overrides, AGENT_DOCKER_NO_LIMIT=1 bypasses.
# No root needed (user manager + ~/.local/bin). Prod is 61G with the cluster at ~25-30G, hence 20G.
#
# --install [--live] (default: files only; --live also set-property --runtime on the running scope)
# --status (exit 1 on a missing layer) · --uninstall · --dry-run
####################################
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UD="$HOME/.config/systemd/user"
SCOPE_D="$UD/snap.intellij-idea.intellij-idea-.scope.d"; SCOPE_F="$SCOPE_D/memory-cap.conf"
GNOME_D="$UD/org.gnome.Shell@ubuntu.service.d";          GNOME_F="$GNOME_D/oomd-avoid.conf"
SHIM="$HOME/.local/bin/docker"; SHIM_SRC="$SCRIPT_DIR/agent-guard/docker-shim"
CAP_MAX="${AGENT_SCOPE_MAX:-20G}"; CAP_SWAP="${AGENT_SCOPE_SWAP:-4G}"
MODE="${1:---status}"; LIVE=0; DRY=0
for a in "$@"; do case "$a" in --live) LIVE=1;; --dry-run) DRY=1;; esac; done
run() { if [ $DRY = 1 ]; then echo "DRYRUN> $*"; else "$@"; fi; }

scope_conf() { cat <<EOC
# Managed by STEP0/agent-memory-guard.sh — see that file. Mirrors the dev box (2026-11-18).
# No MemoryHigh: throttling => sustained pressure => systemd-oomd kills the whole IDE.
[Scope]
MemoryMax=$CAP_MAX
MemorySwapMax=$CAP_SWAP
ManagedOOMPreference=avoid
EOC
}
live_scope() { systemctl --user list-units --type=scope --no-legend 2>/dev/null | awk '/snap.intellij-idea/{print $1; exit}'; }

do_install() {
  [ -f "$SHIM_SRC" ] || { echo "missing $SHIM_SRC" >&2; return 1; }
  run mkdir -p "$SCOPE_D" "$GNOME_D" "$(dirname "$SHIM")"
  if [ $DRY = 1 ]; then echo "DRYRUN> write $SCOPE_F ($CAP_MAX/$CAP_SWAP), $GNOME_F, copy shim -> $SHIM"
  else
    scope_conf > "$SCOPE_F"
    printf '[Service]\nManagedOOMPreference=avoid\n' > "$GNOME_F"
    # COPY, never symlink: a dangling symlink here would break every `docker` call on the box.
    install -m 755 "$SHIM_SRC" "$SHIM"
  fi
  run systemctl --user daemon-reload 2>/dev/null || true
  if [ $LIVE = 1 ]; then
    s=$(live_scope)
    [ -n "$s" ] && run systemctl --user set-property --runtime "$s" MemoryMax="$CAP_MAX" MemorySwapMax="$CAP_SWAP" ManagedOOMPreference=avoid \
      || echo "no live IntelliJ scope (cap applies on its next launch)"
  fi
  echo "agent-memory-guard installed (scope cap $CAP_MAX/$CAP_SWAP; docker shim $SHIM). Live scopes keep the old limits until --live or an IDE restart."
}

do_status() {
  local bad=0 s mm
  s=$(live_scope)
  if [ -n "$s" ]; then
    mm=$(systemctl --user show "$s" -p MemoryMax --value 2>/dev/null)
    if [ "$mm" = infinity ] || [ -z "$mm" ]; then echo "FAIL live IntelliJ scope has NO MemoryMax ($s) — ./agent-memory-guard.sh --install --live"; bad=1
    else echo "PASS live IntelliJ scope capped: MemoryMax=$((mm/1073741824))G"; fi
  else echo "INFO no live IntelliJ scope (cap applies on next launch)"; fi
  if grep -q '^MemoryMax=' "$SCOPE_F" 2>/dev/null; then echo "PASS scope drop-in present"; else echo "FAIL scope drop-in missing ($SCOPE_F)"; bad=1; fi
  if grep -q 'ManagedOOMPreference=avoid' "$GNOME_F" 2>/dev/null; then echo "PASS gnome-shell oomd-avoid present"; else echo "FAIL gnome-shell oomd-avoid missing"; bad=1; fi
  if cmp -s "$SHIM_SRC" "$SHIM" 2>/dev/null; then echo "PASS docker shim installed and current"; else echo "FAIL docker shim missing/stale ($SHIM)"; bad=1; fi
  [ "$(command -v docker)" = "$SHIM" ] && echo "PASS shim first on PATH" || echo "WARN shim not first on this shell's PATH ($(command -v docker))"
  return $bad
}

do_uninstall() {
  run rm -f "$SCOPE_F" "$GNOME_F" "$SHIM"; run systemctl --user daemon-reload 2>/dev/null || true
  echo "removed (a running scope keeps its limits until the IDE restarts)"
}

case "$MODE" in
  --install) do_install;; --status) do_status;; --uninstall) do_uninstall;;
  --dry-run) DRY=1; do_install;;
  *) sed -n '2,/^####/p' "$0" | sed -n '1,40p' >&2; exit 2;;
esac
