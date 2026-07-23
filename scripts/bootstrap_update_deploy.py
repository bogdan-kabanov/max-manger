#!/usr/bin/env python3
"""One-time bootstrap: deploy SSH key + HTTP uploader on the update server.

Requires UPDATE_SERVER_PASSWORD (or MAX_SSH_PASS) once. After this, use:
  .\\scripts\\deploy_update.ps1
which uploads over HTTP with the local token (no interactive SSH).
"""
from __future__ import annotations

import os
import secrets
import sys
from pathlib import Path

import paramiko

HOST = os.environ.get("UPDATE_SERVER_HOST", "145.63.130.142")
USER = os.environ.get("UPDATE_SERVER_USER", "root")
PASSWORD = os.environ.get("UPDATE_SERVER_PASSWORD") or os.environ.get("MAX_SSH_PASS")
WEB_ROOT = "/var/www/max-desktop"
UPLOAD_PORT = int(os.environ.get("MAX_UPLOAD_PORT", "8091"))

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent
SERVER_DIR = SCRIPTS / "server"
LOCAL_SECRETS = SCRIPTS / ".deploy_secrets"
DEPLOY_KEY = Path.home() / ".ssh" / "max_desktop_deploy"
USER_PUB = Path.home() / ".ssh" / "id_ed25519.pub"


def _run(client: paramiko.SSHClient, cmd: str, check: bool = True) -> tuple[int, str, str]:
    _, stdout, stderr = client.exec_command(cmd)
    code = stdout.channel.recv_exit_status()
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    if check and code != 0:
        raise RuntimeError(f"cmd failed ({code}): {cmd}\n{out}\n{err}")
    return code, out, err


def _ensure_local_deploy_key() -> str:
    DEPLOY_KEY.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not DEPLOY_KEY.exists():
        # Passphrase-less key dedicated to deploys — never hangs on agent prompt.
        import subprocess

        subprocess.run(
            [
                "ssh-keygen",
                "-t",
                "ed25519",
                "-f",
                str(DEPLOY_KEY),
                "-N",
                "",
                "-C",
                "max-desktop-deploy",
            ],
            check=True,
        )
    pub = (DEPLOY_KEY.with_suffix(".pub")).read_text(encoding="utf-8").strip()
    return pub


def main() -> int:
    if not PASSWORD:
        print(
            "Set UPDATE_SERVER_PASSWORD (or MAX_SSH_PASS) once for bootstrap.",
            file=sys.stderr,
        )
        return 1

    deploy_pub = _ensure_local_deploy_key()
    pubs = [deploy_pub]
    if USER_PUB.exists():
        pubs.append(USER_PUB.read_text(encoding="utf-8").strip())

    token = secrets.token_urlsafe(32)
    uploader_py = (SERVER_DIR / "max_desktop_uploader.py").read_text(encoding="utf-8")
    service_unit = (SERVER_DIR / "max-desktop-uploader.service").read_text(encoding="utf-8")
    nginx_snippet = f"""
# MAX Desktop deploy proxy (added by bootstrap_update_deploy.py)
location = /_deploy/healthz {{
    proxy_pass http://127.0.0.1:{UPLOAD_PORT}/healthz;
}}
location = /_deploy/upload {{
    client_max_body_size 250m;
    proxy_request_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    proxy_pass http://127.0.0.1:{UPLOAD_PORT}/upload;
}}
""".strip()

    print(f"Connecting to {HOST}...")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        HOST,
        username=USER,
        password=PASSWORD,
        timeout=30,
        allow_agent=False,
        look_for_keys=False,
    )
    print("SSH (password) OK — installing deploy machinery...")

    sftp = client.open_sftp()

    # authorized_keys
    _run(
        client,
        "mkdir -p /root/.ssh && chmod 700 /root/.ssh && "
        "touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys",
    )
    with sftp.file("/root/.ssh/authorized_keys", "r") as f:
        existing = f.read().decode("utf-8", errors="replace")
    lines = [ln.strip() for ln in existing.splitlines() if ln.strip()]
    for pub in pubs:
        if pub not in lines:
            lines.append(pub)
    with sftp.file("/root/.ssh/authorized_keys", "w") as f:
        f.write("\n".join(lines) + "\n")

    # uploader files
    _run(client, "mkdir -p /opt/max-desktop /etc/max-desktop /var/www/max-desktop")
    with sftp.file("/opt/max-desktop/max_desktop_uploader.py", "w") as f:
        f.write(uploader_py)
    with sftp.file("/etc/systemd/system/max-desktop-uploader.service", "w") as f:
        f.write(service_unit)
    with sftp.file("/etc/max-desktop/uploader.env", "w") as f:
        f.write(
            f"MAX_DEPLOY_TOKEN={token}\n"
            f"MAX_UPDATE_WEB_ROOT={WEB_ROOT}\n"
            f"MAX_UPLOAD_HOST=127.0.0.1\n"
            f"MAX_UPLOAD_PORT={UPLOAD_PORT}\n"
        )
    _run(client, "chmod 600 /etc/max-desktop/uploader.env && chmod 755 /opt/max-desktop/max_desktop_uploader.py")

    # Patch nginx site if present: inject location blocks before final }
    code, nginx_conf, _ = _run(
        client,
        "test -f /etc/nginx/sites-available/max-desktop && cat /etc/nginx/sites-available/max-desktop || true",
        check=False,
    )
    if nginx_conf and "/_deploy/upload" not in nginx_conf:
        if nginx_conf.rstrip().endswith("}"):
            patched = nginx_conf.rstrip()[:-1] + "\n    " + nginx_snippet.replace("\n", "\n    ") + "\n}\n"
            with sftp.file("/etc/nginx/sites-available/max-desktop", "w") as f:
                f.write(patched)
            _run(client, "nginx -t && systemctl reload nginx")
        else:
            print("WARN: unexpected nginx config shape; uploader still on :8091", file=sys.stderr)
    elif not nginx_conf:
        # Minimal nginx site for updates + deploy proxy
        site = f"""
server {{
    listen 8080;
    listen [::]:8080;
    server_name _;
    root {WEB_ROOT};
    index index.html;
    client_max_body_size 250m;

    location / {{
        autoindex on;
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache";
    }}

    location = /latest.json {{
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        default_type application/json;
    }}

    {nginx_snippet}
}}
""".strip()
        with sftp.file("/etc/nginx/sites-available/max-desktop", "w") as f:
            f.write(site + "\n")
        _run(
            client,
            "ln -sfn /etc/nginx/sites-available/max-desktop /etc/nginx/sites-enabled/max-desktop && "
            "nginx -t && systemctl reload nginx",
        )

    _run(client, "systemctl daemon-reload && systemctl enable --now max-desktop-uploader && systemctl restart max-desktop-uploader")
    _run(client, "systemctl is-active max-desktop-uploader")
    _run(client, f"curl -fsS http://127.0.0.1:{UPLOAD_PORT}/healthz")

    # Verify key auth quickly
    sftp.close()
    client.close()

    LOCAL_SECRETS.write_text(
        "\n".join(
            [
                f"MAX_DEPLOY_TOKEN={token}",
                f"MAX_UPDATE_HOST={HOST}",
                f"MAX_UPDATE_UPLOAD_URL=http://{HOST}:8080/_deploy/upload",
                f"MAX_DEPLOY_KEY={DEPLOY_KEY}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    try:
        os.chmod(LOCAL_SECRETS, 0o600)
    except OSError:
        pass

    print("")
    print("Bootstrap OK.")
    print(f"  Secrets: {LOCAL_SECRETS}")
    print(f"  Deploy key: {DEPLOY_KEY}")
    print(f"  Upload: http://{HOST}:8080/_deploy/upload")
    print("Next: .\\scripts\\deploy_update.ps1 -SkipBuild")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
