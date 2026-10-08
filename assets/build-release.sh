#!/usr/bin/env bash
# Build a slim, distributable end-user package: chrome/ (fonts pruned to
# just what's referenced), install.sh/uninstall.sh/lib.sh, a short
# end-user README, and LICENSE — zipped into dist/. Dev-only tool; assumes
# git and zip are present. Never touches the working tree, only reads it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log_info() { printf '%s\n' "$*"; }
log_warn() { printf 'warning: %s\n' "$*" >&2; }
log_err()  { printf 'error: %s\n' "$*" >&2; }

command -v zip >/dev/null 2>&1 || { log_err "zip is required to build a release (not found in PATH)."; exit 1; }

VERSION=""
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || true)"
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
    log_warn "Working tree has uncommitted changes — the version string will be marked -dirty."
  fi
fi
VERSION="${VERSION:-$(date +%Y%m%d)}"
PKG="thunderbird-dark-theme-${VERSION}"

STAGE_ROOT="$REPO_ROOT/dist/.stage"
STAGE="$STAGE_ROOT/$PKG"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE/chrome/modules" "$STAGE/chrome/icons" "$STAGE/chrome/fonts/Inter-4.1/web"

# ---- chrome/ (allow-list, not exclude-list — a new dev-only file can never
# leak into a release by accident; globs auto-include future new modules/icons) ----
cp "$REPO_ROOT/chrome/userChrome.css"  "$STAGE/chrome/"
cp "$REPO_ROOT/chrome/userContent.css" "$STAGE/chrome/"
cp "$REPO_ROOT/chrome/tokens.css"      "$STAGE/chrome/"
cp "$REPO_ROOT"/chrome/modules/*.css   "$STAGE/chrome/modules/"
cp "$REPO_ROOT"/chrome/icons/*.svg     "$STAGE/chrome/icons/"
cp "$REPO_ROOT/chrome/icons/ICONS.md"  "$STAGE/chrome/icons/"

# Fonts pruned to exactly what tokens.css's @font-face references, plus the
# upstream license — same relative paths tokens.css already uses, so no CSS
# changes are needed.
cp "$REPO_ROOT/chrome/fonts/Inter-4.1/LICENSE.txt" "$STAGE/chrome/fonts/Inter-4.1/"
cp "$REPO_ROOT/chrome/fonts/Inter-4.1/web/InterVariable.woff2" \
   "$REPO_ROOT/chrome/fonts/Inter-4.1/web/InterVariable-Italic.woff2" \
   "$STAGE/chrome/fonts/Inter-4.1/web/"

# ---- installer + shared lib ----
cp "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" "$SCRIPT_DIR/lib.sh" "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"

# ---- docs ----
if [[ ! -f "$REPO_ROOT/docs/RELEASE-README.md" ]]; then
  log_err "Missing $REPO_ROOT/docs/RELEASE-README.md — can't build a release without the end-user README."
  exit 1
fi
cp "$REPO_ROOT/docs/RELEASE-README.md" "$STAGE/README.md"

if [[ ! -f "$REPO_ROOT/LICENSE" ]]; then
  log_err "Missing $REPO_ROOT/LICENSE."
  exit 1
fi
cp "$REPO_ROOT/LICENSE" "$STAGE/LICENSE"

# ---- safety net: every fonts/ url() the staged tokens.css references must
# actually exist in the staged tree, or the prune above has drifted from
# what tokens.css expects — fail loudly rather than ship a broken font. ----
missing=0
while IFS= read -r rel; do
  [[ -f "$STAGE/chrome/$rel" ]] || { log_err "Staged tokens.css references $rel but it wasn't copied."; missing=1; }
done < <(grep -o 'url("fonts/[^"]*")' "$STAGE/chrome/tokens.css" | sed -E 's/url\("(fonts\/[^"]*)"\)/\1/')
if [[ "$missing" == "1" ]]; then
  log_err "Aborting — fix the font allow-list above before releasing."
  exit 1
fi

# ---- zip (top-level folder inside, so unzip doesn't spill into the cwd) ----
mkdir -p "$REPO_ROOT/dist"
ZIP_PATH="$REPO_ROOT/dist/${PKG}.zip"
rm -f "$ZIP_PATH"
( cd "$STAGE_ROOT" && zip -rq -X "$ZIP_PATH" "$PKG/" )
rm -rf "$STAGE_ROOT"

log_info "Built $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))"
if command -v sha256sum >/dev/null 2>&1; then
  log_info "$(sha256sum "$ZIP_PATH")"
fi
