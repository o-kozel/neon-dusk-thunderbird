#!/usr/bin/env bash
# Undo install.sh: remove the chrome/ symlink (only if it points at this
# repo), optionally restore a pre-existing backup, and strip the managed
# user.js pref block. Linux only, mirrors install.sh's detection logic.
#
# Usage: ./uninstall.sh [--profile <dir>] [--yes] [--all] \
#                        [--no-restore-backup] [--revoke-flatpak-override] [--help]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
  echo "error: lib.sh not found next to uninstall.sh ($SCRIPT_DIR/lib.sh) — repo/package looks incomplete." >&2
  exit 1
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PROFILE_OVERRIDE=""
ASSUME_YES=0
DO_ALL=0
RESTORE_BACKUP=1
REVOKE_OVERRIDE=0

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

Options:
  --profile <dir>            Only uninstall from this profile (skips scanning).
  --yes, -y                   Don't prompt when multiple installed profiles
                               are found; requires --all in that case.
  --all                        Uninstall from every profile this theme is
                               found installed in, without prompting.
  --no-restore-backup          Don't restore a chrome.bak-* backup even if
                               one exists (leaves no chrome/ at all).
  --revoke-flatpak-override     Also revoke the Flatpak sandbox filesystem
                               grant this repo was given (left in place by
                               default — see below).
  --help                       Show this help.

Only ever touches a profile's chrome/ if it's a symlink pointing at this
repo — a real chrome/ directory, or a symlink pointing somewhere else, is
always left alone. The Flatpak sandbox override is left granted by default
since it's a scoped, read-only, harmless-to-keep permission; the exact
manual command to revoke it is printed at the end either way.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { log_err "--profile needs an argument"; exit 1; }
      PROFILE_OVERRIDE="$2"; shift 2 ;;
    --yes|-y)
      ASSUME_YES=1; shift ;;
    --all)
      DO_ALL=1; shift ;;
    --no-restore-backup)
      RESTORE_BACKUP=0; shift ;;
    --revoke-flatpak-override)
      REVOKE_OVERRIDE=1; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      log_err "Unknown option: $1"
      usage
      exit 1 ;;
  esac
done

# ---- locate chrome/ (same self-discovery as install.sh) ----
if [[ -d "$SCRIPT_DIR/chrome" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [[ -d "$SCRIPT_DIR/../chrome" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  log_err "Couldn't find a chrome/ folder next to this script or one level up."
  exit 1
fi
REPO_CHROME="$REPO_ROOT/chrome"

# profile_matches_repo <abspath> — true if this profile's chrome/ links to
# this repo, or its user.js still carries our managed-pref marker.
profile_matches_repo() {
  local profile="$1"
  is_symlink_to "$profile/chrome" "$REPO_CHROME" && return 0
  [[ -f "$profile/user.js" ]] && grep -qF "$BEGIN_MARKER" "$profile/user.js" 2>/dev/null && return 0
  return 1
}

# ---- gather targets: source<TAB>name<TAB>abspath per entry ----
declare -a TARGETS=()

if [[ -n "$PROFILE_OVERRIDE" ]]; then
  [[ -d "$PROFILE_OVERRIDE" ]] || { log_err "Profile dir not found: $PROFILE_OVERRIDE"; exit 1; }
  src="native"
  if [[ "$PROFILE_OVERRIDE" == *"/.var/app/"* ]]; then
    src="flatpak:$(printf '%s\n' "$PROFILE_OVERRIDE" | sed -n 's#.*/\.var/app/\([^/]*\)/\.thunderbird/.*#\1#p')"
  fi
  TARGETS+=("$src"$'\t'"(explicit)"$'\t'"$PROFILE_OVERRIDE")
else
  while IFS=$'\t' read -r src name abspath is_default; do
    [[ -n "$abspath" ]] || continue
    profile_matches_repo "$abspath" || continue
    TARGETS+=("$src"$'\t'"$name"$'\t'"$abspath")
  done < <(list_candidates)

  if [[ "${#TARGETS[@]}" -eq 0 ]]; then
    log_info "Theme not installed in any detected Thunderbird profile — nothing to do."
    exit 0
  fi

  if [[ "${#TARGETS[@]}" -gt 1 && "$DO_ALL" != "1" ]]; then
    if [[ -t 0 && "$ASSUME_YES" != "1" ]]; then
      log_info "Theme is installed in multiple profiles:"
      idx=0
      for t in "${TARGETS[@]}"; do
        idx=$((idx + 1))
        IFS=$'\t' read -r src name abspath <<< "$t"
        printf '  [%d] %-18s (%s)  %s\n' "$idx" "$name" "$src" "$abspath"
      done
      choice=""
      while true; do
        read -r -p "Select profile to uninstall from [1-${#TARGETS[@]}], or 'a' for all: " choice
        if [[ "$choice" == "a" || "$choice" == "A" ]]; then
          DO_ALL=1; break
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#TARGETS[@]} )); then
          TARGETS=("${TARGETS[$((choice - 1))]}")
          break
        fi
        log_warn "Enter a number between 1 and ${#TARGETS[@]}, or 'a' for all."
      done
    else
      log_err "Theme is installed in multiple profiles; re-run with --all to uninstall from every one, or --profile <dir> to pick one:"
      for t in "${TARGETS[@]}"; do
        IFS=$'\t' read -r src name abspath <<< "$t"
        log_err "  $name ($src) at $abspath"
      done
      exit 1
    fi
  fi
fi

# ---- act on each target ----
for t in "${TARGETS[@]}"; do
  IFS=$'\t' read -r src name abspath <<< "$t"
  log_info ""
  log_info "== $name ($src) at $abspath =="

  flavor="native"; app_id=""
  if [[ "$src" == flatpak:* ]]; then
    flavor="flatpak"; app_id="${src#flatpak:}"
  fi

  target="$abspath/chrome"
  removed=0
  if is_symlink_to "$target" "$REPO_CHROME"; then
    rm "$target"
    log_info "Removed chrome/ symlink."
    removed=1
  elif [[ -L "$target" ]]; then
    other="$(readlink -f "$target" 2>/dev/null || readlink "$target")"
    log_info "Not touching chrome/ — it links to $other, not this repo."
  elif [[ -e "$target" ]]; then
    log_info "Not touching chrome/ — it's a real directory/file, not a symlink."
  else
    log_info "No chrome/ present."
  fi

  if [[ "$removed" == "1" ]]; then
    backup="$(latest_backup_for "$abspath")"
    if [[ -n "$backup" && "$RESTORE_BACKUP" == "1" ]]; then
      mv "$backup" "$target"
      log_info "Restored backup: $backup -> $target"
    elif [[ -n "$backup" ]]; then
      log_info "A backup exists at $backup but was left alone (--no-restore-backup)."
    fi
  fi

  remaining_backups=("$abspath"/chrome.bak-*)
  if [[ -e "${remaining_backups[0]}" ]]; then
    log_info "Note: backup dir(s) still present in $abspath, not auto-deleted:"
    for b in "${remaining_backups[@]}"; do
      log_info "  ${b##*/}"
    done
  fi

  userjs="$abspath/user.js"
  if [[ -f "$userjs" ]] && grep -qF "$BEGIN_MARKER" "$userjs" 2>/dev/null; then
    strip_managed_userjs_block "$userjs"
    log_info "Removed managed prefs from user.js."
  fi

  if [[ "$flavor" == "flatpak" && -n "$app_id" ]]; then
    if [[ "$REVOKE_OVERRIDE" == "1" ]] && command -v flatpak >/dev/null 2>&1; then
      revoke_flatpak_override "$REPO_ROOT" "$app_id"
      log_info "Revoked Flatpak sandbox override for $app_id."
    else
      log_info "Flatpak sandbox override left in place. To revoke it manually:"
      log_info "  flatpak override --user --nofilesystem=$(readlink -f "$REPO_ROOT") $app_id"
    fi
  fi
done

log_info ""
log_info "Done. Fully quit and relaunch Thunderbird for this to take effect."
