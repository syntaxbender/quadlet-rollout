#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo quadlet-agentctl status <user> [user...]
  sudo quadlet-agentctl run    <user> [user...]
  sudo quadlet-agentctl logs   <user> [user...]
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID:-0}" -eq 0 ]] || die "root olarak çalıştırılmalı"
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

status_user() {
  local user="$1"
  local uid
  uid="$(id -u "$user")"

  printf '== %s ==\n' "$user"
  run_user_systemctl "$user" "$uid" is-enabled quadlet-agent.timer || true
  run_user_systemctl "$user" "$uid" is-active quadlet-agent.timer || true
  run_user_systemctl "$user" "$uid" status quadlet-agent.service --no-pager || true
}

run_user() {
  local user="$1"
  local uid
  uid="$(id -u "$user")"

  printf '== %s ==\n' "$user"
  run_user_systemctl "$user" "$uid" start quadlet-agent.service
  run_user_systemctl "$user" "$uid" status quadlet-agent.service --no-pager || true
}

logs_user() {
  local user="$1"
  local uid
  uid="$(id -u "$user")"

  printf '== %s ==\n' "$user"
  journalctl --no-pager -n 120 _UID="$uid" _SYSTEMD_USER_UNIT=quadlet-agent.service || true
}

main() {
  require_root

  [[ $# -ge 2 ]] || {
    usage
    exit 1
  }

  local action="$1"
  shift

  local user
  for user in "$@"; do
    id -u "$user" >/dev/null 2>&1 || die "kullanıcı bulunamadı: $user"
    case "$action" in
      status) status_user "$user" ;;
      run) run_user "$user" ;;
      logs) logs_user "$user" ;;
      *) usage; exit 1 ;;
    esac
  done
}

main "$@"

