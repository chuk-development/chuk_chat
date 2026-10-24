"""``docker run`` argv of a fresh agent container, with a fake CLI: the
workspace mount, and (cowork-b5) the read-only transcript mount that keeps a
``run_command`` inside the box from deleting the host's thread record."""

from __future__ import annotations

import os

from chuk_agents_sandbox.docker import CONTAINER_WORKSPACE, DockerEnvironment
from chuk_agents_sandbox.lifecycle import CliResult


class _FakeCli:
    binary = "docker"

    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def run(self, *args: str, timeout: int | None = None) -> CliResult:
        self.calls.append(args)
        return CliResult(stdout="cid-1\n", stderr="", exit_code=0)


def _run_argv(cli: _FakeCli) -> list[str]:
    return [list(c) for c in cli.calls if c and c[0] == "run"][0]


def _mounts(argv: list[str]) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv) if a == "-v"]


def test_transcript_folder_is_mounted_read_only_when_present(tmp_path):
    workspace = tmp_path / "ws"
    (workspace / "transcript").mkdir(parents=True)
    cli = _FakeCli()
    env = DockerEnvironment(workdir=str(workspace), cli=cli, user="1000:1000")
    env._create()
    mounts = _mounts(_run_argv(cli))
    assert f"{workspace}:{CONTAINER_WORKSPACE}" in mounts
    assert f"{workspace / 'transcript'}:{CONTAINER_WORKSPACE}/transcript:ro" in mounts


def test_no_transcript_folder_no_extra_mount(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    cli = _FakeCli()
    env = DockerEnvironment(workdir=str(workspace), cli=cli, user="1000:1000")
    env._create()
    mounts = _mounts(_run_argv(cli))
    assert mounts == [f"{workspace}:{CONTAINER_WORKSPACE}"]
    assert not any(m.endswith(":ro") for m in mounts)
    assert os.path.isdir(workspace)


def test_the_box_gets_the_host_time_zone_and_language(tmp_path, monkeypatch):
    """The box browser must agree with the user's IP: UTC behind a German IP
    is a bot signal (docker/browser-mcp.sh)."""
    monkeypatch.setenv("TZ", "Europe/Berlin")
    monkeypatch.delenv("LC_ALL", raising=False)
    monkeypatch.delenv("LC_MESSAGES", raising=False)
    monkeypatch.setenv("LANG", "de_DE.UTF-8")
    cli = _FakeCli()
    env = DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")
    env._create()
    argv = _run_argv(cli)
    values = [argv[i + 1] for i, a in enumerate(argv) if a == "-e"]
    assert "TZ=Europe/Berlin" in values
    assert "AGENTS_BROWSER_LOCALE=de-DE" in values


def test_a_strange_host_time_zone_is_not_passed_on(monkeypatch):
    from chuk_agents_sandbox.docker import host_browser_locale, host_timezone

    monkeypatch.setenv("TZ", "../../etc/passwd")
    assert host_timezone() is None
    monkeypatch.setenv("TZ", ":America/New_York")
    assert host_timezone() == "America/New_York"
    monkeypatch.setenv("LC_ALL", "C")
    assert host_browser_locale() == "en-US"
