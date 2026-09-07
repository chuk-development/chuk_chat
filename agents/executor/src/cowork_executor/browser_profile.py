"""Host-side proof that a Chromium singleton belongs to a retired container.

The container cannot distinguish a retired owner from another live container
sharing its bind mount. Only the Docker host may attest retirement. Any missing
or inconsistent inventory fails closed; this module never deletes profile data.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess


def retired_browser_hostname(binary: str, container_id: str, workspace: str | None) -> str | None:
    if not workspace:
        return None
    root = Path(workspace).resolve()
    profile = root / ".cowork" / "chrome-profile"
    lock = profile / "SingletonLock"
    try:
        target = os.readlink(lock)
        hostname, pid = target.rsplit("-", 1)
        if not hostname or not pid.isdecimal() or int(pid) <= 0:
            return None
        listing = subprocess.run(
            [binary, "ps", "-aq", "--no-trunc"], capture_output=True, text=True,
            check=True, timeout=10,
        ).stdout.split()
        if not listing:
            return None
        containers = json.loads(subprocess.run(
            [binary, "inspect", *listing], capture_output=True, text=True,
            check=True, timeout=10,
        ).stdout)
        current = next((item for item in containers if item["Id"].startswith(container_id)), None)
        if current is None or not current.get("State", {}).get("Running"):
            return None
        # This repair path applies only to the default profile mounted by our
        # managed DockerEnvironment, never an arbitrary/custom browser path.
        config = current.get("Config", {})
        if config.get("Labels", {}).get("cowork.managed") != "true":
            return None
        for value in config.get("Env", []) or []:
            if value.startswith("COWORK_BROWSER_PROFILE=") and value != "COWORK_BROWSER_PROFILE=/workspace/.cowork/chrome-profile":
                return None
        if not any(m.get("Destination") == "/workspace" and Path(m.get("Source", "")).resolve() == root
                   for m in current.get("Mounts", [])):
            return None
        for item in containers:
            # A stopped container still exists and can be resumed. It is not a
            # retired owner; require absence, not merely State.Running=false.
            if item.get("Config", {}).get("Hostname") == hostname or item["Id"].startswith(hostname):
                return None
            if item["Id"] == current["Id"] or not item.get("State", {}).get("Running"):
                continue
            for mount in item.get("Mounts", []):
                source = Path(mount.get("Source", "")).resolve()
                if source == profile or source in profile.parents:
                    return None
        # Don't attest a different owner if another process changed the link
        # during Docker inventory. Container-side validation checks it again.
        if os.readlink(lock) != target:
            return None
        return hostname
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return None
