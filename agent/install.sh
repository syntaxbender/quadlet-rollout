#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd /

APP_USER="${APP_USER:-quadlet-rollout}"
PROJECT_DIR="${PROJECT_DIR:-/opt/quadlet-rollout}"
VERSION_FILE="${VERSION_FILE:-$PROJECT_DIR/global_version}"
AGENT_REPO_URL="${AGENT_REPO_URL:-https://github.com/syntaxbender/quadlet-services.git}"
SHARED_REPO_NAME="${SHARED_REPO_NAME:-quadlet-nginx-shared-repo}"
AGENT_REPO_DIR="${AGENT_REPO_DIR:-$PROJECT_DIR/repos/$SHARED_REPO_NAME}"
AGENT_ENV_FILENAME="${AGENT_ENV_FILENAME:-app.env}"
TARGET_USER="${TARGET_USER:-}"
TARGET_USERS_RAW="${TARGET_USERS_RAW:-}"
TARGET_USERS=()

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

prompt_required() {
  local __var="$1"
  local prompt="$2"
  local value
  while true; do
    read -r -p "$prompt: " value
    if [[ -n "${value// }" ]]; then
      printf -v "$__var" '%s' "$value"
      return 0
    fi
  done
}

prompt_default() {
  local __var="$1"
  local prompt="$2"
  local default="$3"
  local value
  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  printf -v "$__var" '%s' "$value"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "Bu script root olarak çalıştırılmalı. Örn: sudo ./agent/install.sh"
  fi
}

require_files() {
  [[ -f "$SCRIPT_DIR/quadlet-agent.sh" ]] || die "Eksik dosya: $SCRIPT_DIR/quadlet-agent.sh"
  [[ -f "$SCRIPT_DIR/systemd-user/quadlet-agent.service" ]] || die "Eksik dosya: $SCRIPT_DIR/systemd-user/quadlet-agent.service"
  [[ -f "$SCRIPT_DIR/systemd-user/quadlet-agent.timer" ]] || die "Eksik dosya: $SCRIPT_DIR/systemd-user/quadlet-agent.timer"
}

validate_absolute_path() {
  local p="$1"
  [[ "$p" == /* ]] || die "Absolute path bekleniyor: $p"
  [[ "$p" != *".."* ]] || die "Path '..' içeremez: $p"
}

collect_inputs() {
  prompt_default PROJECT_DIR "Quadlet rollout project dizini" "$PROJECT_DIR"
  VERSION_FILE="$PROJECT_DIR/global_version"

  prompt_default AGENT_REPO_URL "Agent/Nginx ortak REPO_URL" "$AGENT_REPO_URL"
  AGENT_REPO_DIR="$PROJECT_DIR/repos/$SHARED_REPO_NAME"

  if [[ -z "${TARGET_USERS_RAW// }" ]]; then
    TARGET_USERS_RAW="$TARGET_USER"
  fi
  [[ -n "${TARGET_USERS_RAW// }" ]] || prompt_required TARGET_USERS_RAW "Kurulacak Linux kullanıcı(lar)ı (boşluk/virgül)"
}

normalize_target_users() {
  local normalized user
  declare -A seen=()

  TARGET_USERS=()
  normalized="${TARGET_USERS_RAW//,/ }"
  for user in $normalized; do
    [[ -n "${seen[$user]:-}" ]] && continue
    TARGET_USERS+=("$user")
    seen[$user]=1
  done
}

run_user_systemctl() {
  local user="$1"
  local uid="$2"
  shift 2
  local runtime_dir="/run/user/$uid"

  systemctl start "user@$uid.service" >/dev/null 2>&1 || true
  runuser -u "$user" -- env \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
    systemctl --user "$@"
}

ensure_git_safe_directory() {
  local user="$1"
  local path="$2"
  local user_home
  local existing

  user_home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$user_home" ]] || die "Home dizini okunamadı: $user"

  existing="$(runuser -u "$user" -- env HOME="$user_home" XDG_CONFIG_HOME="$user_home/.config" \
    git -C "$user_home" config --global --get-all safe.directory 2>/dev/null || true)"
  if ! printf '%s\n' "$existing" | grep -Fxq "$path"; then
    runuser -u "$user" -- env HOME="$user_home" XDG_CONFIG_HOME="$user_home/.config" \
      git -C "$user_home" config --global --add safe.directory "$path"
  fi
}

prepare_shared_repo_dir() {
  local repo_dir="$1"
  local repo_parent

  repo_parent="$(dirname "$repo_dir")"
  install -d -m 0755 "$(dirname "$repo_parent")"
  install -d -m 2775 -o root -g "$APP_USER" "$repo_parent"
  install -d -m 2775 -o root -g "$APP_USER" "$repo_dir"

  chgrp -R "$APP_USER" "$repo_dir"
  find "$repo_dir" -type d -exec chmod g+rws {} +
  find "$repo_dir" -type f -exec chmod g+rw {} +

  if [[ -d "$repo_dir/.git" ]]; then
    git -C "$repo_dir" config core.sharedRepository group || true
  fi

  local existing
  existing="$(git config --system --get-all safe.directory 2>/dev/null || true)"
  if ! printf '%s\n' "$existing" | grep -Fxq "$repo_dir"; then
    git config --system --add safe.directory "$repo_dir"
  fi
}

validate_inputs() {
  validate_absolute_path "$PROJECT_DIR"
  validate_absolute_path "$VERSION_FILE"
  validate_absolute_path "$AGENT_REPO_DIR"
  [[ "${#TARGET_USERS[@]}" -gt 0 ]] || die "Kurulacak Linux kullanıcı listesi boş olamaz"

  local user
  for user in "${TARGET_USERS[@]}"; do
    id -u "$user" >/dev/null 2>&1 || die "Kullanıcı bulunamadı: $user"
  done

  if ! getent group "$APP_USER" >/dev/null 2>&1; then
    die "Grup bulunamadı: $APP_USER (önce webhook-app/install.sh veya root install.sh çalıştırılmalı)"
  fi
}

install_agent_for_user() {
  local user="$1"
  local uid home config_path env_file

  uid="$(id -u "$user")"
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" ]] || die "Home dizini okunamadı: $user"

  log "Agent kuruluyor: $user"
  loginctl enable-linger "$user"
  if id -nG "$user" | tr ' ' '\n' | grep -Fxq "$APP_USER"; then
    :
  else
    usermod -a -G "$APP_USER" "$user"
    if systemctl is-active --quiet "user@$uid.service"; then
      warn "$user için user@$uid.service yeniden başlatılıyor (yeni grup üyeliği için)"
      systemctl restart "user@$uid.service" || true
    fi
  fi

  ensure_git_safe_directory "$user" "$AGENT_REPO_DIR"

  install -d -m 0755 -o "$user" -g "$user" "$home/.local/bin"
  install -d -m 0755 -o "$user" -g "$user" "$home/.config/quadlet-agent"
  install -d -m 0755 -o "$user" -g "$user" "$home/.config/systemd/user"

  install -m 0755 -o "$user" -g "$user" \
    "$SCRIPT_DIR/quadlet-agent.sh" "$home/.local/bin/quadlet-agent.sh"
  install -m 0644 -o "$user" -g "$user" \
    "$SCRIPT_DIR/systemd-user/quadlet-agent.service" "$home/.config/systemd/user/quadlet-agent.service"
  install -m 0644 -o "$user" -g "$user" \
    "$SCRIPT_DIR/systemd-user/quadlet-agent.timer" "$home/.config/systemd/user/quadlet-agent.timer"

  config_path="$home/.config/quadlet-agent/config"
  cat >"$config_path" <<EOF_INNER
GLOBAL_VERSION_FILE="$VERSION_FILE"
REPO_URL="$AGENT_REPO_URL"
REPO_DIR="$AGENT_REPO_DIR"
EOF_INNER
  chown "$user:$user" "$config_path"
  chmod 0644 "$config_path"

  env_file="$home/.config/quadlet-agent/$AGENT_ENV_FILENAME"
  if [[ ! -f "$env_file" ]]; then
    : >"$env_file"
    chown "$user:$user" "$env_file"
    chmod 0600 "$env_file"
    log "Boş env dosyası oluşturuldu: $env_file"
  else
    log "Mevcut env dosyası korunuyor: $env_file"
  fi

  run_user_systemctl "$user" "$uid" daemon-reload
  run_user_systemctl "$user" "$uid" enable --now quadlet-agent.timer
}

main() {
  local user

  require_root
  require_files
  collect_inputs
  normalize_target_users
  validate_inputs
  prepare_shared_repo_dir "$AGENT_REPO_DIR"

  for user in "${TARGET_USERS[@]}"; do
    install_agent_for_user "$user"
  done

  log "Agent kurulumu tamamlandı: ${TARGET_USERS[*]}"
}

main "$@"
