"""The browser image variant (§8, §9) — static contract, no build.

Building it downloads Chromium plus its system libraries (several hundred MB), so
this suite does not build it. What it does pin is the property that made it a
separate file in the first place: **the default build must stay the cheap one.**

``docker build`` without ``--target`` builds the LAST stage of a Dockerfile. A
browser stage appended to ``Dockerfile`` would therefore silently turn the build
``scripts/install.sh`` runs into the heavy one. So:

* ``Dockerfile`` must not install a browser, and
* ``Dockerfile.browser`` must build FROM the base image, not from Debian again —
  otherwise the two images drift apart on Python, uv and tmux.
"""

from __future__ import annotations

from pathlib import Path
import importlib.util
import os
import socket
import signal
import subprocess
import sys

import pytest

DOCKER_DIR = Path(__file__).resolve().parents[1] / "docker"
BASE = DOCKER_DIR / "Dockerfile"
BROWSER = DOCKER_DIR / "Dockerfile.browser"
OWNER_PATH = DOCKER_DIR / "browser-mcp-owner.py"
spec = importlib.util.spec_from_file_location("browser_mcp_owner", OWNER_PATH)
assert spec and spec.loader
owner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owner)


def _instructions(path: Path) -> list[str]:
    """The Dockerfile without comments and blank lines, line continuations joined."""
    joined = path.read_text(encoding="utf-8").replace("\\\n", " ")
    return [
        line.strip()
        for line in joined.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def test_the_browser_variant_exists_as_its_own_file():
    assert BROWSER.is_file()


def test_the_browser_variant_builds_on_top_of_the_base_image():
    lines = _instructions(BROWSER)
    froms = [line for line in lines if line.upper().startswith("FROM ")]
    assert froms == ["FROM ${BASE_IMAGE}"]
    args = " ".join(line for line in lines if line.upper().startswith("ARG "))
    assert "BASE_IMAGE=cowork-base:latest" in args


def test_the_base_image_installs_no_browser():
    lines = _instructions(BASE)
    installs = [
        line
        for line in lines
        if any(token in line for token in ("chromium", "chrome", "playwright"))
    ]
    assert installs == [], f"the base image must stay browser-free: {installs}"
    # And it must stay a single-stage file: a second stage would become what a
    # plain `docker build` produces instead of the base image.
    assert len([line for line in lines if line.upper().startswith("FROM ")]) == 1


def test_the_browser_variant_pins_the_installer_and_keeps_the_entrypoint():
    lines = _instructions(BROWSER)
    text = " ".join(lines)
    # Pinned, like every other tool in the base image.
    assert "PLAYWRIGHT_VERSION=" in text
    assert 'playwright==${PLAYWRIGHT_VERSION}"' in text or "playwright==${PLAYWRIGHT_VERSION}" in text
    # The uid-remapping entrypoint must survive, or workspace files land on the
    # host owned by the wrong user.
    assert any(line.startswith("ENTRYPOINT") and "cowork-entrypoint" in line for line in lines)
    # A browser in a container has no CAP_SYS_ADMIN for its own sandbox; the
    # marker browser-use reads for that has to be set.
    assert "IN_DOCKER=true" in text
    # No phone-home from a user's machine.
    assert "ANONYMIZED_TELEMETRY=false" in text
    assert "BROWSER_USE_CLOUD_SYNC=false" in text


def test_launcher_uses_preinstalled_server_and_profile_supervisor():
    launcher = (DOCKER_DIR / "browser-mcp.sh").read_text()
    assert "exec python3 /usr/local/lib/cowork/browser-mcp-owner.py playwright-mcp" in launcher
    assert "exec npx" not in launcher
    assert "COPY browser-mcp-owner.py /usr/local/lib/cowork/browser-mcp-owner.py" in BROWSER.read_text()
    assert "playwright-mcp --version" in BROWSER.read_text()


def test_the_agents_mouse_is_big_enough_to_see():
    """x11vnc sends the REAL remote pointer, so what the watcher sees is the
    shape Chromium sets. With no cursor theme in the image that is the X core
    cursor font at a fixed 10x16 px — a few specks once a 1280x800 screen is
    scaled onto a phone. A theme plus XCURSOR_SIZE makes the same pointer
    48x48 (measured in a live container)."""
    launcher = (DOCKER_DIR / "browser-mcp.sh").read_text()
    assert "export XCURSOR_THEME=" in launcher
    assert "export XCURSOR_SIZE=" in launcher
    # Exported BEFORE the server is launched, or Chromium never sees them.
    assert launcher.index("export XCURSOR_SIZE=") < launcher.index("exec python3")
    assert "dmz-cursor-theme" in BROWSER.read_text()


def singleton(profile, host="old-container", pid=42):
    (profile / "SingletonLock").symlink_to(f"{host}-{pid}")
    (profile / "SingletonCookie").symlink_to("cookie")
    (profile / "SingletonSocket").symlink_to("/tmp/nonexistent-browser-socket")


def test_foreign_profile_requires_host_retirement_attestation(tmp_path):
    singleton(tmp_path)
    with pytest.raises(RuntimeError, match="host must verify"):
        owner.prepare_profile(tmp_path)
    assert (tmp_path / "SingletonLock").is_symlink()


def test_retired_profile_removes_only_runtime_symlinks(tmp_path):
    singleton(tmp_path)
    login = tmp_path / "Cookies"
    login.write_bytes(b"persistent-session")
    owner.prepare_profile(tmp_path, "old-container")
    assert login.read_bytes() == b"persistent-session"
    assert not any((tmp_path / name).is_symlink() for name in owner.SINGLETON_FILES)


def test_current_live_pid_cannot_be_overridden_by_retirement_attestation(tmp_path):
    singleton(tmp_path, socket.gethostname(), os.getpid())
    with pytest.raises(RuntimeError, match="live owner"):
        owner.prepare_profile(tmp_path, socket.gethostname())
    assert (tmp_path / "SingletonLock").is_symlink()


def test_local_dead_pid_can_recover(tmp_path):
    proc = tmp_path / "proc"
    proc.mkdir()
    singleton(tmp_path, "current", 42)
    owner.prepare_profile(tmp_path, hostname="current", proc=proc)
    assert not (tmp_path / "SingletonLock").is_symlink()


def test_zombie_does_not_count_as_live_owner(tmp_path):
    proc = tmp_path / "proc"
    (proc / "42").mkdir(parents=True)
    (proc / "42" / "stat").write_text("42 (chrome) Z 1 1 1")
    (proc / "42" / "cmdline").write_bytes(b"")
    singleton(tmp_path, "current", 42)
    owner.prepare_profile(tmp_path, hostname="current", proc=proc)
    assert not (tmp_path / "SingletonLock").is_symlink()


def test_other_live_profile_process_prevents_foreign_cleanup(tmp_path):
    proc = tmp_path / "proc"
    (proc / "55").mkdir(parents=True)
    (proc / "55" / "stat").write_text("55 (chrome) S 1 1 1")
    (proc / "55" / "cmdline").write_bytes(f"chrome\0--user-data-dir={tmp_path}\0".encode())
    singleton(tmp_path)
    with pytest.raises(RuntimeError, match="active use"):
        owner.prepare_profile(tmp_path, "old-container", proc=proc)


def test_non_symlink_runtime_file_is_never_deleted(tmp_path):
    singleton(tmp_path)
    (tmp_path / "SingletonCookie").unlink()
    (tmp_path / "SingletonCookie").write_text("unexpected data")
    with pytest.raises(RuntimeError, match="non-symlink"):
        owner.prepare_profile(tmp_path, "old-container")
    assert (tmp_path / "SingletonCookie").read_text() == "unexpected data"
    assert (tmp_path / "SingletonLock").is_symlink()


def test_supervisor_reaps_detached_browser_child_on_mcp_exit(tmp_path):
    # Simulate Playwright's detached Chromium subprocess, which cannot be
    # cleaned up by terminating the MCP process group alone.
    code = (
        "import subprocess,sys; "
        "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'], "
        "start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
        "print(p.pid, flush=True)"
    )
    result = subprocess.run(
        [sys.executable, str(OWNER_PATH), sys.executable, "-c", code],
        env={**os.environ, "COWORK_BROWSER_PROFILE": str(tmp_path)},
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    pid = int(result.stdout.strip())
    assert not Path(f"/proc/{pid}").exists()


def test_concurrent_launch_fails_without_touching_profile(tmp_path):
    import fcntl
    with (tmp_path / ".cowork-launcher.lock").open("a") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(
            [sys.executable, str(OWNER_PATH), sys.executable, "-c", "print('should not run')"],
            env={**os.environ, "COWORK_BROWSER_PROFILE": str(tmp_path)},
            capture_output=True, text=True, timeout=10,
        )
    assert result.returncode == 1
    assert "another MCP launcher owns" in result.stderr
    assert not result.stdout


def test_supervisor_sigterm_reaps_owned_children_and_releases_profile(tmp_path):
    code = (
        "import subprocess,sys,time; "
        "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'], "
        "start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
        "print(p.pid, flush=True); time.sleep(60)"
    )
    process = subprocess.Popen(
        [sys.executable, str(OWNER_PATH), sys.executable, "-c", code],
        env={**os.environ, "COWORK_BROWSER_PROFILE": str(tmp_path)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        import select
        assert select.select([process.stdout], [], [], 5)[0], "supervisor did not launch child"
        pid = int(process.stdout.readline().strip())
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=10)
        assert process.returncode == 128 + signal.SIGTERM
        assert not Path(f"/proc/{pid}").exists()
        result = subprocess.run(
            [sys.executable, str(OWNER_PATH), sys.executable, "-c", "print('reconnected')"],
            env={**os.environ, "COWORK_BROWSER_PROFILE": str(tmp_path)},
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "reconnected"
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
