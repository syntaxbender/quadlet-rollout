#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WEBHOOK_APP_DIR="$SCRIPT_DIR/webhook-app"
AGENT_DIR="$SCRIPT_DIR/agent"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

APP_USER="quadlet-rollout"
APP_UID="21001"
APP_GID="21001"

VERSION_DIR="/opt/quadlet-rollout"
VERSION_FILE="$VERSION_DIR/global_version"
WEBHOOK_UNIT_PATH="/etc/containers/systemd/quadlet-webhook.container"
WEBHOOK_SERVICE_NAME="quadlet-webhook.service"
WEBHOOK_UNIT_TEMPLATE_PATH="$TEMPLATE_DIR/quadlet-webhook.container.tmpl"
NGINX_SITE_TEMPLATE_PATH_SSL="$TEMPLATE_DIR/webhook-ingress.nginx.conf.tmpl"
NGINX_SITE_TEMPLATE_PATH_HTTP="$TEMPLATE_DIR/webhook-ingress.http-only.nginx.conf.tmpl"

NGINX_SITE_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITE_ENABLED_DIR="/etc/nginx/sites-enabled"

AGENT_USERS=()

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
  if [[ "${EUID}" -ne 0 ]]; then
    die "Bu script root olarak çalıştırılmalı. Örn: sudo ./install.sh"
  fi
}

require_files() {
  [[ -f "$WEBHOOK_APP_DIR/Containerfile" ]] || die "Eksik dosya: $WEBHOOK_APP_DIR/Containerfile"
  [[ -f "$WEBHOOK_APP_DIR/webhook.py" ]] || die "Eksik dosya: $WEBHOOK_APP_DIR/webhook.py"
  [[ -f "$AGENT_DIR/quadlet-agent.sh" ]] || die "Eksik dosya: $AGENT_DIR/quadlet-agent.sh"
  [[ -f "$AGENT_DIR/systemd-user/quadlet-agent.service" ]] || die "Eksik dosya: agent service"
  [[ -f "$AGENT_DIR/systemd-user/quadlet-agent.timer" ]] || die "Eksik dosya: agent timer"
  [[ -f "$WEBHOOK_UNIT_TEMPLATE_PATH" ]] || die "Eksik template: $WEBHOOK_UNIT_TEMPLATE_PATH"
  [[ -f "$NGINX_SITE_TEMPLATE_PATH_SSL" ]] || die "Eksik template: $NGINX_SITE_TEMPLATE_PATH_SSL"
  [[ -f "$NGINX_SITE_TEMPLATE_PATH_HTTP" ]] || die "Eksik template: $NGINX_SITE_TEMPLATE_PATH_HTTP"
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

prompt_secret_optional() {
  local __var="$1"
  local prompt="$2"
  local value
  read -r -s -p "$prompt (boş bırakılırsa otomatik üretilir): " value
  printf '\n'
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
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
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

version_ge() {
  local current="$1"
  local minimum="$2"
  [[ "$(printf '%s\n' "$minimum" "$current" | sort -V | head -n1)" == "$minimum" ]]
}

check_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release okunamıyor"
  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "Script Ubuntu için tasarlandı (algılanan: ${ID:-unknown})."
  fi

  if [[ "${VERSION_ID:-}" != "22.04" && "${VERSION_ID:-}" != "24.04" ]]; then
    warn "Resmi hedef Ubuntu 22.04/24.04 (algılanan: ${VERSION_ID:-unknown})."
    local continue_anyway
    prompt_yes_no continue_anyway "Yine de devam edilsin mi?" "n"
    [[ "$continue_anyway" == "y" ]] || exit 1
  fi
}

install_packages() {
  log "Gerekli paketler kuruluyor (podman + network/storage bağımlılıkları, nginx, git, curl, openssl)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    podman uidmap slirp4netns passt fuse-overlayfs \
    apparmor apparmor-utils \
    nginx git curl openssl
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
    podman build -t "$WEBHOOK_IMAGE" "$WEBHOOK_APP_DIR"
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

parse_agent_users() {
  local raw="$1"
  local u
  mapfile -t AGENT_USERS < <(printf '%s' "$raw" | tr ', ' '\n\n' | sed '/^$/d')
  if [[ "${#AGENT_USERS[@]}" -eq 0 ]]; then
    die "En az bir agent kullanıcısı gerekli"
  fi
  for u in "${AGENT_USERS[@]}"; do
    if ! id -u "$u" >/dev/null 2>&1; then
      die "Kullanıcı bulunamadı: $u"
    fi
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

validate_inputs() {
  [[ "$WEBHOOK_LOCAL_PORT" =~ ^[0-9]+$ ]] || die "Webhook local port sayısal olmalı"
  (( WEBHOOK_LOCAL_PORT >= 1 && WEBHOOK_LOCAL_PORT <= 65535 )) || die "Webhook local port 1-65535 aralığında olmalı"

  [[ "$TOKEN_TOLERANCE_MINUTES" =~ ^[0-9]+$ ]] || die "TOKEN_TOLERANCE_MINUTES sayısal olmalı"
  (( TOKEN_TOLERANCE_MINUTES <= 60 )) || die "TOKEN_TOLERANCE_MINUTES çok yüksek (önerilen: 0-10)"

  [[ "$SALT_SECRET" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "SALT_SECRET yalnızca [A-Za-z0-9._-] karakterleri içermeli"
}

install_agent_for_user() {
  local user="$1"
  local services="$2"
  local uid home config_path

  uid="$(id -u "$user")"
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" ]] || die "Home dizini okunamadı: $user"

  log "Agent kuruluyor: $user"
  loginctl enable-linger "$user"

  install -d -m 0755 -o "$user" -g "$user" "$home/.local/bin"
  install -d -m 0755 -o "$user" -g "$user" "$home/.config/quadlet-agent"
  install -d -m 0755 -o "$user" -g "$user" "$home/.config/systemd/user"

  install -m 0755 -o "$user" -g "$user" \
    "$AGENT_DIR/quadlet-agent.sh" "$home/.local/bin/quadlet-agent.sh"
  install -m 0644 -o "$user" -g "$user" \
    "$AGENT_DIR/systemd-user/quadlet-agent.service" "$home/.config/systemd/user/quadlet-agent.service"
  install -m 0644 -o "$user" -g "$user" \
    "$AGENT_DIR/systemd-user/quadlet-agent.timer" "$home/.config/systemd/user/quadlet-agent.timer"

  config_path="$home/.config/quadlet-agent/config"
  cat >"$config_path" <<EOF
GLOBAL_VERSION_FILE="$VERSION_FILE"
REPO_URL="$AGENT_REPO_URL"
REPO_DIR="\$HOME/$AGENT_REPO_SUBDIR"
SERVICES="$services"
EOF
  chown "$user:$user" "$config_path"
  chmod 0644 "$config_path"

  run_user_systemctl "$user" "$uid" daemon-reload
  run_user_systemctl "$user" "$uid" enable --now quadlet-agent.timer
}

collect_inputs() {
  prompt_default WEBHOOK_DOMAIN "Webhook domain" "webhook.example.com"
  prompt_default WEBHOOK_LOCAL_PORT "Webhook local port (Nginx upstream)" "18080"
  prompt_default TOKEN_TOLERANCE_MINUTES "TOKEN_TOLERANCE_MINUTES" "5"

  prompt_secret_optional SALT_SECRET "SALT_SECRET girin"
  if [[ -z "$SALT_SECRET" ]]; then
    SALT_SECRET="$(openssl rand -hex 32)"
    log "SALT_SECRET otomatik üretildi."
  fi

  prompt_yes_no BUILD_IMAGE "Webhook imajı local build edilsin mi?" "y"
  if [[ "$BUILD_IMAGE" == "y" ]]; then
    prompt_default WEBHOOK_IMAGE "Webhook image ref" "localhost/quadlet-webhook:latest"
  else
    prompt_required WEBHOOK_IMAGE "Webhook image ref (örn: ghcr.io/org/quadlet-webhook:latest)"
  fi

  prompt_yes_no CONFIGURE_NGINX "Nginx reverse proxy yapılandırılsın mı?" "y"
  if [[ "$CONFIGURE_NGINX" == "y" ]]; then
    prompt_yes_no NGINX_ENABLE_SSL "Nginx üzerinde SSL/TLS aktif edilsin mi?" "y"
    if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
      prompt_default SSL_CERT_PATH "TLS fullchain path" "/etc/letsencrypt/live/$WEBHOOK_DOMAIN/fullchain.pem"
      prompt_default SSL_KEY_PATH "TLS private key path" "/etc/letsencrypt/live/$WEBHOOK_DOMAIN/privkey.pem"
      prompt_default ACME_CHALLENGE_ROOT "ACME challenge root" "/var/www/certbot"
    else
      SSL_CERT_PATH=""
      SSL_KEY_PATH=""
      ACME_CHALLENGE_ROOT="/var/www/certbot"
    fi
  else
    NGINX_ENABLE_SSL="n"
    SSL_CERT_PATH=""
    SSL_KEY_PATH=""
    ACME_CHALLENGE_ROOT="/var/www/certbot"
  fi

  prompt_default AGENT_REPO_URL "Agent REPO_URL" "https://github.com/org/server-quadlets.git"
  prompt_default AGENT_REPO_SUBDIR "Agent REPO_DIR alt dizini" "quadlets"

  local users_input
  prompt_required users_input "Agent kurulacak kullanıcılar (boşluk veya virgül ile ayırın)"
  parse_agent_users "$users_input"
}

summary() {
  local deploy_scheme
  if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
    deploy_scheme="https"
  else
    deploy_scheme="http"
  fi

  cat <<EOF

Kurulum tamamlandı.

Webhook:
  Domain: ${deploy_scheme}://$WEBHOOK_DOMAIN
  Quadlet unit: $WEBHOOK_UNIT_PATH
  Service: $WEBHOOK_SERVICE_NAME
  Version file: $VERSION_FILE
  Local upstream: 127.0.0.1:${WEBHOOK_LOCAL_PORT}

GitHub Actions secret:
  DEPLOY_URL=${deploy_scheme}://$WEBHOOK_DOMAIN
  DEPLOY_SALT_SECRET=$SALT_SECRET

Not:
  SALT_SECRET değeri sadece bu kurulum sırasında gösterildi.
  Kendi secret yönetim sisteminize güvenli şekilde kaydedin.
EOF
}

main() {
  require_root
  require_files
  check_os
  collect_inputs
  validate_inputs

  install_packages
  ensure_quadlet_capable_podman
  ensure_service_user
  prepare_version_file
  build_or_use_image
  write_webhook_quadlet

  if [[ "$CONFIGURE_NGINX" == "y" ]]; then
    write_nginx_site
  else
    warn "Nginx kurulumu atlandı. Webhook sadece localhost:${WEBHOOK_LOCAL_PORT} üzerinde dinliyor."
  fi

  local user services
  for user in "${AGENT_USERS[@]}"; do
    prompt_default services "$user kullanıcısı için SERVICES" "appsvc"
    install_agent_for_user "$user" "$services"
  done

  summary
}

main "$@"
