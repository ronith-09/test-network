#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NETWORK_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${REPO_ROOT}/betweennetwork"
BACKEND_DIR="${APP_DIR}/backend"
FRONTEND_DIR="${APP_DIR}/frontend"
RUNTIME_DIR="${TEST_NETWORK_DIR}/.runtime"
mkdir -p "${RUNTIME_DIR}"

DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-betweennetwork-db}"
DB_IMAGE="${DB_IMAGE:-postgres:latest}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-betweennetwork}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"
BACKEND_PORT="${BACKEND_PORT:-3000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
ONBOARDING_SCRIPT="${BLOCKCHAIN_ORG_ONBOARDING_SCRIPT:-${TEST_NETWORK_DIR}/dynamic-org/onboard-bank-org.sh}"

START_FRONTEND=true
START_BACKEND=true
START_FABRIC=true
START_DB=true
REBUILD_FABRIC=false
RECONCILE_ACTIVE_BANKS=true
STRICT_RESTORE=false

log() { printf '[start] %s\n' "$1"; }
warn() { printf '[start] WARN: %s\n' "$1" >&2; }
fail() { printf '[start] ERROR: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ./start.sh [options]

Options:
  --skip-db           Do not start PostgreSQL
  --skip-fabric       Do not start Fabric
  --skip-backend      Do not start backend
  --skip-frontend     Do not start frontend
  --rebuild-fabric    Rebuild the base Fabric network if needed and then restore approved banks
  --no-reconcile      Skip restoring approved dynamic banks from the database
  --strict-restore    Fail startup if restoring approved banks fails
  -h, --help          Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-db) START_DB=false ;;
    --skip-fabric) START_FABRIC=false ;;
    --skip-backend) START_BACKEND=false ;;
    --skip-frontend) START_FRONTEND=false ;;
    --rebuild-fabric) REBUILD_FABRIC=true ;;
    --no-reconcile) RECONCILE_ACTIVE_BANKS=false ;;
    --strict-restore) STRICT_RESTORE=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

filter_lines() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg "$pattern"
  else
    grep -E "$pattern"
  fi
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local attempts="${3:-60}"
  local delay="${4:-1}"

  for ((i=1; i<=attempts; i++)); do
    if nc -z "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-60}"
  local delay="${3:-1}"

  for ((i=1; i<=attempts; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

stop_pid_from_file() {
  local pid_file="$1"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
    fi
    rm -f "$pid_file"
  fi
}

kill_port_listener() {
  local port="$1"
  local pids
  pids="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    log "Releasing port ${port}"
    kill $pids >/dev/null 2>&1 || true
    sleep 1
  fi
}

ensure_postgres() {
  $START_DB || return 0

  require_cmd docker
  require_cmd nc

  if docker inspect "${DB_CONTAINER_NAME}" >/dev/null 2>&1; then
    log "Starting PostgreSQL container ${DB_CONTAINER_NAME}"
    docker start "${DB_CONTAINER_NAME}" >/dev/null 2>&1 || true
  else
    log "Creating PostgreSQL container ${DB_CONTAINER_NAME}"
    docker run -d \
      --name "${DB_CONTAINER_NAME}" \
      -e POSTGRES_DB="${DB_NAME}" \
      -e POSTGRES_USER="${DB_USER}" \
      -e POSTGRES_PASSWORD="${DB_PASSWORD}" \
      -p "${DB_PORT}:5432" \
      -v betweennetwork-postgres:/var/lib/postgresql/data \
      "${DB_IMAGE}" >/dev/null
  fi

  wait_for_tcp localhost "${DB_PORT}" 60 1 || fail "PostgreSQL did not become ready on port ${DB_PORT}"
}

base_fabric_exists() {
  docker inspect orderer.example.com >/dev/null 2>&1 && \
  docker inspect peer0.betweenorganization.example.com >/dev/null 2>&1 && \
  docker inspect peer0.bank1organization.example.com >/dev/null 2>&1 && \
  docker inspect peer0.bank2.example.com >/dev/null 2>&1 && \
  docker inspect peer0.bankd.example.com >/dev/null 2>&1
}

start_existing_fabric_containers() {
  require_cmd docker

  local containers=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && containers+=("$name")
  done < <(docker ps -a --format '{{.Names}}' | filter_lines '^(orderer\.example\.com|peer0\..+|dev-peer.+)$' || true)

  if [[ ${#containers[@]} -eq 0 ]]; then
    return 1
  fi

  log "Starting existing Fabric containers"
  docker start "${containers[@]}" >/dev/null 2>&1 || true
  return 0
}

ensure_fabric() {
  $START_FABRIC || return 0

  require_cmd docker
  if [[ "$REBUILD_FABRIC" == true ]]; then
    log "Rebuilding Fabric base network"
    (cd "${TEST_NETWORK_DIR}" && ./deploy.script.sh)
    return 0
  fi

  if base_fabric_exists; then
    start_existing_fabric_containers || true
    return 0
  fi

  log "Base Fabric network not found. Deploying it now"
  (cd "${TEST_NETWORK_DIR}" && ./deploy.script.sh)
}

run_backend_migrations() {
  $START_DB || return 0
  require_cmd npm
  log "Running backend migrations"
  (cd "${BACKEND_DIR}" && npm run migrate) >/dev/null
}

reconcile_active_banks() {
  $RECONCILE_ACTIVE_BANKS || return 0
  $START_FABRIC || return 0
  $START_DB || return 0

  require_cmd node

  log "Reconciling approved banks back onto Fabric"
  if ! (cd "${BACKEND_DIR}" && BLOCKCHAIN_ORG_ONBOARDING_SCRIPT="${ONBOARDING_SCRIPT}" node scripts/reconcile-approved-banks.js | tee "${RUNTIME_DIR}/reconcile.log"); then
    if [[ "${STRICT_RESTORE}" == true ]]; then
      fail "Approved bank recovery failed. See ${RUNTIME_DIR}/reconcile.log"
    fi
    warn "Approved bank recovery had errors. See ${RUNTIME_DIR}/reconcile.log"
  fi
}

start_backend() {
  $START_BACKEND || return 0
  require_cmd npm
  require_cmd curl
  require_cmd lsof

  if wait_for_http "http://localhost:${BACKEND_PORT}/health" 1 1; then
    log "Backend already running on port ${BACKEND_PORT}"
    return 0
  fi

  stop_pid_from_file "${RUNTIME_DIR}/backend.pid"
  kill_port_listener "${BACKEND_PORT}"

  log "Starting backend"
  (
    cd "${BACKEND_DIR}"
    BLOCKCHAIN_ORG_ONBOARDING_SCRIPT="${ONBOARDING_SCRIPT}" nohup npm start < /dev/null > "${RUNTIME_DIR}/backend.log" 2>&1 &
    echo $! > "${RUNTIME_DIR}/backend.pid"
  )

  wait_for_http "http://localhost:${BACKEND_PORT}/health" 60 1 || fail "Backend failed to start. See ${RUNTIME_DIR}/backend.log"
}

start_frontend() {
  $START_FRONTEND || return 0
  require_cmd curl
  require_cmd lsof

  local vite_bin="${FRONTEND_DIR}/node_modules/.bin/vite"
  [[ -x "${vite_bin}" ]] || fail "Frontend vite binary not found at ${vite_bin}. Run npm install in ${FRONTEND_DIR} first."

  if curl -fsS "http://localhost:${FRONTEND_PORT}" >/dev/null 2>&1; then
    log "Frontend already running on port ${FRONTEND_PORT}"
    return 0
  fi

  stop_pid_from_file "${RUNTIME_DIR}/frontend.pid"
  kill_port_listener "${FRONTEND_PORT}"

  log "Starting frontend"
  (
    cd "${FRONTEND_DIR}"
    nohup "${vite_bin}" --host 0.0.0.0 --port "${FRONTEND_PORT}" < /dev/null > "${RUNTIME_DIR}/frontend.log" 2>&1 &
    echo $! > "${RUNTIME_DIR}/frontend.pid"
  )

  sleep 2
  if ! ps -p "$(cat "${RUNTIME_DIR}/frontend.pid" 2>/dev/null || echo 0)" >/dev/null 2>&1; then
    fail "Frontend process exited early. See ${RUNTIME_DIR}/frontend.log"
  fi
}

main() {
  require_cmd curl
  ensure_postgres
  run_backend_migrations
  ensure_fabric
  reconcile_active_banks
  start_backend
  start_frontend

  log "Stack is ready"
  log "Backend:  http://localhost:${BACKEND_PORT}"
  log "Frontend: http://localhost:${FRONTEND_PORT}"
}

main "$@"
