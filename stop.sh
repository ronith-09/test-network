#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NETWORK_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${TEST_NETWORK_DIR}/.runtime"
DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-betweennetwork-db}"
BACKEND_PORT="${BACKEND_PORT:-3000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
KEEP_DB=false
FULL_RESET=false

log() { printf '[stop] %s\n' "$1"; }
warn() { printf '[stop] WARN: %s\n' "$1" >&2; }
fail() { printf '[stop] ERROR: %s\n' "$1" >&2; exit 1; }

filter_lines() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg "$pattern"
  else
    grep -E "$pattern"
  fi
}

usage() {
  cat <<USAGE
Usage: ./stop.sh [options]

Options:
  --keep-db      Leave PostgreSQL running
  --full-reset   Perform destructive Fabric cleanup after stopping services
  -h, --help     Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-db) KEEP_DB=true ;;
    --full-reset) FULL_RESET=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

stop_pid_from_file() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file"
  fi
}

kill_port_listener() {
  local port="$1"
  local pids
  pids="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    kill $pids >/dev/null 2>&1 || true
    sleep 1
  fi
}

stop_app_processes() {
  stop_pid_from_file "${RUNTIME_DIR}/backend.pid"
  stop_pid_from_file "${RUNTIME_DIR}/frontend.pid"
  kill_port_listener "${BACKEND_PORT}"
  kill_port_listener "${FRONTEND_PORT}"
}

stop_fabric_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    warn 'docker not found; skipping Fabric shutdown'
    return 0
  fi

  local containers=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && containers+=("$name")
  done < <(docker ps --format '{{.Names}}' | filter_lines '^(orderer\.example\.com|peer0\..+|dev-peer.+)$' || true)

  if [[ ${#containers[@]} -gt 0 ]]; then
    log "Stopping Fabric containers"
    docker stop "${containers[@]}" >/dev/null 2>&1 || true
  fi
}

stop_db_container() {
  [[ "$KEEP_DB" == true ]] && return 0

  if command -v docker >/dev/null 2>&1 && docker inspect "${DB_CONTAINER_NAME}" >/dev/null 2>&1; then
    log "Stopping PostgreSQL container ${DB_CONTAINER_NAME}"
    docker stop "${DB_CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

full_reset_fabric() {
  [[ "$FULL_RESET" == true ]] || return 0
  log "Running destructive Fabric reset"
  (cd "${TEST_NETWORK_DIR}" && ./network.sh down) || true
}

main() {
  stop_app_processes
  stop_fabric_containers
  stop_db_container
  full_reset_fabric
  log 'Stack stopped'
}

main "$@"
