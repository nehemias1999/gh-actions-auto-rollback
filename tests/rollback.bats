#!/usr/bin/env bats
# Bats tests for scripts/rollback.sh (REQ-006).
# Hermetic: stubs the `docker` CLI with a fake executable on PATH and uses
# ephemeral python3 stub HTTP servers on 127.0.0.1; never a real daemon.

ROLLBACK="$BATS_TEST_DIRNAME/../scripts/rollback.sh"

# Find a free TCP port on 127.0.0.1 and print it.
_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Start a stub HTTP server in the background.
# $1: port, $2: mode (healthy | unhealthy)
# healthy: GET -> 200 {"status": "healthy"}
# unhealthy: GET -> 200 {"status": "sick"}
# Echoes the server PID.
_start_stub() {
  local port="$1" mode="$2"
  python3 - "$port" "$mode" >/dev/null 2>&1 <<'EOF' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port = int(sys.argv[1])
mode = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if mode == "healthy":
            body = b'{"status": "healthy"}'
            self.send_response(200)
        else:
            body = b'{"status": "sick"}'
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
  echo "$!"
}

# Install a fake `docker` CLI on PATH.
# $1: state dir. Expects $state_dir/ps_running and $state_dir/ps_all files
# (newline-separated container names). Calls are appended to $state_dir/calls.
_make_fake_docker() {
  local state_dir="$1"
  mkdir -p "$state_dir/bin"
  cat > "$state_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: logs calls, serves canned `ps` output. State via env files.
echo "docker $*" >> "$FAKE_STATE_DIR/calls"
cmd="${1:-}"
shift || true
case "$cmd" in
  stop|rm|start)
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

setup() {
  STATE_DIR="$(mktemp -d)"
  export FAKE_STATE_DIR="$STATE_DIR"
  : > "$STATE_DIR/calls"
  : > "$STATE_DIR/ps_running"
  : > "$STATE_DIR/ps_all"
  _make_fake_docker "$STATE_DIR"
  export PATH="$STATE_DIR/bin:$PATH"
}

teardown() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$STATE_DIR"
}

@test "successful rollback: stops new, keeps old running, exits 0" {
  port="$(_free_port)"
  STUB_PID="$(_start_stub "$port" healthy)"
  sleep 1
  printf 'old-app\n' > "$STATE_DIR/ps_running"
  printf 'old-app\nnew-app\n' > "$STATE_DIR/ps_all"
  run "$ROLLBACK" --new-container new-app --old-container old-app \
    --health-url "http://127.0.0.1:${port}/health" --retries 2 --interval 0 --timeout 2
  [ "$status" -eq 0 ]
  grep -q "docker stop new-app" "$STATE_DIR/calls"
  grep -q "docker rm new-app" "$STATE_DIR/calls"
}

@test "old container down: starts it and exits 0 when healthy" {
  port="$(_free_port)"
  STUB_PID="$(_start_stub "$port" healthy)"
  sleep 1
  : > "$STATE_DIR/ps_running"
  printf 'old-app\nnew-app\n' > "$STATE_DIR/ps_all"
  run "$ROLLBACK" --new-container new-app --old-container old-app \
    --health-url "http://127.0.0.1:${port}/health" --retries 2 --interval 0 --timeout 2
  [ "$status" -eq 0 ]
  grep -q "docker start old-app" "$STATE_DIR/calls"
}

@test "old container unhealthy: exits 1" {
  port="$(_free_port)"
  STUB_PID="$(_start_stub "$port" unhealthy)"
  sleep 1
  printf 'old-app\n' > "$STATE_DIR/ps_running"
  printf 'old-app\nnew-app\n' > "$STATE_DIR/ps_all"
  run "$ROLLBACK" --new-container new-app --old-container old-app \
    --health-url "http://127.0.0.1:${port}/health" --retries 2 --interval 0 --timeout 2
  [ "$status" -eq 1 ]
}

@test "missing docker CLI: exits 1 with clear error" {
  clean="$STATE_DIR/cleanbin"
  mkdir -p "$clean"
  for tool in bash date dirname grep; do
    p="$(command -v "$tool")"
    ln -sf "$p" "$clean/$tool"
  done
  PATH="$clean" run "$ROLLBACK" --new-container new-app --old-container old-app \
    --health-url "http://127.0.0.1:9/health" --retries 1 --interval 0 --timeout 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker"* ]]
}

@test "help: -h prints usage to stdout and exits 0" {
  run "$ROLLBACK" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "usage error: missing required flags exits 2" {
  run "$ROLLBACK" --new-container new-app
  [ "$status" -eq 2 ]
}

@test "idempotent: re-run after rollback exits 0" {
  port="$(_free_port)"
  STUB_PID="$(_start_stub "$port" healthy)"
  sleep 1
  printf 'old-app\n' > "$STATE_DIR/ps_running"
  printf 'old-app\n' > "$STATE_DIR/ps_all"
  run "$ROLLBACK" --new-container new-app --old-container old-app \
    --health-url "http://127.0.0.1:${port}/health" --retries 2 --interval 0 --timeout 2
  [ "$status" -eq 0 ]
  run "$ROLLBACK" --new-container new-app --old-container old-app \
    --health-url "http://127.0.0.1:${port}/health" --retries 2 --interval 0 --timeout 2
  [ "$status" -eq 0 ]
}
