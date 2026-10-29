"""``docker run`` argv of a fresh agent container, with a fake CLI: the
workspace mount, and (cowork-b5) the read-only transcript mount that keeps a
``run_command`` inside the box from deleting the host's thread record."""

from __future__ import annotations

import os

import pytest

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
    monkeypatch.delenv("AGENTS_BROWSER_TIMEZONE", raising=False)
    monkeypatch.delenv("AGENTS_BROWSER_LOCALE", raising=False)
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


class _GpuCli(_FakeCli):
    """A daemon with the NVIDIA runtime; ``fail_gpu`` makes a create with
    ``--gpus`` fail the way a broken toolkit does."""

    def __init__(self, *, runtimes: str = '{"nvidia":{},"runc":{}}', fail_gpu: bool = False):
        super().__init__()
        self.runtimes = runtimes
        self.fail_gpu = fail_gpu
        self.revision = "1"

    def run(self, *args: str, timeout: int | None = None) -> CliResult:
        self.calls.append(args)
        if args[:1] == ("info",):
            return CliResult(stdout=self.runtimes, stderr="", exit_code=0)
        if args[:2] == ("image", "inspect"):  # a browser image, revision 1
            return CliResult(stdout=self.revision + "\n", stderr="", exit_code=0)
        if args[:1] == ("run",) and "--gpus" in args and self.fail_gpu:
            return CliResult(stdout="", stderr="could not select device driver", exit_code=125)
        return CliResult(stdout="cid-1\n", stderr="", exit_code=0)


def _creates(cli: _FakeCli) -> list[list[str]]:
    return [list(c) for c in cli.calls if c[:2] == ("run", "-d")]


@pytest.fixture()
def nvidia_host(monkeypatch):
    from chuk_agents_sandbox import docker

    docker.forget_image_probes()
    real_exists = os.path.exists
    monkeypatch.setattr(
        docker.os.path, "exists", lambda p: p == docker.NVIDIA_CTL or real_exists(p)
    )
    monkeypatch.delenv(docker.GPU_ENV_VAR, raising=False)
    yield docker
    docker.forget_image_probes()


def test_a_browser_box_gets_the_nvidia_gpu(tmp_path, nvidia_host):
    """With no GPU the box browser reports SwiftShader as its WebGL renderer,
    the strongest bot tell (docker/browser-mcp.sh)."""
    cli = _GpuCli()
    env = DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")
    env._create()
    argv = _creates(cli)[0]
    i = argv.index("--gpus")
    assert argv[i + 1] == "all,capabilities=graphics"
    # Before the image, or docker reads it as the command.
    assert i < argv.index(env.image)


def test_no_nvidia_runtime_no_gpu(tmp_path, nvidia_host):
    cli = _GpuCli(runtimes='{"runc":{}}')
    DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")._create()
    assert "--gpus" not in _creates(cli)[0]


def test_the_gpu_can_be_switched_off(tmp_path, nvidia_host, monkeypatch):
    monkeypatch.setenv(nvidia_host.GPU_ENV_VAR, "0")
    cli = _GpuCli()
    DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")._create()
    assert "--gpus" not in _creates(cli)[0]
    assert not any(c[:1] == ("info",) for c in cli.calls)


def test_a_gpu_that_cannot_be_attached_still_gives_a_box(tmp_path, nvidia_host):
    """The failed `docker run` may have created the container already: it is
    removed. The new box says the GPU failed, not that it has one."""
    from chuk_agents_sandbox.docker import LABEL_BOX

    cli = _GpuCli(fail_gpu=True)
    env = DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")
    assert env._create() == "cid-1"
    first, second = _creates(cli)
    assert "--gpus" in first and "--gpus" not in second
    assert ("rm", "-f", env.container_name) in cli.calls
    assert cli.calls.index(("rm", "-f", env.container_name)) < len(cli.calls) - 1
    assert f"{LABEL_BOX}=browser=1;gpu=failed" in second
    assert f"{LABEL_BOX}=browser=1;gpu=1" in first


def test_a_host_without_nvidia_never_probes(tmp_path, monkeypatch):
    from chuk_agents_sandbox import docker

    docker.forget_image_probes()
    real_exists = os.path.exists
    monkeypatch.setattr(
        docker.os.path, "exists", lambda p: False if p == docker.NVIDIA_CTL else real_exists(p)
    )
    cli = _GpuCli()
    DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")._create()
    assert [c[0] for c in cli.calls] == ["image", "run"]
    assert "--gpus" not in _creates(cli)[0]


def test_the_box_label_records_revision_and_gpu(tmp_path, nvidia_host):
    from chuk_agents_sandbox.docker import LABEL_BOX

    cli = _GpuCli()
    DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")._create()
    assert f"{LABEL_BOX}=browser=1;gpu=1" in _creates(cli)[0]


def test_a_base_image_box_has_the_default_box_key(tmp_path, monkeypatch):
    """No revision label = no browser: no GPU, no ``docker info``, and the
    key a box from before the label counts as, so it is not made again."""
    from chuk_agents_sandbox.docker import DEFAULT_BOX_KEY

    cli = _GpuCli()
    cli.revision = ""
    env = DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000")
    assert env.box_key() == DEFAULT_BOX_KEY
    assert not any(c[:1] == ("info",) for c in cli.calls)


def test_a_server_in_utc_can_name_the_users_zone_and_language(monkeypatch):
    """A VPS often runs in UTC with LANG=C.UTF-8 while its user is in
    Berlin: the box then names the user's zone and language instead."""
    from chuk_agents_sandbox.docker import host_browser_locale, host_timezone

    monkeypatch.setenv("TZ", "UTC")
    monkeypatch.setenv("LANG", "C.UTF-8")
    monkeypatch.delenv("LC_ALL", raising=False)
    monkeypatch.delenv("LC_MESSAGES", raising=False)
    monkeypatch.setenv("AGENTS_BROWSER_TIMEZONE", "Europe/Berlin")
    monkeypatch.setenv("AGENTS_BROWSER_LOCALE", "de_DE")
    assert host_timezone() == "Europe/Berlin"
    assert host_browser_locale() == "de-DE"
    monkeypatch.setenv("AGENTS_BROWSER_TIMEZONE", "../etc")
    assert host_timezone() == "UTC"
