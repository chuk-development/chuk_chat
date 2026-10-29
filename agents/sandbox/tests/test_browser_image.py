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
    assert "BASE_IMAGE=agents-base:latest" in args


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
    assert any(line.startswith("ENTRYPOINT") and "agents-entrypoint" in line for line in lines)
    # A browser in a container has no CAP_SYS_ADMIN for its own sandbox; the
    # marker browser-use reads for that has to be set.
    assert "IN_DOCKER=true" in text
    # No phone-home from a user's machine.
    assert "ANONYMIZED_TELEMETRY=false" in text
    assert "BROWSER_USE_CLOUD_SYNC=false" in text


def test_launcher_uses_preinstalled_server_and_profile_supervisor():
    launcher = (DOCKER_DIR / "browser-mcp.sh").read_text()
    assert "exec python3 /usr/local/lib/agents/browser-mcp-owner.py playwright-mcp" in launcher
    assert "exec npx" not in launcher
    assert "COPY browser-mcp-owner.py /usr/local/lib/agents/browser-mcp-owner.py" in BROWSER.read_text()
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


def _run_launcher(tmp_path, dimensions, env_extra=None):
    """Run browser-mcp.sh with stand-ins for xdpyinfo and python3.

    The fake xdpyinfo reports an X display of ``dimensions`` (or one with no
    size line when it is ``None``), so no real Xvfb is started; the fake python3 is where the launcher ``exec``s the MCP owner, so
    it records the argv instead of starting a browser.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    if dimensions is None:
        # The display answers but reports no size line.
        xdpyinfo = "#!/bin/sh\necho 'name of display:    :99'\n"
    else:
        xdpyinfo = (
            "#!/bin/sh\n"
            "echo 'screen #0:'\n"
            f"echo '  dimensions:    {dimensions} pixels (338x211 millimeters)'\n"
        )
    (bin_dir / "xdpyinfo").write_text(xdpyinfo)
    # The fake python3 also records the language the browser gets.
    (bin_dir / "python3").write_text(
        '#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGV_OUT"\n'
        'printf "%s" "$LANGUAGE" > "$ARGV_OUT.language"\n'
    )
    (bin_dir / "xprop").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGV_OUT.xprop"\n')
    for name in ("xdpyinfo", "python3", "xprop"):
        (bin_dir / name).chmod(0o755)
    env = {
        "PATH": f"{bin_dir}:/usr/bin:/bin",
        "TMPDIR": str(tmp_path),
        "ARGV_OUT": str(tmp_path / "argv"),
        "AGENTS_BROWSER_PROFILE": str(tmp_path / "profile"),
        **(env_extra or {}),
    }
    subprocess.run(["sh", str(DOCKER_DIR / "browser-mcp.sh")], env=env, check=True, timeout=30)
    argv = (tmp_path / "argv").read_text().splitlines()
    config_path = Path(argv[argv.index("--config") + 1])
    import json

    return argv, json.loads(config_path.read_text())


def _work_area(tmp_path):
    xprop = tmp_path / "argv.xprop"
    return xprop.read_text().splitlines()[-1] if xprop.exists() else None


def test_the_browser_window_fills_the_work_area(tmp_path):
    """Bead chuk_chat-elw7: with no window manager Chromium opened at its own
    default size in the top-left corner and the rest of the live view (and of
    every screenshot of the display) was black. The window sits at 0,0 and
    the page follows the window.

    Fingerprint (2026-10-29): the old window was 1 px LARGER than the screen
    (Chromium shrinks an exactly screen-sized X11 window by 1 px), and a
    window larger than the screen is a bot tell, as is avail* == screen. The
    launcher now writes a work area with a 44 px bottom panel and makes the
    window as large as the work area."""
    argv, config = _run_launcher(tmp_path, "1280x800")
    browser = config["browser"]
    args = browser["launchOptions"]["args"]
    assert "--window-position=0,0" in args
    assert "--window-size=1280,756" in args
    assert _work_area(tmp_path) == "0,0,1280,756"
    assert browser["contextOptions"]["viewport"] is None
    # A fixed viewport makes Playwright resize the window to viewport + chrome,
    # taller than the screen; none is passed unless somebody asks for one.
    assert "--viewport-size" not in argv


def test_a_display_too_small_for_a_panel_keeps_the_old_window(tmp_path):
    _, config = _run_launcher(tmp_path, "160x120")
    assert "--window-size=161,121" in config["browser"]["launchOptions"]["args"]
    assert _work_area(tmp_path) == "0,0,160,120"


def test_the_browser_does_not_say_it_is_automated(tmp_path):
    """PayPal and similar sites answer an automated browser with endless
    captchas. Playwright's --enable-automation sets navigator.webdriver; the
    launcher drops it and turns the Blink automation flag off."""
    _, config = _run_launcher(tmp_path, "1280x800")
    launch = config["browser"]["launchOptions"]
    assert launch["ignoreDefaultArgs"] == ["--enable-automation"]
    assert "--disable-blink-features=AutomationControlled" in launch["args"]


def test_a_real_pc_has_a_microphone_a_camera_and_a_speaker(tmp_path):
    """enumerateDevices() was [] in the container. The fake devices list one
    of each kind, with empty labels until a permission grant (measured)."""
    _, config = _run_launcher(tmp_path, "1280x800")
    assert "--use-fake-device-for-media-stream" in config["browser"]["launchOptions"]["args"]


def test_webgl_uses_the_gpu_when_the_container_has_one(tmp_path):
    """SwiftShader in UNMASKED_RENDERER is the strongest bot tell. With the
    NVIDIA GPU in the container (docker.py), ANGLE's Vulkan backend reports
    the real card; with no GPU the flag is not passed."""
    _, config = _run_launcher(tmp_path, "1280x800")
    args = config["browser"]["launchOptions"]["args"]
    assert ("--use-angle=vulkan" in args) == os.path.exists("/dev/nvidiactl")


@pytest.mark.parametrize(
    ("value", "expected"), [(None, "en_US"), ("de-DE", "de_DE"), ("x;rm -rf", "en_US")]
)
def test_the_browser_language_comes_from_the_host(tmp_path, value, expected):
    """Chrome on Linux takes its language from the environment (--lang does
    nothing there) and then builds the same Accept-Language list a real
    Chrome of that language sends. Playwright's contextOptions.locale must
    stay unset: it replaces that list with the bare locale, a tell."""
    extra = {} if value is None else {"AGENTS_BROWSER_LOCALE": value}
    _, config = _run_launcher(tmp_path, "1280x800", extra)
    browser = config["browser"]
    assert (tmp_path / "argv.language").read_text() == expected
    assert "locale" not in browser["contextOptions"]
    assert not any(a.startswith(("--lang", "--accept-lang")) for a in browser["launchOptions"]["args"])


def test_the_window_follows_a_display_somebody_else_started(tmp_path):
    """The display may exist already with another size (an agent once started a
    1440x2000 Xvfb on :99). The window follows the display that is there."""
    _, config = _run_launcher(tmp_path, "1440x2000")
    assert "--window-size=1440,1956" in config["browser"]["launchOptions"]["args"]


@pytest.mark.parametrize("screen", ["1600x900x24", "1600x900"])
def test_an_unmeasurable_display_uses_the_configured_screen(tmp_path, screen):
    _, config = _run_launcher(tmp_path, None, {"AGENTS_BROWSER_SCREEN": screen})
    assert "--window-size=1600,856" in config["browser"]["launchOptions"]["args"]


def test_a_fixed_viewport_is_still_possible_on_request(tmp_path):
    argv, _ = _run_launcher(tmp_path, "1280x800", {"AGENTS_BROWSER_VIEWPORT": "1024x600"})
    assert argv[argv.index("--viewport-size") + 1] == "1024x600"


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
        env={**os.environ, "AGENTS_BROWSER_PROFILE": str(tmp_path)},
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    pid = int(result.stdout.strip())
    assert not Path(f"/proc/{pid}").exists()


def test_concurrent_launch_fails_without_touching_profile(tmp_path):
    import fcntl
    with (tmp_path / ".agents-launcher.lock").open("a") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(
            [sys.executable, str(OWNER_PATH), sys.executable, "-c", "print('should not run')"],
            env={**os.environ, "AGENTS_BROWSER_PROFILE": str(tmp_path)},
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
        env={**os.environ, "AGENTS_BROWSER_PROFILE": str(tmp_path)},
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
            env={**os.environ, "AGENTS_BROWSER_PROFILE": str(tmp_path)},
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "reconnected"
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def test_a_box_without_gpu_gets_the_webgl_init_script(tmp_path):
    """A VPS has no GPU: SwiftShader in UNMASKED_RENDERER is then the
    strongest tell, so webgl-mesa.js reports a common Intel GPU. A box with
    the GPU reports the real card and gets no script."""
    script = tmp_path / "webgl.js"
    script.write_text("// test\n")
    argv, _ = _run_launcher(tmp_path, "1280x800", {"AGENTS_BROWSER_WEBGL_SCRIPT": str(script)})
    has_gpu = os.path.exists("/dev/nvidiactl")
    assert ("--init-script" in argv) == (not has_gpu)
    if not has_gpu:
        assert argv[argv.index("--init-script") + 1] == str(script)


def test_the_webgl_init_script_can_be_turned_off(tmp_path):
    argv, _ = _run_launcher(tmp_path, "1280x800", {"AGENTS_BROWSER_WEBGL_SCRIPT": ""})
    assert "--init-script" not in argv


def test_the_image_ships_the_webgl_init_script():
    assert "COPY webgl-mesa.js /usr/local/lib/agents/webgl-mesa.js" in BROWSER.read_text()
    script = (DOCKER_DIR / "webgl-mesa.js").read_text()
    # Only a software renderer is replaced; a real GPU stays as it is.
    assert "SwiftShader|llvmpipe" in script
