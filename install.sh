#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd /

WEBHOOK_INSTALLER="$SCRIPT_DIR/webhook-app/install.sh"
AGENT_INSTALLER="$SCRIPT_DIR/agent/install.sh"
NGINX_ROLLOUT_INSTALLER="$SCRIPT_DIR/nginx-rollout/install.sh"

PROJECT_DIR="${PROJECT_DIR:-/opt/quadlet-rollout}"
SHARED_REPO_URL="${SHARED_REPO_URL:-https://github.com/syntaxbender/quadlet-services.git}"
AGENT_USERS_RAW="${AGENT_USERS_RAW:-}"

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

prompt_default() {
  local __var="$1"
  local prompt="$2"
  local default="$3"
  local value

  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  printf -v "$__var" '%s' "$value"
}

prompt_optional() {
  local __var="$1"
  local prompt="$2"
  local value

  read -r -p "$prompt: " value
  printf -v "$__var" '%s' "$value"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "Bu script root olarak çalıştırılmalı. Örn: sudo ./install.sh"
  fi
}

require_files() {
  [[ -f "$WEBHOOK_INSTALLER" ]] || die "Eksik dosya: $WEBHOOK_INSTALLER"
  [[ -f "$AGENT_INSTALLER" ]] || die "Eksik dosya: $AGENT_INSTALLER"
  [[ -f "$NGINX_ROLLOUT_INSTALLER" ]] || die "Eksik dosya: $NGINX_ROLLOUT_INSTALLER"

  [[ -x "$WEBHOOK_INSTALLER" ]] || chmod +x "$WEBHOOK_INSTALLER"
  [[ -x "$AGENT_INSTALLER" ]] || chmod +x "$AGENT_INSTALLER"
  [[ -x "$NGINX_ROLLOUT_INSTALLER" ]] || chmod +x "$NGINX_ROLLOUT_INSTALLER"
}

validate_absolute_path() {
  local p="$1"
  [[ "$p" == /* ]] || die "Absolute path bekleniyor: $p"
  [[ "$p" != *".."* ]] || die "Path '..' içeremez: $p"
}

collect_inputs() {
  prompt_default PROJECT_DIR "Quadlet rollout project dizini" "$PROJECT_DIR"
  prompt_default SHARED_REPO_URL "Agent/Nginx ortak REPO_URL" "$SHARED_REPO_URL"

  if [[ -n "${AGENT_USERS_RAW// }" ]]; then
    prompt_default AGENT_USERS_RAW "Agent kurulacak kullanıcılar (boşlukla ayır)" "$AGENT_USERS_RAW"
  else
    prompt_optional AGENT_USERS_RAW "Agent kurulacak kullanıcılar (boşlukla ayır, boş bırakılırsa atlanır)"
  fi
}

normalize_agent_users() {
  local user normalized
  declare -A seen=()

  AGENT_USERS=()
  normalized="${AGENT_USERS_RAW//,/ }"
  for user in $normalized; do
    [[ -n "${seen[$user]:-}" ]] && continue
    AGENT_USERS+=("$user")
    seen[$user]=1
  done
}

run_webhook_installer() {
  log "Webhook installer çalıştırılıyor..."
  PROJECT_DIR="$PROJECT_DIR" "$WEBHOOK_INSTALLER"
}

run_agent_installers() {
  local user

  if [[ "${#AGENT_USERS[@]}" -eq 0 ]]; then
    warn "Agent kullanıcı listesi boş. Agent kurulum adımı atlandı."
    return 0
  fi

  for user in "${AGENT_USERS[@]}"; do
    log "Agent installer çalıştırılıyor: $user"
    PROJECT_DIR="$PROJECT_DIR" \
    AGENT_REPO_URL="$SHARED_REPO_URL" \
    TARGET_USER="$user" \
      "$AGENT_INSTALLER"
  done
}

run_nginx_rollout_installer() {
  log "Nginx rollout installer çalıştırılıyor..."
  PROJECT_DIR="$PROJECT_DIR" \
  NGINX_ROLLOUT_REPO_URL="$SHARED_REPO_URL" \
    "$NGINX_ROLLOUT_INSTALLER"
}

main() {
  require_root
  require_files
  collect_inputs
  validate_absolute_path "$PROJECT_DIR"
  normalize_agent_users

  run_webhook_installer
  run_agent_installers
  run_nginx_rollout_installer

  log "Kök kurulum tamamlandı."
  log "Project dir: $PROJECT_DIR"
  log "Shared repo URL: $SHARED_REPO_URL"
}

main "$@"
