#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_USER="${APP_USER:-quadlet-rollout}"
PROJECT_DIR="${PROJECT_DIR:-/opt/quadlet-rollout}"
VERSION_FILE="${VERSION_FILE:-$PROJECT_DIR/global_version}"
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
NGINX_ROLLOUT_CERTBOT_BIN="${NGINX_ROLLOUT_CERTBOT_BIN:-/usr/bin/certbot}"
NGINX_ROLLOUT_ENABLE_TIMER="${NGINX_ROLLOUT_ENABLE_TIMER:-y}"

NGINX_ROLLOUT_SCRIPT_SRC="$SCRIPT_DIR/nginx-rollout.sh"
NGINX_ROLLOUT_SERVICE_SRC="$SCRIPT_DIR/systemd/nginx-rollout.service"
NGINX_ROLLOUT_TIMER_SRC="$SCRIPT_DIR/systemd/nginx-rollout.timer"
NGINX_ROLLOUT_SCRIPT_DST="/usr/local/bin/nginx-rollout.sh"
NGINX_ROLLOUT_ENV_DIR="/etc/quadlet-rollout"
NGINX_ROLLOUT_ENV_PATH="$NGINX_ROLLOUT_ENV_DIR/nginx-rollout.env"
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
  validate_absolute_path "$NGINX_ROLLOUT_REPO_DIR"
  validate_absolute_path "$NGINX_ROLLOUT_ACME_ROOT"
  validate_absolute_path "$NGINX_ROLLOUT_STATE_FILE"
  validate_absolute_path "$NGINX_ROLLOUT_CERTBOT_BIN"
  validate_repo_relative_path "$NGINX_ROLLOUT_HTTP_DIR"
  validate_repo_relative_path "$NGINX_ROLLOUT_HTTPS_DIR"
  validate_repo_relative_path "$NGINX_ROLLOUT_CERT_BUNDLES_DIR"

  getent group "$APP_USER" >/dev/null 2>&1 || die "Grup bulunamadı: $APP_USER"
}

install_nginx_rollout_agent() {
  log "Nginx+Certbot rollout agent kuruluyor (root systemd timer)..."

  prepare_shared_repo_dir "$NGINX_ROLLOUT_REPO_DIR"

  install -m 0755 "$NGINX_ROLLOUT_SCRIPT_SRC" "$NGINX_ROLLOUT_SCRIPT_DST"
  install -m 0644 "$NGINX_ROLLOUT_SERVICE_SRC" "$NGINX_ROLLOUT_SERVICE_DST"
  install -m 0644 "$NGINX_ROLLOUT_TIMER_SRC" "$NGINX_ROLLOUT_TIMER_DST"

  install -d -m 0755 "$NGINX_ROLLOUT_ENV_DIR"
  install -d -m 0755 "$NGINX_ROLLOUT_ACME_ROOT/.well-known/acme-challenge"
  install -d -m 0755 "$(dirname "$NGINX_ROLLOUT_STATE_FILE")"

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
  validate_inputs
  install_nginx_rollout_agent
  log "Nginx rollout kurulumu tamamlandı. Config: $NGINX_ROLLOUT_ENV_PATH"
}

main "$@"
