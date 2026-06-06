#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${NGINX_ROLLOUT_CONFIG:-/opt/quadlet-rollout/nginx-rollout.env}"

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

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

require_var() {
  local k="$1"
  [[ -n "${!k:-}" ]] || die "missing config var: $k"
}

realpath_m() {
  realpath -m "$1"
}

ensure_within() {
  local base="$1"
  local path="$2"
  local base_real path_real
  base_real="$(realpath_m "$base")"
  path_real="$(realpath_m "$path")"

  case "$path_real" in
    "$base_real"|"$base_real"/*) return 0 ;;
  esac
  die "path escapes base: $path -> $path_real (base: $base_real)"
}

safe_rm_dir_contents() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  while IFS= read -r -d '' p; do
    rm -rf -- "$p"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
}

normalize_repo_permissions() {
  local repo_dir="$1"
  local repo_parent="$2"
  local lock_file="$3"
  local repo_group

  repo_group="$(stat -c '%G' "$repo_parent" 2>/dev/null || true)"
  [[ -n "$repo_group" ]] || repo_group="root"

  install -d -m 2775 -o root -g "$repo_group" "$repo_parent"
  install -d -m 2775 -o root -g "$repo_group" "$repo_dir"
  if [[ ! -e "$lock_file" ]]; then
    install -m 0664 -o root -g "$repo_group" /dev/null "$lock_file"
  fi

  chgrp -R "$repo_group" "$repo_dir" 2>/dev/null || true
  find "$repo_dir" -type d -exec chmod g+rws {} + 2>/dev/null || true
  find "$repo_dir" -type f -exec chmod g+rw {} + 2>/dev/null || true
  chgrp "$repo_group" "$lock_file" 2>/dev/null || true
  chmod 0664 "$lock_file" 2>/dev/null || true
}

ensure_no_symlink_tree() {
  local src="$1"
  if find "$src" -type l -print -quit | grep -q .; then
    die "symlink is not allowed under $src"
  fi
}

copy_conf_tree() {
  local src_dir="$1"
  local dst_dir="$2"
  local copied=0

  ensure_no_symlink_tree "$src_dir"
  install -d -m 0755 "$dst_dir"
  safe_rm_dir_contents "$dst_dir"

  while IFS= read -r -d '' src_path; do
    local rel target
    rel="${src_path#"$src_dir"/}"
    target="$dst_dir/$rel"

    ensure_within "$dst_dir" "$target"

    if [[ -d "$src_path" ]]; then
      install -d -m 0755 "$target"
      continue
    fi

    case "$src_path" in
      *.conf)
        install -d -m 0755 "$(dirname "$target")"
        install -m 0644 "$src_path" "$target"
        copied=1
        ;;
      *)
        ;;
    esac
  done < <(find "$src_dir" -mindepth 1 -print0)

  [[ "$copied" -eq 1 ]] || warn "no *.conf found under $src_dir"
}

sync_enabled_links() {
  local available_dir="$1"
  local enabled_dir="$2"
  local phase="$3"
  local link_prefix="quadlet-rollout-$phase-"
  local -A seen_links=()

  install -d -m 0755 "$enabled_dir"

  while IFS= read -r -d '' link_path; do
    rm -f -- "$link_path"
  done < <(find "$enabled_dir" -maxdepth 1 -type l -name "${link_prefix}*.conf" -print0)

  while IFS= read -r -d '' conf_path; do
    local rel flat link_name link_path
    rel="${conf_path#"$available_dir"/}"
    flat="$(printf '%s' "$rel" | sed -e 's#[^A-Za-z0-9._-]#_#g')"
    link_name="${link_prefix}${flat}"
    link_path="$enabled_dir/$link_name"

    if [[ -n "${seen_links[$link_name]:-}" ]]; then
      die "conf link collision detected for phase=$phase name=$link_name"
    fi
    seen_links[$link_name]=1

    ensure_within "$enabled_dir" "$link_path"
    ln -sfn "$conf_path" "$link_path"
  done < <(find "$available_dir" -type f -name '*.conf' -print0)
}

disable_acme_http_config() {
  rm -f -- "$NGINX_SITE_ENABLED_DIR/000-quadlet-rollout-acme.conf"
}

disable_enabled_sites_for_acme() {
  local state_dir="$1"
  local entry name target backup
  local state_file="$state_dir/enabled-sites.tsv"

  install -d -m 0700 "$state_dir/files"
  : > "$state_file"
  install -d -m 0755 "$NGINX_SITE_ENABLED_DIR"

  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"

    if [[ "$name" == "000-quadlet-rollout-acme.conf" ]]; then
      rm -f -- "$entry"
      continue
    fi

    if [[ -L "$entry" ]]; then
      target="$(readlink "$entry")"
      printf 'L\t%s\t%s\n' "$name" "$target" >> "$state_file"
      rm -f -- "$entry"
    elif [[ -f "$entry" ]]; then
      backup="$state_dir/files/$name"
      printf 'F\t%s\t%s\n' "$name" "$backup" >> "$state_file"
      mv -- "$entry" "$backup"
    fi
  done < <(find "$NGINX_SITE_ENABLED_DIR" -maxdepth 1 \( -type f -o -type l \) -print0)
}

restore_enabled_sites_for_acme() {
  local state_dir="$1"
  local state_file="$state_dir/enabled-sites.tsv"
  local kind name target enabled_path

  [[ -f "$state_file" ]] || return 0
  install -d -m 0755 "$NGINX_SITE_ENABLED_DIR"

  while IFS=$'\t' read -r kind name target; do
    [[ -n "$kind" && -n "$name" ]] || continue
    enabled_path="$NGINX_SITE_ENABLED_DIR/$name"

    case "$kind" in
      L)
        ln -sfn "$target" "$enabled_path"
        ;;
      F)
        if [[ -f "$target" ]]; then
          mv -f -- "$target" "$enabled_path"
        else
          warn "cannot restore enabled site file, backup missing: $target"
        fi
        ;;
      *)
        warn "unknown enabled site state entry: $kind $name"
        ;;
    esac
  done < "$state_file"
}

restore_nginx_after_acme() {
  local state_dir="$1"

  disable_acme_http_config
  restore_enabled_sites_for_acme "$state_dir"
  if nginx -t; then
    systemctl reload nginx
  else
    warn "nginx -t failed while restoring previous enabled sites"
  fi
}

record_failed_version() {
  local tmp_file

  [[ -n "${FAILED_VERSION_FILE:-}" && -n "${CURRENT_VERSION:-}" ]] || return 0

  install -d -m 0755 "$(dirname "$FAILED_VERSION_FILE")"
  tmp_file="$FAILED_VERSION_FILE.tmp"
  printf '%s\n' "$CURRENT_VERSION" > "$tmp_file"
  mv -f -- "$tmp_file" "$FAILED_VERSION_FILE"
  warn "rollout failed for version: $CURRENT_VERSION; skip retries until global_version changes"
}

clear_failed_version() {
  [[ -n "${FAILED_VERSION_FILE:-}" ]] || return 0
  rm -f -- "$FAILED_VERSION_FILE"
}

on_exit() {
  local rc=$?

  if [[ -n "${ACME_RESTORE_DIR:-}" ]]; then
    restore_nginx_after_acme "$ACME_RESTORE_DIR" || true
    rm -rf -- "$ACME_RESTORE_DIR" || true
    ACME_RESTORE_DIR=""
  fi

  if [[ "$rc" -ne 0 && "${TRACK_FAILED_VERSION:-0}" == "1" ]]; then
    record_failed_version || true
  fi

  exit "$rc"
}

parse_bundle_file() {
  local bundle_file="$1"
  local line key val

  BUNDLE_CERT_NAME=""
  BUNDLE_CERT_EMAIL=""
  BUNDLE_DOMAINS=""
  BUNDLE_WEBROOT=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    [[ "$line" == *=* ]] || die "invalid bundle line ($bundle_file): $line"
    key="${line%%=*}"
    val="${line#*=}"

    key="$(trim "$key")"
    val="$(trim "$val")"

    if [[ "$val" =~ ^\".*\"$ ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "$val" =~ ^\'.*\'$ ]]; then
      val="${val:1:${#val}-2}"
    fi

    case "$key" in
      CERT_NAME)
        BUNDLE_CERT_NAME="$val"
        ;;
      CERT_EMAIL)
        BUNDLE_CERT_EMAIL="$val"
        ;;
      DOMAINS)
        BUNDLE_DOMAINS="$val"
        ;;
      WEBROOT)
        BUNDLE_WEBROOT="$val"
        ;;
      *)
        die "unknown key in bundle ($bundle_file): $key"
        ;;
    esac
  done < "$bundle_file"

  [[ -n "$BUNDLE_CERT_NAME" ]] || die "CERT_NAME missing in $bundle_file"
  [[ -n "$BUNDLE_CERT_EMAIL" ]] || die "CERT_EMAIL missing in $bundle_file"
  [[ -n "$BUNDLE_DOMAINS" ]] || die "DOMAINS missing in $bundle_file"

  if [[ -z "$BUNDLE_WEBROOT" ]]; then
    BUNDLE_WEBROOT="$ACME_CHALLENGE_ROOT"
  fi
}

activate_acme_http_config() {
  local bundle_dir="$REPO_DIR/$CERT_BUNDLES_DIR"
  local available_root="$NGINX_SITE_AVAILABLE_DIR/quadlet-rollout"
  local available="$available_root/acme"
  local conf_path="$available/quadlet-rollout-acme.conf"
  local tmp_path="$conf_path.tmp"
  local bundle_file webroot domains_raw domain
  local -a domain_args
  local wrote=0
  declare -A seen_domains=()

  if [[ ! -d "$bundle_dir" ]]; then
    warn "skip ACME HTTP activation: bundle directory missing: $bundle_dir"
    return 0
  fi

  install -d -m 0755 "$available" "$NGINX_SITE_ENABLED_DIR"

  {
    printf '# Generated by nginx-rollout.sh. Serves ACME http-01 challenges before HTTPS certs exist.\n\n'
  } > "$tmp_path"

  while IFS= read -r -d '' bundle_file; do
    parse_bundle_file "$bundle_file"
    webroot="$BUNDLE_WEBROOT"
    domains_raw="$BUNDLE_DOMAINS"

    [[ "$webroot" == /* ]] || die "WEBROOT must be absolute in $bundle_file: $webroot"
    install -d -m 0755 "$webroot/.well-known/acme-challenge"

    mapfile -t domain_args < <(printf '%s' "$domains_raw" | tr ', ' '\n\n' | sed '/^$/d')
    [[ "${#domain_args[@]}" -gt 0 ]] || die "no domain parsed in $bundle_file"

    for domain in "${domain_args[@]}"; do
      [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain in $bundle_file: $domain"
      if [[ -n "${seen_domains[$domain]:-}" ]]; then
        die "duplicate domain across cert bundles: $domain"
      fi
      seen_domains[$domain]=1
    done

    {
      printf 'server {\n'
      printf '    listen 80;\n'
      printf '    listen [::]:80;\n'
      printf '    server_name %s;\n' "${domain_args[*]}"
      printf '\n'
      printf '    location ^~ /.well-known/acme-challenge/ {\n'
      printf '        root %s;\n' "$webroot"
      printf '        try_files $uri =404;\n'
      printf '    }\n'
      printf '\n'
      printf '    location / {\n'
      printf '        return 301 https://$host$request_uri;\n'
      printf '    }\n'
      printf '}\n\n'
    } >> "$tmp_path"
    wrote=1
  done < <(find "$bundle_dir" -type f -name '*.env' -print0 | sort -z)

  if [[ "$wrote" -ne 1 ]]; then
    rm -f -- "$tmp_path"
    warn "skip ACME HTTP activation: no cert bundle env files found under $bundle_dir"
    return 0
  fi

  install -m 0644 "$tmp_path" "$conf_path"
  rm -f -- "$tmp_path"

  ln -sfn "$conf_path" "$NGINX_SITE_ENABLED_DIR/000-quadlet-rollout-acme.conf"
  nginx -t
  systemctl reload nginx
}

request_or_renew_bundle_cert() {
  local bundle_file="$1"
  local webroot domains_raw domain
  local -a certbot_args domain_args

  parse_bundle_file "$bundle_file"
  webroot="$BUNDLE_WEBROOT"
  domains_raw="$BUNDLE_DOMAINS"

  install -d -m 0755 "$webroot/.well-known/acme-challenge"

  mapfile -t domain_args < <(printf '%s' "$domains_raw" | tr ', ' '\n\n' | sed '/^$/d')
  [[ "${#domain_args[@]}" -gt 0 ]] || die "no domain parsed in $bundle_file"

  certbot_args=(
    certonly
    --webroot
    -w "$webroot"
    --cert-name "$BUNDLE_CERT_NAME"
    --email "$BUNDLE_CERT_EMAIL"
    --agree-tos
    --no-eff-email
    --non-interactive
    --keep-until-expiring
    --expand
    --staple-ocsp
  )

  for domain in "${domain_args[@]}"; do
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain in $bundle_file: $domain"
    certbot_args+=( -d "$domain" )
  done

  log "certbot certonly: cert_name=$BUNDLE_CERT_NAME domains=${domain_args[*]}"
  "$CERTBOT_BIN" "${certbot_args[@]}"
}

activate_phase() {
  local phase="$1"
  local src_rel available enabled src_dir available_root

  if [[ "$phase" == "http" ]]; then
    src_rel="$NGINX_HTTP_DIR"
  else
    src_rel="$NGINX_HTTPS_DIR"
  fi

  src_dir="$REPO_DIR/$src_rel"
  ensure_within "$REPO_DIR" "$src_dir"

  if [[ ! -d "$src_dir" ]]; then
    warn "skip $phase activation: directory not found: $src_dir"
    return 0
  fi

  available_root="$NGINX_SITE_AVAILABLE_DIR/quadlet-rollout"
  available="$available_root/$phase"
  enabled="$NGINX_SITE_ENABLED_DIR"

  install -d -m 0755 "$available_root"
  copy_conf_tree "$src_dir" "$available"
  sync_enabled_links "$available" "$enabled" "$phase"

  nginx -t
  systemctl reload nginx
}

main() {
  local -a BUNDLE_FILES

  [[ -f "$CONFIG_FILE" ]] || die "missing config: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  require_var GLOBAL_VERSION_FILE
  require_var REPO_URL
  require_var REPO_DIR
  require_var NGINX_HTTP_DIR
  require_var NGINX_HTTPS_DIR
  require_var CERT_BUNDLES_DIR
  require_var NGINX_SITE_AVAILABLE_DIR
  require_var NGINX_SITE_ENABLED_DIR
  require_var ACME_CHALLENGE_ROOT
  require_var STATE_FILE

  CERTBOT_BIN="${CERTBOT_BIN:-certbot}"
  FAILED_VERSION_FILE="${FAILED_VERSION_FILE:-$(dirname "$STATE_FILE")/nginx_failed_version}"
  REPO_PARENT="$(dirname "$REPO_DIR")"
  REPO_LOCK_FILE="${REPO_LOCK_FILE:-$REPO_PARENT/.quadlet-nginx-shared-repo.lock}"

  [[ -r "$GLOBAL_VERSION_FILE" ]] || die "global version unreadable: $GLOBAL_VERSION_FILE"
  NEW_VERSION="$(tr -d '[:space:]' < "$GLOBAL_VERSION_FILE")"
  [[ -n "$NEW_VERSION" ]] || { warn "global version empty"; exit 0; }

  OLD_VERSION=""
  if [[ -f "$STATE_FILE" ]]; then
    OLD_VERSION="$(tr -d '[:space:]' < "$STATE_FILE")"
  fi

  if [[ "$NEW_VERSION" == "$OLD_VERSION" ]]; then
    log "version unchanged ($NEW_VERSION), skip"
    exit 0
  fi

  FAILED_VERSION=""
  if [[ -f "$FAILED_VERSION_FILE" ]]; then
    FAILED_VERSION="$(tr -d '[:space:]' < "$FAILED_VERSION_FILE")"
  fi

  if [[ "$NEW_VERSION" == "$FAILED_VERSION" ]]; then
    warn "version already failed ($NEW_VERSION), skip until global_version changes"
    exit 0
  fi

  CURRENT_VERSION="$NEW_VERSION"
  TRACK_FAILED_VERSION=1
  ACME_RESTORE_DIR=""
  trap on_exit EXIT

  [[ -d "$REPO_PARENT" ]] || die "repo parent directory missing: $REPO_PARENT"
  normalize_repo_permissions "$REPO_DIR" "$REPO_PARENT" "$REPO_LOCK_FILE"

  exec 9>>"$REPO_LOCK_FILE"
  if ! flock -w 120 9; then
    die "failed to acquire repo lock: $REPO_LOCK_FILE"
  fi

  # Root ve user-agent aynı repo üzerinde çalıştığı için grup yazma bitini koru.
  umask 0002

  if [[ ! -d "$REPO_DIR/.git" ]]; then
    git clone "$REPO_URL" "$REPO_DIR"
    git -C "$REPO_DIR" config core.sharedRepository 0660 || true
  else
    git -C "$REPO_DIR" config core.sharedRepository 0660 || true
    UPSTREAM_REF="$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    [[ -n "$UPSTREAM_REF" && "$UPSTREAM_REF" == */* ]] || die "missing upstream branch in repo: $REPO_DIR"
    UPSTREAM_REMOTE="${UPSTREAM_REF%%/*}"
    UPSTREAM_BRANCH="${UPSTREAM_REF#*/}"
    git -C "$REPO_DIR" fetch --prune --no-write-fetch-head "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
    git -C "$REPO_DIR" merge --ff-only "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  fi

  normalize_repo_permissions "$REPO_DIR" "$REPO_PARENT" "$REPO_LOCK_FILE"

  ensure_within "$REPO_DIR" "$REPO_DIR/$CERT_BUNDLES_DIR"
  BUNDLE_FILES=()
  if [[ -d "$REPO_DIR/$CERT_BUNDLES_DIR" ]]; then
    mapfile -d '' BUNDLE_FILES < <(find "$REPO_DIR/$CERT_BUNDLES_DIR" -type f -name '*.env' -print0 | sort -z)
  fi

  # 1) ACME-only HTTP phase first:
  # Temporarily disable current enabled sites so http-01 validation is not
  # captured by an older redirect/proxy server block.
  ACME_RESTORE_DIR="$(mktemp -d /tmp/nginx-rollout-acme.XXXXXX)"
  disable_enabled_sites_for_acme "$ACME_RESTORE_DIR"
  activate_acme_http_config

  # 2) Cert phase: grouped SAN bundle definitions.
  if [[ "${#BUNDLE_FILES[@]}" -gt 0 ]]; then
    for bundle_file in "${BUNDLE_FILES[@]}"; do
      request_or_renew_bundle_cert "$bundle_file"
    done
  else
    warn "bundle directory missing: $REPO_DIR/$CERT_BUNDLES_DIR"
  fi

  # 3) Restore the previous nginx state before applying repo-managed configs.
  restore_nginx_after_acme "$ACME_RESTORE_DIR"
  rm -rf -- "$ACME_RESTORE_DIR"
  ACME_RESTORE_DIR=""

  # 4) Normal HTTP/HTTPS phases after cert material is available.
  activate_phase "http"
  activate_phase "https"

  install -d -m 0755 "$(dirname "$STATE_FILE")"
  clear_failed_version
  printf '%s\n' "$NEW_VERSION" > "$STATE_FILE"
  TRACK_FAILED_VERSION=0
  trap - EXIT
  log "nginx rollout completed for version: $NEW_VERSION"
}

main "$@"
