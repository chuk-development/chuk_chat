"""The safety floor (research H23-H25) and command-prefix rules (item 9)."""

from __future__ import annotations

import pytest

from chuk_agents_runtime import LocalEnvironment, ToolRegistry, register_builtin_tools
from chuk_agents_runtime.action_policy import CommandRules
from chuk_agents_runtime.file_edit import EditGuard
from chuk_agents_runtime.safety_floor import SafetyFloor


@pytest.fixture()
def floor(tmp_path):
    return SafetyFloor(home=str(tmp_path / "home"), self_dirs=(str(tmp_path / "install"),))


# -- hard deny ----------------------------------------------------------------


@pytest.mark.parametrize(
    "command",
    [
        "rm -rf /",
        "rm -rf ~",
        "rm -rf $HOME",
        "sudo rm -rf /",
        "mkfs.ext4 /dev/sda1",
        "dd if=/dev/zero of=/dev/sda bs=1M",
        ":(){ :|:& };:",
        "chmod -R 777 /",
    ],
)
def test_catastrophic_commands_are_hard_denied(floor, command):
    verdict = floor.check_command(command)
    assert verdict is not None and verdict.hard is True


def test_shutdown_is_soft_unless_allowed(tmp_path):
    f = SafetyFloor(home=str(tmp_path))
    assert f.check_command("shutdown now").hard is False
    f2 = SafetyFloor(home=str(tmp_path), allow_shutdown=True)
    assert f2.check_command("shutdown now") is None


def test_deleting_the_agents_own_dir_is_hard_denied(tmp_path):
    f = SafetyFloor(home=str(tmp_path / "home"), self_dirs=(str(tmp_path / "install"),))
    v = f.check_command(f"rm -rf {tmp_path / 'install'}")
    assert v is not None and v.hard is True


def test_an_ordinary_command_passes(floor):
    assert floor.check_command("ls -la && git status") is None
    assert floor.check_command("rm -rf build/") is None


# -- protected paths (soft) ---------------------------------------------------


def test_writing_ssh_is_soft_stopped(floor):
    v = floor.check_command("echo key >> ~/.ssh/authorized_keys")
    assert v is not None and v.hard is False


def test_reading_an_env_file_asks(floor):
    v = floor.check_command("cat .env")
    assert v is not None and v.hard is False
    assert floor.check_command("cat README.md") is None


def test_rm_of_a_protected_file_is_soft(floor):
    v = floor.check_command("rm ~/.aws/credentials")
    assert v is not None and v.hard is False


def test_an_approved_prefix_lifts_a_soft_stop(tmp_path):
    rules = CommandRules().remembered("cat .env")
    f = SafetyFloor(home=str(tmp_path), prefix_allowed=rules.allowed)
    assert f.check_command("cat .env") is None
    # but never a hard deny
    f2 = SafetyFloor(home=str(tmp_path), prefix_allowed=lambda c: True)
    assert f2.check_command("rm -rf /") is not None


# -- path checks used by the file tools ---------------------------------------


def test_floor_blocks_writing_a_protected_path_through_the_file_tools(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    env = LocalEnvironment()
    home = tmp_path / "home"
    (home / ".ssh").mkdir(parents=True)
    floor = SafetyFloor(home=str(home))
    reg = ToolRegistry()
    register_builtin_tools(reg, env, guard=EditGuard(env), floor=floor)
    out = reg.dispatch(
        "write_file", {"path": str(home / ".ssh" / "config"), "content": "x"}
    )
    assert out["ok"] is False and out.get("blocked") is True


def test_floor_blocks_reading_a_dot_env_through_read_file(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".env").write_text("SECRET=1\n")
    env = LocalEnvironment()
    reg = ToolRegistry()
    register_builtin_tools(reg, env, guard=EditGuard(env), floor=SafetyFloor(home=str(tmp_path)))
    out = reg.dispatch("read_file", {"path": ".env"})
    assert out["ok"] is False and out.get("blocked") is True


def test_floor_blocks_a_run_command_that_is_catastrophic(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    env = LocalEnvironment()
    reg = ToolRegistry()
    register_builtin_tools(reg, env, floor=SafetyFloor(home=str(tmp_path)))
    out = reg.dispatch("run_command", {"description": "wipe", "command": "rm -rf /"})
    assert out["ok"] is False and out.get("blocked") is True
    assert "never allowed" in out["error"]


# -- command rules ------------------------------------------------------------


def test_command_rules_match_token_prefix_and_survive_roundtrip():
    rules = CommandRules().remembered("git push")
    assert rules.allowed("git push origin main") is True
    assert rules.allowed("sudo git push") is True
    assert rules.allowed("git status") is False
    restored = CommandRules.from_stored(rules.to_stored())
    assert restored == rules
