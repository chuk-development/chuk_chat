#!/usr/bin/env python3
"""Own one persistent browser profile and reap only this launcher's children.

Foreign-host Chromium singleton files require a host-side retirement attestation.
The host must verify that the named old container no longer exists before setting
COWORK_BROWSER_RETIRED_HOSTNAME. A hostname mismatch alone is not proof of death.
"""

from __future__ import annotations

import ctypes
import errno
import fcntl
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time


SINGLETON_FILES = ("SingletonLock", "SingletonCookie", "SingletonSocket")


def process_running(pid: int, proc: Path = Path("/proc")) -> bool:
    try:
        # Zombies cannot own a browser profile; kill(pid, 0) alone misidentifies
        # them as active in containers whose PID 1 does not reap children.
        state = (proc / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()[0]
        return state not in {"Z", "X"}
    except FileNotFoundError:
        return False


def prepare_profile(profile: Path, retired_hostname: str = "", *,
                    hostname: str | None = None, proc: Path = Path("/proc")) -> None:
    """Remove only proven-stale runtime symlinks, never browser session data."""
    hostname = hostname or socket.gethostname()
    lock = profile / "SingletonLock"
    if not lock.is_symlink():
        if lock.exists():
            raise RuntimeError("unexpected non-symlink SingletonLock; refusing to alter it")
        return
    target = os.readlink(lock)
    try:
        owner_host, owner_pid = target.rsplit("-", 1)
        pid = int(owner_pid)
        if pid <= 0 or not owner_host:
            raise ValueError
    except ValueError as exc:
        raise RuntimeError("unrecognized browser singleton owner; refusing cleanup") from exc
    if owner_host == hostname:
        if process_running(pid, proc):
            raise RuntimeError(f"browser profile still has a live owner (PID {pid})")
    elif owner_host != retired_hostname:
        raise RuntimeError(
            f"browser profile belongs to container {owner_host}; host must verify "
            "its retirement before stale runtime links can be repaired"
        )
    # A second local browser could have won a startup race before writing its
    # singleton link. Detect its exact profile argument, not a name substring.
    expected = f"--user-data-dir={profile}"
    for entry in proc.iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            argv = (entry / "cmdline").read_bytes().split(b"\0")
            if expected.encode() in argv and process_running(int(entry.name), proc):
                raise RuntimeError("browser profile is in active use; refusing cleanup")
        except FileNotFoundError:
            continue
    links = {}
    for name in SINGLETON_FILES:
        path = profile / name
        if path.is_symlink():
            links[path] = os.readlink(path)
        elif path.exists():
            raise RuntimeError(f"unexpected non-symlink {name}; refusing cleanup")
    # Guard against modifications between inspection and cleanup. The advisory
    # profile lease also serializes all compliant launchers across bind mounts.
    if any(not path.is_symlink() or os.readlink(path) != value for path, value in links.items()):
        raise RuntimeError("browser singleton ownership changed during inspection")
    for path in links:
        path.unlink()


def descendants() -> list[int]:
    """Only descendants of this supervisor, including adopted browser orphans."""
    parents: dict[int, int] = {}
    for path in Path("/proc").glob("[0-9]*/stat"):
        try:
            tail = path.read_text().rsplit(")", 1)[1].split()
            parents[int(path.parent.name)] = int(tail[1])
        except FileNotFoundError:
            pass
    owned = {os.getpid()}
    while True:
        expanded = owned | {pid for pid, parent in parents.items() if parent in owned}
        if expanded == owned:
            return list(owned - {os.getpid()})
        owned = expanded


def stop_children() -> None:
    # Playwright puts Chromium into its own process group. Killing only the MCP
    # process group is insufficient; subreaping keeps those descendants ours.
    deadline = time.monotonic() + 3
    while True:
        children = descendants()
        if not children:
            return
        force = time.monotonic() >= deadline
        for pid in children:
            try:
                os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
            except ProcessLookupError:
                pass
        while True:
            try:
                if os.waitpid(-1, os.WNOHANG)[0] == 0:
                    break
            except ChildProcessError:
                break
        if force:
            # Reap SIGKILLed children before releasing the profile lease.
            while True:
                try:
                    os.waitpid(-1, 0)
                except ChildProcessError:
                    return
        time.sleep(0.05)


def main() -> int:
    profile = Path(os.environ.get("COWORK_BROWSER_PROFILE", "/workspace/.cowork/chrome-profile")).resolve()
    profile.mkdir(parents=True, exist_ok=True)
    with (profile / ".cowork-launcher.lock").open("a") as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno not in {errno.EACCES, errno.EAGAIN}:
                raise
            raise RuntimeError("another MCP launcher owns this browser profile; reuse its connection") from exc
        prepare_profile(profile, os.environ.get("COWORK_BROWSER_RETIRED_HOSTNAME", ""))
        # Linux PR_SET_CHILD_SUBREAPER: adopt Chromium when MCP exits, including
        # descendants in separate process groups, without touching other agents.
        if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "cannot enable browser child supervision")
        def interrupted(signum: int, _frame: object) -> None:
            raise SystemExit(128 + signum)
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        try:
            child = subprocess.Popen(sys.argv[1:])
            return child.wait()
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            stop_children()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as error:
        print(f"cowork-browser-mcp: {error}", file=sys.stderr)
        sys.exit(1)
