#!/bin/bash
# desktop-settings.sh — replay the GNOME desktop preferences this box is set up with.
#
# WHY THIS EXISTS
# ---------------
# Everything else in STEP0 rebuilds the *platform*; nothing rebuilds the **desk**. GNOME
# keybindings live in per-user dconf (~/.config/dconf/user) — a binary blob that is in no
# git repo, is NOT swept by the weekly DR archive (backup-minikube-mnt.sh takes /mnt +
# nginx + STEP0 + qcguy + ~/wd-backup, not ~/.config), and is destroyed by a boot-disk
# swap. So after GM9000-MIGRATION.md or DEVBOX-9100PRO-MIGRATION.md you come back to a
# working cluster and a keyboard that has forgotten every shortcut you built muscle
# memory for. This script is the declarative record, so re-arming it is one command.
#
# Deliberately NOT wired into restore-scratch.sh. dconf writes need a live D-Bus session
# bus, which a bare-metal restore (headless, over SSH, often pre-login) does not have —
# calling it there would fail-or-silently-no-op on every run. It is a post-install manual
# step; the migration runbooks say so.
#
# Scope note: this is per-USER state (no sudo, no /etc). Run it as the desktop user, in
# a graphical session. Settings take effect immediately — no logout, no gnome-shell restart.
#
# Usage:
#   ./desktop-settings.sh              # apply (idempotent — only writes what differs)
#   ./desktop-settings.sh --status     # read-only: current vs desired, exit 1 if drifted
#   ./desktop-settings.sh --dry-run    # print the gsettings calls, change nothing
set -u

MODE="apply"
case "${1:-}" in
  --status)  MODE="status" ;;
  --dry-run) MODE="dryrun" ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  "")        ;;
  *)         echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
esac

RC=0
ok()   { printf '  . %s\n' "$1"; }
chg()  { printf '  ~ %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# The settings.  One per line: <schema> <key> <desired-GVariant-value>
#
# The value is the FULL desired value, not a delta — declaring the whole list is
# idempotent and makes "what will this key end up as" readable at a glance. It must be
# byte-identical to what `gsettings get` prints (GNOME serializes string arrays as
# ['a', 'b'] — single quotes, comma-SPACE), or --status will report permanent drift.
#
# Conflict-checked against GNOME 50 / Ubuntu 26.04 defaults on 2026-08-07:
#   <Super>e         free.
#   <Super>r         free.
#   <Super><Shift>s  free. NOTE <Super>s ALONE is toggle-quick-settings — that is a
#                    different binding and is deliberately left untouched.
# Re-check with:  gsettings list-recursively | grep -i '<Super>x'
# ---------------------------------------------------------------------------
read -r -d '' SETTINGS <<'EOF'
# Win+E -> Files (Nautilus, home folder).  The "home" media key IS the file-manager
# action; there is no need for a custom-keybinding entry running `nautilus`.
org.gnome.settings-daemon.plugins.media-keys|home|['<Super>e']

# Win+R -> terminal (resolves via xdg-terminal-exec -> Ptyxis, the 25.10+ Ubuntu default).
# Ctrl+Alt+T is kept as the second binding: it is what every Ubuntu doc on the internet
# tells you to press, and losing it costs nothing.
org.gnome.settings-daemon.plugins.media-keys|terminal|['<Super>r', '<Primary><Alt>t']

# Win+Shift+S -> screenshot overlay, which opens in area-select mode.  Closest GNOME has
# to the Windows behaviour; note GNOME both saves to ~/Pictures/Screenshots AND copies to
# the clipboard, where Windows only does the clipboard.  Print is kept as the second
# binding (it is the GNOME default and other people's fingers expect it).
org.gnome.shell.keybindings|show-screenshot-ui|['Print', '<Shift><Super>s']

# --- add further settings below; keep them grouped and commented like the above ---
EOF

# ---------------------------------------------------------------------------
# Preflight.  Two ways this silently does nothing, both worth failing loudly on.
# ---------------------------------------------------------------------------
if ! command -v gsettings >/dev/null 2>&1; then
  warn "gsettings not found — not a GNOME box. Nothing to do."
  exit 0
fi

# dconf writes go over D-Bus. Over SSH with no session bus, `gsettings set` either errors
# or writes into a throwaway bus that evaporates — the classic "it said nothing and
# nothing changed". Only matters when we are actually writing.
if [ "$MODE" = "apply" ] && [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  warn "no DBUS_SESSION_BUS_ADDRESS — dconf writes will not stick."
  warn "Run this from a terminal inside the graphical session (not a bare SSH shell)."
  exit 1
fi

echo "desktop-settings.sh [$MODE] — $(whoami)@$(hostname)"

while IFS='|' read -r schema key want; do
  # skip blanks and comment lines
  case "${schema// /}" in ""|\#*) continue ;; esac

  if ! gsettings writable "$schema" "$key" >/dev/null 2>&1; then
    warn "$schema $key — schema/key not present on this GNOME version (skipped)"
    RC=1
    continue
  fi

  have="$(gsettings get "$schema" "$key" 2>/dev/null)"
  if [ "$have" = "$want" ]; then
    ok "$key = $want"
    continue
  fi

  case "$MODE" in
    status)
      chg "$key  is: $have   want: $want"
      RC=1
      ;;
    dryrun)
      chg "$key  is: $have"
      printf '      gsettings set %s %s "%s"\n' "$schema" "$key" "$want"
      ;;
    apply)
      if gsettings set "$schema" "$key" "$want" 2>/dev/null; then
        chg "$key  $have -> $want"
      else
        warn "$schema $key — set FAILED (value rejected?)"
        RC=1
      fi
      ;;
  esac
done <<< "$SETTINGS"

if [ "$MODE" = "status" ] && [ "$RC" -ne 0 ]; then
  echo "drift detected — run ./desktop-settings.sh to re-apply"
fi
exit "$RC"
