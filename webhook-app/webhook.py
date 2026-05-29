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
# TOKEN_TOLERANCE_MINUTES: now etrafında kabul edilen +/- dakika aralığı.
TOKEN_TOLERANCE_MINUTES = int(os.environ.get("TOKEN_TOLERANCE_MINUTES", "5"))
MAX_HEADER_VALUE_LEN = int(os.environ.get("MAX_HEADER_VALUE_LEN", "128"))

if TOKEN_TOLERANCE_MINUTES < 0:
    raise ValueError("TOKEN_TOLERANCE_MINUTES must be >= 0")

SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
TIME_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def normalize_time_utc(raw: str) -> str:
    normalized = raw.strip()
    if TIME_UTC_RE.fullmatch(normalized):
        return normalized
    return ""


def parse_time_utc(raw: str):
    try:
        return datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


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


def derive_token(secret: str, time_utc: str, sha: str) -> str:
    payload = f"{time_utc}\n{sha}"
    return hmac.new(secret.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()


def valid_token(secret: str, supplied: str, sha: str, time_utc: str) -> bool:
    if not supplied or not secret or not sha or not time_utc:
        return False
    expected = derive_token(secret, time_utc, sha)
    return hmac.compare_digest(supplied, expected)


def within_tolerance(ts_utc: datetime) -> bool:
    now_utc = datetime.now(timezone.utc)
    age_seconds = abs((now_utc - ts_utc).total_seconds())
    return age_seconds <= TOKEN_TOLERANCE_MINUTES * 60


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
        time_utc = self.headers.get("X-Deploy-Time-UTC", "")
        return parsed, token, sha, time_utc

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
        parsed, token_raw, sha_raw, time_utc_raw = self._extract_inputs()
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

        if (
            len(token_raw) > MAX_HEADER_VALUE_LEN
            or len(sha_raw) > MAX_HEADER_VALUE_LEN
            or len(time_utc_raw) > MAX_HEADER_VALUE_LEN
        ):
            self._send(400, {"ok": False, "error": "header_too_long"})
            return

        time_utc = normalize_time_utc(time_utc_raw)
        if not time_utc:
            self._send(400, {"ok": False, "error": "invalid_time_utc"})
            return

        ts_utc = parse_time_utc(time_utc)
        if ts_utc is None:
            self._send(400, {"ok": False, "error": "invalid_time_utc"})
            return

        if not within_tolerance(ts_utc):
            self._send(401, {"ok": False, "error": "timestamp_outside_tolerance"})
            return

        sha = normalize_sha(sha_raw)
        if not sha:
            self._send(400, {"ok": False, "error": "invalid_sha"})
            return

        token = normalize_token(token_raw)
        if not token:
            self._send(401, {"ok": False, "error": "invalid_token"})
            return

        if not valid_token(SALT_SECRET, token, sha, time_utc):
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
