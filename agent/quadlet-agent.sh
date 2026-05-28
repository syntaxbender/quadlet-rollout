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
require_var SERVICES

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

if [[ ! -d "$REPO_DIR/.git" ]]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
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

while IFS= read -r -d '' src_path; do
  rel_path="${src_path#"$SRC_USER_DIR"/}"
  target_path="$DST_HOME/$rel_path"

  # Hedefin kullanıcı home dışına taşmadığını kesin doğrula.
  target_real="$(realpath -m "$target_path")"
  home_real="$(realpath -m "$DST_HOME")"
  case "$target_real" in
    "$home_real"/*) ;;
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
      ;;
    *)
      ;;
  esac
done < <(find "$SRC_USER_DIR" -mindepth 1 -print0)

if [[ "$copied_any" -eq 0 ]]; then
  echo "no whitelisted quadlet files found under $SRC_USER_DIR" >&2
fi

systemctl --user daemon-reload
for svc in $SERVICES; do
  systemctl --user restart "$svc"
done

printf '%s\n' "$NEW_VERSION" > "$SEEN_FILE"
