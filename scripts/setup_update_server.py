#!/usr/bin/env python3
"""Install SSH pubkey + nginx update host. Password via env UPDATE_SERVER_PASSWORD only."""
from __future__ import annotations

import os
import pathlib
import sys

import paramiko

HOST = os.environ.get("UPDATE_SERVER_HOST", "145.63.130.142")
USER = os.environ.get("UPDATE_SERVER_USER", "root")
PASSWORD = os.environ.get("UPDATE_SERVER_PASSWORD")
PUBKEY_PATH = pathlib.Path.home() / ".ssh" / "id_ed25519.pub"
WEB_ROOT = "/var/www/max-desktop"


def main() -> int:
    if not PASSWORD:
        print("Set UPDATE_SERVER_PASSWORD env var", file=sys.stderr)
        return 1
    pubkey = PUBKEY_PATH.read_text(encoding="utf-8").strip()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASSWORD, timeout=30, allow_agent=False, look_for_keys=False)

    def run(cmd: str) -> int:
        _, stdout, stderr = client.exec_command(cmd)
        code = stdout.channel.recv_exit_status()
        sys.stdout.buffer.write(stdout.read())
        sys.stderr.buffer.write(stderr.read())
        return code

    code = run(
        f"mkdir -p /root/.ssh && chmod 700 /root/.ssh && "
        f"touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && "
        f"grep -qxF '{pubkey}' /root/.ssh/authorized_keys || echo '{pubkey}' >> /root/.ssh/authorized_keys"
    )
    client.close()
    return code


if __name__ == "__main__":
    raise SystemExit(main())
