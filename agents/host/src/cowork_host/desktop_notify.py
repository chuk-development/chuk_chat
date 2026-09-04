"""Desktop notification from the host process (docs/WIRE_CONTRACT.md).

The simplest channel when the host and the desktop app share a machine: the
host itself shows an OS notification when a run ends with no app attached. It
needs no cloud, no Firebase and no app process. It never carries the answer:
the content stays in the store and reaches the app over the sealed channel.

Linux uses ``notify-send`` (falls back to ``gdbus``), macOS ``osascript``.
Windows is skipped. Everything is best-effort: a missing tool or a failure is
swallowed, and a notification can never take a run down.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import threading
from collections.abc import Callable, Sequence

#: The command runner, injectable so tests assert the argv without a display.
Runner = Callable[[Sequence[str]], None]


def _run(argv: Sequence[str]) -> None:
    subprocess.run(
        list(argv),
        check=False,
        timeout=5.0,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class DesktopNotifier:
    """Fire-and-forget desktop notification."""

    APP_NAME = "CoWork"
    #: The desktop-entry hint: on GNOME/KDE a click focuses or launches the app.
    DESKTOP_ENTRY = "cowork"

    def __init__(
        self,
        *,
        runner: Runner = _run,
        enabled: bool | None = None,
        system: str | None = None,
        which: Callable[[str], str | None] = shutil.which,
        background: bool = True,
    ) -> None:
        self._runner = runner
        self._system = system or platform.system()
        self._which = which
        # Fire on a daemon thread by default: the hook that calls this runs on
        # the executor's task worker, and a slow notification daemon must never
        # hold up the next task. Tests pass ``background=False`` to assert.
        self._background = background
        self.enabled = self._default_enabled() if enabled is None else enabled

    def _default_enabled(self) -> bool:
        if os.environ.get("COWORK_DESKTOP_NOTIFY", "1") == "0":
            return False
        if self._system == "Darwin":
            return True
        if self._system == "Windows":
            return False
        return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))

    def notify(self, title: str, body: str) -> bool:
        """Show one notification. Returns True when a command was run."""
        if not self.enabled:
            return False
        argv = self._argv(title, body)
        if argv is None:
            return False
        if self._background:
            threading.Thread(
                target=self._run_quietly, args=(argv,), name="cowork-desktop-notify",
                daemon=True,
            ).start()
            return True
        return self._run_quietly(argv)

    def _run_quietly(self, argv: list[str]) -> bool:
        try:
            self._runner(argv)
        except Exception:  # noqa: BLE001 — a notification must never raise
            return False
        return True

    def _argv(self, title: str, body: str) -> list[str] | None:
        if self._system == "Darwin":
            script = (
                f'display notification "{_esc(body)}" '
                f'with title "{_esc(title)}"'
            )
            return ["osascript", "-e", script]
        if self._system == "Windows":
            return None
        if self._which("notify-send"):
            return [
                "notify-send",
                f"--app-name={self.APP_NAME}",
                "--urgency=normal",
                f"--hint=string:desktop-entry:{self.DESKTOP_ENTRY}",
                title,
                body,
            ]
        if self._which("gdbus"):
            return [
                "gdbus",
                "call",
                "--session",
                "--dest",
                "org.freedesktop.Notifications",
                "--object-path",
                "/org/freedesktop/Notifications",
                "--method",
                "org.freedesktop.Notifications.Notify",
                self.APP_NAME,
                "0",
                "",
                title,
                body,
                "[]",
                "{}",
                "5000",
            ]
        return None


def _esc(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def completion_text(agent_name: str, *, failed: bool = False) -> tuple[str, str]:
    """The generic title/body of a completion notification. No answer content."""
    name = agent_name or "Your coworker"
    if failed:
        return (f"{name} could not finish the task", "Open the app to see what happened")
    return (f"{name} finished your task", "Open the app to see the answer")
