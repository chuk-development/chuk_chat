"""The offline sanity check before an ``npx`` / ``uvx`` MCP server starts."""

from __future__ import annotations

import pytest

from chuk_agents_runtime.mcp_package_check import check_stdio_launch


def test_popular_pinned_package_is_clean():
    result = check_stdio_launch(
        "npx", ["-y", "@modelcontextprotocol/server-filesystem@2025.8.21", "/tmp"]
    )
    assert result.ok
    assert result.package == "@modelcontextprotocol/server-filesystem"
    assert result.version == "2025.8.21"
    assert result.warnings == ()


def test_unpinned_package_warns_but_runs():
    result = check_stdio_launch("npx", ["-y", "@playwright/mcp@latest"])
    assert result.ok
    assert any("no exact version" in w for w in result.warnings)


def test_uvx_pinned_and_unpinned():
    assert check_stdio_launch("uvx", ["mcp-server-fetch==2025.4.7"]).warnings == ()
    assert check_stdio_launch("uvx", ["mcp-server-fetch@2025.4.7"]).warnings == ()
    loose = check_stdio_launch("uvx", ["mcp-server-fetch>=1"])
    assert loose.ok and loose.warnings


def test_uvx_from_option_names_the_package():
    result = check_stdio_launch("uvx", ["--from", "mcp-server-git==1.0.0", "mcp-server-git"])
    assert result.package == "mcp-server-git"
    assert result.warnings == ()


@pytest.mark.parametrize(
    "args",
    [
        ["-y", "@modelcontextprotocol/server-filesytem"],  # missing letter
        ["-y", "@modelcontextprotocol/server-filesystems"],  # extra letter
        ["-y", "@modelcontextprotocoI/server-filesystem"],  # look-alike scope
        ["-y", "@model-context-protocol/server-memory"],  # look-alike scope
        ["-y", "@modelcontextprotocol/server_filesystem"],  # separator swap
        ["-y", "chrome-devtools-mpc"],  # swapped letters
        ["-y", "@plаywright/mcp"],  # Cyrillic a
    ],
)
def test_typosquats_are_refused(args):
    result = check_stdio_launch("npx", args)
    assert not result.ok
    assert result.reason


def test_pypi_typosquat_is_refused():
    assert not check_stdio_launch("uvx", ["mcp-server-fecth"]).ok


def test_unrelated_names_are_not_typosquats():
    for name in ("mcpx", "mcp-server-gitee", "my-own-mcp-server", "@acme/mcp"):
        assert check_stdio_launch("npx", ["-y", f"{name}@1.0.0"]).ok, name
    assert check_stdio_launch("uvx", ["mcp-server-gitee==1.0.0"]).ok


def test_known_malicious_package_is_refused_even_when_pinned():
    result = check_stdio_launch("npx", ["-y", "postmark-mcp@1.0.15"])
    assert not result.ok
    assert "malicious" in result.reason


def test_user_deny_and_allow_lists():
    assert not check_stdio_launch("npx", ["foo-mcp@1.0.0"], deny=["foo-mcp"]).ok
    squat = ["-y", "chrome-devtools-mpc@1.0.0"]
    assert check_stdio_launch("npx", squat, allow=["chrome-devtools-mpc"]).ok
    # The allow list never beats the built-in deny list.
    assert not check_stdio_launch("npx", ["postmark-mcp"], allow=["postmark-mcp"]).ok


def test_other_runners_and_full_paths():
    assert check_stdio_launch("/usr/bin/npx", ["-y", "postmark-mcp"]).ok is False
    assert check_stdio_launch("pnpm", ["dlx", "postmark-mcp"]).ok is False
    assert check_stdio_launch("uv", ["tool", "run", "mcp-server-fecth"]).ok is False
    assert check_stdio_launch("npx -y postmark-mcp", []).ok is False
    assert check_stdio_launch("npx", ["--package=postmark-mcp", "pm"]).ok is False


def test_remote_source_warns():
    result = check_stdio_launch("npx", ["-y", "github:someone/mcp-thing"])
    assert result.ok
    assert any("not from the package registry" in w for w in result.warnings)


def test_plain_commands_are_not_checked():
    for command, args in (("node", ["server.js"]), ("python", ["-m", "x"]), ("./srv", [])):
        result = check_stdio_launch(command, args)
        assert result.ok and not result.checked and result.warnings == ()


def test_runner_with_no_package_is_not_checked():
    assert check_stdio_launch("npx", ["-y"]).checked is False
