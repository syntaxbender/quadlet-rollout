#!/usr/bin/env python3
import hashlib
import hmac
import json
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

SALT_SECRET = os.environ.get("SALT_SECRET", "")
VERSION_FILE = os.environ.get("VERSION_FILE", "/opt/quadlet-rollout/global_version")
BIND = os.environ.get("BIND", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8080"))
# CLOCK_SKEW_MINUTES: webhook host saati ile GitHub runner arasında fark varsa
# küçük düzeltme için kullanılır. Geriye uyum için TZ_OFFSET_MINUTES da desteklenir.
CLOCK_SKEW_MINUTES = int(os.environ.get("CLOCK_SKEW_MINUTES", os.environ.get("TZ_OFFSET_MINUTES", "0")))
MAX_HEADER_VALUE_LEN = int(os.environ.get("MAX_HEADER_VALUE_LEN", "128"))

SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")


def floor_to_10min(dt: datetime) -> datetime:
    minute_window = (dt.minute // 10) * 10
    return dt.replace(minute=minute_window, second=0, microsecond=0)


def format_window(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M")


def normalize_sha(raw: str) -> str:
    normalized = raw.strip().lower()
    if SHA_RE.fullmatch(normalized):
        return normalized
    return ""


def normalize_token(raw: str) -> str:
    normalized = raw.strip().lower()
    if TOKEN_RE.fullmatch(normalized):
        return normalized
    return ""


def derive_token(secret: str, window_str: str, sha: str) -> str:
    payload = f"{window_str}\n{sha}"
    return hmac.new(secret.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()


def valid_token(secret: str, supplied: str, sha: str) -> bool:
    if not supplied or not secret or not sha:
        return False

    now = datetime.now(timezone.utc) + timedelta(minutes=CLOCK_SKEW_MINUTES)
    current = floor_to_10min(now)
    previous = current - timedelta(minutes=10)

    current_token = derive_token(secret, format_window(current), sha)
    previous_token = derive_token(secret, format_window(previous), sha)

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

    def _extract_inputs(self):
        parsed = urlparse(self.path)
        token = self.headers.get("X-Deploy-Token", "")
        sha = self.headers.get("X-Deploy-Sha", "")
        return parsed, token, sha

    def _send(self, status: int, payload: dict):
        out = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self._send(200, {"ok": True})
            return
        if parsed.path == "/deploy":
            self._send(405, {"ok": False, "error": "method_not_allowed"})
            return
        self._send(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        self.handle_deploy()

    def handle_deploy(self):
        parsed, token_raw, sha_raw = self._extract_inputs()
        path = parsed.path

        if path not in ("/deploy", "/healthz"):
            self._send(404, {"ok": False, "error": "not_found"})
            return

        if path == "/healthz":
            self._send(200, {"ok": True})
            return

        if not SALT_SECRET:
            self._send(500, {"ok": False, "error": "missing_secret"})
            return

        if parsed.query:
            self._send(400, {"ok": False, "error": "query_not_allowed"})
            return

        if len(token_raw) > MAX_HEADER_VALUE_LEN or len(sha_raw) > MAX_HEADER_VALUE_LEN:
            self._send(400, {"ok": False, "error": "header_too_long"})
            return

        sha = normalize_sha(sha_raw)
        if not sha:
            self._send(400, {"ok": False, "error": "invalid_sha"})
            return

        token = normalize_token(token_raw)
        if not token:
            self._send(401, {"ok": False, "error": "invalid_token"})
            return

        if not valid_token(SALT_SECRET, token, sha):
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
