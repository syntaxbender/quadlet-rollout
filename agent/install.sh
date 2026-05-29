#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_USER="${APP_USER:-quadlet-rollout}"
PROJECT_DIR="${PROJECT_DIR:-/opt/quadlet-rollout}"
VERSION_FILE="${VERSION_FILE:-$PROJECT_DIR/global_version}"
AGENT_REPO_URL="${AGENT_REPO_URL:-https://github.com/syntaxbender/quadlet-services.git}"
SHARED_REPO_NAME="${SHARED_REPO_NAME:-quadlet-nginx-shared-repo}"
AGENT_REPO_DIR="${AGENT_REPO_DIR:-$PROJECT_DIR/repos/$SHARED_REPO_NAME}"
AGENT_ENV_FILENAME="${AGENT_ENV_FILENAME:-app.env}"
TARGET_USER="${TARGET_USER:-}"

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
  local existing

  existing="$(runuser -u "$user" -- git config --global --get-all safe.directory 2>/dev/null || true)"
  if ! printf '%s\n' "$existing" | grep -Fxq "$path"; then
    runuser -u "$user" -- git config --global --add safe.directory "$path"
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

  [[ -n "$TARGET_USER" ]] || prompt_required TARGET_USER "Kurulacak Linux kullanıcısı"

  id -u "$TARGET_USER" >/dev/null 2>&1 || die "Kullanıcı bulunamadı: $TARGET_USER"

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

  prepare_shared_repo_dir "$AGENT_REPO_DIR"
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
  require_root
  require_files
  validate_inputs
  install_agent_for_user "$TARGET_USER"
  log "Agent kurulumu tamamlandı: $TARGET_USER"
}

main "$@"
