#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/templates"

WEBHOOK_UNIT_TEMPLATE_PATH="$TEMPLATE_DIR/quadlet-webhook.container.tmpl"
NGINX_SITE_TEMPLATE_PATH_SSL="$TEMPLATE_DIR/webhook-ingress.nginx.conf.tmpl"
NGINX_SITE_TEMPLATE_PATH_HTTP="$TEMPLATE_DIR/webhook-ingress.http-only.nginx.conf.tmpl"

WEBHOOK_UNIT_PATH="${WEBHOOK_UNIT_PATH:-/etc/containers/systemd/quadlet-webhook.container}"
WEBHOOK_SERVICE_NAME="${WEBHOOK_SERVICE_NAME:-quadlet-webhook.service}"
NGINX_SITE_AVAILABLE_DIR="${NGINX_SITE_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_SITE_ENABLED_DIR="${NGINX_SITE_ENABLED_DIR:-/etc/nginx/sites-enabled}"

APP_USER="${APP_USER:-quadlet-rollout}"
APP_UID="${APP_UID:-21001}"
APP_GID="${APP_GID:-21001}"

PROJECT_DIR="${PROJECT_DIR:-/opt/quadlet-rollout}"
VERSION_DIR="${VERSION_DIR:-$PROJECT_DIR}"
VERSION_FILE="${VERSION_FILE:-$VERSION_DIR/global_version}"

WEBHOOK_DOMAIN="${WEBHOOK_DOMAIN:-webhook.example.com}"
WEBHOOK_LOCAL_PORT="${WEBHOOK_LOCAL_PORT:-18080}"
TOKEN_TOLERANCE_MINUTES="${TOKEN_TOLERANCE_MINUTES:-5}"
BUILD_IMAGE="${BUILD_IMAGE:-y}"
WEBHOOK_IMAGE="${WEBHOOK_IMAGE:-localhost/quadlet-webhook:latest}"
CONFIGURE_NGINX="${CONFIGURE_NGINX:-n}"
NGINX_ENABLE_SSL="${NGINX_ENABLE_SSL:-n}"
NGINX_ACTIVATE_CONFIG="${NGINX_ACTIVATE_CONFIG:-n}"
ACME_CHALLENGE_ROOT="${ACME_CHALLENGE_ROOT:-/var/www/certbot}"
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_KEY_PATH="${SSL_KEY_PATH:-}"
SALT_SECRET="${SALT_SECRET:-}"

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

prompt_yes_no() {
  local __var="$1"
  local prompt="$2"
  local default="$3"
  local answer default_hint
  if [[ "$default" == "y" ]]; then
    default_hint="Y/n"
  else
    default_hint="y/N"
  fi
  while true; do
    read -r -p "$prompt [$default_hint]: " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes)
        printf -v "$__var" 'y'
        return 0
        ;;
      n|no)
        printf -v "$__var" 'n'
        return 0
        ;;
    esac
  done
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

render_template() {
  local template_path="$1"
  local output_path="$2"
  shift 2

  cp "$template_path" "$output_path"

  local kv key value escaped
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    escaped="$(escape_sed_replacement "$value")"
    sed -i "s|{{${key}}}|$escaped|g" "$output_path"
  done

  if grep -Eq '{{[A-Z0-9_]+}}' "$output_path"; then
    die "Template render hatası: $output_path içinde çözümlenmemiş placeholder var"
  fi
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "Bu script root olarak çalıştırılmalı. Örn: sudo ./webhook-app/install.sh"
  fi
}

require_files() {
  [[ -f "$SCRIPT_DIR/Containerfile" ]] || die "Eksik dosya: $SCRIPT_DIR/Containerfile"
  [[ -f "$SCRIPT_DIR/webhook.py" ]] || die "Eksik dosya: $SCRIPT_DIR/webhook.py"
  [[ -f "$WEBHOOK_UNIT_TEMPLATE_PATH" ]] || die "Eksik template: $WEBHOOK_UNIT_TEMPLATE_PATH"
  [[ -f "$NGINX_SITE_TEMPLATE_PATH_SSL" ]] || die "Eksik template: $NGINX_SITE_TEMPLATE_PATH_SSL"
  [[ -f "$NGINX_SITE_TEMPLATE_PATH_HTTP" ]] || die "Eksik template: $NGINX_SITE_TEMPLATE_PATH_HTTP"
}

collect_missing_inputs() {
  if [[ -z "$SALT_SECRET" ]]; then
    SALT_SECRET="$(openssl rand -hex 32)"
    warn "SALT_SECRET env verilmedi, otomatik üretildi. Değeri güvenli bir yere kaydet."
  fi

  if [[ "$CONFIGURE_NGINX" == "y" ]]; then
    if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
      [[ -n "$SSL_CERT_PATH" ]] || prompt_default SSL_CERT_PATH "TLS fullchain path" "/etc/letsencrypt/live/$WEBHOOK_DOMAIN/fullchain.pem"
      [[ -n "$SSL_KEY_PATH" ]] || prompt_default SSL_KEY_PATH "TLS private key path" "/etc/letsencrypt/live/$WEBHOOK_DOMAIN/privkey.pem"
      [[ -n "$ACME_CHALLENGE_ROOT" ]] || prompt_default ACME_CHALLENGE_ROOT "ACME challenge root" "/var/www/certbot"
    else
      SSL_CERT_PATH=""
      SSL_KEY_PATH=""
      ACME_CHALLENGE_ROOT="${ACME_CHALLENGE_ROOT:-/var/www/certbot}"
    fi
  fi
}

validate_inputs() {
  [[ "$WEBHOOK_LOCAL_PORT" =~ ^[0-9]+$ ]] || die "WEBHOOK_LOCAL_PORT sayısal olmalı"
  (( WEBHOOK_LOCAL_PORT >= 1 && WEBHOOK_LOCAL_PORT <= 65535 )) || die "WEBHOOK_LOCAL_PORT 1-65535 aralığında olmalı"

  [[ "$TOKEN_TOLERANCE_MINUTES" =~ ^[0-9]+$ ]] || die "TOKEN_TOLERANCE_MINUTES sayısal olmalı"
  (( TOKEN_TOLERANCE_MINUTES <= 60 )) || die "TOKEN_TOLERANCE_MINUTES çok yüksek (önerilen: 0-10)"

  [[ "$PROJECT_DIR" == /* ]] || die "PROJECT_DIR absolute path olmalı"
  [[ "$SALT_SECRET" =~ ^[A-Za-z0-9._-]+$ ]] || die "SALT_SECRET yalnızca [A-Za-z0-9._-] içermeli"
}

ensure_service_user() {
  if ! getent group "$APP_USER" >/dev/null 2>&1; then
    groupadd --system --gid "$APP_GID" "$APP_USER"
  fi

  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --uid "$APP_UID" --gid "$APP_USER" \
      --home-dir /nonexistent --shell /usr/sbin/nologin "$APP_USER"
  fi
}

prepare_version_file() {
  install -d -m 0755 -o "$APP_USER" -g "$APP_USER" "$VERSION_DIR"
  touch "$VERSION_FILE"
  chown "$APP_USER:$APP_USER" "$VERSION_FILE"
  chmod 0644 "$VERSION_FILE"
}

build_or_use_image() {
  if [[ "$BUILD_IMAGE" == "y" ]]; then
    log "Webhook imajı build ediliyor: $WEBHOOK_IMAGE"
    podman build -t "$WEBHOOK_IMAGE" "$SCRIPT_DIR"
  else
    log "Webhook için mevcut imaj kullanılacak: $WEBHOOK_IMAGE"
  fi
}

write_webhook_quadlet() {
  log "Webhook quadlet unit yazılıyor: $WEBHOOK_UNIT_PATH"
  install -d -m 0755 /etc/containers/systemd
  render_template \
    "$WEBHOOK_UNIT_TEMPLATE_PATH" \
    "$WEBHOOK_UNIT_PATH" \
    "WEBHOOK_IMAGE=$WEBHOOK_IMAGE" \
    "WEBHOOK_LOCAL_PORT=$WEBHOOK_LOCAL_PORT" \
    "SALT_SECRET=$SALT_SECRET" \
    "TOKEN_TOLERANCE_MINUTES=$TOKEN_TOLERANCE_MINUTES" \
    "VERSION_DIR=$VERSION_DIR"

  chmod 0644 "$WEBHOOK_UNIT_PATH"
  systemctl daemon-reload
  systemctl enable --now "$WEBHOOK_SERVICE_NAME"
}

write_nginx_site() {
  local site_path="$NGINX_SITE_AVAILABLE_DIR/$WEBHOOK_DOMAIN"
  local enabled_path="$NGINX_SITE_ENABLED_DIR/$WEBHOOK_DOMAIN"
  local nginx_template
  local continue_without_cert

  if [[ "$CONFIGURE_NGINX" != "y" ]]; then
    warn "Nginx config adımı atlandı. Webhook sadece localhost:${WEBHOOK_LOCAL_PORT} üzerinde dinliyor."
    return 0
  fi

  log "Nginx site dosyası yazılıyor: $site_path"

  if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
    nginx_template="$NGINX_SITE_TEMPLATE_PATH_SSL"
  else
    nginx_template="$NGINX_SITE_TEMPLATE_PATH_HTTP"
  fi

  render_template \
    "$nginx_template" \
    "$site_path" \
    "WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN" \
    "ACME_CHALLENGE_ROOT=$ACME_CHALLENGE_ROOT" \
    "SSL_CERT_PATH=$SSL_CERT_PATH" \
    "SSL_KEY_PATH=$SSL_KEY_PATH" \
    "WEBHOOK_LOCAL_PORT=$WEBHOOK_LOCAL_PORT"

  if [[ "$NGINX_ACTIVATE_CONFIG" != "y" ]]; then
    warn "Nginx config oluşturuldu ama aktive edilmedi: $site_path"
    warn "Manuel aktivasyon için:"
    warn "  ln -sfn $site_path $enabled_path"
    warn "  nginx -t && systemctl reload nginx"
    return 0
  fi

  if [[ "$NGINX_ENABLE_SSL" == "y" && ( ! -f "$SSL_CERT_PATH" || ! -f "$SSL_KEY_PATH" ) ]]; then
    warn "TLS dosyaları bulunamadı:"
    warn "  cert: $SSL_CERT_PATH"
    warn "  key : $SSL_KEY_PATH"
    prompt_yes_no continue_without_cert "Yine de Nginx config test/reload denensin mi?" "n"
    [[ "$continue_without_cert" == "y" ]] || return 0
  fi

  ln -sfn "$site_path" "$enabled_path"
  nginx -t
  systemctl reload nginx
}

main() {
  require_root
  require_files
  collect_missing_inputs
  validate_inputs
  ensure_service_user
  prepare_version_file
  build_or_use_image
  write_webhook_quadlet
  write_nginx_site

  log "Webhook bileşen kurulumu tamamlandı."
  log "Version file: $VERSION_FILE"
  log "Webhook service: $WEBHOOK_SERVICE_NAME"
}

main "$@"
