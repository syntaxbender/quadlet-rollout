#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd /

APP_USER="${APP_USER:-quadlet-rollout}"
PROJECT_DIR="${PROJECT_DIR:-/opt/quadlet-rollout}"
VERSION_FILE="${VERSION_FILE:-$PROJECT_DIR/global_version}"
STATUS_DIR="${STATUS_DIR:-$PROJECT_DIR/status}"
SHARED_REPO_NAME="${SHARED_REPO_NAME:-quadlet-nginx-shared-repo}"
NGINX_ROLLOUT_REPO_URL="${NGINX_ROLLOUT_REPO_URL:-https://github.com/syntaxbender/quadlet-services.git}"
NGINX_ROLLOUT_REPO_DIR="${NGINX_ROLLOUT_REPO_DIR:-$PROJECT_DIR/repos/$SHARED_REPO_NAME}"
NGINX_ROLLOUT_HTTP_DIR="${NGINX_ROLLOUT_HTTP_DIR:-nginx/http}"
NGINX_ROLLOUT_HTTPS_DIR="${NGINX_ROLLOUT_HTTPS_DIR:-nginx/https}"
NGINX_ROLLOUT_CERT_BUNDLES_DIR="${NGINX_ROLLOUT_CERT_BUNDLES_DIR:-nginx/cert-bundles}"
NGINX_SITE_AVAILABLE_DIR="${NGINX_SITE_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_SITE_ENABLED_DIR="${NGINX_SITE_ENABLED_DIR:-/etc/nginx/sites-enabled}"
NGINX_ROLLOUT_ACME_ROOT="${NGINX_ROLLOUT_ACME_ROOT:-/var/www/certbot}"
NGINX_ROLLOUT_STATE_FILE="${NGINX_ROLLOUT_STATE_FILE:-$PROJECT_DIR/nginx_seen_version}"
NGINX_ROLLOUT_FAILED_VERSION_FILE="${NGINX_ROLLOUT_FAILED_VERSION_FILE:-$PROJECT_DIR/nginx_failed_version}"
NGINX_ROLLOUT_STATUS_FILE="${NGINX_ROLLOUT_STATUS_FILE:-$STATUS_DIR/nginx/seen_version}"
NGINX_ROLLOUT_CERTBOT_BIN="${NGINX_ROLLOUT_CERTBOT_BIN:-/usr/bin/certbot}"
NGINX_ROLLOUT_ENABLE_TIMER="${NGINX_ROLLOUT_ENABLE_TIMER:-y}"

NGINX_ROLLOUT_SCRIPT_SRC="$SCRIPT_DIR/nginx-rollout.sh"
NGINX_ROLLOUT_SERVICE_SRC="$SCRIPT_DIR/systemd/nginx-rollout.service"
NGINX_ROLLOUT_TIMER_SRC="$SCRIPT_DIR/systemd/nginx-rollout.timer"
NGINX_ROLLOUT_SCRIPT_DST="/usr/local/bin/nginx-rollout.sh"
NGINX_ROLLOUT_ENV_DIR="${NGINX_ROLLOUT_ENV_DIR:-$PROJECT_DIR}"
NGINX_ROLLOUT_ENV_PATH="${NGINX_ROLLOUT_ENV_PATH:-$NGINX_ROLLOUT_ENV_DIR/nginx-rollout.env}"
NGINX_ROLLOUT_SERVICE_DST="/etc/systemd/system/nginx-rollout.service"
NGINX_ROLLOUT_TIMER_DST="/etc/systemd/system/nginx-rollout.timer"
CERTBOT_DEPLOY_HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/10-nginx-reload.sh"

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

prompt_default() {
  local __var="$1"
  local prompt="$2"
  local default="$3"
  local value
  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  printf -v "$__var" '%s' "$value"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "Bu script root olarak çalıştırılmalı. Örn: sudo ./nginx-rollout/install.sh"
  fi
}

require_files() {
  [[ -f "$NGINX_ROLLOUT_SCRIPT_SRC" ]] || die "Eksik dosya: $NGINX_ROLLOUT_SCRIPT_SRC"
  [[ -f "$NGINX_ROLLOUT_SERVICE_SRC" ]] || die "Eksik dosya: $NGINX_ROLLOUT_SERVICE_SRC"
  [[ -f "$NGINX_ROLLOUT_TIMER_SRC" ]] || die "Eksik dosya: $NGINX_ROLLOUT_TIMER_SRC"
}

validate_absolute_path() {
  local p="$1"
  [[ "$p" == /* ]] || die "Absolute path bekleniyor: $p"
  [[ "$p" != *".."* ]] || die "Path '..' içeremez: $p"
}

validate_repo_relative_path() {
  local rel="$1"
  [[ -n "$rel" ]] || die "Repo relative path boş olamaz"
  [[ "$rel" != /* ]] || die "Repo relative path absolute olamaz: $rel"
  [[ "$rel" != *".."* ]] || die "Repo relative path '..' içeremez: $rel"
  [[ "$rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Geçersiz karakter içeren repo relative path: $rel"
}

collect_inputs() {
  prompt_default PROJECT_DIR "Quadlet rollout project dizini" "$PROJECT_DIR"
  NGINX_ROLLOUT_ENV_DIR="$PROJECT_DIR"
  NGINX_ROLLOUT_ENV_PATH="$NGINX_ROLLOUT_ENV_DIR/nginx-rollout.env"
  VERSION_FILE="$PROJECT_DIR/global_version"
  STATUS_DIR="$PROJECT_DIR/status"
  NGINX_ROLLOUT_REPO_DIR="$PROJECT_DIR/repos/$SHARED_REPO_NAME"
  NGINX_ROLLOUT_STATE_FILE="$PROJECT_DIR/nginx_seen_version"
  NGINX_ROLLOUT_FAILED_VERSION_FILE="$PROJECT_DIR/nginx_failed_version"
  NGINX_ROLLOUT_STATUS_FILE="$STATUS_DIR/nginx/seen_version"

  prompt_default NGINX_ROLLOUT_REPO_URL "Agent/Nginx ortak REPO_URL" "$NGINX_ROLLOUT_REPO_URL"

  # Kullanıcıya sorulmadan default aktif bırakılır.
  NGINX_ROLLOUT_ENABLE_TIMER="y"
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
  validate_absolute_path "$STATUS_DIR"
  validate_absolute_path "$NGINX_ROLLOUT_REPO_DIR"
  validate_absolute_path "$NGINX_ROLLOUT_ACME_ROOT"
  validate_absolute_path "$NGINX_ROLLOUT_STATE_FILE"
  validate_absolute_path "$NGINX_ROLLOUT_FAILED_VERSION_FILE"
  validate_absolute_path "$NGINX_ROLLOUT_STATUS_FILE"
  validate_absolute_path "$NGINX_ROLLOUT_CERTBOT_BIN"
  validate_repo_relative_path "$NGINX_ROLLOUT_HTTP_DIR"
  validate_repo_relative_path "$NGINX_ROLLOUT_HTTPS_DIR"
  validate_repo_relative_path "$NGINX_ROLLOUT_CERT_BUNDLES_DIR"

  getent group "$APP_USER" >/dev/null 2>&1 || die "Grup bulunamadı: $APP_USER"
}

prepare_project_state() {
  install -d -m 0755 -o "$APP_USER" -g "$APP_USER" "$PROJECT_DIR"
  chown "$APP_USER:$APP_USER" "$PROJECT_DIR"
  chmod 0755 "$PROJECT_DIR"

  if [[ ! -f "$VERSION_FILE" ]]; then
    install -m 0644 -o "$APP_USER" -g "$APP_USER" /dev/null "$VERSION_FILE"
  else
    chown "$APP_USER:$APP_USER" "$VERSION_FILE"
    chmod 0644 "$VERSION_FILE"
  fi
}

install_nginx_rollout_agent() {
  log "Nginx+Certbot rollout agent kuruluyor (root systemd timer)..."
  local env_path_escaped

  prepare_shared_repo_dir "$NGINX_ROLLOUT_REPO_DIR"

  install -m 0755 "$NGINX_ROLLOUT_SCRIPT_SRC" "$NGINX_ROLLOUT_SCRIPT_DST"
  install -m 0644 "$NGINX_ROLLOUT_SERVICE_SRC" "$NGINX_ROLLOUT_SERVICE_DST"
  install -m 0644 "$NGINX_ROLLOUT_TIMER_SRC" "$NGINX_ROLLOUT_TIMER_DST"
  env_path_escaped="$(escape_sed_replacement "$NGINX_ROLLOUT_ENV_PATH")"
  sed -i "s|__NGINX_ROLLOUT_ENV_PATH__|$env_path_escaped|g" "$NGINX_ROLLOUT_SERVICE_DST"
  if grep -Fq "__NGINX_ROLLOUT_ENV_PATH__" "$NGINX_ROLLOUT_SERVICE_DST"; then
    die "service template render hatası: $NGINX_ROLLOUT_SERVICE_DST"
  fi

  install -d -m 0755 "$NGINX_ROLLOUT_ENV_DIR"
  install -d -m 0755 "$NGINX_ROLLOUT_ACME_ROOT/.well-known/acme-challenge"
  install -d -m 0755 "$(dirname "$NGINX_ROLLOUT_STATE_FILE")"
  install -d -m 0755 -o "$APP_USER" -g "$APP_USER" "$STATUS_DIR" "$STATUS_DIR/nginx"
  if [[ -f "$NGINX_ROLLOUT_STATE_FILE" ]]; then
    install -m 0644 -o "$APP_USER" -g "$APP_USER" "$NGINX_ROLLOUT_STATE_FILE" "$NGINX_ROLLOUT_STATUS_FILE"
    log "Mevcut nginx state ortak status alanına taşındı: $NGINX_ROLLOUT_STATUS_FILE"
  fi

  cat >"$NGINX_ROLLOUT_ENV_PATH" <<EOF_INNER
PROJECT_DIR=$PROJECT_DIR
GLOBAL_VERSION_FILE=$VERSION_FILE
REPO_URL=$NGINX_ROLLOUT_REPO_URL
REPO_DIR=$NGINX_ROLLOUT_REPO_DIR
NGINX_HTTP_DIR=$NGINX_ROLLOUT_HTTP_DIR
NGINX_HTTPS_DIR=$NGINX_ROLLOUT_HTTPS_DIR
CERT_BUNDLES_DIR=$NGINX_ROLLOUT_CERT_BUNDLES_DIR
NGINX_SITE_AVAILABLE_DIR=$NGINX_SITE_AVAILABLE_DIR
NGINX_SITE_ENABLED_DIR=$NGINX_SITE_ENABLED_DIR
ACME_CHALLENGE_ROOT=$NGINX_ROLLOUT_ACME_ROOT
STATE_FILE=$NGINX_ROLLOUT_STATE_FILE
FAILED_VERSION_FILE=$NGINX_ROLLOUT_FAILED_VERSION_FILE
STATUS_FILE=$NGINX_ROLLOUT_STATUS_FILE
CERTBOT_BIN=$NGINX_ROLLOUT_CERTBOT_BIN
EOF_INNER
  chmod 0644 "$NGINX_ROLLOUT_ENV_PATH"

  install -d -m 0755 "$(dirname "$CERTBOT_DEPLOY_HOOK_PATH")"
  cat >"$CERTBOT_DEPLOY_HOOK_PATH" <<'EOF_INNER'
#!/usr/bin/env bash
set -euo pipefail

nginx -t
systemctl reload nginx
EOF_INNER
  chmod 0755 "$CERTBOT_DEPLOY_HOOK_PATH"

  # PROJECT_DIR altında webhook'un yazdığı global_version erişimi korunmalı.
  chown "$APP_USER:$APP_USER" "$PROJECT_DIR" "$VERSION_FILE"
  chmod 0755 "$PROJECT_DIR"
  chmod 0644 "$VERSION_FILE"

  systemctl daemon-reload
  if [[ "$NGINX_ROLLOUT_ENABLE_TIMER" == "y" ]]; then
    systemctl enable --now nginx-rollout.timer
  else
    warn "Nginx rollout timer kuruldu ama aktive edilmedi."
    warn "Manuel aktivasyon için: systemctl enable --now nginx-rollout.timer"
  fi
}

main() {
  require_root
  require_files
  collect_inputs
  validate_inputs
  prepare_project_state
  install_nginx_rollout_agent
  log "Nginx rollout kurulumu tamamlandı. Config: $NGINX_ROLLOUT_ENV_PATH"
}

main "$@"
