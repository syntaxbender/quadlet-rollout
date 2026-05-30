#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/quadlet-agent/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "missing config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quadlet-agent"
SEEN_FILE="$STATE_DIR/seen_version"
mkdir -p "$STATE_DIR"

require_var() {
  local k="$1"
  [[ -n "${!k:-}" ]] || { echo "missing config var: $k" >&2; exit 1; }
}

require_var GLOBAL_VERSION_FILE
require_var REPO_URL
require_var REPO_DIR

[[ -r "$GLOBAL_VERSION_FILE" ]] || { echo "global version unreadable: $GLOBAL_VERSION_FILE" >&2; exit 1; }
NEW_VERSION="$(tr -d '[:space:]' < "$GLOBAL_VERSION_FILE")"
[[ -n "$NEW_VERSION" ]] || { echo "global version empty" >&2; exit 0; }

OLD_VERSION=""
if [[ -f "$SEEN_FILE" ]]; then
  OLD_VERSION="$(tr -d '[:space:]' < "$SEEN_FILE")"
fi

if [[ "$NEW_VERSION" == "$OLD_VERSION" ]]; then
  exit 0
fi

REPO_PARENT="$(dirname "$REPO_DIR")"
LOCK_FILE="${REPO_LOCK_FILE:-$REPO_PARENT/.quadlet-nginx-shared-repo.lock}"
if [[ ! -d "$REPO_PARENT" ]]; then
  echo "repo parent directory missing: $REPO_PARENT" >&2
  exit 1
fi

if [[ ! -e "$LOCK_FILE" ]]; then
  if ! touch "$LOCK_FILE" 2>/dev/null; then
    echo "lock file missing and cannot be created: $LOCK_FILE (rerun installer)" >&2
    exit 1
  fi
fi

if git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$REPO_DIR"; then
  :
else
  git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
fi

# Prefer write-open; if permissions are tighter than expected, fallback to read-open.
if [[ -w "$LOCK_FILE" ]]; then
  exec 9>>"$LOCK_FILE"
elif [[ -r "$LOCK_FILE" ]]; then
  exec 9<"$LOCK_FILE"
else
  echo "cannot open lock file: $LOCK_FILE (check permissions or rerun installer)" >&2
  exit 1
fi

if ! flock -w 60 9; then
  echo "failed to acquire repo lock: $LOCK_FILE" >&2
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone "$REPO_URL" "$REPO_DIR"
  git -C "$REPO_DIR" config core.sharedRepository group || true
else
  git -C "$REPO_DIR" fetch --all --prune
  git -C "$REPO_DIR" pull --ff-only
fi

SRC_USER_DIR="$REPO_DIR/quadlet-containers/$USER"
DST_HOME="$HOME"

# User dizini repoda yoksa sessizce atla (isteğe uygun davranış).
if [[ ! -d "$SRC_USER_DIR" ]]; then
  echo "skip: user dir not found in repo: $SRC_USER_DIR" >&2
  exit 0
fi

# Symlink kapatma: kaynak ağaçta symlink varsa deploy reddedilir.
if find "$SRC_USER_DIR" -type l -print -quit | grep -q .; then
  echo "symlink is not allowed under $SRC_USER_DIR" >&2
  exit 1
fi

copied_any=0
declare -A restart_unit_seen=()
restart_units=()

add_restart_unit() {
  local unit="$1"
  [[ -n "$unit" ]] || return 0
  if [[ -z "${restart_unit_seen[$unit]:-}" ]]; then
    restart_unit_seen["$unit"]=1
    restart_units+=("$unit")
  fi
}

ensure_env_file_near_unit() {
  local unit_path="$1"
  local env_file env_real

  case "$unit_path" in
    *.container) env_file="${unit_path%.container}.env" ;;
    *.service) env_file="${unit_path%.service}.env" ;;
    *) return 0 ;;
  esac

  env_real="$(realpath -m "$env_file")"
  case "$env_real" in
    "$HOME_REAL"/*) ;;
    *)
      echo "refusing env path escape: $unit_path -> $env_real" >&2
      exit 1
      ;;
  esac

  if [[ ! -e "$env_real" ]]; then
    : > "$env_real"
    chmod 0600 "$env_real"
    echo "created empty env file: $env_real" >&2
  fi
}

HOME_REAL="$(realpath -m "$DST_HOME")"

while IFS= read -r -d '' src_path; do
  rel_path="${src_path#"$SRC_USER_DIR"/}"
  target_path="$DST_HOME/$rel_path"

  # Hedefin kullanıcı home dışına taşmadığını kesin doğrula.
  target_real="$(realpath -m "$target_path")"
  case "$target_real" in
    "$HOME_REAL"/*) ;;
    *)
      echo "refusing path escape: $src_path -> $target_real" >&2
      exit 1
      ;;
  esac

  if [[ -d "$src_path" ]]; then
    mkdir -p "$target_real"
    continue
  fi

  case "$src_path" in
    *.container|*.service|*.timer)
      mkdir -p "$(dirname "$target_real")"
      cp -f "$src_path" "$target_real"
      copied_any=1

      case "$target_real" in
        "$HOME_REAL/.config/containers/systemd/"*.container)
          unit_name="$(basename "${target_real%.container}").service"
          add_restart_unit "$unit_name"
          ensure_env_file_near_unit "$target_real"
          ;;
        "$HOME_REAL/.config/systemd/user/"*.service|"$HOME_REAL/.config/systemd/user/"*.timer)
          unit_name="$(basename "$target_real")"
          add_restart_unit "$unit_name"
          ensure_env_file_near_unit "$target_real"
          ;;
      esac
      ;;
    *)
      ;;
  esac
done < <(find "$SRC_USER_DIR" -mindepth 1 -print0)

if [[ "$copied_any" -eq 0 ]]; then
  echo "no whitelisted quadlet files found under $SRC_USER_DIR" >&2
fi

systemctl --user daemon-reload
for unit_name in "${restart_units[@]}"; do
  systemctl --user restart "$unit_name"
done

printf '%s\n' "$NEW_VERSION" > "$SEEN_FILE"
