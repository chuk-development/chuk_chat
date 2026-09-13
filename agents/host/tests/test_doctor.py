"""``cowork-host doctor``: every answer is measured, none is assumed.

Bead cowork-3i5c left the user with no way to tell a working backend from a
broken one until a run failed minutes in. These tests pin what the command
promises: it asks docker, it asks the image, and it makes the browser server
speak before it calls the browser good.
"""

from __future__ import annotations

import json

import pytest

from chuk_agents_host import doctor


class FakeProc:
    def __init__(self, code=0, stdout="", stderr=""):
        self.returncode = code
        self.stdout = stdout
        self.stderr = stderr


def test_a_missing_docker_binary_is_a_failure_with_a_way_out(monkeypatch):
    monkeypatch.setattr(doctor.shutil, "which", lambda _b: None)
    check = doctor.check_docker()
    assert check.ok is False
    assert "--sandbox local" in check.fix


def test_a_dead_daemon_reports_its_own_words(monkeypatch):
    monkeypatch.setattr(doctor.shutil, "which", lambda _b: "/usr/bin/docker")
    monkeypatch.setattr(
        doctor, "_run", lambda *a, **k: (1, "", "Cannot connect to the daemon")
    )
    check = doctor.check_docker()
    assert check.ok is False
    assert "daemon" in check.detail


def test_the_browser_is_good_only_when_the_server_answers(monkeypatch):
    answer = {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {"serverInfo": {"name": "Playwright", "version": "1.63.0"}},
    }
    monkeypatch.setattr(
        doctor.subprocess,
        "run",
        lambda *a, **k: FakeProc(stdout=json.dumps(answer) + "\n"),
    )
    check = doctor.check_browser_speaks_mcp("img:1")
    assert check.ok is True
    assert "Playwright 1.63.0" == check.detail


def test_a_launcher_that_starts_but_says_nothing_is_a_failure(monkeypatch):
    monkeypatch.setattr(
        doctor.subprocess,
        "run",
        lambda *a, **k: FakeProc(code=1, stderr="Xvfb: cannot open display"),
    )
    check = doctor.check_browser_speaks_mcp("img:1")
    assert check.ok is False
    assert "Xvfb" in check.detail


def test_a_hang_is_a_failure_not_a_hang(monkeypatch):
    def boom(*a, **k):
        raise doctor.subprocess.TimeoutExpired(cmd="docker", timeout=90)

    monkeypatch.setattr(doctor.subprocess, "run", boom)
    check = doctor.check_browser_speaks_mcp("img:1")
    assert check.ok is False
    assert "no answer" in check.detail


def test_no_docker_stops_the_cascade_and_names_the_consequence(monkeypatch):
    monkeypatch.setattr(
        doctor, "check_docker", lambda binary="docker": doctor.Check(
            "docker", False, "no daemon"
        )
    )
    checks = doctor.run_checks("/tmp/does-not-exist")
    names = [c.name for c in checks]
    assert "image" not in names
    browser = [c for c in checks if c.name == "browser"][0]
    assert "no browser" in browser.fix


def test_an_engaged_estop_is_reported(tmp_path):
    (tmp_path / "ESTOP").write_text("")
    check = doctor.check_estop(str(tmp_path))
    assert check.ok is False
    assert "ENGAGED" in check.detail


def test_the_report_exit_code_follows_the_checks():
    good = [doctor.Check("a", True, "fine")]
    bad = [doctor.Check("a", False, "broken", "do this")]
    assert doctor.print_report(good, out=lambda *_: None) == 0
    assert doctor.print_report(bad, out=lambda *_: None) == 1


def test_the_report_prints_the_fix_for_a_failure():
    lines: list[str] = []
    doctor.print_report(
        [doctor.Check("image", False, "not built", "build it")],
        out=lambda *a: lines.append(" ".join(str(x) for x in a)),
    )
    body = "\n".join(lines)
    assert "FAIL" in body
    assert "-> build it" in body


@pytest.mark.parametrize("quick", [True, False])
def test_quick_skips_the_container_probe(monkeypatch, tmp_path, quick):
    monkeypatch.setattr(
        doctor, "check_docker", lambda binary="docker": doctor.Check(
            "docker", True, "ok"
        )
    )
    monkeypatch.setattr(
        doctor,
        "check_image",
        lambda binary="docker": (doctor.Check("image", True, "img:1"), "img:1"),
    )
    monkeypatch.setattr(
        doctor,
        "check_browser_launcher",
        lambda image, binary="docker": doctor.Check("browser launcher", True, "in"),
    )
    called: list[str] = []
    monkeypatch.setattr(
        doctor,
        "check_browser_speaks_mcp",
        lambda image, binary="docker": called.append(image)
        or doctor.Check("browser server", True, "Playwright"),
    )
    doctor.run_checks(str(tmp_path), deep=not quick)
    assert called == ([] if quick else ["img:1"])
