"""``cowork-host doctor`` — is the backend actually able to work?

The question this answers is the one the user kept having to guess at: *does
the browser work right now, or is the backend broken again?* Guessing was the
only option, because every part of the answer was silent. A local sandbox has
no browser and said nothing; an image without the Playwright launcher said
nothing; a launcher that fails to start said nothing until a run was already
minutes in and came back with "unknown tool" (bead cowork-3i5c).

Every check here is a real one. Nothing is inferred from a name, a tag or a
setting: docker is asked whether it answers, the image is asked whether it
carries the launcher, and the launcher is *started* and asked to speak MCP.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .identity import HOST_DEVICE_ID
from .pairing_store import HostPairingStore

#: The MCP handshake sent to the launcher. A server that answers this is a
#: server the agent can use; nothing short of an answer proves it.
_INITIALIZE = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "agents-doctor", "version": "1"},
    },
}

#: How long the launcher gets to answer. It starts Xvfb and a Chromium, so it
#: is slower than a plain process start.
BROWSER_PROBE_TIMEOUT_S = 90


@dataclass(frozen=True)
class Check:
    """One question, its answer, and what to do when the answer is no."""

    name: str
    ok: bool
    detail: str
    #: What the user can do about it. Empty when there is nothing to do.
    fix: str = ""

    @property
    def mark(self) -> str:
        return "ok  " if self.ok else "FAIL"


def _run(argv: list[str], *, timeout: int) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"{argv[0]} timed out after {timeout}s"
    except OSError as exc:
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def check_docker(binary: str = "docker") -> Check:
    """Does the container daemon answer? Without it there is no browser."""
    if shutil.which(binary) is None:
        return Check(
            "docker",
            False,
            f"{binary} is not on PATH",
            "install docker, or run the host with --sandbox local (no browser)",
        )
    code, _, err = _run([binary, "ps", "-q"], timeout=20)
    if code != 0:
        return Check(
            "docker",
            False,
            (err or "the daemon did not answer").strip().splitlines()[-1][:200],
            "start the docker daemon (systemctl start docker)",
        )
    return Check("docker", True, "the daemon answers")


def check_image(binary: str = "docker") -> tuple[Check, str]:
    """Is the image this host would run actually on the machine?"""
    from chuk_agents_sandbox.docker import BASE_IMAGE, IMAGE_ENV_VAR, default_image

    image = default_image()
    code, _, _ = _run([binary, "image", "inspect", image], timeout=20)
    if code != 0:
        return (
            Check(
                "image",
                False,
                f"{image} is not built on this machine",
                f"build it, or point {IMAGE_ENV_VAR} at an image you have "
                f"(the plain one is {BASE_IMAGE})",
            ),
            image,
        )
    return Check("image", True, image), image


def check_browser_launcher(image: str, binary: str = "docker") -> Check:
    """Is the Playwright launcher IN the image? The file, not the tag."""
    from chuk_agents_sandbox.docker import BROWSER_MCP_PATH, image_has_browser

    if image_has_browser(image):
        return Check("browser launcher", True, f"{BROWSER_MCP_PATH} in {image}")
    return Check(
        "browser launcher",
        False,
        f"{BROWSER_MCP_PATH} is not in {image}",
        "build the browser image (sandbox/docker/Dockerfile.browser) — without "
        "it the agent has no browser and no screen to take over",
    )


def check_browser_speaks_mcp(image: str, binary: str = "docker") -> Check:
    """Start the launcher and make it answer. The only proof that counts."""
    from chuk_agents_sandbox.docker import BROWSER_MCP_PATH

    argv = [
        binary, "run", "--rm", "-i", "--entrypoint", BROWSER_MCP_PATH, image
    ]
    try:
        proc = subprocess.run(
            argv,
            input=json.dumps(_INITIALIZE) + "\n",
            capture_output=True,
            text=True,
            timeout=BROWSER_PROBE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return Check(
            "browser server",
            False,
            f"no answer within {BROWSER_PROBE_TIMEOUT_S}s",
            "check the image: agents-browser-mcp starts Xvfb and a Chromium",
        )
    except OSError as exc:
        return Check("browser server", False, str(exc), "")
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            answer = json.loads(line)
        except ValueError:
            continue
        info = (answer.get("result") or {}).get("serverInfo") or {}
        if info:
            return Check(
                "browser server",
                True,
                f"{info.get('name', 'MCP')} {info.get('version', '')}".strip(),
            )
    tail = (proc.stderr or proc.stdout or "no output").strip().splitlines()
    return Check(
        "browser server",
        False,
        tail[-1][:200] if tail else "no output",
        "the launcher started but did not speak MCP",
    )


def check_pairing(workspace: str) -> Check:
    """Is a phone paired? Without one the host has nobody to answer."""
    store = HostPairingStore(Path(workspace).expanduser() / "paired.json")
    if store.load() is None:
        return Check(
            "pairing",
            False,
            "no device is paired",
            "run  cowork-host connect  and scan the code with the app",
        )
    return Check("pairing", True, f"a device is paired with {HOST_DEVICE_ID}")


def check_estop(workspace: str) -> Check:
    """The app-free stop. Engaged, nothing runs — and that looks like a break."""
    estop = Path(workspace).expanduser() / "ESTOP"
    if estop.exists():
        return Check(
            "estop",
            False,
            f"ENGAGED — no new work runs ({estop})",
            f"rm {estop}",
        )
    return Check("estop", True, "clear")


def run_checks(
    workspace: str,
    *,
    binary: str = "docker",
    deep: bool = True,
) -> list[Check]:
    """Every check, in the order a failure cascades.

    ``deep`` False skips starting the browser server — the one check that costs
    a container and up to a minute.
    """
    checks: list[Check] = [check_estop(workspace), check_pairing(workspace)]
    docker = check_docker(binary)
    checks.append(docker)
    if not docker.ok:
        checks.append(
            Check(
                "browser",
                False,
                "not checked: there is no container backend",
                "the agent will run on this machine and have no browser",
            )
        )
        return checks
    image_check, image = check_image(binary)
    checks.append(image_check)
    if not image_check.ok:
        return checks
    launcher = check_browser_launcher(image, binary)
    checks.append(launcher)
    if launcher.ok and deep:
        checks.append(check_browser_speaks_mcp(image, binary))
    return checks


def print_report(checks: list[Check], out: Callable[..., None] = print) -> int:
    """Print the checks. Returns the exit code: 0 when every check passed."""
    out("")
    out("  Agents backend check")
    out("")
    width = max(len(c.name) for c in checks)
    for check in checks:
        out(f"    [{check.mark}] {check.name.ljust(width)}  {check.detail}")
        if not check.ok and check.fix:
            out(f"           {' ' * width}  -> {check.fix}")
    failed = [c for c in checks if not c.ok]
    out("")
    if failed:
        out(f"  {len(failed)} of {len(checks)} checks failed.")
    else:
        out("  Everything the agent needs is here.")
    out("")
    return 1 if failed else 0


def cmd_doctor(args, out: Callable[..., None] = print) -> int:
    workspace = getattr(args, "workspace", None) or os.environ.get(
        "AGENTS_HOME", str(Path.home() / ".agents")
    )
    checks = run_checks(str(workspace), deep=not getattr(args, "quick", False))
    return print_report(checks, out)
