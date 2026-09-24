#!/usr/bin/env bats
# Bats tests for scripts/healthcheck.sh (REQ-005).
# Hermetic: uses ephemeral python3 stub servers on 127.0.0.1; never the app image.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/healthcheck.sh"

# Find a free TCP port on 127.0.0.1 and print it.
_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Start a stub HTTP server in the background.
# $1: port, $2: mode (healthy | slow)
# healthy: GET /health -> 200 {"status": "healthy"}
# slow: sleeps 5s before responding (to trigger --timeout)
# Echoes the server PID.
_start_stub() {
  local port="$1" mode="$2"
  python3 - "$port" "$mode" >/dev/null 2>&1 <<'EOF' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
import time
port = int(sys.argv[1])
mode = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if mode == "slow":
            time.sleep(5)
        body = b'{"status": "healthy"}'
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

teardown() {
  # Stop any stub server started by the test.
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
}

@test "success: healthy endpoint exits 0 and logs the attempt" {
  port="$(_free_port)"
  STUB_PID="$(_start_stub "$port" healthy)"
  sleep 1
  run "$SCRIPT" --url "http://127.0.0.1:${port}/health" --retries 3 --interval 0 --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]]
}

@test "timeout: slow endpoint exhausts retries and exits 1" {
  port="$(_free_port)"
  STUB_PID="$(_start_stub "$port" slow)"
  sleep 1
  run "$SCRIPT" --url "http://127.0.0.1:${port}/health" --retries 2 --interval 0 --timeout 1
  [ "$status" -eq 1 ]
}

@test "retry exhaustion: unreachable port exits 1" {
  port="$(_free_port)"  # nothing listens here
  run "$SCRIPT" --url "http://127.0.0.1:${port}/health" --retries 2 --interval 0 --timeout 2
  [ "$status" -eq 1 ]
}

@test "help: -h prints usage to stdout and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "usage error: missing --url exits 2" {
  run "$SCRIPT" --retries 1
  [ "$status" -eq 2 ]
}
