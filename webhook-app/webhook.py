#!/usr/bin/env python3
import hashlib
import hmac
import json
import os
import tempfile
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

SALT_SECRET = os.environ.get("SALT_SECRET", "")
VERSION_FILE = os.environ.get("VERSION_FILE", "/opt/quadlet-rollout/global_version")
BIND = os.environ.get("BIND", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
TZ_OFFSET_MINUTES = int(os.environ.get("TZ_OFFSET_MINUTES", "0"))


def floor_to_10min(dt: datetime) -> datetime:
    minute_window = (dt.minute // 10) * 10
    return dt.replace(minute=minute_window, second=0, microsecond=0)


def format_window(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M")


def derive_token(secret: str, window_str: str) -> str:
    return hmac.new(secret.encode("utf-8"), window_str.encode("utf-8"), hashlib.sha256).hexdigest()


def valid_token(secret: str, supplied: str) -> bool:
    if not supplied or not secret:
        return False

    now = datetime.now(timezone.utc) + timedelta(minutes=TZ_OFFSET_MINUTES)
    current = floor_to_10min(now)
    previous = current - timedelta(minutes=10)

    current_token = derive_token(secret, format_window(current))
    previous_token = derive_token(secret, format_window(previous))

    return hmac.compare_digest(supplied, current_token) or hmac.compare_digest(supplied, previous_token)


def atomic_write(path: str, content: str) -> None:
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(prefix=".global_version.", dir=directory or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    finally:
        try:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError:
            pass


class Handler(BaseHTTPRequestHandler):
    server_version = "quadlet-webhook/0.1"

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def _extract_inputs(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        body = self._read_json_body() if self.command == "POST" else {}

        token = (
            self.headers.get("X-Deploy-Token")
            or qs.get("token", [""])[0]
            or body.get("token", "")
        )
        sha = (
            self.headers.get("X-Deploy-Sha")
            or qs.get("sha", [""])[0]
            or body.get("sha", "")
        )
        return parsed.path, token.strip(), sha.strip()

    def _send(self, status: int, payload: dict):
        out = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        self.handle_deploy()

    def do_POST(self):
        self.handle_deploy()

    def handle_deploy(self):
        path, token, sha = self._extract_inputs()

        if path not in ("/deploy", "/healthz"):
            self._send(404, {"ok": False, "error": "not_found"})
            return

        if path == "/healthz":
            self._send(200, {"ok": True})
            return

        if not SALT_SECRET:
            self._send(500, {"ok": False, "error": "missing_secret"})
            return

        if not sha:
            self._send(400, {"ok": False, "error": "missing_sha"})
            return

        if not valid_token(SALT_SECRET, token):
            self._send(401, {"ok": False, "error": "invalid_token"})
            return

        try:
            atomic_write(VERSION_FILE, sha)
        except Exception as e:
            self._send(500, {"ok": False, "error": "write_failed", "detail": str(e)})
            return

        self._send(200, {"ok": True, "sha": sha})


def main():
    httpd = HTTPServer((BIND, PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
