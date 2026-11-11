"""Bead B9 and research items 36/37: what a local command inherits, how it is
killed, and the bwrap and docker hardening argv."""

from __future__ import annotations

import os
import subprocess
import time

import pytest

from chuk_agents_sandbox import LocalEnvironment, SandboxPolicy, bwrap as bw
from chuk_agents_sandbox.child_env import child_env, is_allowed
from chuk_agents_sandbox.docker import DockerEnvironment
from chuk_agents_sandbox.lifecycle import CliResult
from chuk_agents_sandbox.policy import PIDS_LIMIT, enforced_permissions, hardening_run_args

SECRET_NAMES = (
    "AGENTS_ACCOUNT_TOKEN",
    "OPENAI_API_KEY",
    "GITHUB_TOKEN",
    "DB_PASSWORD",
    "AWS_SECRET_ACCESS_KEY",
    "CHUK_INTERNAL",
    "XDG_SESSION_COOKIE",
)


@pytest.fixture
def leaky_host(monkeypatch):
    for name in SECRET_NAMES:
        monkeypatch.setenv(name, f"leak-{name.lower()}")
    monkeypatch.setenv("UNRELATED_SETTING", "nope")
    monkeypatch.setenv("LC_TIME", "de_DE.UTF-8")


def test_child_env_drops_secrets_and_keeps_the_allowlist(leaky_host):
    env = child_env()
    for name in SECRET_NAMES:
        assert name not in env
    assert "UNRELATED_SETTING" not in env
    assert env["LC_TIME"] == "de_DE.UTF-8"
    assert env["PATH"]
    assert env["NO_COLOR"] == "1" and env["TERM"] == "dumb"
    assert env["PAGER"] == "cat" and env["GIT_PAGER"] == "cat"


def test_granted_secrets_pass_by_grant_only(leaky_host):
    env = child_env({"OPENAI_API_KEY": "granted"})
    assert env["OPENAI_API_KEY"] == "granted"
    assert "GITHUB_TOKEN" not in env


def test_deny_beats_the_allowlist():
    assert not is_allowed("XDG_AUTH_TOKEN")
    assert not is_allowed("LC_SECRET")
    assert is_allowed("LC_ALL") and is_allowed("HOME")


def test_a_local_command_never_sees_the_host_secrets(leaky_host, tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path / "ws"))
    try:
        result = env.run("env")
        assert result.exit_code == 0
        for name in SECRET_NAMES:
            assert f"leak-{name.lower()}" not in result.stdout
        assert "NO_COLOR=1" in result.stdout
        assert "TERM=dumb" in result.stdout
        # A granted secret still arrives, for this command only.
        granted = env.run("echo \"$OPENAI_API_KEY\"", env={"OPENAI_API_KEY": "mine"})
        assert granted.stdout.strip() == "mine"
        again = env.run("echo \"[$OPENAI_API_KEY]\"")
        assert again.stdout.strip() == "[]"
    finally:
        env.cleanup()


def test_a_login_profile_cannot_export_a_key_into_the_session(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".bash_profile").write_text(
        "export PROFILE_API_KEY=from-profile\nexport PROFILE_PLAIN=kept\n"
    )
    monkeypatch.setenv("HOME", str(home))
    env = LocalEnvironment(workdir=str(tmp_path / "ws"))
    try:
        out = env.run('echo "[$PROFILE_API_KEY][$PROFILE_PLAIN]"').stdout.strip()
        assert out == "[][kept]"
    finally:
        env.cleanup()


def test_the_terminal_gets_its_own_tmux_server(tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path / "ws"))
    try:
        out = env.run('echo "$TMUX_TMPDIR"').stdout.strip()
        assert out and "agents-tmux-" in out and out != os.environ.get("TMUX_TMPDIR")
    finally:
        env.cleanup()


# -- kill escalation (item 36) -------------------------------------------- #


def test_timeout_sends_term_first(tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path / "ws"))
    try:
        result = env.run(
            "trap 'echo got-term; exit 3' TERM; sleep 30 & wait", timeout=1
        )
        assert result.timed_out
        assert "got-term" in result.stdout
    finally:
        env.cleanup()


def test_a_command_that_ignores_term_is_killed(tmp_path, monkeypatch):
    import chuk_agents_sandbox.local as local_module

    monkeypatch.setattr(local_module, "KILL_GRACE_S", 0.3)
    env = LocalEnvironment(workdir=str(tmp_path / "ws"))
    try:
        start = time.monotonic()
        result = env.run("trap '' TERM; sleep 30", timeout=1)
        assert result.timed_out
        assert time.monotonic() - start < 10
    finally:
        env.cleanup()


def test_kill_group_escalates_to_sigkill():
    from chuk_agents_sandbox.local import LocalEnvironment as LE

    proc = subprocess.Popen(
        ["bash", "-c", "trap '' TERM; sleep 30"], start_new_session=True
    )
    time.sleep(0.2)
    start = time.monotonic()
    LE._kill_group(proc, grace=0.3)
    assert proc.wait(5) == -9
    assert time.monotonic() - start < 5


# -- bwrap (item 37) ------------------------------------------------------ #


def test_bwrap_argv(tmp_path):
    argv = bw.wrap_argv(
        ["bash", "-c", "true"],
        binary="/usr/bin/bwrap",
        workspace="/w",
        session_dir="/s",
        private_tmp="/s/tmp",
        network=False,
    )
    assert argv[:9] == ["/usr/bin/bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--bind"]
    joined = " ".join(argv)
    assert "--bind /s/tmp /tmp" in joined
    assert "--bind /s /s" in joined
    assert "--bind /w /w" in joined
    assert "--unshare-pid" in argv and "--die-with-parent" in argv
    assert "--unshare-net" in argv
    assert argv[-4:] == ["--", "bash", "-c", "true"]


def test_bwrap_argv_read_only_workspace_and_network_on():
    argv = bw.wrap_argv(
        ["true"], binary="bwrap", workspace="/w", session_dir="/s",
        read_only_workspace=True, network=True,
    )
    joined = " ".join(argv)
    assert "--ro-bind /w /w" in joined
    assert "--tmpfs /tmp" in joined
    assert "--unshare-net" not in argv


def test_isolation_is_off_unless_asked(monkeypatch):
    monkeypatch.delenv(bw.ISOLATION_ENV_VAR, raising=False)
    assert bw.resolve_isolation() == "none"
    assert bw.resolve_isolation("BWRAP") == "bwrap"
    assert bw.resolve_isolation("nonsense") == "none"
    monkeypatch.setenv(bw.ISOLATION_ENV_VAR, "auto")
    assert bw.resolve_isolation() == "auto"


def test_probe_falls_back_when_bwrap_is_missing(monkeypatch, tmp_path, caplog):
    bw.reset_probe()
    monkeypatch.setattr(bw, "_warned", False)
    monkeypatch.setattr(bw, "bwrap_binary", lambda: None)
    try:
        env = LocalEnvironment(workdir=str(tmp_path / "ws"), isolation="bwrap")
        try:
            assert not env.isolated and env.kind == "local"
            assert env.run("echo ok").stdout.strip() == "ok"
        finally:
            env.cleanup()
        assert "WITHOUT isolation" in caplog.text
    finally:
        bw.reset_probe()


def test_probe_failure_is_cached(monkeypatch):
    bw.reset_probe()
    calls: list[list[str]] = []

    def fake_run(argv, **kw):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 1, b"", b"no userns")

    monkeypatch.setattr(bw, "bwrap_binary", lambda: "/usr/bin/bwrap")
    monkeypatch.setattr(bw.subprocess, "run", fake_run)
    try:
        assert bw.bwrap_usable() is False
        assert bw.bwrap_usable() is False
        assert len(calls) == 1
        assert calls[0][-2:] == ["--", "true"]
    finally:
        bw.reset_probe()


def test_probe_timeout_is_a_failure(monkeypatch):
    bw.reset_probe()

    def slow(argv, **kw):
        assert kw["timeout"] == bw.PROBE_TIMEOUT_S
        raise subprocess.TimeoutExpired(argv, kw["timeout"])

    monkeypatch.setattr(bw, "bwrap_binary", lambda: "/usr/bin/bwrap")
    monkeypatch.setattr(bw.subprocess, "run", slow)
    try:
        assert bw.bwrap_usable() is False
    finally:
        bw.reset_probe()


def test_enforced_map_for_bwrap():
    enforced = enforced_permissions("local-bwrap")
    assert enforced["network"] and enforced["workspace_mount"] and enforced["secrets_env"]
    assert not enforced["sudo"]
    assert not enforced_permissions("local")["network"]


def _real_bwrap() -> bool:
    bw.reset_probe()
    return bw.bwrap_usable()


@pytest.mark.skipif(not _real_bwrap(), reason="bwrap not usable here")
def test_real_bwrap_fences_the_file_system_and_network(tmp_path):
    ws = tmp_path / "ws"
    outside = tmp_path / "outside"
    outside.mkdir()
    policy = SandboxPolicy(network=False)
    env = LocalEnvironment(workdir=str(ws), isolation="bwrap", policy=policy)
    try:
        assert env.isolated and env.kind == "local-bwrap"
        assert env.run("echo hi > inside.txt && cat inside.txt").stdout.strip() == "hi"
        assert (ws / "inside.txt").read_text().strip() == "hi"
        blocked = env.run(f"echo x > {outside}/nope.txt")
        assert blocked.exit_code != 0 and not (outside / "nope.txt").exists()
        # /tmp is private but lasts across commands of this environment.
        env.run("echo keep > /tmp/agent-note")
        assert env.run("cat /tmp/agent-note").stdout.strip() == "keep"
        # No network namespace beyond loopback.
        links = env.run("cat /proc/net/dev").stdout
        assert "lo:" in links and links.count(":") <= 2
        # Session state survives across commands.
        env.run("export KEEP_ME=1")
        assert env.run('echo "$KEEP_ME"').stdout.strip() == "1"
    finally:
        env.cleanup()


# -- docker hardening (item 37) ------------------------------------------- #


class _FakeCli:
    binary = "docker"

    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def run(self, *args: str, timeout: int | None = None) -> CliResult:
        self.calls.append(args)
        return CliResult(stdout="cid-1\n", stderr="", exit_code=0)


def _run_argv(policy: SandboxPolicy, tmp_path) -> list[str]:
    cli = _FakeCli()
    env = DockerEnvironment(workdir=str(tmp_path / "ws"), cli=cli, user="1000:1000", policy=policy)
    env._create()
    return [list(c) for c in cli.calls if c and c[0] == "run"][0]


def _caps_added(argv: list[str]) -> set[str]:
    return {argv[i + 1] for i, a in enumerate(argv) if a == "--cap-add"}


def test_docker_box_drops_all_caps_and_limits_pids(tmp_path):
    argv = _run_argv(SandboxPolicy(), tmp_path)
    assert argv[argv.index("--cap-drop") + 1] == "ALL"
    assert argv[argv.index("--pids-limit") + 1] == str(PIDS_LIMIT) == "512"
    caps = _caps_added(argv)
    assert {"SETUID", "SETGID", "CHOWN"} <= caps
    assert "NET_RAW" not in caps and "SYS_ADMIN" not in caps
    # sudo on: no no-new-privileges (it would break sudo).
    assert "no-new-privileges" not in argv
    # The image comes after every flag.
    assert argv.index("--cap-drop") < argv.index("sleep")


def test_docker_box_without_sudo_keeps_fewer_caps(tmp_path):
    argv = _run_argv(SandboxPolicy(sudo=False), tmp_path)
    assert "no-new-privileges" in argv
    caps = _caps_added(argv)
    assert "KILL" not in caps and "NET_BIND_SERVICE" not in caps
    assert hardening_run_args(SandboxPolicy(sudo=False))[:2] == ("--cap-drop", "ALL")


def test_docker_exec_gets_plain_output_vars_and_secret_names_only(tmp_path, monkeypatch):
    captured: dict = {}

    class _Proc:
        returncode = 0

        def communicate(self, input=None, timeout=None):
            return ("", "")

        def poll(self):
            return 0

    def fake_popen(argv, **kw):
        captured["argv"] = argv
        captured["env"] = kw.get("env")
        return _Proc()

    import chuk_agents_sandbox.docker as docker_module

    env = DockerEnvironment(workdir=str(tmp_path / "ws"), cli=_FakeCli(), user="1000:1000")
    monkeypatch.setattr(env, "_ensure_container", lambda: "cid-1")
    monkeypatch.setattr(docker_module.subprocess, "Popen", fake_popen)
    env._run_bash("true", env={"MY_API_KEY": "v"})
    argv = captured["argv"]
    assert "NO_COLOR=1" in argv and "TERM=dumb" in argv
    assert "MY_API_KEY" in argv and "MY_API_KEY=v" not in " ".join(argv)


@pytest.mark.parametrize("module", ["chuk_agents_sandbox.child_env"])
def test_the_scrub_snippet_runs_on_bash_3_2(module):
    """macOS ships bash 3.2: no ``${var^^}``. The scrub must still drop names
    in any case, keep the rest, and leave ``nocasematch`` as it found it."""
    import importlib

    snippet = importlib.import_module(module).SCRUB_SNIPPET
    assert "^^" not in snippet and ",," not in snippet
    script = (
        f"{snippet}; "
        'echo "lower=${my_api_key-unset} mixed=${Github_Token-unset} '
        'keep=${KEEP_ME-unset}"; shopt -q nocasematch && echo nc=on || echo nc=off'
    )
    env = {
        "PATH": os.environ["PATH"],
        "my_api_key": "s1",
        "Github_Token": "s2",
        "KEEP_ME": "yes",
    }
    out = subprocess.run(
        ["bash", "--norc", "--noprofile", "-c", script],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    assert out.stderr == ""
    assert "lower=unset mixed=unset keep=yes" in out.stdout
    assert "nc=off" in out.stdout
