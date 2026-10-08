#!/usr/bin/env bash
# Shared Thunderbird profile detection/parsing helpers for install.sh and
# uninstall.sh. Sourced only — never executed directly. Linux only (native +
# Flatpak Thunderbird); pure bash + coreutils/awk/sed/grep, no jq/python3.
#
# Callers compute their own SCRIPT_DIR/REPO_ROOT before sourcing this file —
# everything in here is path-agnostic on purpose, so it doesn't matter
# whether it's sourced from the dev repo's assets/ layout or a release
# package's top-level layout.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib.sh is a library — source it from install.sh/uninstall.sh, don't run it directly." >&2
  exit 1
fi

BEGIN_MARKER='# >>> tb-dark-theme managed prefs >>>'
END_MARKER='# <<< tb-dark-theme managed prefs <<<'

# ---- logging ----

log_info() { printf '%s\n' "$*"; }
log_warn() { printf 'warning: %s\n' "$*" >&2; }
log_err()  { printf 'error: %s\n' "$*" >&2; }

# ---- misc ----

# looks_transient <path> — true if path lives somewhere that won't survive
# a reboot/cleanup (a symlink into it would silently break later).
looks_transient() {
  local path="$1"
  [[ "$path" =~ ^/tmp/ || "$path" =~ ^/var/tmp/ || "$path" =~ ^/dev/shm/ ]]
}

# latest_backup_for <profile_dir> — prints the most recent chrome.bak-* dir
# in the profile, if any (the timestamp format sorts lexically = chronologically).
latest_backup_for() {
  local profile="$1" latest="" d
  for d in "$profile"/chrome.bak-*; do
    [[ -e "$d" ]] || continue
    latest="$d"
  done
  [[ -n "$latest" ]] && printf '%s\n' "$latest"
}

# is_symlink_to <path> <target> — true if path is a symlink resolving to target.
is_symlink_to() {
  local path="$1" target="$2" resolved_path resolved_target
  [[ -L "$path" ]] || return 1
  resolved_path="$(readlink -f "$path" 2>/dev/null)" || return 1
  resolved_target="$(readlink -f "$target" 2>/dev/null)" || return 1
  [[ "$resolved_path" == "$resolved_target" ]]
}

# ---- Thunderbird install detection ----

detect_native_root() {
  local root="$HOME/.thunderbird"
  [[ -d "$root" ]] && printf '%s\n' "$root"
  return 0
}

# One Flatpak Thunderbird app ID per line (handles zero, one, or several —
# e.g. stable + beta installed side by side). Never fails if flatpak is absent.
detect_flatpak_app_ids() {
  command -v flatpak >/dev/null 2>&1 || return 0
  flatpak list --app --columns=application 2>/dev/null | grep -i thunderbird || true
}

flatpak_root_for() {
  local app_id="$1"
  printf '%s\n' "$HOME/.var/app/$app_id/.thunderbird"
}

# apply_flatpak_override <repo_root> <app_id> — grant the sandbox read-only
# access to the repo path. Idempotent; safe to re-run.
apply_flatpak_override() {
  local repo_root="$1" app_id="$2" abs_repo
  abs_repo="$(readlink -f "$repo_root")"
  flatpak override --user --filesystem="${abs_repo}:ro" "$app_id"
}

# revoke_flatpak_override <repo_root> <app_id> — remove just this one
# filesystem grant (never --reset, which would nuke unrelated overrides).
revoke_flatpak_override() {
  local repo_root="$1" app_id="$2" abs_repo
  abs_repo="$(readlink -f "$repo_root")"
  flatpak override --user --nofilesystem="${abs_repo}" "$app_id"
}

# ---- profiles.ini parsing ----

# parse_profiles_ini <ini_path> — emits tab-separated
#   name<TAB>abspath<TAB>is_default
# one line per [ProfileN] section that has a Path=.
parse_profiles_ini() {
  local ini="$1"
  [[ -f "$ini" ]] || return 0
  local root_dir section="" name="" is_relative="1" path="" is_default="0"
  root_dir="$(dirname "$ini")"

  _pi_flush() {
    [[ "$section" == Profile* && -n "$path" ]] || return 0
    local abs
    if [[ "$is_relative" == "1" ]]; then abs="$root_dir/$path"; else abs="$path"; fi
    printf '%s\t%s\t%s\n' "$name" "$abs" "$is_default"
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      _pi_flush
      section="${BASH_REMATCH[1]}"; name=""; is_relative="1"; path=""; is_default="0"
      continue
    fi
    [[ "$line" == *=* ]] || continue
    local key="${line%%=*}" val="${line#*=}"
    case "$key" in
      Name) name="$val" ;;
      IsRelative) is_relative="$val" ;;
      Path) path="$val" ;;
      Default) is_default="$val" ;;
    esac
  done < "$ini"
  _pi_flush
}

# get_install_default <ini_path> — cross-check helper: prints the absolute
# path of the profile any [InstallXXXX] section's Default= points at, if any
# (newer profiles.ini format; Path there is always relative to the ini's dir).
get_install_default() {
  local ini="$1"
  [[ -f "$ini" ]] || return 0
  local root_dir section="" default_rel=""
  root_dir="$(dirname "$ini")"

  _id_flush() {
    [[ "$section" == Install* && -n "$default_rel" ]] || return 0
    printf '%s\n' "$root_dir/$default_rel"
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      _id_flush
      section="${BASH_REMATCH[1]}"; default_rel=""
      continue
    fi
    [[ "$line" == *=* ]] || continue
    local key="${line%%=*}" val="${line#*=}"
    [[ "$key" == "Default" ]] && default_rel="$val"
  done < "$ini"
  _id_flush
}

# ---- candidate discovery ----

# _emit_root_candidates <source_label> <thunderbird_root>
_emit_root_candidates() {
  local source="$1" root="$2" ini found=0 install_default="" install_default_resolved=""
  ini="$root/profiles.ini"
  if [[ ! -f "$ini" ]]; then
    log_warn "Thunderbird data found at $root but no profiles.ini — installed but never launched?"
    return 0
  fi
  # The [InstallXXXX] Default= marker (newer, per-install, sometimes Locked=1)
  # is authoritative over a profile's own legacy Default=1 flag when both
  # exist and disagree — a stale/never-used profile can carry Default=1 from
  # its own initial creation while the install marker correctly points at
  # the profile actually in use.
  install_default="$(get_install_default "$ini")"
  [[ -n "$install_default" ]] && install_default_resolved="$(readlink -f "$install_default" 2>/dev/null || printf '%s' "$install_default")"
  while IFS=$'\t' read -r name abspath is_default; do
    [[ -n "$abspath" ]] || continue
    found=1
    if [[ -n "$install_default_resolved" ]]; then
      if [[ "$(readlink -f "$abspath" 2>/dev/null || printf '%s' "$abspath")" == "$install_default_resolved" ]]; then
        is_default=1
      else
        is_default=0
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$source" "$name" "$abspath" "$is_default"
  done < <(parse_profiles_ini "$ini")
  if [[ "$found" == "0" ]]; then
    log_warn "profiles.ini found at $ini but it lists no profiles — installed but never launched?"
  fi
  return 0
}

# list_candidates — emits tab-separated
#   source<TAB>name<TAB>abspath<TAB>is_default
# across native + every detected Flatpak Thunderbird install.
# source is "native" or "flatpak:<app_id>".
list_candidates() {
  local native_root
  native_root="$(detect_native_root)"
  [[ -n "$native_root" ]] && _emit_root_candidates "native" "$native_root"

  local app_id fp_root
  while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    fp_root="$(flatpak_root_for "$app_id")"
    [[ -d "$fp_root" ]] || continue
    _emit_root_candidates "flatpak:$app_id" "$fp_root"
  done < <(detect_flatpak_app_ids)
  return 0
}

# ---- profile selection ----

# _apply_selection <source_label> <abspath> — sets PROFILE/FLAVOR/APP_ID.
_apply_selection() {
  local src="$1" abspath="$2"
  PROFILE="$abspath"
  if [[ "$src" == flatpak:* ]]; then
    FLAVOR="flatpak"
    APP_ID="${src#flatpak:}"
  else
    FLAVOR="native"
    APP_ID=""
  fi
}

# select_profile — reads globals PROFILE_OVERRIDE (may be empty) and
# ASSUME_YES (0/1); sets globals PROFILE, FLAVOR ("native"|"flatpak"), APP_ID.
# Exits non-zero with an actionable message on failure to resolve one profile.
select_profile() {
  PROFILE=""; FLAVOR=""; APP_ID=""

  if [[ -n "${PROFILE_OVERRIDE:-}" ]]; then
    PROFILE="$PROFILE_OVERRIDE"
    if [[ ! -d "$PROFILE" ]]; then
      log_err "Profile dir not found: $PROFILE"
      exit 1
    fi
    if [[ ! -f "$PROFILE/prefs.js" ]]; then
      log_warn "$PROFILE doesn't look like a Thunderbird profile (no prefs.js) — proceeding anyway since --profile was given explicitly."
    fi
    if [[ "$PROFILE" == *"/.var/app/"* ]]; then
      FLAVOR="flatpak"
      APP_ID="$(printf '%s\n' "$PROFILE" | sed -n 's#.*/\.var/app/\([^/]*\)/\.thunderbird/.*#\1#p')"
      [[ -z "$APP_ID" ]] && log_warn "Couldn't infer the Flatpak app ID from --profile's path; skipping the sandbox override step."
    else
      FLAVOR="native"
    fi
    log_info "Using profile: $PROFILE ($FLAVOR)"
    return 0
  fi

  local candidates count
  candidates="$(list_candidates)"

  if [[ -z "$candidates" ]]; then
    log_err "No Thunderbird profile found (checked native ~/.thunderbird and any Flatpak Thunderbird install)."
    log_err "If Thunderbird is installed but you've never launched it, launch it once to create a profile, then re-run this script."
    log_err "If it isn't installed at all, install it first (native package, or: flatpak install flathub org.mozilla.Thunderbird)."
    exit 1
  fi

  count="$(printf '%s\n' "$candidates" | grep -c .)"

  if [[ "$count" -eq 1 ]]; then
    local src name abspath is_default
    IFS=$'\t' read -r src name abspath is_default <<< "$candidates"
    _apply_selection "$src" "$abspath"
    log_info "Found one Thunderbird profile: $name ($src) at $abspath"
    return 0
  fi

  local default_line
  default_line="$(printf '%s\n' "$candidates" | awk -F'\t' '$4=="1"{print; exit}')"

  if [[ -t 0 && "${ASSUME_YES:-0}" != "1" ]]; then
    log_info "Multiple Thunderbird profiles found:"
    local i=0 lines=() src name abspath is_default tag
    while IFS=$'\t' read -r src name abspath is_default; do
      i=$((i + 1))
      lines+=("$src"$'\t'"$name"$'\t'"$abspath"$'\t'"$is_default")
      tag=""
      [[ "$is_default" == "1" ]] && tag="  [default]"
      printf '  [%d] %-18s (%s)  %s%s\n' "$i" "$name" "$src" "$abspath" "$tag"
    done <<< "$candidates"

    local default_idx=1 j=0 l
    if [[ -n "$default_line" ]]; then
      for l in "${lines[@]}"; do
        j=$((j + 1))
        [[ "$l" == "$default_line" ]] && default_idx="$j"
      done
    fi

    local choice
    while true; do
      read -r -p "Select profile [1-$i] (default: $default_idx): " choice
      choice="${choice:-$default_idx}"
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= i )); then
        break
      fi
      log_warn "Enter a number between 1 and $i."
    done

    IFS=$'\t' read -r src name abspath is_default <<< "${lines[$((choice - 1))]}"
    _apply_selection "$src" "$abspath"
    return 0
  fi

  # Non-interactive (--yes, or stdin isn't a tty — e.g. curl | bash): require
  # an unambiguous default rather than ever guessing among several profiles.
  if [[ -n "$default_line" ]]; then
    local default_count
    default_count="$(printf '%s\n' "$candidates" | awk -F'\t' '$4=="1"' | wc -l)"
    if [[ "$default_count" -eq 1 ]]; then
      local src name abspath is_default
      IFS=$'\t' read -r src name abspath is_default <<< "$default_line"
      _apply_selection "$src" "$abspath"
      log_info "Auto-selected default profile: $name ($src) at $abspath"
      return 0
    fi
  fi

  log_err "Multiple Thunderbird profiles found and none is unambiguously the default; refusing to guess non-interactively:"
  while IFS=$'\t' read -r src name abspath is_default; do
    log_err "  $name ($src) at $abspath"
  done <<< "$candidates"
  log_err "Re-run with --profile <path> to pick one explicitly."
  exit 1
}

# ---- user.js managed-block helpers ----

# merge_managed_userjs_block <userjs_path> <key=value> [key=value...]
# Idempotently (re)writes a marker-delimited block of user_pref() lines,
# and strips any *stray* user_pref() line for the same keys living outside
# the block first, so a pre-existing hand-set value can't silently fight it.
merge_managed_userjs_block() {
  local userjs="$1"; shift
  local dir tmp scratch
  dir="$(dirname "$userjs")"
  tmp="$(mktemp "$dir/.user.js.XXXXXX")"
  scratch="${tmp}.scratch"
  # Defense in depth: no step below relies on grep/sed's own exit status to
  # decide whether to keep going (grep -v exits 1, not 0, when its *input*
  # is empty — nothing to do with success/failure of the filter — so gating
  # a subsequent mv on that via `&&` silently skips the mv under set -e
  # whenever the file happens to be empty at that point, e.g. a brand new
  # user.js's first pass). Every write below is unconditional; only the
  # final content is what matters.
  trap 'rm -f "$tmp" "$scratch"' RETURN

  if [[ -f "$userjs" ]]; then
    awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" \
      '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$userjs" > "$tmp"
  else
    : > "$tmp"
  fi

  local kv key esc
  for kv in "$@"; do
    key="${kv%%=*}"
    esc="$(printf '%s' "$key" | sed 's/[.[\*^$/]/\\&/g')"
    grep -vE "^user_pref\(\"${esc}\"" "$tmp" > "$scratch" || true
    mv "$scratch" "$tmp"
  done

  {
    cat "$tmp"
    [[ -s "$tmp" ]] && printf '\n'
    printf '%s\n' "$BEGIN_MARKER"
    for kv in "$@"; do
      printf 'user_pref("%s", %s);\n' "${kv%%=*}" "${kv#*=}"
    done
    printf '%s\n' "$END_MARKER"
  } > "$scratch"

  mv "$scratch" "$userjs"
}

# strip_managed_userjs_block <userjs_path>
# Removes exactly the marker-delimited block. Deletes the file entirely if
# nothing else remains; otherwise leaves the rest of the file untouched
# (squeezing repeated blank lines and trimming a leading/trailing blank left
# over from the block's own separator — cosmetic only, never functional).
strip_managed_userjs_block() {
  local userjs="$1"
  [[ -f "$userjs" ]] || return 0
  local dir tmp scratch
  dir="$(dirname "$userjs")"
  tmp="$(mktemp "$dir/.user.js.XXXXXX")"
  scratch="${tmp}.scratch"
  trap 'rm -f "$tmp" "$scratch"' RETURN

  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" \
    '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$userjs" | cat -s > "$tmp"
  sed -e '1{/^$/d}' -e '${/^$/d}' "$tmp" > "$scratch"
  mv "$scratch" "$tmp"

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp" "$userjs"
  else
    mv "$tmp" "$userjs"
  fi
}
