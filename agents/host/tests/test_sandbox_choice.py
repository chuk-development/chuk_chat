"""What backend and image a host picks when the user names neither.

Bead cowork-3i5c. Two defaults used to conspire against the watchable browser:
``--sandbox`` defaulted to ``local`` (no container, so no Playwright MCP server)
and the browser gate matched a word in ``COWORK_SANDBOX_IMAGE`` (unset, so
false). A host started with no flags could therefore never browse.
"""

from __future__ import annotations

import cowork_host.cli as cli_mod
from cowork_host.cli import resolve_sandbox_kind


def test_auto_takes_docker_when_the_daemon_answers(monkeypatch):
    monkeypatch.setattr("cowork_sandbox.docker_available", lambda: True)
    assert resolve_sandbox_kind("auto") == "docker"


def test_auto_falls_back_to_local_without_docker(monkeypatch):
    monkeypatch.setattr("cowork_sandbox.docker_available", lambda: False)
    assert resolve_sandbox_kind("auto") == "local"


def test_a_broken_daemon_is_local_not_a_crash(monkeypatch):
    def boom():
        raise RuntimeError("socket gone")

    monkeypatch.setattr("cowork_sandbox.docker_available", boom)
    assert resolve_sandbox_kind("auto") == "local"


def test_an_explicit_choice_is_never_second_guessed(monkeypatch):
    monkeypatch.setattr("cowork_sandbox.docker_available", lambda: True)
    assert resolve_sandbox_kind("local") == "local"
    monkeypatch.setattr("cowork_sandbox.docker_available", lambda: False)
    assert resolve_sandbox_kind("docker") == "docker"


def test_the_run_parser_defaults_to_auto():
    parser = cli_mod._build_parser()
    args = parser.parse_args(["run"])
    assert args.sandbox == "auto"


# -- the browser gate --------------------------------------------------------


def _docker_host(tmp_path, monkeypatch, *, image: str, has_browser: bool):
    from cowork_host.host import LocalHost

    monkeypatch.setattr("cowork_host.host.default_image", lambda: image)
    monkeypatch.setattr(
        "cowork_host.host.image_has_browser", lambda name: has_browser
    )
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="w",
        sandbox_kind="docker",
    )


def test_the_gate_opens_for_an_image_that_carries_the_launcher(tmp_path, monkeypatch):
    host = _docker_host(tmp_path, monkeypatch, image="own:1", has_browser=True)
    # The tag says nothing about a browser; the image does.
    assert host._browser_mcp is True
    assert host._containers.image == "own:1"


def test_the_gate_stays_shut_for_a_browserless_image(tmp_path, monkeypatch):
    host = _docker_host(
        tmp_path, monkeypatch, image="looks-like-browser:1", has_browser=False
    )
    assert host._browser_mcp is False


def test_a_local_sandbox_has_no_image_and_no_browser(tmp_path, monkeypatch):
    from cowork_host.host import LocalHost

    monkeypatch.setattr(
        "cowork_host.host.default_image", lambda: (_ for _ in ()).throw(AssertionError)
    )
    host = LocalHost(
        port=0, workspace_dir=str(tmp_path), agent_name="w", sandbox_kind="local"
    )
    assert host._sandbox_image is None
    assert host._browser_mcp is False
