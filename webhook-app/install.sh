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
WEBHOOK_IMAGE="${WEBHOOK_IMAGE:-localhost/quadlet-webhook:latest}"
CONFIGURE_NGINX="${CONFIGURE_NGINX:-n}"
NGINX_ENABLE_SSL="${NGINX_ENABLE_SSL:-n}"
NGINX_ACTIVATE_CONFIG="${NGINX_ACTIVATE_CONFIG:-n}"
ACME_CHALLENGE_ROOT="${ACME_CHALLENGE_ROOT:-/var/www/certbot}"
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_KEY_PATH="${SSL_KEY_PATH:-}"
CERTBOT_BIN="${CERTBOT_BIN:-/usr/bin/certbot}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
CERTBOT_CERT_NAME="${CERTBOT_CERT_NAME:-}"
SALT_SECRET="${SALT_SECRET:-}"
CHECK_TOKEN="${CHECK_TOKEN:-}"
WEBHOOK_APPARMOR_PROFILE="${WEBHOOK_APPARMOR_PROFILE:-auto}"
WEBHOOK_APPARMOR_PODMAN_ARGS="${WEBHOOK_APPARMOR_PODMAN_ARGS:-}"

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

version_ge() {
  local current="$1"
  local minimum="$2"
  [[ "$(printf '%s\n' "$minimum" "$current" | sort -V | head -n1)" == "$minimum" ]]
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

collect_inputs() {
  prompt_default PROJECT_DIR "Quadlet rollout project dizini" "$PROJECT_DIR"
  VERSION_DIR="$PROJECT_DIR"
  VERSION_FILE="$VERSION_DIR/global_version"

  prompt_default WEBHOOK_DOMAIN "Webhook domain" "$WEBHOOK_DOMAIN"
  prompt_default TOKEN_TOLERANCE_MINUTES "TOKEN_TOLERANCE_MINUTES" "$TOKEN_TOLERANCE_MINUTES"

  prompt_yes_no CONFIGURE_NGINX "Nginx reverse proxy yapılandırılsın mı?" "$CONFIGURE_NGINX"
  if [[ "$CONFIGURE_NGINX" == "y" ]]; then
    prompt_yes_no NGINX_ACTIVATE_CONFIG "Oluşturulan Nginx config otomatik aktive edilsin mi?" "$NGINX_ACTIVATE_CONFIG"
    prompt_yes_no NGINX_ENABLE_SSL "Nginx üzerinde SSL/TLS aktif edilsin mi?" "$NGINX_ENABLE_SSL"
  else
    NGINX_ACTIVATE_CONFIG="n"
    NGINX_ENABLE_SSL="n"
  fi
}

collect_missing_inputs() {
  local existing_salt=""
  if [[ -f "$WEBHOOK_UNIT_PATH" ]]; then
    existing_salt="$(sed -n 's/^Environment=SALT_SECRET=//p' "$WEBHOOK_UNIT_PATH" | head -n1 || true)"
  fi

  if [[ -n "$SALT_SECRET" ]]; then
    warn "SALT_SECRET manuel verilmiş; bu değer kullanılacak."
  elif [[ -n "$existing_salt" ]]; then
    SALT_SECRET="$existing_salt"
    log "Mevcut SALT_SECRET değeri korunuyor (unit dosyasından alındı)."
  else
    SALT_SECRET="$(openssl rand -hex 32)"
    log "SALT_SECRET otomatik üretildi: $SALT_SECRET"
    warn "SALT_SECRET değerini güvenli şekilde saklayın (GitHub Actions secret vb.)."
  fi

  if [[ "$CONFIGURE_NGINX" == "y" ]]; then
    if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
      SSL_CERT_PATH="${SSL_CERT_PATH:-/etc/letsencrypt/live/$WEBHOOK_DOMAIN/fullchain.pem}"
      SSL_KEY_PATH="${SSL_KEY_PATH:-/etc/letsencrypt/live/$WEBHOOK_DOMAIN/privkey.pem}"
      ACME_CHALLENGE_ROOT="${ACME_CHALLENGE_ROOT:-/var/www/certbot}"
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

  [[ "$WEBHOOK_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "WEBHOOK_DOMAIN geçersiz formatta"
  [[ "$PROJECT_DIR" == /* ]] || die "PROJECT_DIR absolute path olmalı"
  [[ "$SALT_SECRET" =~ ^[A-Za-z0-9._-]+$ ]] || die "SALT_SECRET yalnızca [A-Za-z0-9._-] içermeli"
  [[ -z "$CHECK_TOKEN" || "$CHECK_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || die "CHECK_TOKEN yalnızca [A-Za-z0-9._-] içermeli"
  [[ "$WEBHOOK_APPARMOR_PROFILE" =~ ^[A-Za-z0-9._/-]+$ ]] || die "WEBHOOK_APPARMOR_PROFILE geçersiz formatta"

  if [[ "$CONFIGURE_NGINX" == "y" && "$NGINX_ENABLE_SSL" == "y" && "$NGINX_ACTIVATE_CONFIG" == "y" ]]; then
    [[ "$ACME_CHALLENGE_ROOT" == /* ]] || die "ACME_CHALLENGE_ROOT absolute path olmalı"
    [[ "$CERTBOT_BIN" == /* ]] || die "CERTBOT_BIN absolute path olmalı"
    [[ -z "$CERTBOT_EMAIL" || "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || \
      die "CERTBOT_EMAIL geçersiz formatta"
  fi
}

ensure_quadlet_capable_podman() {
  command -v podman >/dev/null 2>&1 || die "podman bulunamadı"

  local podman_ver
  podman_ver="$(podman version --format '{{.Version}}' 2>/dev/null || true)"
  if [[ -z "$podman_ver" ]]; then
    warn "Podman versiyonu okunamadı."
  elif ! version_ge "$podman_ver" "4.6.0"; then
    die "Quadlet için Podman >= 4.6 gerekiyor. Mevcut: $podman_ver"
  fi

  if [[ ! -x /usr/lib/systemd/system-generators/podman-system-generator ]] \
    && [[ ! -x /usr/libexec/podman/quadlet ]]; then
    die "Quadlet generator bulunamadı. Podman kurulumunu doğrulayın."
  fi
}

ensure_nginx_certbot_ready() {
  command -v nginx >/dev/null 2>&1 || die "nginx bulunamadı"

  if [[ -x "$CERTBOT_BIN" ]]; then
    return 0
  fi

  if command -v certbot >/dev/null 2>&1; then
    CERTBOT_BIN="$(command -v certbot)"
    return 0
  fi

  die "certbot bulunamadı (CERTBOT_BIN=$CERTBOT_BIN)"
}

debug_quadlet_generation_failure() {
  warn "Quadlet unit generate edilemedi: $WEBHOOK_SERVICE_NAME"
  warn "Muhtemel neden: .container syntax/unsupported key veya generator eksikliği."

  if [[ -x /usr/libexec/podman/quadlet ]]; then
    warn "Quadlet dry-run çıktısı (/usr/libexec/podman/quadlet -dryrun):"
    /usr/libexec/podman/quadlet -dryrun 2>&1 | tail -n 120 >&2 || true
  fi

  warn "Journal (quadlet/podman-system-generator) son kayıtları:"
  journalctl -b --no-pager 2>/dev/null \
    | grep -E "quadlet|podman-system-generator|$WEBHOOK_SERVICE_NAME" \
    | tail -n 120 >&2 || true
}

debug_webhook_start_failure() {
  warn "Webhook service start/restart başarısız: $WEBHOOK_SERVICE_NAME"
  warn "systemctl status çıktısı:"
  systemctl status "$WEBHOOK_SERVICE_NAME" --no-pager -l >&2 || true

  warn "journalctl -xeu çıktısı (son 120 satır):"
  journalctl -xeu "$WEBHOOK_SERVICE_NAME" --no-pager -n 120 >&2 || true

  if command -v podman >/dev/null 2>&1; then
    warn "podman ps -a (quadlet-webhook filtreli):"
    podman ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E '^quadlet-webhook($| )' >&2 || true
    warn "podman logs quadlet-webhook (varsa):"
    podman logs quadlet-webhook 2>&1 | tail -n 120 >&2 || true
  fi
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
  chown "$APP_USER:$APP_USER" "$VERSION_DIR"
  chmod 0755 "$VERSION_DIR"

  if [[ ! -f "$VERSION_FILE" ]]; then
    install -m 0644 -o "$APP_USER" -g "$APP_USER" /dev/null "$VERSION_FILE"
  else
    chown "$APP_USER:$APP_USER" "$VERSION_FILE"
    chmod 0644 "$VERSION_FILE"
  fi

  install -d -m 0755 -o "$APP_USER" -g "$APP_USER" \
    "$VERSION_DIR/status" "$VERSION_DIR/status/agents" "$VERSION_DIR/status/nginx"
}

build_or_use_image() {
  log "Webhook imajı build ediliyor: $WEBHOOK_IMAGE"
  podman build -t "$WEBHOOK_IMAGE" "$SCRIPT_DIR"
}

detect_webhook_apparmor_profile() {
  local socket_test=(
    podman run --rm
    --security-opt=no-new-privileges
    --entrypoint python3
    "$WEBHOOK_IMAGE"
    -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0", 8080))'
  )

  case "$WEBHOOK_APPARMOR_PROFILE" in
    auto)
      if "${socket_test[@]}" >/dev/null 2>&1; then
        WEBHOOK_APPARMOR_PODMAN_ARGS=""
        log "Webhook AppArmor: varsayılan profil NoNewPrivileges ile uyumlu."
        return 0
      fi

      if podman run --rm \
        --security-opt=no-new-privileges \
        --security-opt=apparmor=unconfined \
        --entrypoint python3 \
        "$WEBHOOK_IMAGE" \
        -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0", 8080))' >/dev/null 2>&1; then
        WEBHOOK_APPARMOR_PODMAN_ARGS="PodmanArgs=--security-opt=apparmor=unconfined"
        warn "Varsayılan AppArmor profili NoNewPrivileges ile socket açmayı engelliyor."
        warn "NoNewPrivileges=true korunuyor; webhook için apparmor=unconfined eklenecek."
        return 0
      fi

      die "Webhook socket testi NoNewPrivileges ile başarısız. AppArmor unconfined ile de düzelmedi."
      ;;
    default)
      WEBHOOK_APPARMOR_PODMAN_ARGS=""
      ;;
    unconfined)
      WEBHOOK_APPARMOR_PODMAN_ARGS="PodmanArgs=--security-opt=apparmor=unconfined"
      warn "WEBHOOK_APPARMOR_PROFILE=unconfined seçildi. NoNewPrivileges=true korunur, AppArmor confinement uygulanmaz."
      ;;
    *)
      WEBHOOK_APPARMOR_PODMAN_ARGS="PodmanArgs=--security-opt=apparmor=$WEBHOOK_APPARMOR_PROFILE"
      log "Webhook AppArmor profili kullanılacak: $WEBHOOK_APPARMOR_PROFILE"
      ;;
  esac
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
    "CHECK_TOKEN=$CHECK_TOKEN" \
    "TOKEN_TOLERANCE_MINUTES=$TOKEN_TOLERANCE_MINUTES" \
    "VERSION_DIR=$VERSION_DIR" \
    "WEBHOOK_APPARMOR_PODMAN_ARGS=$WEBHOOK_APPARMOR_PODMAN_ARGS"

  chmod 0644 "$WEBHOOK_UNIT_PATH"
  systemctl daemon-reload

  local load_state
  load_state="$(systemctl show -p LoadState --value "$WEBHOOK_SERVICE_NAME" 2>/dev/null || true)"
  if [[ -z "$load_state" || "$load_state" == "not-found" ]]; then
    debug_quadlet_generation_failure
    die "Unit oluşturulamadı: $WEBHOOK_SERVICE_NAME"
  fi

  local service_action="start"
  if systemctl is-active --quiet "$WEBHOOK_SERVICE_NAME"; then
    service_action="restart"
  fi

  if ! systemctl "$service_action" "$WEBHOOK_SERVICE_NAME"; then
    debug_webhook_start_failure
    die "Webhook service ${service_action} başarısız: $WEBHOOK_SERVICE_NAME"
  fi

  # Quadlet units are generated/transient; do not call "systemctl enable" on *.service.
  if ! systemctl is-active --quiet "$WEBHOOK_SERVICE_NAME"; then
    debug_webhook_start_failure
    die "Webhook service aktif değil: $WEBHOOK_SERVICE_NAME"
  fi
}

request_or_renew_webhook_cert() {
  local -a certbot_args

  install -d -m 0755 "$ACME_CHALLENGE_ROOT/.well-known/acme-challenge"

  certbot_args=(
    certonly
    --webroot
    -w "$ACME_CHALLENGE_ROOT"
    --agree-tos
    --no-eff-email
    --non-interactive
    --keep-until-expiring
    --expand
    --staple-ocsp
    -d "$WEBHOOK_DOMAIN"
  )

  if [[ -n "$CERTBOT_CERT_NAME" ]]; then
    certbot_args+=( --cert-name "$CERTBOT_CERT_NAME" )
  fi

  if [[ -n "$CERTBOT_EMAIL" ]]; then
    certbot_args+=( --email "$CERTBOT_EMAIL" )
  else
    certbot_args+=( --register-unsafely-without-email )
  fi

  log "certbot certonly: domain=$WEBHOOK_DOMAIN cert_name=${CERTBOT_CERT_NAME:-<default>} email=${CERTBOT_EMAIL:-<none>}"
  "$CERTBOT_BIN" "${certbot_args[@]}"
}

write_nginx_site() {
  local site_path="$NGINX_SITE_AVAILABLE_DIR/$WEBHOOK_DOMAIN"
  local enabled_path="$NGINX_SITE_ENABLED_DIR/$WEBHOOK_DOMAIN"
  local nginx_template="$NGINX_SITE_TEMPLATE_PATH_HTTP"
  local continue_without_cert

  if [[ "$CONFIGURE_NGINX" != "y" ]]; then
    warn "Nginx config adımı atlandı. Webhook sadece localhost:${WEBHOOK_LOCAL_PORT} üzerinde dinliyor."
    return 0
  fi

  if [[ "$NGINX_ACTIVATE_CONFIG" != "y" ]]; then
    if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
      nginx_template="$NGINX_SITE_TEMPLATE_PATH_SSL"
    fi
    log "Nginx site dosyası yazılıyor: $site_path"
    render_template \
      "$nginx_template" \
      "$site_path" \
      "WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN" \
      "ACME_CHALLENGE_ROOT=$ACME_CHALLENGE_ROOT" \
      "SSL_CERT_PATH=$SSL_CERT_PATH" \
      "SSL_KEY_PATH=$SSL_KEY_PATH" \
      "WEBHOOK_LOCAL_PORT=$WEBHOOK_LOCAL_PORT"

    warn "Nginx config oluşturuldu ama aktive edilmedi: $site_path"
    warn "Manuel aktivasyon için:"
    warn "  ln -sfn $site_path $enabled_path"
    warn "  nginx -t && systemctl reload nginx"
    return 0
  fi

  # Always activate HTTP config first so ACME webroot can be served on port 80.
  log "Nginx HTTP config aktive ediliyor (ACME hazırlığı): $site_path"
  render_template \
    "$NGINX_SITE_TEMPLATE_PATH_HTTP" \
    "$site_path" \
    "WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN" \
    "ACME_CHALLENGE_ROOT=$ACME_CHALLENGE_ROOT" \
    "SSL_CERT_PATH=$SSL_CERT_PATH" \
    "SSL_KEY_PATH=$SSL_KEY_PATH" \
    "WEBHOOK_LOCAL_PORT=$WEBHOOK_LOCAL_PORT"
  ln -sfn "$site_path" "$enabled_path"
  nginx -t
  systemctl reload nginx

  if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
    ensure_nginx_certbot_ready
    request_or_renew_webhook_cert

    if [[ ! -f "$SSL_CERT_PATH" || ! -f "$SSL_KEY_PATH" ]]; then
      warn "TLS dosyaları certbot sonrası da bulunamadı:"
      warn "  cert: $SSL_CERT_PATH"
      warn "  key : $SSL_KEY_PATH"
      prompt_yes_no continue_without_cert "HTTP config ile devam edilsin mi?" "n"
      [[ "$continue_without_cert" == "y" ]] || return 1
      return 0
    fi

    log "Nginx HTTPS config aktive ediliyor: $site_path"
    render_template \
      "$NGINX_SITE_TEMPLATE_PATH_SSL" \
      "$site_path" \
      "WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN" \
      "ACME_CHALLENGE_ROOT=$ACME_CHALLENGE_ROOT" \
      "SSL_CERT_PATH=$SSL_CERT_PATH" \
      "SSL_KEY_PATH=$SSL_KEY_PATH" \
      "WEBHOOK_LOCAL_PORT=$WEBHOOK_LOCAL_PORT"
  fi

  nginx -t
  systemctl reload nginx
}

main() {
  require_root
  require_files
  collect_inputs
  collect_missing_inputs
  validate_inputs
  ensure_quadlet_capable_podman
  ensure_service_user
  prepare_version_file
  build_or_use_image
  detect_webhook_apparmor_profile
  write_webhook_quadlet
  write_nginx_site

  log "Webhook bileşen kurulumu tamamlandı."
  log "Version file: $VERSION_FILE"
  log "Webhook service: $WEBHOOK_SERVICE_NAME"
}

main "$@"
