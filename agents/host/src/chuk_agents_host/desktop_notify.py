"""Desktop notification from the host process (docs/WIRE_CONTRACT.md,
docs/agents/NOTIFICATIONS.md).

The simplest channel when the host and the desktop app share a machine: the
host itself shows an OS notification when a run ends with no app attached. It
needs no cloud, no Firebase and no app process. The toast is local, so its
body may show the answer preview as plain text.

Linux uses ``notify-send`` (falls back to ``gdbus``), macOS ``osascript``,
Windows a PowerShell toast (``Windows.UI.Notifications``, no extra package).
Everything is best-effort: a missing tool or a failure is swallowed, and a
notification can never take a run down.

The icon is the agent's avatar (``<workspace>/avatars/<agent_id>.png``) when
the caller gives one, else the app logo. A notification daemon draws a logo
only when it is given one: the ``desktop-entry`` hint finds an icon only where
a ``agents.desktop`` file is installed, which a host running from a checkout or
a pip install does not have. So the app logo ships with this package
(``data/agents.png``, the app's launcher icon) and is passed by absolute path;
``AGENTS_NOTIFY_ICON`` overrides it for an install that has its own themed
icon. macOS ``display notification`` cannot show a custom icon.
"""

from __future__ import annotations

import base64
import os
import platform
import shutil
import subprocess
import threading
from collections.abc import Callable, Sequence
from pathlib import Path, PureWindowsPath
from xml.sax.saxutils import escape as _xml_escape

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
            return True
        return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))

    def notify(self, title: str, body: str, *, icon: str | None = None) -> bool:
        """Show one notification. ``icon`` is an absolute image path (the
        agent's avatar); without it the app logo is used. Returns True when a
        command was run."""
        if not self.enabled:
            return False
        argv = self._argv(title, body, icon or self._icon())
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

    def _argv(self, title: str, body: str, icon: str | None) -> list[str] | None:
        if self._system == "Darwin":
            script = (
                f'display notification "{_esc(body)}" '
                f'with title "{_esc(title)}"'
            )
            return ["osascript", "-e", script]
        if self._system == "Windows":
            shell = self._which("powershell") or self._which("powershell.exe")
            if not shell:
                return None
            return [
                shell,
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-EncodedCommand",
                encode_powershell(windows_toast_script(title, body, icon)),
            ]
        # The freedesktop body is markup: a raw ``&`` or ``<`` in an answer
        # makes some daemons drop the body.
        body = _xml_escape(body)
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


#: The AppUserModelID the toast is shown under. Windows shows a toast only for
#: a registered app id; this is the id of Windows PowerShell itself, which
#: every Windows 10/11 has.
WINDOWS_APP_ID = r"{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"


def _file_uri(path: str) -> str:
    windows = PureWindowsPath(path)
    if windows.is_absolute():
        return windows.as_uri()
    return Path(path).resolve().as_uri()


def windows_toast_xml(title: str, body: str, icon: str | None) -> str:
    """The toast XML: title, body and the icon as ``appLogoOverride``."""
    image = ""
    if icon:
        image = (
            '<image placement="appLogoOverride" hint-crop="circle" '
            f'src="{_xml_escape(_file_uri(icon), {chr(34): "&quot;"})}"/>'
        )
    return (
        '<toast><visual><binding template="ToastGeneric">'
        f"<text>{_xml_escape(title)}</text>"
        f"<text>{_xml_escape(body)}</text>"
        f"{image}"
        "</binding></visual></toast>"
    )


def windows_toast_script(title: str, body: str, icon: str | None) -> str:
    """The PowerShell script that shows one toast. Values are in single-quoted
    PowerShell strings, so only a quote needs escaping (it is doubled)."""
    xml = _ps_quote(windows_toast_xml(title, body, icon))
    app_id = _ps_quote(WINDOWS_APP_ID)
    return (
        "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, "
        "ContentType = WindowsRuntime] > $null\n"
        "[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, "
        "ContentType = WindowsRuntime] > $null\n"
        "$xml = New-Object Windows.Data.Xml.Dom.XmlDocument\n"
        f"$xml.LoadXml('{xml}')\n"
        "$toast = New-Object Windows.UI.Notifications.ToastNotification $xml\n"
        f"[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{app_id}').Show($toast)\n"
    )


#: PowerShell reads each of these as a single quote in a quoted string.
_PS_QUOTES = ("'", "\u2018", "\u2019", "\u201a", "\u201b")


def _ps_quote(text: str) -> str:
    for quote in _PS_QUOTES:
        text = text.replace(quote, quote + quote)
    return text


def encode_powershell(script: str) -> str:
    """``-EncodedCommand`` wants base64 of UTF-16LE. No quoting problems."""
    return base64.b64encode(script.encode("utf-16-le")).decode("ascii")


#: Where this module gets the name the reader knows. The host's own
#: desktop-only path (an automation that finished while an app was attached)
#: calls :func:`completion_text` with nothing but the roster's agent name, and
#: that name is a generated codename; the notifier installs this provider at
#: start-up so both paths say the same thing. Set once, read from the
#: notification thread.
_labels_provider: Callable[[], RunLabels] | None = None


def set_labels_provider(provider: Callable[[], RunLabels] | None) -> None:
    """Install (or clear) the resolver for the agent's own name."""
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


def completion_text(
    agent_name: str, *, failed: bool = False, answer: str | None = None
) -> tuple[str, str]:
    """Title/body for a caller that has only the roster's agent name.

    That name (``ivory-lynx``) is generated and doubles as the workspace
    directory: the reader has never seen it, so it is deliberately not shown.
    The name the user chose in the app comes from the installed provider, and
    without one the text stays generic — honest beats a codename.
    """
    del agent_name  # accepted for the existing call sites; see above
    return compose_completion_text(current_labels(), failed=failed, answer=answer)
