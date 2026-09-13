"""``agents-vnc-up`` — the contract the live browser view depends on (§9.1).

The script is what decides how long the user waits for the first picture and
whether a quiet stream survives a bad mobile link (bead cowork-c0zd), so the
three things that decide it are pinned here:

* a healthy x11vnc is REUSED, never restarted — a restart per view costs the
  user a second and throws the screen away;
* an x11vnc left behind by an older copy of this script IS replaced, because it
  is still serving the old, slow flags in a container that was up before the
  change;
* the flag list itself keeps the options every one of those numbers came from.

Run against real ``/bin/sh`` with shims on PATH instead of docker: the logic
under test is shell, and a fake x11vnc records its argv.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "docker" / "vnc-up.sh"

#: Bumped in the script whenever the x11vnc flags change; a running x11vnc
#: without this marker is from an older image and must be replaced.
MARKER = "cowork-vnc/2"


def _starts(started: Path) -> list[str]:
    """One entry per x11vnc the script actually launched.

    Counting the word would overcount: the argv carries a log path that also
    contains it.
    """
    return [
        line for line in started.read_text(encoding="utf-8").splitlines()
        if line.startswith("x11vnc ")
    ]


def _shim(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(f"#!/bin/sh\n{body}\n", encoding="utf-8")
    path.chmod(0o755)


@pytest.fixture()
def rig(tmp_path):
    """A fake container: PATH shims for everything the script shells out to.

    ``running.txt`` is the pretend process table x11vnc lives in — ``pgrep``
    greps it, ``pkill`` empties it, and the fake ``x11vnc`` appends its own argv
    to it AND to ``started.txt``, so a test can tell "was started" from "was
    already there".
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    running = tmp_path / "running.txt"
    started = tmp_path / "started.txt"
    running.write_text("", encoding="utf-8")
    started.write_text("", encoding="utf-8")

    _shim(bin_dir, "xdpyinfo", "exit 0")
    _shim(bin_dir, "xwininfo", 'echo \'0x1 "page": ("chromium" "Chromium")\'')
    # grep -Eci counts the lines above; the real grep is fine, so no shim.
    _shim(bin_dir, "socat", "exit 0")  # the port probe always says "listening"
    _shim(
        bin_dir,
        "pgrep",
        f'shift $(($# - 1)); grep -E -- "$1" "{running}" >/dev/null 2>&1',
    )
    _shim(
        bin_dir,
        "pkill",
        f'shift $(($# - 1)); grep -v -E -- "$1" "{running}" > "{running}.new" '
        f'2>/dev/null; mv -f "{running}.new" "{running}"',
    )
    _shim(bin_dir, "setsid", 'exec "$@"')
    _shim(
        bin_dir,
        "x11vnc",
        f'echo "x11vnc $*" >> "{running}"; echo "x11vnc $*" >> "{started}"',
    )
    return bin_dir, running, started


def _run(bin_dir: Path, tmp_path: Path, **env_extra) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["AGENTS_VNC_PASSWD"] = "s3cr3t"
    env["AGENTS_VNC_PASS_FILE"] = str(tmp_path / "vnc.pass")
    env["AGENTS_VNC_LOG"] = str(tmp_path / "x11vnc.log")
    env.update(env_extra)
    return subprocess.run(
        ["/bin/sh", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=30
    )


def test_a_healthy_x11vnc_is_reused_not_restarted(rig, tmp_path):
    bin_dir, running, started = rig

    first = _run(bin_dir, tmp_path)
    assert first.returncode == 0, first.stderr
    assert first.stdout.strip() == "WINDOWS=1"
    assert len(_starts(started)) == 1

    second = _run(bin_dir, tmp_path)
    assert second.returncode == 0, second.stderr
    assert second.stdout.strip() == "WINDOWS=1"
    # Still one start: the second call found the first one serving the port.
    assert len(_starts(started)) == 1
    assert len(_starts(running)) == 1


def test_an_x11vnc_from_an_older_script_is_replaced(rig, tmp_path):
    """A container that was already up when the flags changed keeps serving the
    old ones forever unless the marker is checked. It is checked."""
    bin_dir, running, started = rig
    running.write_text(
        "x11vnc -display :99 -rfbport 5900 -localhost -forever -shared "
        "-noxdamage -noshm -quiet -threads -defer 1 -wait 2\n",
        encoding="utf-8",
    )

    result = _run(bin_dir, tmp_path)

    assert result.returncode == 0, result.stderr
    fresh = _starts(started)
    assert len(fresh) == 1, "the stale server was not replaced"
    assert MARKER in fresh[0]
    # The old one is gone from the table, so only the replacement serves.
    assert len(_starts(running)) == 1


def test_the_flags_that_decide_latency_and_stability_are_all_there(rig, tmp_path):
    bin_dir, _running, started = rig

    assert _run(bin_dir, tmp_path).returncode == 0
    argv = _starts(started)[0]

    # Latency: x11vnc's own idle throttle is what made an idle box take about
    # four seconds to paint its first frame instead of a few milliseconds.
    assert "-sb 0" in argv
    assert "-nonap" in argv
    assert "-noxdamage" not in argv, "DAMAGE is what makes -nonap affordable"
    # Stability: keep bytes flowing, and do not drop a client whose link is slow.
    assert "-ping 30" in argv
    assert "-readtimeout 120" in argv
    # Throughput, unchanged and still measured.
    assert "-threads" in argv and "-defer 1" in argv and "-wait 2" in argv
    # Shared memory stays off: x11vnc runs as root against an Xvfb owned by
    # `agents`, and XShmAttach fails with BadAccess there.
    assert "-noshm" in argv
    # The real remote pointer stays in the stream: x11vnc's cursor defaults are
    # what puts the agent's mouse on the user's screen (measured: RichCursor
    # rectangles for a client that asks, composited into the framebuffer for one
    # that does not), so nothing may switch them off.
    assert "-nocursor" not in argv
    assert "-nocursorpos" not in argv
    assert "-nocursorshape" not in argv
    # The secret, and only inside the container.
    assert "-passwdfile read:" in argv and "-localhost" in argv
    assert "-nopw" not in argv


def test_xdamage_can_be_switched_off_for_a_display_that_misbehaves(rig, tmp_path):
    bin_dir, _running, started = rig

    assert _run(bin_dir, tmp_path, AGENTS_VNC_XDAMAGE="0").returncode == 0
    argv = _starts(started)[0]

    assert "-noxdamage" in argv
    # Polling without DAMAGE costs 2.3x the CPU with -nonap, so the two travel
    # together: switching DAMAGE off switches the nap back on.
    assert "-nonap" not in argv
    assert "-sb 0" in argv, "the idle throttle fix does not depend on DAMAGE"


def test_a_passwordless_start_is_still_refused(rig, tmp_path):
    bin_dir, _running, started = rig
    env = dict(os.environ)
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["AGENTS_VNC_PASS_FILE"] = str(tmp_path / "vnc.pass")
    env["AGENTS_VNC_LOG"] = str(tmp_path / "x11vnc.log")
    env.pop("AGENTS_VNC_PASSWD", None)

    result = subprocess.run(
        ["/bin/sh", str(SCRIPT)], capture_output=True, text=True, env=env, timeout=30
    )

    assert result.returncode == 4
    assert _starts(started) == []


def test_no_display_is_exit_3_and_starts_nothing(rig, tmp_path):
    bin_dir, _running, started = rig
    _shim(bin_dir, "xdpyinfo", "exit 1")

    result = _run(bin_dir, tmp_path)

    assert result.returncode == 3
    assert _starts(started) == []
