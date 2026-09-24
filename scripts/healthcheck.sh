#!/usr/bin/env bash
# ==============================================================================
# Description: Polls an HTTP health endpoint until it reports healthy or the
#   retry budget is exhausted. Used by the automated rollback pipeline to gate
#   deployments: exit 0 keeps the new release, exit 1 triggers a rollback.
# Author: gh-actions-auto-rollback maintainers
# Usage: ./scripts/healthcheck.sh --url <health-endpoint> [--retries 10]
#   [--interval 3] [--timeout 2]
# Env Vars: None.
# Dependencies: curl, python3 (tests only, for the local stub server),
#   jq (optional; exact grep fallback is used when jq is unavailable).
# Exit codes: 0 healthy (HTTP 200 and body {"status": "healthy"} observed
#   within the retry budget); 1 unhealthy (retries exhausted or timeout on
#   every attempt); 2 usage error (missing/invalid arguments).
# ==============================================================================

set -u

# Print CLI help to STDOUT.
usage() {
  cat <<'EOF'
Usage: healthcheck.sh --url <health-endpoint> [--retries N] [--interval S] [--timeout S]

Polls an HTTP health endpoint until it returns 200 OK with body
{"status": "healthy"}, or until the retry budget is exhausted.

Options:
  --url <endpoint>   Health endpoint to poll (required).
  --retries <N>      Max attempts (default: 10, must be >= 1).
  --interval <S>     Seconds to wait between attempts (default: 3, must be >= 0).
  --timeout <S>      Per-request timeout in seconds, passed to curl
                     --max-time (default: 2, must be >= 1).
  -h, --help         Print this help to STDOUT and exit 0.

Exit codes: 0 healthy, 1 retries exhausted, 2 usage error.
EOF
}

# Return 0 when $1 is a non-negative integer, 1 otherwise.
is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Report a usage error to STDERR and exit 2.
usage_error() {
  printf 'healthcheck: %s\n' "$1" >&2
  printf 'healthcheck: try --help for usage.\n' >&2
  exit 2
}

# Check one response body file for the healthy marker.
# $1: path to the body file. Returns 0 when the service reports healthy.
is_healthy_body() {
  local body_file="$1"
  local body_status
  if command -v jq >/dev/null 2>&1; then
    body_status="$(jq --raw-output '.status // empty' "$body_file" 2>/dev/null)" || return 1
    [ "$body_status" = "healthy" ]
  else
    grep --quiet '"status"[[:space:]]*:[[:space:]]*"healthy"' "$body_file" 2>/dev/null
  fi
}

URL=""
RETRIES=10
INTERVAL=3
TIMEOUT=2

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --url)
      [ "$#" -ge 2 ] || usage_error "missing value for --url."
      URL="$2"
      shift 2
      ;;
    --url=*)
      URL="${1#--url=}"
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

[ -n "$URL" ] || usage_error "missing required --url <health-endpoint>."
is_non_negative_int "$RETRIES" && [ "$RETRIES" -ge 1 ] \
  || usage_error "--retries must be an integer >= 1 (got: $RETRIES)."
is_non_negative_int "$INTERVAL" \
  || usage_error "--interval must be an integer >= 0 (got: $INTERVAL)."
is_non_negative_int "$TIMEOUT" && [ "$TIMEOUT" -ge 1 ] \
  || usage_error "--timeout must be an integer >= 1 (got: $TIMEOUT)."

BODY_FILE="$(mktemp)" || { printf 'healthcheck: cannot create temp file.\n' >&2; exit 1; }
trap 'rm --force "$BODY_FILE"' EXIT

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
  start_seconds="$SECONDS"
  http_code="$(curl --silent --output "$BODY_FILE" --write-out "%{http_code}" \
    --max-time "$TIMEOUT" "$URL" 2>/dev/null)" || http_code="000"
  elapsed_seconds="$((SECONDS - start_seconds))"
  printf 'Attempt %s/%s: GET %s -> HTTP %s in %ss\n' \
    "$attempt" "$RETRIES" "$URL" "$http_code" "$elapsed_seconds"

  if [ "$http_code" = "200" ] && is_healthy_body "$BODY_FILE"; then
    printf 'Healthcheck passed on attempt %s/%s.\n' "$attempt" "$RETRIES"
    exit 0
  fi

  if [ "$attempt" -lt "$RETRIES" ]; then
    sleep "$INTERVAL"
  fi
  attempt="$((attempt + 1))"
done

printf 'healthcheck: endpoint %s did not report healthy after %s attempt(s).\n' \
  "$URL" "$RETRIES" >&2
exit 1
