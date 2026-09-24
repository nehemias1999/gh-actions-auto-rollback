#!/usr/bin/env bats
# Bats tests for scripts/deploy.sh (REQ-007).
# Hermetic: stubs the `docker` CLI with a fake executable plus shim
# healthcheck.sh/rollback.sh injected via DEPLOY_HEALTHCHECK_BIN and
# DEPLOY_ROLLBACK_BIN; never touches a real Docker daemon.

DEPLOY="$BATS_TEST_DIRNAME/../scripts/deploy.sh"

# Install a fake `docker` CLI on PATH.
# Serves canned `ps` output from $FAKE_STATE_DIR/ps_running (docker ps)
# and ps_all (docker ps -a); appends every call to $FAKE_STATE_DIR/calls.
_make_fake_docker() {
  local state_dir="$1"
  mkdir -p "$state_dir/bin"
  cat > "$state_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_STATE_DIR/calls"
cmd="${1:-}"
shift || true
case "$cmd" in
  run|stop|rm|rename|start)
    exit 0
    ;;
  ps)
    if [[ "$*" == *"-a"* ]]; then
      cat "$FAKE_STATE_DIR/ps_all"
    else
      cat "$FAKE_STATE_DIR/ps_running"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$state_dir/bin/docker"
}

# Install a shim healthcheck.sh.
# Exit code per call: pops the first line of $FAKE_STATE_DIR/health_seq when
# non-empty; otherwise reads $FAKE_STATE_DIR/health_<port> (from --url);
# defaults to 1 when neither exists.
_make_healthcheck_shim() {
  local state_dir="$1"
  cat > "$state_dir/bin/healthcheck.sh" <<'EOF'
#!/usr/bin/env bash
echo "healthcheck $*" >> "$FAKE_STATE_DIR/calls"
seq="$FAKE_STATE_DIR/health_seq"
if [[ -s "$seq" ]]; then
  code="$(head -n 1 "$seq")"
  tail -n +2 "$seq" > "$seq.tmp" && mv "$seq.tmp" "$seq"
  exit "$code"
fi
url=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--url" ]]; then url="$a"; fi
  prev="$a"
done
port="$(printf '%s' "$url" | sed -n 's#.*:\([0-9][0-9]*\)/.*#\1#p')"
f="$FAKE_STATE_DIR/health_$port"
if [[ -f "$f" ]]; then exit "$(cat "$f")"; fi
exit 1
EOF
  chmod +x "$state_dir/bin/healthcheck.sh"
}

# Install a shim rollback.sh that logs its args and exits $ROLLBACK_EXIT (0).
_make_rollback_shim() {
  local state_dir="$1"
  cat > "$state_dir/bin/rollback.sh" <<'EOF'
#!/usr/bin/env bash
echo "rollback $*" >> "$FAKE_STATE_DIR/calls"
exit "${ROLLBACK_EXIT:-0}"
EOF
  chmod +x "$state_dir/bin/rollback.sh"
}

setup() {
  STATE_DIR="$(mktemp -d)"
  export FAKE_STATE_DIR="$STATE_DIR"
  : > "$STATE_DIR/calls"
  : > "$STATE_DIR/ps_running"
  : > "$STATE_DIR/ps_all"
  : > "$STATE_DIR/health_seq"
  _make_fake_docker "$STATE_DIR"
  _make_healthcheck_shim "$STATE_DIR"
  _make_rollback_shim "$STATE_DIR"
  export PATH="$STATE_DIR/bin:$PATH"
  export DEPLOY_HEALTHCHECK_BIN="$STATE_DIR/bin/healthcheck.sh"
  export DEPLOY_ROLLBACK_BIN="$STATE_DIR/bin/rollback.sh"
  export ACTIVE_PORT_FILE="$STATE_DIR/active-port"
}

teardown() {
  rm -rf "$STATE_DIR"
}

@test "success: stages on idle port, switches, writes active-port, exits 0" {
  printf '0' > "$STATE_DIR/health_8080"
  printf '0' > "$STATE_DIR/health_8081"
  printf 'app-v1-active\n' > "$STATE_DIR/ps_running"
  printf 'app-v1-active\n' > "$STATE_DIR/ps_all"
  run "$DEPLOY" --version v2.0.0 --image example/app:v2.0.0
  [ "$status" -eq 0 ]
  grep -q "docker run.*app-v2.0.0-staging" "$STATE_DIR/calls"
  grep -q "docker stop app-v1-active" "$STATE_DIR/calls"
  grep -q "docker rename app-v2.0.0-staging app-v2.0.0-active" "$STATE_DIR/calls"
  [ "$(cat "$STATE_DIR/active-port")" = "8081" ]
  ! grep -q "^rollback " "$STATE_DIR/calls"
}

@test "failure: unhealthy staging invokes rollback and exits 1" {
  printf '0' > "$STATE_DIR/health_8080"
  printf '1' > "$STATE_DIR/health_8081"
  printf 'app-v1-active\n' > "$STATE_DIR/ps_running"
  printf 'app-v1-active\n' > "$STATE_DIR/ps_all"
  run "$DEPLOY" --version v2.0.0 --image example/app:v2.0.0
  [ "$status" -eq 1 ]
  grep -q "rollback --new-container app-v2.0.0-staging --old-container app-v1-active --health-url http://localhost:8080/health" "$STATE_DIR/calls"
  [ ! -f "$STATE_DIR/active-port" ]
}

@test "idempotent: re-run with same active+healthy version exits 0 without churn" {
  printf '0' > "$STATE_DIR/health_8080"
  printf 'app-v2.0.0-active\n' > "$STATE_DIR/ps_running"
  printf 'app-v2.0.0-active\n' > "$STATE_DIR/ps_all"
  run "$DEPLOY" --version v2.0.0 --image example/app:v2.0.0
  [ "$status" -eq 0 ]
  ! grep -q "docker run" "$STATE_DIR/calls"
  ! grep -q "docker rename" "$STATE_DIR/calls"
  ! grep -q "docker stop" "$STATE_DIR/calls"
}

@test "fresh deploy: no healthy port deploys without stopping old, exits 0" {
  printf '1\n1\n0\n' > "$STATE_DIR/health_seq"
  run "$DEPLOY" --version v1.0.0 --image example/app:v1.0.0
  [ "$status" -eq 0 ]
  grep -q "docker run.*app-v1.0.0-staging" "$STATE_DIR/calls"
  ! grep -q "docker stop" "$STATE_DIR/calls"
  ! grep -q "^rollback " "$STATE_DIR/calls"
  [ "$(cat "$STATE_DIR/active-port")" = "8081" ]
}

@test "stale staging: leftover container from same version is removed before run" {
  printf '0' > "$STATE_DIR/health_8080"
  printf '0' > "$STATE_DIR/health_8081"
  printf 'app-v1-active\n' > "$STATE_DIR/ps_running"
  printf 'app-v1-active\napp-v2.0.0-staging\n' > "$STATE_DIR/ps_all"
  run "$DEPLOY" --version v2.0.0 --image example/app:v2.0.0
  [ "$status" -eq 0 ]
  grep -q "docker rm.*app-v2.0.0-staging" "$STATE_DIR/calls"
  grep -q "docker rename app-v2.0.0-staging app-v2.0.0-active" "$STATE_DIR/calls"
}

@test "help: -h prints usage to stdout and exits 0" {
  run "$DEPLOY" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "usage error: missing required flags exits 2" {
  run "$DEPLOY" --version v1.0.0
  [ "$status" -eq 2 ]
}
