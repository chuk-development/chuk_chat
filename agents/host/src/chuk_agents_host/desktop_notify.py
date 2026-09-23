"""Desktop notification from the host process (docs/WIRE_CONTRACT.md).

The simplest channel when the host and the desktop app share a machine: the
host itself shows an OS notification when a run ends with no app attached. It
needs no cloud, no Firebase and no app process. It never carries the answer:
the content stays in the store and reaches the app over the sealed channel.

Linux uses ``notify-send`` (falls back to ``gdbus``), macOS ``osascript``.
Windows is skipped. Everything is best-effort: a missing tool or a failure is
swallowed, and a notification can never take a run down.

The Linux toast also carries an icon path. A notification daemon draws a logo
only when it is given one: the ``desktop-entry`` hint finds an icon only where
a ``agents.desktop`` file is installed, which a host running from a checkout or
a pip install does not have. So the app logo ships with this package
(``data/agents.png``, the app's launcher icon) and is passed by absolute path;
``AGENTS_NOTIFY_ICON`` overrides it for an install that has its own themed
icon.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import threading
from collections.abc import Callable, Sequence
from pathlib import Path

from .notification_text import RunLabels
from .notification_text import completion_text as compose_completion_text

#: The command runner, injectable so tests assert the argv without a display.
Runner = Callable[[Sequence[str]], None]

#: The app logo that ships with this package: the same launcher icon the
#: Android and Linux builds use, copied in so an installed host has it too.
PACKAGED_ICON = Path(__file__).with_name("data") / "agents.png"


def icon_path() -> str | None:
    """The absolute path (or icon-theme name) the toast should draw, or None."""
    override = os.environ.get("AGENTS_NOTIFY_ICON")
    if override:
        return override
    return str(PACKAGED_ICON) if PACKAGED_ICON.is_file() else None


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

    APP_NAME = "Agents"
    #: The desktop-entry hint: on GNOME/KDE a click focuses or launches the app.
    DESKTOP_ENTRY = "agents"

    def __init__(
        self,
        *,
        runner: Runner = _run,
        enabled: bool | None = None,
        system: str | None = None,
        which: Callable[[str], str | None] = shutil.which,
        background: bool = True,
        icon: str | None = None,
    ) -> None:
        self._runner = runner
        self._system = system or platform.system()
        self._which = which
        self._icon_override = icon
        # Fire on a daemon thread by default: the hook that calls this runs on
        # the executor's task worker, and a slow notification daemon must never
        # hold up the next task. Tests pass ``background=False`` to assert.
        self._background = background
        self.enabled = self._default_enabled() if enabled is None else enabled

    def _default_enabled(self) -> bool:
        if os.environ.get("AGENTS_DESKTOP_NOTIFY", "1") == "0":
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
                target=self._run_quietly, args=(argv,), name="agents-desktop-notify",
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

    def _icon(self) -> str | None:
        return self._icon_override or icon_path()

    def _argv(self, title: str, body: str) -> list[str] | None:
        if self._system == "Darwin":
            script = (
                f'display notification "{_esc(body)}" '
                f'with title "{_esc(title)}"'
            )
            return ["osascript", "-e", script]
        if self._system == "Windows":
            return None
        icon = self._icon()
        if self._which("notify-send"):
            return [
                "notify-send",
                f"--app-name={self.APP_NAME}",
                "--urgency=normal",
                f"--hint=string:desktop-entry:{self.DESKTOP_ENTRY}",
                *([f"--icon={icon}"] if icon else []),
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
                # The Notify signature's third argument is the app icon.
                icon or "",
                title,
                body,
                "[]",
                "{}",
                "5000",
            ]
        return None


def _esc(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


#: Where this module gets the name the reader knows. The host's own
#: desktop-only path (an automation that finished while an app was attached)
#: calls :func:`completion_text` with nothing but the roster's agent name, and
#: that name is a generated codename; the notifier installs this provider at
#: start-up so both paths say the same thing. Set once, read from the
#: notification thread.
_labels_provider: Callable[[], RunLabels] | None = None


def set_labels_provider(provider: Callable[[], RunLabels] | None) -> None:
    """Install (or clear) the resolver for the coworker's own name."""
    global _labels_provider
    _labels_provider = provider


def current_labels() -> RunLabels:
    provider = _labels_provider
    if provider is None:
        return RunLabels()
    try:
        return provider()
    except Exception:  # noqa: BLE001 — a name lookup must never lose the toast
        return RunLabels()


def completion_text(agent_name: str, *, failed: bool = False) -> tuple[str, str]:
    """Title/body for a caller that has only the roster's agent name.

    That name (``ivory-lynx``) is generated and doubles as the workspace
    directory: the reader has never seen it, so it is deliberately not shown.
    The name the user chose in the app comes from the installed provider, and
    without one the text stays generic — honest beats a codename.
    """
    del agent_name  # accepted for the existing call sites; see above
    return compose_completion_text(current_labels(), failed=failed)
