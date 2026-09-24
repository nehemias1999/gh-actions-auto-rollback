#!/usr/bin/env bash
# ==============================================================================
# Description: Blue/green deploy orchestrator. Starts the requested version on
#   the idle port, health-checks it via healthcheck.sh, then either switches
#   traffic (stop old, rename new to app-<version>-active, record the port)
#   or delegates recovery to rollback.sh. Re-running an already active and
#   healthy version exits 0 without touching containers.
# Author: gh-actions-auto-rollback
# Usage: ./scripts/deploy.sh --version <semver> --image <name> [--current-port 8080] [--staging-port 8081]
# Env Vars: DEPLOY_HEALTHCHECK_BIN (override healthcheck.sh path),
#   DEPLOY_ROLLBACK_BIN (override rollback.sh path),
#   ACTIVE_PORT_FILE (default /tmp/active-port)
# Dependencies: docker, healthcheck.sh (sibling script), rollback.sh (sibling script)
# Output / Exit codes: timestamped logs to STDOUT, errors to STDERR;
#   0 success (or already deployed), 1 deploy/health failure, 2 usage error.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HEALTHCHECK_BIN="${DEPLOY_HEALTHCHECK_BIN:-$SCRIPT_DIR/healthcheck.sh}"
ROLLBACK_BIN="${DEPLOY_ROLLBACK_BIN:-$SCRIPT_DIR/rollback.sh}"
ACTIVE_PORT_FILE="${ACTIVE_PORT_FILE:-/tmp/active-port}"

VERSION=""
IMAGE=""
CURRENT_PORT="8080"
STAGING_PORT="8081"

# Print a timestamped log line to STDOUT. Args: $1 message.
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

# Print a timestamped error line to STDERR. Args: $1 message.
err() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

# Print usage to STDOUT and exit 0.
usage() {
  cat <<'EOF'
Usage: deploy.sh --version <semver> --image <name> [--current-port 8080] [--staging-port 8081]

Performs a blue/green deployment with Docker port mapping.

Options:
  --version <semver>      Version to deploy (required, e.g. v1.0.0).
  --image <name>          Docker image to run (required).
  --current-port <port>   Port expected to serve traffic (default: 8080).
  --staging-port <port>   Port used to stage the new version (default: 8081).
  -h, --help              Print this help to STDOUT and exit 0.

Exit codes: 0 success (or version already active and healthy),
1 deploy/health failure, 2 usage error.
EOF
}

# Probe a local port via healthcheck.sh with short retries.
# Args: $1 port. Returns 0 when healthy.
probe_port() {
  "$HEALTHCHECK_BIN" --url "http://localhost:$1/health" \
    --retries 2 --interval 1 --timeout 2 >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -lt 2 ]] && { err "--version requires a value."; usage >&2; exit 2; }
      VERSION="$2"; shift 2
      ;;
    --image)
      [[ $# -lt 2 ]] && { err "--image requires a value."; usage >&2; exit 2; }
      IMAGE="$2"; shift 2
      ;;
    --current-port)
      [[ $# -lt 2 ]] && { err "--current-port requires a value."; usage >&2; exit 2; }
      CURRENT_PORT="$2"; shift 2
      ;;
    --staging-port)
      [[ $# -lt 2 ]] && { err "--staging-port requires a value."; usage >&2; exit 2; }
      STAGING_PORT="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --*)
      err "Unknown option: $1"
      usage >&2
      exit 2
      ;;
    *)
      err "Unexpected argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  err "--version is required."
  usage >&2
  exit 2
fi
if [[ -z "$IMAGE" ]]; then
  err "--image is required."
  usage >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  err "--version must be a semantic version (e.g. v1.0.0)."
  usage >&2
  exit 2
fi
if [[ ! "$CURRENT_PORT" =~ ^[0-9]+$ ]] || [[ ! "$STAGING_PORT" =~ ^[0-9]+$ ]]; then
  err "Ports must be numeric."
  usage >&2
  exit 2
fi
if [[ "$CURRENT_PORT" == "$STAGING_PORT" ]]; then
  err "--current-port and --staging-port must differ."
  usage >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
  err "docker CLI not found on PATH."
  exit 1
fi
if [[ ! -x "$HEALTHCHECK_BIN" ]]; then
  err "healthcheck script not executable: $HEALTHCHECK_BIN"
  exit 1
fi
if [[ ! -x "$ROLLBACK_BIN" ]]; then
  err "rollback script not executable: $ROLLBACK_BIN"
  exit 1
fi

NEW_STAGING="app-${VERSION}-staging"
NEW_ACTIVE="app-${VERSION}-active"

# Determine the active port: the first healthy one wins. When neither port is
# healthy this is a fresh deploy, staged on --staging-port.
ACTIVE_PORT=""
STAGE_PORT=""
if probe_port "$CURRENT_PORT"; then
  ACTIVE_PORT="$CURRENT_PORT"
  STAGE_PORT="$STAGING_PORT"
  log "Active port detected: ${ACTIVE_PORT} (staging: ${STAGE_PORT})."
elif probe_port "$STAGING_PORT"; then
  ACTIVE_PORT="$STAGING_PORT"
  STAGE_PORT="$CURRENT_PORT"
  log "Active port detected: ${ACTIVE_PORT} (staging: ${STAGE_PORT})."
else
  ACTIVE_PORT="$CURRENT_PORT"
  STAGE_PORT="$STAGING_PORT"
  log "No healthy port found; fresh deploy on staging port ${STAGE_PORT}."
fi

# Discover the currently active container; tolerates none (fresh deploy).
OLD_CONTAINER="$(docker ps --filter 'name=app-.*-active' --format '{{.Names}}' 2>/dev/null | grep -E '^app-.*-active$' | head -n 1 || true)"

# Idempotent fast path: requested version already active and healthy.
if [[ "$OLD_CONTAINER" == "$NEW_ACTIVE" ]] && probe_port "$ACTIVE_PORT"; then
  log "Version ${VERSION} already active and healthy on port ${ACTIVE_PORT}; nothing to do."
  exit 0
fi

# Drop a leftover staging container from a previous attempt of this version.
if docker ps --all --format '{{.Names}}' 2>/dev/null | grep --quiet --line-regexp "$NEW_STAGING"; then
  log "Removing leftover staging container ${NEW_STAGING}."
  docker rm --force "$NEW_STAGING" >/dev/null 2>&1 || true
fi

log "Starting ${NEW_STAGING} on port ${STAGE_PORT} from image ${IMAGE}."
if ! docker run --detach --name "$NEW_STAGING" --publish "${STAGE_PORT}:8080" "$IMAGE" >/dev/null; then
  err "Failed to start container ${NEW_STAGING}."
  exit 1
fi

log "Health-checking ${NEW_STAGING} on port ${STAGE_PORT}."
if "$HEALTHCHECK_BIN" --url "http://localhost:${STAGE_PORT}/health" >/dev/null 2>&1; then
  log "Staging container healthy; switching traffic."
  if [[ -n "$OLD_CONTAINER" ]]; then
    log "Stopping old container ${OLD_CONTAINER}."
    docker stop "$OLD_CONTAINER" >/dev/null || { err "Failed to stop ${OLD_CONTAINER}."; exit 1; }
    docker rm "$OLD_CONTAINER" >/dev/null || { err "Failed to remove ${OLD_CONTAINER}."; exit 1; }
  fi
  docker rename "$NEW_STAGING" "$NEW_ACTIVE" >/dev/null || { err "Failed to rename ${NEW_STAGING}."; exit 1; }
  printf '%s\n' "$STAGE_PORT" > "$ACTIVE_PORT_FILE"
  log "Deployed ${VERSION} as ${NEW_ACTIVE} on port ${STAGE_PORT}."
  exit 0
fi

err "Staging container ${NEW_STAGING} failed its health check."
if [[ -n "$OLD_CONTAINER" ]]; then
  log "Invoking rollback to restore ${OLD_CONTAINER}."
  "$ROLLBACK_BIN" --new-container "$NEW_STAGING" --old-container "$OLD_CONTAINER" \
    --health-url "http://localhost:${ACTIVE_PORT}/health"
else
  log "No previous container to restore; removing ${NEW_STAGING}."
  docker rm --force "$NEW_STAGING" >/dev/null 2>&1 || true
fi
exit 1
