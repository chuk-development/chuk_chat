"""Talking to the systemd **user** service ``install.sh`` installed (§5).

Only the CLI needs this, and only for one reason: ``cowork-host connect`` has to
pair on the same TCP port the running service already holds. So it stops the
service, pairs, and starts it again. Everything here is therefore about that
handover — nothing installs or writes units (``scripts/install.sh`` owns that).

``systemctl`` is invoked through an injectable ``runner``, so the CLI's decision
logic is tested without a systemd on the machine, and a host with no systemd at
all degrades to :meth:`SystemdUserService.available` returning ``False``.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

#: The unit ``scripts/install.sh`` writes.
UNIT_NAME = "cowork-manager.service"


@dataclass(frozen=True, slots=True)
class CommandResult:
    stdout: str
    stderr: str
    exit_code: int

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


Runner = Callable[[list[str]], CommandResult]


def subprocess_runner(argv: list[str]) -> CommandResult:
    """Default runner: run ``argv`` and capture it."""
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        return CommandResult("", str(exc), 127)
    return CommandResult(proc.stdout, proc.stderr, proc.returncode)


def user_unit_path(unit: str = UNIT_NAME) -> Path:
    """Where the user unit lives (``$XDG_CONFIG_HOME/systemd/user/<unit>``)."""
    config = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(config) / "systemd" / "user" / unit


@dataclass
class SystemdUserService:
    """A systemd user unit, queried and controlled through ``systemctl --user``."""

    unit: str = UNIT_NAME
    runner: Runner = subprocess_runner
    binary: str = "systemctl"

    def _run(self, *args: str) -> CommandResult:
        return self.runner([self.binary, "--user", *args])

    def available(self) -> bool:
        """True when a reachable systemd user instance knows this unit's file.

        Three ways to be unavailable, all normal: no systemd (macOS, a container),
        no session bus, or CoWork installed with ``--no-service``.
        """
        if shutil.which(self.binary) is None:
            return False
        if not self._run("show-environment").ok:
            return False
        return user_unit_path(self.unit).exists()

    def is_active(self) -> bool:
        return self._run("is-active", "--quiet", self.unit).ok

    def is_enabled(self) -> bool:
        return self._run("is-enabled", "--quiet", self.unit).ok

    def stop(self) -> bool:
        return self._run("stop", self.unit).ok

    def start(self) -> bool:
        return self._run("start", self.unit).ok

    def restart(self) -> bool:
        return self._run("restart", self.unit).ok

    def state(self) -> str:
        """One word for the status output."""
        if not self.available():
            return "not installed"
        if self.is_active():
            return "running"
        return "enabled, stopped" if self.is_enabled() else "installed, disabled"
