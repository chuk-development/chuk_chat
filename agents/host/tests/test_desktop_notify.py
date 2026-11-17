"""The host's desktop notification (docs/WIRE_CONTRACT.md): the simplest
"your answer is ready" channel when the host and the desktop app share a
machine. Asserted on the argv it would run, with no display and no process."""

from __future__ import annotations

import base64

from chuk_agents_host.desktop_notify import (
    PACKAGED_ICON,
    DesktopNotifier,
    completion_text,
    icon_path,
    set_labels_provider,
    windows_toast_script,
    windows_toast_xml,
)
from chuk_agents_host.notification_text import RunLabels


def _capture():
    calls: list[list[str]] = []

    def runner(argv):
        calls.append(list(argv))

    return calls, runner


def test_linux_uses_notify_send_with_app_name_and_desktop_entry():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner, enabled=True, system="Linux", which=lambda name: "/usr/bin/" + name,
        background=False,
    )
    assert notifier.notify("Ada: Wahlradar", "The answer is ready.")
    (argv,) = calls
    assert argv[0] == "notify-send"
    assert "--app-name=Agents" in argv
    assert "--hint=string:desktop-entry:agents" in argv
    assert argv[-2:] == ["Ada: Wahlradar", "The answer is ready."]


def test_linux_falls_back_to_gdbus_when_notify_send_is_missing():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner,
        enabled=True,
        system="Linux",
        which=lambda name: "/usr/bin/gdbus" if name == "gdbus" else None,
        background=False,
    )
    assert notifier.notify("t", "b")
    (argv,) = calls
    assert argv[:2] == ["gdbus", "call"]
    assert "org.freedesktop.Notifications.Notify" in argv


def test_disabled_runs_nothing():
    calls, runner = _capture()
    notifier = DesktopNotifier(runner=runner, enabled=False, system="Linux")
    assert notifier.notify("t", "b") is False
    assert calls == []


def test_no_display_means_disabled_on_linux(monkeypatch):
    monkeypatch.delenv("DISPLAY", raising=False)
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    monkeypatch.delenv("AGENTS_DESKTOP_NOTIFY", raising=False)
    assert DesktopNotifier(runner=lambda argv: None, system="Linux").enabled is False
    monkeypatch.setenv("DISPLAY", ":0")
    assert DesktopNotifier(runner=lambda argv: None, system="Linux").enabled is True
    monkeypatch.setenv("AGENTS_DESKTOP_NOTIFY", "0")
    assert DesktopNotifier(runner=lambda argv: None, system="Linux").enabled is False


def test_macos_uses_osascript_with_the_preview_body():
    calls, runner = _capture()
    mac = DesktopNotifier(runner=runner, enabled=True, system="Darwin", background=False)
    assert mac.notify('say "hi"', "Die Summe ist 210.")
    assert calls[0][0] == "osascript" and '\\"hi\\"' in calls[0][2]
    assert "Die Summe ist 210." in calls[0][2]


def _decode_ps(argv: list[str]) -> str:
    return base64.b64decode(argv[argv.index("-EncodedCommand") + 1]).decode("utf-16-le")


def test_windows_shows_a_powershell_toast_with_the_avatar():
    calls, runner = _capture()
    win = DesktopNotifier(
        runner=runner, enabled=True, system="Windows", background=False,
        which=lambda name: "C:\\Windows\\powershell.exe" if name == "powershell" else None,
    )
    assert win.notify("Ada", "It's 210 & done <ok>", icon="C:\\ws\\avatars\\local_a.png")
    (argv,) = calls
    assert argv[0].endswith("powershell.exe") and "-NoProfile" in argv
    script = _decode_ps(argv)
    assert "ToastNotificationManager" in script
    assert 'placement="appLogoOverride"' in script
    assert "file:///C:/ws/avatars/local_a.png" in script
    # XML-escaped, and the single quote doubled for the PowerShell string.
    assert "It''s 210 &amp; done &lt;ok&gt;" in script


def test_windows_toast_xml_falls_back_to_no_image_without_an_icon():
    xml = windows_toast_xml("t", "b", None)
    assert "<image" not in xml and "<text>t</text><text>b</text>" in xml
    script = windows_toast_script("t", "\u2019q", None)
    assert "\u2019\u2019q" in script


def test_windows_without_powershell_runs_nothing():
    calls, runner = _capture()
    win = DesktopNotifier(runner=runner, enabled=True, system="Windows", background=False,
                          which=lambda name: None)
    assert win.notify("t", "b") is False and calls == []


def test_windows_is_enabled_by_default(monkeypatch):
    monkeypatch.delenv("AGENTS_DESKTOP_NOTIFY", raising=False)
    assert DesktopNotifier(runner=lambda argv: None, system="Windows").enabled is True


def test_a_per_call_icon_wins_over_the_app_logo_on_linux():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner, enabled=True, system="Linux", which=lambda name: "/usr/bin/" + name,
        background=False, icon="/opt/agents/logo.png",
    )
    notifier.notify("t", "b", icon="/ws/avatars/local_a.png")
    assert "--icon=/ws/avatars/local_a.png" in calls[0]
    assert "--icon=/opt/agents/logo.png" not in calls[0]


def test_gdbus_gets_the_avatar_icon_too():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner, enabled=True, system="Linux",
        which=lambda name: "/usr/bin/gdbus" if name == "gdbus" else None, background=False,
    )
    notifier.notify("t", "b", icon="/ws/avatars/local_a.png")
    argv = calls[0]
    assert argv[argv.index("t") - 1] == "/ws/avatars/local_a.png"


def test_the_linux_body_is_markup_escaped():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner, enabled=True, system="Linux", which=lambda name: "/usr/bin/" + name,
        background=False,
    )
    notifier.notify("t", "a < b & c")
    assert calls[0][-1] == "a &lt; b &amp; c"


def test_a_failing_runner_never_raises():
    def boom(argv):
        raise RuntimeError("no dbus")

    notifier = DesktopNotifier(runner=boom, enabled=True, system="Linux", which=lambda n: "/x", background=False)
    assert notifier.notify("t", "b") is False


def test_the_toast_carries_the_app_icon_so_the_slot_is_not_blank():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner, enabled=True, system="Linux", which=lambda name: "/usr/bin/" + name,
        background=False, icon="/opt/agents/logo.png",
    )
    notifier.notify("t", "b")
    assert "--icon=/opt/agents/logo.png" in calls[0]


def test_gdbus_passes_the_icon_in_the_notify_signature():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner,
        enabled=True,
        system="Linux",
        which=lambda name: "/usr/bin/gdbus" if name == "gdbus" else None,
        background=False,
        icon="/opt/agents/logo.png",
    )
    notifier.notify("t", "b")
    argv = calls[0]
    # ... Notify <app-name> <replaces-id> <app-icon> <title> <body> ...
    assert argv[argv.index("t") - 1] == "/opt/agents/logo.png"


def test_the_packaged_icon_ships_with_the_host(monkeypatch):
    # The override wins over the packaged file, so a value left in the shell
    # or the CI image would fail this test for the wrong reason.
    monkeypatch.delenv("AGENTS_NOTIFY_ICON", raising=False)
    assert PACKAGED_ICON.is_file()
    assert icon_path() == str(PACKAGED_ICON)


def test_an_icon_override_wins(monkeypatch):
    monkeypatch.setenv("AGENTS_NOTIFY_ICON", "agents")
    assert icon_path() == "agents"


def test_completion_text_never_shows_the_roster_codename():
    set_labels_provider(None)
    try:
        title, body = completion_text("ivory-lynx")
        assert "ivory-lynx" not in title and "ivory-lynx" not in body
        assert title == "Your agent"
        assert "answer" in body and "hello" not in body
        # The run is over: the body reports, it does not hand the user a task.
        assert "finish your task" not in body.lower()
        title, _ = completion_text("ivory-lynx", failed=True)
        assert title == "Your agent"
    finally:
        set_labels_provider(None)


def test_completion_text_uses_the_installed_labels_provider():
    set_labels_provider(lambda: RunLabels(coworker="Nova"))
    try:
        title, _ = completion_text("ivory-lynx")
        assert title == "Nova"
    finally:
        set_labels_provider(None)


def test_a_broken_labels_provider_still_yields_a_toast():
    def boom():
        raise RuntimeError("db is locked")

    set_labels_provider(boom)
    try:
        title, body = completion_text("ivory-lynx")
        assert title == "Your agent" and body
    finally:
        set_labels_provider(None)
