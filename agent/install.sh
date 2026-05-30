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

run_as_user() {
  local user="$1"
  shift
  runuser -u "$user" -- "$@"
}

user_unit_enabled_state() {
  local user="$1"
  local uid="$2"
  local unit="$3"
  local state

  state="$(run_user_systemctl "$user" "$uid" is-enabled "$unit" 2>/dev/null || true)"
  printf '%s' "${state//$'\n'/}"
}

user_unit_active_state() {
  local user="$1"
  local uid="$2"
  local unit="$3"
  local state

  state="$(run_user_systemctl "$user" "$uid" is-active "$unit" 2>/dev/null || true)"
  printf '%s' "${state//$'\n'/}"
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
  local lock_file

  repo_parent="$(dirname "$repo_dir")"
  lock_file="$repo_parent/.quadlet-nginx-shared-repo.lock"
  install -d -m 0755 "$(dirname "$repo_parent")"
  install -d -m 2775 -o root -g "$APP_USER" "$repo_parent"
  install -d -m 2775 -o root -g "$APP_USER" "$repo_dir"
  install -m 0664 -o root -g "$APP_USER" /dev/null "$lock_file"
  chown root:"$APP_USER" "$repo_parent" "$repo_dir" "$lock_file"
  chmod 2775 "$repo_parent" "$repo_dir"
  chmod 0664 "$lock_file"

  chgrp -R "$APP_USER" "$repo_dir"
  find "$repo_dir" -type d -exec chmod g+rws {} +
  find "$repo_dir" -type f -exec chmod g+rw {} +

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "g:$APP_USER:rwx" "$repo_parent" "$repo_dir" 2>/dev/null || true
    setfacl -d -m "g:$APP_USER:rwx" "$repo_parent" "$repo_dir" 2>/dev/null || true
  fi

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

prepare_global_version_file() {
  local project_parent

  project_parent="$(dirname "$PROJECT_DIR")"
  install -d -m 0755 "$project_parent"
  install -d -m 0755 -o "$APP_USER" -g "$APP_USER" "$PROJECT_DIR"
  chown "$APP_USER:$APP_USER" "$PROJECT_DIR"
  chmod 0755 "$PROJECT_DIR"
  if [[ ! -f "$VERSION_FILE" ]]; then
    install -m 0644 -o "$APP_USER" -g "$APP_USER" /dev/null "$VERSION_FILE"
  else
    chown "$APP_USER:$APP_USER" "$VERSION_FILE"
    chmod 0644 "$VERSION_FILE"
  fi

  log "Global version dosyası hazırlandı: $VERSION_FILE"
}

install_agent_for_user() {
  local user="$1"
  local uid home config_path linger_state enabled_state active_state
  local lock_file

  uid="$(id -u "$user")"
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" ]] || die "Home dizini okunamadı: $user"
  lock_file="$(dirname "$AGENT_REPO_DIR")/.quadlet-nginx-shared-repo.lock"

  log "Agent kuruluyor: $user (uid=$uid home=$home)"
  loginctl enable-linger "$user"
  linger_state="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"
  log "Linger durumu ($user): ${linger_state:-unknown}"

  if id -nG "$user" | tr ' ' '\n' | grep -Fxq "$APP_USER"; then
    log "$user zaten '$APP_USER' grubunda"
  else
    log "$user '$APP_USER' grubuna ekleniyor"
    usermod -a -G "$APP_USER" "$user"
    if systemctl is-active --quiet "user@$uid.service"; then
      warn "$user için user@$uid.service yeniden başlatılıyor (yeni grup üyeliği için)"
      systemctl restart "user@$uid.service" || true
    fi
  fi

  log "Git safe.directory kontrolü: $AGENT_REPO_DIR ($user)"
  ensure_git_safe_directory "$user" "$AGENT_REPO_DIR"

  log "Kullanıcı dizinleri hazırlanıyor ve ownership düzeltiliyor"
  install -d -m 0700 -o "$user" -g "$user" "$home/.config" "$home/.local" "$home/.local/state"
  chown -R "$user:$user" "$home/.config" "$home/.local"

  log "Kullanıcı dizinleri hazırlanıyor: $home/.local/bin ve .config yolları"
  install -d -m 0755 -o "$user" -g "$user" "$home/.local/bin"
  install -d -m 0755 -o "$user" -g "$user" "$home/.config/quadlet-agent"
  install -d -m 0755 -o "$user" -g "$user" "$home/.config/systemd/user"

  log "Agent script ve systemd user unit dosyaları kopyalanıyor"
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
  log "Config yazıldı: $config_path"
  log "Not: env dosyaları rollout sırasında unit dosyasının yanında otomatik oluşturulur"

  if run_as_user "$user" test -r "$VERSION_FILE"; then
    log "Version file erişimi OK ($user): $VERSION_FILE"
  else
    die "Version file kullanıcı tarafından okunamıyor ($user): $VERSION_FILE"
  fi

  if run_as_user "$user" test -w "$lock_file"; then
    log "Repo lock dosyası erişimi OK ($user): $lock_file"
  else
    die "Repo lock dosyası kullanıcı tarafından yazılamıyor ($user): $lock_file"
  fi

  log "User systemd daemon-reload ve timer enable --now çalıştırılıyor"
  run_user_systemctl "$user" "$uid" daemon-reload
  run_user_systemctl "$user" "$uid" enable --now quadlet-agent.timer

  enabled_state="$(user_unit_enabled_state "$user" "$uid" "quadlet-agent.timer")"
  active_state="$(user_unit_active_state "$user" "$uid" "quadlet-agent.timer")"
  log "Timer durumu ($user): enabled=$enabled_state active=$active_state"

  case "$enabled_state" in
    enabled|enabled-runtime)
      ;;
    *)
      die "Timer enable doğrulanamadı ($user): $enabled_state"
      ;;
  esac
  case "$active_state" in
    active|activating)
      ;;
    *)
      die "Timer active doğrulanamadı ($user): $active_state"
      ;;
  esac
}

main() {
  local user

  require_root
  require_files
  collect_inputs
  normalize_target_users
  validate_inputs
  prepare_global_version_file
  log "Ortak repo dizini hazırlanıyor: $AGENT_REPO_DIR"
  prepare_shared_repo_dir "$AGENT_REPO_DIR"

  for user in "${TARGET_USERS[@]}"; do
    install_agent_for_user "$user"
  done

  log "Agent kurulumu tamamlandı: ${TARGET_USERS[*]}"
}

main "$@"
