#!/usr/bin/env bash
# ==============================================================================
# Description: Integration test runner for the full pipeline (CI + deploy +
#   healthcheck + rollback) executed locally with `act` (nektos/act). Runs
#   three scenarios — ci, deploy-success, deploy-rollback — each in an
#   isolated Docker network, and cleans up all test containers and networks
#   afterwards. When `act` is not installed, prints a skip message with the
#   install pointer and exits 0 (skip, not failure).
# Author: gh-actions-auto-rollback
# Usage: ./tests/integration.sh [ci|deploy-success|deploy-rollback]
# Env Vars: ACT_SECRETS_FILE (default .secrets.local; falls back to
#   .secrets.local.example template), TEST_IMAGE_HEALTHY (override health
#   flag for deploy scenarios), DOCKER_BIN (override docker path)
# Dependencies: act (nektos/act), docker
# Output / Exit codes: timestamped logs to STDOUT, errors to STDERR;
#   0 all scenarios pass (or skip when act is missing), 1 scenario failure,
#   2 usage error.
# Examples:
#   ./tests/integration.sh                  # run all three scenarios
#   ./tests/integration.sh ci               # CI workflow only
#   ./tests/integration.sh deploy-success   # healthy deploy only
#   ./tests/integration.sh deploy-rollback  # unhealthy deploy + rollback only
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DOCKER_BIN="${DOCKER_BIN:-docker}"
ACT_SECRETS_FILE="${ACT_SECRETS_FILE:-.secrets.local}"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
CURRENT_NETWORK=""
FAILURES=0

# Prints usage instructions to STDOUT.
usage() {
  cat <<'EOF'
Usage: ./tests/integration.sh [ci|deploy-success|deploy-rollback]

Run pipeline integration tests locally with act (nektos/act).

Scenarios:
  ci               Run `act pull_request` for the CI workflow and validate pass.
  deploy-success   Run `act push` for the deploy workflow with a healthy
                   image and validate successful deployment.
  deploy-rollback  Run `act push` for the deploy workflow with an unhealthy
                   image (failing healthcheck) and validate automatic rollback.

  (no argument)    Run all three scenarios in order.

Options:
  -h, --help       Show this help and exit 0.

Environment:
  ACT_SECRETS_FILE  Secrets file passed to act via --secret-file
                    (default: .secrets.local; see .secrets.local.example).
  DOCKER_BIN        Override docker binary path (default: docker).

Examples:
  ./tests/integration.sh
  ./tests/integration.sh ci
  ./tests/integration.sh deploy-rollback
EOF
}

# Timestamped info log to STDOUT.
log() {
  printf '%s [integration] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# Error log to STDERR.
err() {
  printf '%s [integration] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Checks that `act` is installed; otherwise prints a skip message with the
# install pointer and exits 0 (skip, not failure).
require_act() {
  if command -v act >/dev/null 2>&1; then
    return 0
  fi
  log "SKIP: 'act' is not installed in this environment; integration scenarios require act."
  log "SKIP: Install act to run them: https://github.com/nektos/act#installation"
  log "SKIP: (e.g. 'curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash')"
  log "SKIP: Then re-run: ./tests/integration.sh"
  exit 0
}

# Creates an isolated Docker network for one scenario run; echoes its name.
# Args: $1 = scenario name.
create_network() {
  local scenario="$1"
  local network="rb-int-${scenario}-${RUN_ID}"
  if command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
    "${DOCKER_BIN}" network create --driver bridge "${network}" >/dev/null 2>&1 || true
  fi
  printf '%s' "${network}"
}

# Removes test containers and the scenario network; safe to call twice.
# Args: $1 = network name.
cleanup_scenario() {
  local network="$1"
  if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
    return 0
  fi
  "${DOCKER_BIN}" ps --all --quiet --filter "label=rb-integration-run=${RUN_ID}" 2>/dev/null \
    | xargs --no-run-if-empty "${DOCKER_BIN}" rm --force >/dev/null 2>&1 || true
  if [ -n "${network}" ]; then
    "${DOCKER_BIN}" network rm "${network}" >/dev/null 2>&1 || true
  fi
}

# Resolves the secrets file flag for act (real file preferred, template fallback).
# Prints only the flag; callers log the fallback notice themselves.
act_secrets_flag() {
  if [ -f "${REPO_ROOT}/${ACT_SECRETS_FILE}" ]; then
    printf -- '--secret-file %s' "${ACT_SECRETS_FILE}"
  elif [ -f "${REPO_ROOT}/.secrets.local.example" ]; then
    printf -- '--secret-file %s' ".secrets.local.example"
  fi
}

# Logs which secrets file will be handed to act.
log_secrets_source() {
  if [ -f "${REPO_ROOT}/${ACT_SECRETS_FILE}" ]; then
    log "Using secrets file '${ACT_SECRETS_FILE}'."
  else
    log "No ${ACT_SECRETS_FILE} found; using .secrets.local.example template (no real secrets)."
  fi
}

# Runs one scenario in its own network with cleanup trap; returns 0/1.
# Args: $1 = scenario name (ci|deploy-success|deploy-rollback).
run_scenario() {
  local scenario="$1"
  CURRENT_NETWORK="$(create_network "${scenario}")"
  log "Scenario '${scenario}': using isolated network '${CURRENT_NETWORK}'."
  # shellcheck disable=SC2064
  trap "cleanup_scenario '${CURRENT_NETWORK}'" EXIT INT TERM
  local rc=0
  case "${scenario}" in
    ci)
      run_ci_scenario || rc=1
      ;;
    deploy-success)
      run_deploy_success_scenario || rc=1
      ;;
    deploy-rollback)
      run_deploy_rollback_scenario || rc=1
      ;;
  esac
  cleanup_scenario "${CURRENT_NETWORK}"
  trap - EXIT INT TERM
  if [ "${rc}" -eq 0 ]; then
    log "Scenario '${scenario}': PASS."
  else
    err "Scenario '${scenario}': FAIL."
  fi
  return "${rc}"
}

# AC-001: runs `act pull_request` for the CI workflow and validates pass.
run_ci_scenario() {
  log "AC-001: running CI workflow via 'act pull_request'."
  # shellcheck disable=SC2086
  act pull_request \
    --workflows "${REPO_ROOT}/.github/workflows/ci.yml" \
    --network "${CURRENT_NETWORK}" \
    --label "rb-integration-run=${RUN_ID}" \
    ${ACT_FLAG_SECRETS}
}

# AC-002: runs `act push` for the deploy workflow with a healthy image.
run_deploy_success_scenario() {
  log "AC-002: running deploy workflow via 'act push' with a healthy image."
  local healthy="${TEST_IMAGE_HEALTHY:-true}"
  # shellcheck disable=SC2086
  act push \
    --workflows "${REPO_ROOT}/.github/workflows/deploy-prod.yml" \
    --network "${CURRENT_NETWORK}" \
    --label "rb-integration-run=${RUN_ID}" \
    --env "TEST_IMAGE_HEALTHY=${healthy}" \
    ${ACT_FLAG_SECRETS}
}

# AC-003: runs `act push` for the deploy workflow with an unhealthy image
# (failing healthcheck) and validates automatic rollback.
run_deploy_rollback_scenario() {
  log "AC-003: running deploy workflow via 'act push' with an unhealthy image; expecting automatic rollback."
  # shellcheck disable=SC2086
  act push \
    --workflows "${REPO_ROOT}/.github/workflows/deploy-prod.yml" \
    --network "${CURRENT_NETWORK}" \
    --label "rb-integration-run=${RUN_ID}" \
    --env TEST_IMAGE_HEALTHY=false \
    ${ACT_FLAG_SECRETS}
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    ci | deploy-success | deploy-rollback)
      require_act
      log_secrets_source
      ACT_FLAG_SECRETS="$(act_secrets_flag)"
      export ACT_FLAG_SECRETS
      run_scenario "$1" || exit 1
      exit 0
      ;;
    "")
      require_act
      log_secrets_source
      ACT_FLAG_SECRETS="$(act_secrets_flag)"
      export ACT_FLAG_SECRETS
      local scenario
      for scenario in ci deploy-success deploy-rollback; do
        run_scenario "${scenario}" || FAILURES=$((FAILURES + 1))
      done
      if [ "${FAILURES}" -gt 0 ]; then
        err "${FAILURES} scenario(s) failed."
        exit 1
      fi
      log "All integration scenarios passed."
      exit 0
      ;;
    *)
      err "Unknown scenario '$1'. Expected ci|deploy-success|deploy-rollback."
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
