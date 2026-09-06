"""The host's desktop notification (docs/WIRE_CONTRACT.md): the simplest
"your answer is ready" channel when the host and the desktop app share a
machine. Asserted on the argv it would run, with no display and no process."""

from __future__ import annotations

from cowork_host.desktop_notify import (
    PACKAGED_ICON,
    DesktopNotifier,
    completion_text,
    icon_path,
    set_labels_provider,
)
from cowork_host.notification_text import RunLabels


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
    assert "--app-name=CoWork" in argv
    assert "--hint=string:desktop-entry:cowork" in argv
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
    monkeypatch.delenv("COWORK_DESKTOP_NOTIFY", raising=False)
    assert DesktopNotifier(runner=lambda argv: None, system="Linux").enabled is False
    monkeypatch.setenv("DISPLAY", ":0")
    assert DesktopNotifier(runner=lambda argv: None, system="Linux").enabled is True
    monkeypatch.setenv("COWORK_DESKTOP_NOTIFY", "0")
    assert DesktopNotifier(runner=lambda argv: None, system="Linux").enabled is False


def test_macos_uses_osascript_and_windows_is_skipped():
    calls, runner = _capture()
    mac = DesktopNotifier(runner=runner, enabled=True, system="Darwin", background=False)
    assert mac.notify('say "hi"', "body")
    assert calls[0][0] == "osascript" and '\\"hi\\"' in calls[0][2]
    win = DesktopNotifier(runner=runner, enabled=True, system="Windows", background=False)
    assert win.notify("t", "b") is False


def test_a_failing_runner_never_raises():
    def boom(argv):
        raise RuntimeError("no dbus")

    notifier = DesktopNotifier(runner=boom, enabled=True, system="Linux", which=lambda n: "/x", background=False)
    assert notifier.notify("t", "b") is False


def test_the_toast_carries_the_app_icon_so_the_slot_is_not_blank():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner, enabled=True, system="Linux", which=lambda name: "/usr/bin/" + name,
        background=False, icon="/opt/cowork/logo.png",
    )
    notifier.notify("t", "b")
    assert "--icon=/opt/cowork/logo.png" in calls[0]


def test_gdbus_passes_the_icon_in_the_notify_signature():
    calls, runner = _capture()
    notifier = DesktopNotifier(
        runner=runner,
        enabled=True,
        system="Linux",
        which=lambda name: "/usr/bin/gdbus" if name == "gdbus" else None,
        background=False,
        icon="/opt/cowork/logo.png",
    )
    notifier.notify("t", "b")
    argv = calls[0]
    # ... Notify <app-name> <replaces-id> <app-icon> <title> <body> ...
    assert argv[argv.index("t") - 1] == "/opt/cowork/logo.png"


def test_the_packaged_icon_ships_with_the_host():
    assert PACKAGED_ICON.is_file()
    assert icon_path() == str(PACKAGED_ICON)


def test_an_icon_override_wins(monkeypatch):
    monkeypatch.setenv("COWORK_NOTIFY_ICON", "cowork")
    assert icon_path() == "cowork"


def test_completion_text_never_shows_the_roster_codename():
    set_labels_provider(None)
    try:
        title, body = completion_text("ivory-lynx")
        assert "ivory-lynx" not in title and "ivory-lynx" not in body
        assert title == "Your coworker"
        assert "answer" in body and "hello" not in body
        # The run is over: the body reports, it does not hand the user a task.
        assert "finish your task" not in body.lower()
        title, _ = completion_text("ivory-lynx", failed=True)
        assert title == "Your coworker"
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
        assert title == "Your coworker" and body
    finally:
        set_labels_provider(None)
