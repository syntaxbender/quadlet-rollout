#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WEBHOOK_APP_DIR="$SCRIPT_DIR/webhook-app"
AGENT_DIR="$SCRIPT_DIR/agent"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
NGINX_ROLLOUT_DIR="$SCRIPT_DIR/nginx-rollout"

APP_USER="quadlet-rollout"
APP_UID="21001"
APP_GID="21001"

PROJECT_DIR="/opt/quadlet-rollout"
VERSION_DIR="$PROJECT_DIR"
VERSION_FILE="$VERSION_DIR/global_version"
WEBHOOK_UNIT_PATH="/etc/containers/systemd/quadlet-webhook.container"
WEBHOOK_SERVICE_NAME="quadlet-webhook.service"
WEBHOOK_UNIT_TEMPLATE_PATH="$TEMPLATE_DIR/quadlet-webhook.container.tmpl"
NGINX_SITE_TEMPLATE_PATH_SSL="$TEMPLATE_DIR/webhook-ingress.nginx.conf.tmpl"
NGINX_SITE_TEMPLATE_PATH_HTTP="$TEMPLATE_DIR/webhook-ingress.http-only.nginx.conf.tmpl"

NGINX_SITE_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITE_ENABLED_DIR="/etc/nginx/sites-enabled"

NGINX_ROLLOUT_SCRIPT_SRC="$NGINX_ROLLOUT_DIR/nginx-rollout.sh"
NGINX_ROLLOUT_SERVICE_SRC="$NGINX_ROLLOUT_DIR/systemd/nginx-rollout.service"
NGINX_ROLLOUT_TIMER_SRC="$NGINX_ROLLOUT_DIR/systemd/nginx-rollout.timer"
NGINX_ROLLOUT_SCRIPT_DST="/usr/local/bin/nginx-rollout.sh"
NGINX_ROLLOUT_ENV_DIR="/etc/quadlet-rollout"
NGINX_ROLLOUT_ENV_PATH="$NGINX_ROLLOUT_ENV_DIR/nginx-rollout.env"
NGINX_ROLLOUT_SERVICE_DST="/etc/systemd/system/nginx-rollout.service"
NGINX_ROLLOUT_TIMER_DST="/etc/systemd/system/nginx-rollout.timer"
CERTBOT_DEPLOY_HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/10-nginx-reload.sh"

AGENT_USERS=()
AGENT_ENV_FILENAME="app.env"
SHARED_REPO_NAME="quadlet-nginx-shared-repo"

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
  [[ -f "$NGINX_ROLLOUT_SCRIPT_SRC" ]] || die "Eksik dosya: $NGINX_ROLLOUT_SCRIPT_SRC"
  [[ -f "$NGINX_ROLLOUT_SERVICE_SRC" ]] || die "Eksik dosya: $NGINX_ROLLOUT_SERVICE_SRC"
  [[ -f "$NGINX_ROLLOUT_TIMER_SRC" ]] || die "Eksik dosya: $NGINX_ROLLOUT_TIMER_SRC"
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
  log "Gerekli paketler kuruluyor (podman + network/storage bağımlılıkları, nginx, certbot, git, curl, openssl)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    podman uidmap slirp4netns passt fuse-overlayfs \
    apparmor apparmor-utils \
    nginx certbot git curl openssl
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

  local service_action="start"
  if systemctl is-active --quiet "$WEBHOOK_SERVICE_NAME"; then
    service_action="restart"
  fi

  if ! systemctl "$service_action" "$WEBHOOK_SERVICE_NAME"; then
    debug_webhook_start_failure
    die "Webhook service ${service_action} başarısız: $WEBHOOK_SERVICE_NAME"
  fi

  if ! systemctl is-active --quiet "$WEBHOOK_SERVICE_NAME"; then
    debug_webhook_start_failure
    die "Webhook service aktif değil: $WEBHOOK_SERVICE_NAME"
  fi
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

validate_repo_relative_path() {
  local rel="$1"
  [[ -n "$rel" ]] || die "Repo relative path boş olamaz"
  [[ "$rel" != /* ]] || die "Repo relative path absolute olamaz: $rel"
  [[ "$rel" != *".."* ]] || die "Repo relative path '..' içeremez: $rel"
  [[ "$rel" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Geçersiz karakter içeren repo relative path: $rel"
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

validate_inputs() {
  [[ "$WEBHOOK_LOCAL_PORT" =~ ^[0-9]+$ ]] || die "Webhook local port sayısal olmalı"
  (( WEBHOOK_LOCAL_PORT >= 1 && WEBHOOK_LOCAL_PORT <= 65535 )) || die "Webhook local port 1-65535 aralığında olmalı"

  [[ "$TOKEN_TOLERANCE_MINUTES" =~ ^[0-9]+$ ]] || die "TOKEN_TOLERANCE_MINUTES sayısal olmalı"
  (( TOKEN_TOLERANCE_MINUTES <= 60 )) || die "TOKEN_TOLERANCE_MINUTES çok yüksek (önerilen: 0-10)"

  [[ "$SALT_SECRET" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "SALT_SECRET yalnızca [A-Za-z0-9._-] karakterleri içermeli"

  validate_absolute_path "$PROJECT_DIR"
  validate_absolute_path "$AGENT_REPO_DIR"

  if [[ "${INSTALL_NGINX_ROLLOUT:-n}" == "y" ]]; then
    validate_absolute_path "$NGINX_ROLLOUT_REPO_DIR"
    validate_absolute_path "$NGINX_ROLLOUT_ACME_ROOT"
    validate_absolute_path "$NGINX_ROLLOUT_STATE_FILE"
    validate_absolute_path "$NGINX_ROLLOUT_CERTBOT_BIN"
    validate_repo_relative_path "$NGINX_ROLLOUT_HTTP_DIR"
    validate_repo_relative_path "$NGINX_ROLLOUT_HTTPS_DIR"
    validate_repo_relative_path "$NGINX_ROLLOUT_CERT_BUNDLES_DIR"
  fi
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
    "$AGENT_DIR/quadlet-agent.sh" "$home/.local/bin/quadlet-agent.sh"
  install -m 0644 -o "$user" -g "$user" \
    "$AGENT_DIR/systemd-user/quadlet-agent.service" "$home/.config/systemd/user/quadlet-agent.service"
  install -m 0644 -o "$user" -g "$user" \
    "$AGENT_DIR/systemd-user/quadlet-agent.timer" "$home/.config/systemd/user/quadlet-agent.timer"

  config_path="$home/.config/quadlet-agent/config"
  cat >"$config_path" <<EOF
GLOBAL_VERSION_FILE="$VERSION_FILE"
REPO_URL="$AGENT_REPO_URL"
REPO_DIR="$AGENT_REPO_DIR"
EOF
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

install_nginx_rollout_agent() {
  log "Nginx+Certbot rollout agent kuruluyor (root systemd timer)..."

  install -m 0755 "$NGINX_ROLLOUT_SCRIPT_SRC" "$NGINX_ROLLOUT_SCRIPT_DST"
  install -m 0644 "$NGINX_ROLLOUT_SERVICE_SRC" "$NGINX_ROLLOUT_SERVICE_DST"
  install -m 0644 "$NGINX_ROLLOUT_TIMER_SRC" "$NGINX_ROLLOUT_TIMER_DST"

  install -d -m 0755 "$NGINX_ROLLOUT_ENV_DIR"
  install -d -m 0755 "$NGINX_ROLLOUT_ACME_ROOT/.well-known/acme-challenge"
  install -d -m 0755 "$(dirname "$NGINX_ROLLOUT_STATE_FILE")"

  cat >"$NGINX_ROLLOUT_ENV_PATH" <<EOF
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
EOF
  chmod 0644 "$NGINX_ROLLOUT_ENV_PATH"

  install -d -m 0755 "$(dirname "$CERTBOT_DEPLOY_HOOK_PATH")"
  cat >"$CERTBOT_DEPLOY_HOOK_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

nginx -t
systemctl reload nginx
EOF
  chmod 0755 "$CERTBOT_DEPLOY_HOOK_PATH"

  systemctl daemon-reload
  if [[ "$NGINX_ROLLOUT_ENABLE_TIMER" == "y" ]]; then
    systemctl enable --now nginx-rollout.timer
  else
    warn "Nginx rollout timer kurulmuş ama aktive edilmedi."
    warn "Manuel aktivasyon için: systemctl enable --now nginx-rollout.timer"
  fi
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
    prompt_yes_no NGINX_ACTIVATE_CONFIG "Oluşturulan Nginx config otomatik aktive edilsin mi?" "n"
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
    NGINX_ACTIVATE_CONFIG="n"
    SSL_CERT_PATH=""
    SSL_KEY_PATH=""
    ACME_CHALLENGE_ROOT="/var/www/certbot"
  fi

  prompt_default PROJECT_DIR "Quadlet rollout project dizini" "/opt/quadlet-rollout"
  VERSION_DIR="$PROJECT_DIR"
  VERSION_FILE="$VERSION_DIR/global_version"
  QUADLET_ROLLOUT_REPOS_DIR="$PROJECT_DIR/repos"

  prompt_default AGENT_REPO_URL "Agent/Nginx ortak REPO_URL" "https://github.com/syntaxbender/quadlet-services.git"
  AGENT_REPO_DIR="$QUADLET_ROLLOUT_REPOS_DIR/$SHARED_REPO_NAME"
  INSTALL_NGINX_ROLLOUT="y"
  NGINX_ROLLOUT_REPO_URL="$AGENT_REPO_URL"
  NGINX_ROLLOUT_REPO_DIR="$AGENT_REPO_DIR"
  NGINX_ROLLOUT_HTTP_DIR="nginx/http"
  NGINX_ROLLOUT_HTTPS_DIR="nginx/https"
  NGINX_ROLLOUT_CERT_BUNDLES_DIR="nginx/cert-bundles"
  prompt_default NGINX_ROLLOUT_ACME_ROOT "Nginx rollout ACME challenge root" "/var/www/certbot"
  prompt_default NGINX_ROLLOUT_STATE_FILE "Nginx rollout state dosyası" "$PROJECT_DIR/nginx_seen_version"
  prompt_default NGINX_ROLLOUT_CERTBOT_BIN "Certbot binary path" "/usr/bin/certbot"
  NGINX_ROLLOUT_ENABLE_TIMER="y"

  local users_input
  prompt_required users_input "Agent kurulacak kullanıcılar (boşluk veya virgül ile ayırın)"
  parse_agent_users "$users_input"
}

summary() {
  local deploy_scheme
  local nginx_activation_note
  local nginx_rollout_note
  if [[ "$NGINX_ENABLE_SSL" == "y" ]]; then
    deploy_scheme="https"
  else
    deploy_scheme="http"
  fi
  if [[ "$CONFIGURE_NGINX" == "y" && "$NGINX_ACTIVATE_CONFIG" != "y" ]]; then
    nginx_activation_note="Nginx config oluşturuldu ancak aktive edilmedi (manuel aktive etmelisin)."
  else
    nginx_activation_note="Nginx config aktivasyon durumu: otomatik."
  fi
  if [[ "$INSTALL_NGINX_ROLLOUT" == "y" ]]; then
    nginx_rollout_note="Kuruldu. Config: $NGINX_ROLLOUT_ENV_PATH | Timer: nginx-rollout.timer (enable=$NGINX_ROLLOUT_ENABLE_TIMER) | Renew hook: $CERTBOT_DEPLOY_HOOK_PATH"
  else
    nginx_rollout_note="Kurulmadı."
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

Nginx:
  $nginx_activation_note

Nginx rollout:
  $nginx_rollout_note

Ortak repo:
  REPO_URL=$AGENT_REPO_URL
  REPO_DIR=$AGENT_REPO_DIR
  PROJECT_DIR=$PROJECT_DIR

Agent env dosyası:
  Her kullanıcı için: ~/.config/quadlet-agent/$AGENT_ENV_FILENAME

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
  prepare_shared_repo_dir "$AGENT_REPO_DIR"
  if [[ "${INSTALL_NGINX_ROLLOUT:-n}" == "y" && "$NGINX_ROLLOUT_REPO_DIR" != "$AGENT_REPO_DIR" ]]; then
    prepare_shared_repo_dir "$NGINX_ROLLOUT_REPO_DIR"
  fi
  build_or_use_image
  write_webhook_quadlet

  if [[ "$CONFIGURE_NGINX" == "y" ]]; then
    write_nginx_site
  else
    warn "Nginx kurulumu atlandı. Webhook sadece localhost:${WEBHOOK_LOCAL_PORT} üzerinde dinliyor."
  fi

  local user
  for user in "${AGENT_USERS[@]}"; do
    install_agent_for_user "$user"
  done

  if [[ "$INSTALL_NGINX_ROLLOUT" == "y" ]]; then
    install_nginx_rollout_agent
  fi

  summary
}

main "$@"
