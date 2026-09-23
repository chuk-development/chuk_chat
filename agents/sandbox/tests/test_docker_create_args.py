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
