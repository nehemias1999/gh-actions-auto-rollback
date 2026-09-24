#!/usr/bin/env bash
# ==============================================================================
# Description: Performs automated rollback by stopping and removing the new
#   container, ensuring the old container is running, and verifying it is
#   healthy. Used by the automated rollback pipeline when a deployment fails
#   its health gate: exit 0 keeps the old release serving, exit 1 signals the
#   rollback itself failed.
# Author: gh-actions-auto-rollback maintainers
# Usage: ./scripts/rollback.sh --new-container <name> --old-container <name>
#   --health-url <endpoint> [--retries N] [--interval S] [--timeout S]
# Env Vars: None.
# Dependencies: docker, ./scripts/healthcheck.sh (resolved relative to this
#   script so it works from any cwd).
# Exit codes: 0 rollback succeeded (old container running and healthy);
#   1 rollback failed (docker missing, old container missing or unhealthy);
#   2 usage error (missing/invalid arguments).
# ==============================================================================

set -u

# Print CLI help to STDOUT.
usage() {
  cat <<'EOF'
Usage: rollback.sh --new-container <name> --old-container <name> --health-url <endpoint> [--retries N] [--interval S] [--timeout S]

Performs automated rollback: stops and removes the new container, ensures the
old container is running (starts it if stopped), and runs a health check on
the old container via healthcheck.sh.

Options:
  --new-container <name>   New (failed) container to stop and remove (required).
  --old-container <name>   Previous container to restore (required).
  --health-url <endpoint>  Health endpoint of the old container (required).
  --retries <N>            Health check max attempts, passed through to
                           healthcheck.sh (default: 10, must be >= 1).
  --interval <S>           Seconds between health check attempts, passed through
                           to healthcheck.sh (default: 3, must be >= 0).
  --timeout <S>            Per-request timeout in seconds, passed through to
                           healthcheck.sh (default: 2, must be >= 1).
  -h, --help               Print this help to STDOUT and exit 0.

Exit codes: 0 rollback succeeded, 1 rollback failed, 2 usage error.
EOF
}

# Log an informational message with timestamp to STDOUT.
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

# Report an error with timestamp to STDERR.
err() {
  printf '%s rollback: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

# Report a usage error to STDERR and exit 2.
usage_error() {
  printf '%s rollback: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >&2
  printf 'rollback: try --help for usage.\n' >&2
  exit 2
}

# Return 0 when $1 is a non-negative integer, 1 otherwise.
is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

NEW_CONTAINER=""
OLD_CONTAINER=""
HEALTH_URL=""
RETRIES=10
INTERVAL=3
TIMEOUT=2

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --new-container)
      [ "$#" -ge 2 ] || usage_error "missing value for --new-container."
      NEW_CONTAINER="$2"
      shift 2
      ;;
    --new-container=*)
      NEW_CONTAINER="${1#--new-container=}"
      shift
      ;;
    --old-container)
      [ "$#" -ge 2 ] || usage_error "missing value for --old-container."
      OLD_CONTAINER="$2"
      shift 2
      ;;
    --old-container=*)
      OLD_CONTAINER="${1#--old-container=}"
      shift
      ;;
    --health-url)
      [ "$#" -ge 2 ] || usage_error "missing value for --health-url."
      HEALTH_URL="$2"
      shift 2
      ;;
    --health-url=*)
      HEALTH_URL="${1#--health-url=}"
      shift
      ;;
    --retries)
      [ "$#" -ge 2 ] || usage_error "missing value for --retries."
      RETRIES="$2"
      shift 2
      ;;
    --retries=*)
      RETRIES="${1#--retries=}"
      shift
      ;;
    --interval)
      [ "$#" -ge 2 ] || usage_error "missing value for --interval."
      INTERVAL="$2"
      shift 2
      ;;
    --interval=*)
      INTERVAL="${1#--interval=}"
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage_error "missing value for --timeout."
      TIMEOUT="$2"
      shift 2
      ;;
    --timeout=*)
      TIMEOUT="${1#--timeout=}"
      shift
      ;;
    --*)
      usage_error "unknown option: $1."
      ;;
    *)
      usage_error "unexpected positional argument: $1 (long flags only)."
      ;;
  esac
done

[ -n "$NEW_CONTAINER" ] || usage_error "missing required --new-container <name>."
[ -n "$OLD_CONTAINER" ] || usage_error "missing required --old-container <name>."
[ -n "$HEALTH_URL" ] || usage_error "missing required --health-url <endpoint>."
is_non_negative_int "$RETRIES" && [ "$RETRIES" -ge 1 ] \
  || usage_error "--retries must be an integer >= 1 (got: $RETRIES)."
is_non_negative_int "$INTERVAL" \
  || usage_error "--interval must be an integer >= 0 (got: $INTERVAL)."
is_non_negative_int "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] \
  || usage_error "--timeout must be an integer >= 1 (got: $TIMEOUT)."

command -v docker >/dev/null 2>&1 \
  || { err "docker CLI not found; install docker to perform rollback."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEALTHCHECK="$SCRIPT_DIR/healthcheck.sh"
[ -x "$HEALTHCHECK" ] \
  || { err "healthcheck.sh not found or not executable at $HEALTHCHECK."; exit 1; }

log "Stopping new container: $NEW_CONTAINER"
if docker stop "$NEW_CONTAINER" >/dev/null 2>&1; then
  log "Stopped new container: $NEW_CONTAINER"
else
  log "New container already stopped or missing (tolerated): $NEW_CONTAINER"
fi

log "Removing new container: $NEW_CONTAINER"
if docker rm "$NEW_CONTAINER" >/dev/null 2>&1; then
  log "Removed new container: $NEW_CONTAINER"
else
  log "New container already removed or missing (tolerated): $NEW_CONTAINER"
fi

log "Verifying old container is running: $OLD_CONTAINER"
RUNNING_NAMES="$(docker ps --format '{{.Names}}' 2>/dev/null)" || {
  err "failed to list running containers (docker ps)."
  exit 1
}
if printf '%s\n' "$RUNNING_NAMES" | grep --quiet --line-regexp -- "$OLD_CONTAINER"; then
  log "Old container already running: $OLD_CONTAINER"
else
  ALL_NAMES="$(docker ps --all --format '{{.Names}}' 2>/dev/null)" || {
    err "failed to list all containers (docker ps --all)."
    exit 1
  }
  if printf '%s\n' "$ALL_NAMES" | grep --quiet --line-regexp -- "$OLD_CONTAINER"; then
    log "Old container stopped; starting: $OLD_CONTAINER"
    if docker start "$OLD_CONTAINER" >/dev/null 2>&1; then
      log "Started old container: $OLD_CONTAINER"
    else
      err "failed to start old container: $OLD_CONTAINER."
      exit 1
    fi
  else
    err "old container not found: $OLD_CONTAINER."
    exit 1
  fi
fi

log "Running health check on old container via healthcheck.sh: $HEALTH_URL"
if "$HEALTHCHECK" --url "$HEALTH_URL" --retries "$RETRIES" --interval "$INTERVAL" --timeout "$TIMEOUT"; then
  log "Rollback succeeded; old container healthy: $OLD_CONTAINER"
  exit 0
else
  err "old container failed health check: $OLD_CONTAINER ($HEALTH_URL)."
  exit 1
fi
