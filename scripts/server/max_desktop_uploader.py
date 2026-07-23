#!/usr/bin/env python3
"""Authenticated HTTP upload for MAX Desktop updates (stdlib only).

POST /upload?name=MAX-Desktop-Setup-1.0.18.exe
  Authorization: Bearer <token>
  X-Latest-Json: {"version":"1.0.18","build":20,...}   (optional, utf-8)
  Body: raw installer bytes (application/octet-stream)

GET /healthz — liveness
"""
from __future__ import annotations

import json
import os
import shutil
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

WEB_ROOT = Path(os.environ.get("MAX_UPDATE_WEB_ROOT", "/var/www/max-desktop"))
TOKEN = os.environ.get("MAX_DEPLOY_TOKEN", "").strip()
HOST = os.environ.get("MAX_UPLOAD_HOST", "127.0.0.1")
PORT = int(os.environ.get("MAX_UPLOAD_PORT", "8091"))
MAX_BYTES = int(os.environ.get("MAX_UPLOAD_MAX_BYTES", str(250 * 1024 * 1024)))


def _authorized(handler: BaseHTTPRequestHandler) -> bool:
    if not TOKEN:
        return False
    auth = handler.headers.get("Authorization", "")
    if auth == f"Bearer {TOKEN}":
        return True
    return handler.headers.get("X-Deploy-Token", "") == TOKEN


class Handler(BaseHTTPRequestHandler):
    server_version = "MaxDesktopUploader/1.0"

    def log_message(self, fmt: str, *args) -> None:
        import sys

        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if urlparse(self.path).path in ("/healthz", "/health"):
            self._send(200, {"ok": True})
            return
        self._send(404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/upload":
            self._send(404, {"ok": False, "error": "not_found"})
            return
        if not _authorized(self):
            self._send(401, {"ok": False, "error": "unauthorized"})
            return

        qs = parse_qs(parsed.query)
        setup_name = (qs.get("name") or [None])[0] or self.headers.get("X-Setup-Name", "")
        setup_name = Path(setup_name).name
        if not setup_name.endswith(".exe") or ".." in setup_name:
            self._send(400, {"ok": False, "error": "bad_setup_name"})
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > MAX_BYTES:
            self._send(413, {"ok": False, "error": "bad_size", "max": MAX_BYTES})
            return

        latest_header = self.headers.get("X-Latest-Json")
        latest_obj = None
        if latest_header:
            try:
                latest_obj = json.loads(latest_header)
            except json.JSONDecodeError:
                self._send(400, {"ok": False, "error": "bad_latest_json"})
                return
            if not isinstance(latest_obj, dict) or "version" not in latest_obj or "build" not in latest_obj:
                self._send(400, {"ok": False, "error": "latest_missing_fields"})
                return

        WEB_ROOT.mkdir(parents=True, exist_ok=True)
        dest = WEB_ROOT / setup_name
        tmp_dir = Path(tempfile.mkdtemp(prefix="max-upload-"))
        try:
            tmp_setup = tmp_dir / setup_name
            remaining = length
            with open(tmp_setup, "wb") as out:
                while remaining > 0:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise IOError("unexpected EOF")
                    out.write(chunk)
                    remaining -= len(chunk)
            # /tmp and /var/www may be different filesystems — os.replace can raise EXDEV.
            try:
                os.replace(tmp_setup, dest)
            except OSError:
                shutil.copy2(tmp_setup, dest)
                tmp_setup.unlink(missing_ok=True)

            latest_updated = False
            latest_path = WEB_ROOT / "latest.json"
            if latest_obj is not None:
                tmp_latest = tmp_dir / "latest.json"
                tmp_latest.write_text(
                    json.dumps(latest_obj, ensure_ascii=False, separators=(",", ":")),
                    encoding="utf-8",
                )
                try:
                    os.replace(tmp_latest, latest_path)
                except OSError:
                    shutil.copy2(tmp_latest, latest_path)
                    tmp_latest.unlink(missing_ok=True)
                latest_updated = True

            latest_link = WEB_ROOT / "MAX-Desktop-Setup-latest.exe"
            if latest_link.exists() or latest_link.is_symlink():
                latest_link.unlink()
            latest_link.symlink_to(setup_name)

            try:
                shutil.chown(dest, user="www-data", group="www-data")
                if latest_updated:
                    shutil.chown(latest_path, user="www-data", group="www-data")
            except Exception:
                pass
            os.chmod(dest, 0o644)
            if latest_path.exists():
                os.chmod(latest_path, 0o644)
        except Exception as exc:
            self._send(500, {"ok": False, "error": "write_failed", "detail": str(exc)})
            return
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

        self._send(200, {"ok": True, "setup": setup_name, "latest_updated": latest_updated})


def main() -> None:
    if not TOKEN:
        raise SystemExit("MAX_DEPLOY_TOKEN is required")
    WEB_ROOT.mkdir(parents=True, exist_ok=True)
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"max-desktop-uploader on {HOST}:{PORT} root={WEB_ROOT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
