#!/usr/bin/env bash
# Exercise a real curl cookie jar and the two CSRF epochs with a local-only fake panel.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
server_pid=""
shutdown() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tmp"
}
trap shutdown EXIT

cat > "$tmp/mock-panel.py" <<'PY'
import http.server
import json
import pathlib
import sys

port_file = pathlib.Path(sys.argv[1])
posted_file = pathlib.Path(sys.argv[2])


class Panel(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def json(self, data, status=200, cookie=None):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", f"sid={cookie}; Path=/fixturebase/; HttpOnly")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        cookie = self.headers.get("Cookie", "")
        if self.path == "/fixturebase/csrf-token":
            is_auth = "sid=auth" in cookie
            self.json({"success": True, "obj": "auth-token" if is_auth else "anon-token"},
                      cookie=None if is_auth else "anon")
        elif self.path == "/fixturebase/panel/api/inbounds/list":
            if "sid=auth" not in cookie:
                self.json({"success": False}, 401)
            else:
                self.json({"success": True, "obj": []})
        elif self.path == "/fixturebase/panel/api/server/getNewX25519Cert":
            if "sid=auth" not in cookie:
                self.json({"success": False}, 401)
            else:
                self.json({"success": True, "obj": {"privateKey": "fixture-private",
                                                   "publicKey": "fixture-public"}})
        else:
            self.json({"success": False}, 404)

    def do_POST(self):
        content = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        cookie = self.headers.get("Cookie", "")
        token = self.headers.get("X-CSRF-Token", "")
        if self.path == "/fixturebase/login":
            credentials = json.loads(content)
            if (cookie != "sid=anon" or token != "anon-token" or
                    credentials.get("username") != "testuser" or
                    credentials.get("password") != "testpass"):
                self.json({"success": False, "msg": "CSRF/login rejected"}, 403)
                return
            self.json({"success": True}, cookie="auth")
        elif self.path == "/fixturebase/panel/api/inbounds/add":
            inbound = json.loads(content)
            if (cookie != "sid=auth" or token != "auth-token" or
                    inbound.get("port") != 2443 or
                    inbound.get("protocol") != "vless"):
                self.json({"success": False, "msg": "CSRF/inbound rejected"}, 403)
                return
            posted_file.write_text("ok", encoding="utf-8")
            self.json({"success": True})
        else:
            self.json({"success": False}, 404)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Panel)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY

python3 "$tmp/mock-panel.py" "$tmp/port" "$tmp/posted" &
server_pid="$!"
for _ in $(seq 1 100); do
  [[ -s "$tmp/port" ]] && break
  sleep 0.05
done
[[ -s "$tmp/port" ]] || { echo "Mock panel did not start" >&2; exit 1; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/ss" <<'SH'
#!/bin/sh
echo 'LISTEN 0 128 127.0.0.1:2443'
SH
chmod +x "$tmp/bin/ss"
export PATH="$tmp/bin:$PATH"

# Sourcing install.sh is safe: its guarded main only runs when executed.
# shellcheck disable=SC1091
. "$root/install.sh"
trap 'cleanup; shutdown' EXIT

PANEL_PORT=$(cat "$tmp/port")
PANEL_BASE="/fixturebase/"
PANEL_USER="testuser"
PANEL_PASSWORD="testpass"
XRAY_INTERNAL_PORT_DEFAULT=2443
panel_login
ensure_reality_port_free_in_panel
create_reality_inbound
[[ -f "$tmp/posted" ]] && [[ $(cat "$tmp/posted") == "ok" ]] ||
  { echo "Authenticated inbound request did not reach mock panel" >&2; exit 1; }
echo "3x-ui CSRF cookie + post-login token refresh test passed"