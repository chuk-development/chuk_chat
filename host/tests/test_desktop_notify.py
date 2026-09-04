"""The host's desktop notification (docs/WIRE_CONTRACT.md): the simplest
"your answer is ready" channel when the host and the desktop app share a
machine. Asserted on the argv it would run, with no display and no process."""

from __future__ import annotations

from cowork_host.desktop_notify import DesktopNotifier, completion_text


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
    assert notifier.notify("Ada finished your task", "Open the app to see the answer")
    (argv,) = calls
    assert argv[0] == "notify-send"
    assert "--app-name=CoWork" in argv
    assert "--hint=string:desktop-entry:cowork" in argv
    assert argv[-2:] == ["Ada finished your task", "Open the app to see the answer"]


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


def test_completion_text_carries_no_answer_content():
    title, body = completion_text("Ada")
    assert title == "Ada finished your task"
    assert "answer" in body and "hello" not in body
    title, body = completion_text("", failed=True)
    assert title.startswith("Your coworker")
