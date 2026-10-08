#!/usr/bin/env bash
# Install this theme into a Thunderbird profile: symlinks chrome/, sets the
# required about:config pref via user.js, and (for Flatpak installs) grants
# the sandbox override needed to see the repo. Linux only, native + Flatpak.
# Safe to re-run any time — every step is idempotent.
#
# Usage: ./install.sh [--profile <dir>] [--yes] [--dev] [--help]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
  echo "error: lib.sh not found next to install.sh ($SCRIPT_DIR/lib.sh) — repo/package looks incomplete." >&2
  exit 1
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PROFILE_OVERRIDE=""
ASSUME_YES=0
DEV_MODE=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --profile <dir>   Use this Thunderbird profile directory instead of
                     auto-detecting one.
  --yes, -y          Don't prompt; auto-pick the default profile when
                     several are found (fails if that's ambiguous).
  --dev              Also enable the Browser Toolbox prefs
                     (devtools.chrome.enabled / devtools.debugger.remote-enabled)
                     — only useful if you're going to hack on the theme itself.
  --help             Show this help.

With no options, the script auto-detects your Thunderbird install (native
and/or Flatpak) and profile, symlinks this repo's chrome/ folder in, sets
the one required about:config pref, and — for a Flatpak install — grants
the sandbox the read-only filesystem access it needs to see this repo.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { log_err "--profile needs an argument"; exit 1; }
      PROFILE_OVERRIDE="$2"; shift 2 ;;
    --yes|-y)
      ASSUME_YES=1; shift ;;
    --dev)
      DEV_MODE=1; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      log_err "Unknown option: $1"
      usage
      exit 1 ;;
  esac
done

# ---- locate chrome/ (self-discovering: release layout, then dev-repo layout) ----
# Release package: install.sh sits next to chrome/. Dev repo: install.sh
# lives in assets/, chrome/ is one level up. Same script file works in both.
if [[ -d "$SCRIPT_DIR/chrome" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [[ -d "$SCRIPT_DIR/../chrome" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  log_err "Couldn't find a chrome/ folder next to this script or one level up."
  log_err "Expected either <script-dir>/chrome (release package) or <script-dir>/../chrome (dev repo)."
  exit 1
fi
REPO_CHROME="$REPO_ROOT/chrome"

if looks_transient "$REPO_ROOT"; then
  log_warn "This repo appears to live under a temporary directory ($REPO_ROOT)."
  log_warn "The symlink this script creates will break once that's cleaned up or you reboot."
  if [[ "$ASSUME_YES" != "1" && -t 0 ]]; then
    read -r -p "Continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 1; }
  fi
fi

# ---- select profile ----
select_profile   # reads PROFILE_OVERRIDE/ASSUME_YES, sets PROFILE/FLAVOR/APP_ID

# ---- symlink chrome/ (idempotent: no-op / relink / backup+link) ----
TARGET="$PROFILE/chrome"
if is_symlink_to "$TARGET" "$REPO_CHROME"; then
  log_info "chrome/ already linked correctly: $TARGET -> $REPO_CHROME"
elif [[ -L "$TARGET" ]]; then
  old="$(readlink -f "$TARGET" 2>/dev/null || readlink "$TARGET")"
  ln -sfn "$REPO_CHROME" "$TARGET"
  log_info "Relinked $TARGET -> $REPO_CHROME (was pointing at $old)"
elif [[ -e "$TARGET" ]]; then
  backup="$PROFILE/chrome.bak-$(date +%Y%m%d-%H%M%S)"
  mv "$TARGET" "$backup"
  ln -sfn "$REPO_CHROME" "$TARGET"
  log_info "Backed up existing chrome/ to $backup, then linked $TARGET -> $REPO_CHROME"
else
  ln -sfn "$REPO_CHROME" "$TARGET"
  log_info "Linked $TARGET -> $REPO_CHROME"
fi

# ---- prefs via user.js ----
USERJS="$PROFILE/user.js"
PREFS=("toolkit.legacyUserProfileCustomizations.stylesheets=true")
if [[ "$DEV_MODE" == "1" ]]; then
  PREFS+=("devtools.chrome.enabled=true" "devtools.debugger.remote-enabled=true")
fi
merge_managed_userjs_block "$USERJS" "${PREFS[@]}"
log_info "Wrote ${#PREFS[@]} pref(s) to $USERJS"

# ---- Flatpak sandbox override ----
if [[ "$FLAVOR" == "flatpak" && -n "$APP_ID" ]]; then
  if command -v flatpak >/dev/null 2>&1; then
    apply_flatpak_override "$REPO_ROOT" "$APP_ID"
    log_info "Granted Flatpak sandbox read-only access to $REPO_ROOT for $APP_ID"
  else
    log_warn "flatpak command not found, but this profile is under a Flatpak data dir."
    log_warn "Run this manually once flatpak is available:"
    log_warn "  flatpak override --user --filesystem=$(readlink -f "$REPO_ROOT"):ro $APP_ID"
  fi
fi

cat <<'EOF'

Done. Now:
  1. Fully quit Thunderbird — Ctrl+Q, and check your system tray/dock; some
     desktops minimize Thunderbird there instead of closing it.
  2. Relaunch Thunderbird. There is no hot reload — CSS only loads on start.
EOF
