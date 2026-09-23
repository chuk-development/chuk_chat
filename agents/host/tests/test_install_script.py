"""scripts/install.sh — test-driven twice, in a throwaway HOME.

The one property that matters for an installer is **idempotence**: running it a
second time must change nothing and break nothing. That is asserted literally
here (byte-compare the unit file and the launcher across two runs).

Nothing in this module may touch the real system: every run gets its own HOME
and XDG_CONFIG_HOME, and the flags that would reach outside
(``--no-runtime`` = no container runtime, ``--no-env`` = no uv sync,
``--no-service`` = no systemctl) are always passed.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
INSTALL_SH = REPO_ROOT / "scripts" / "install.sh"
UNIT_TEMPLATE = REPO_ROOT / "scripts" / "agents-manager.service"

#: Everything that could reach the real machine, switched off.
SAFE_FLAGS = ["--no-runtime", "--no-env", "--no-service"]


pytestmark = pytest.mark.skipif(
    not INSTALL_SH.exists(), reason="scripts/install.sh missing from this checkout"
)


def run_install(home: Path, *args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    # Never inherit the developer's own settings into the test install.
    for leaked in (
        "AGENTS_HOME",
        "COWORK_HOME",
        "XDG_DATA_HOME",
        "AGENTS_SANDBOX_IMAGE",
        "AGENTS_SANDBOX_KIND",
        "AGENTS_RUNTIME",
    ):
        env.pop(leaked, None)
    return subprocess.run(
        ["bash", str(INSTALL_SH), *args],
        capture_output=True,
        text=True,
        timeout=180,
        env=env,
        cwd=str(home),
    )


@pytest.fixture()
def home(tmp_path) -> Path:
    h = tmp_path / "home"
    (h / ".config").mkdir(parents=True)
    return h


def unit_path(home: Path) -> Path:
    return home / ".config" / "systemd" / "user" / "agents-manager.service"


def state_dir(home: Path) -> Path:
    return home / ".local" / "share" / "chuk-agents"


def launcher(home: Path, name: str = "agents-host") -> Path:
    return home / ".local" / "bin" / name


# ------------------------------------------------------------------- shape


def test_script_is_syntactically_valid():
    proc = subprocess.run(
        ["bash", "-n", str(INSTALL_SH)], capture_output=True, text=True, timeout=60
    )
    assert proc.returncode == 0, proc.stderr


def test_help_exits_cleanly_and_documents_connect():
    proc = subprocess.run(
        ["bash", str(INSTALL_SH), "--help"], capture_output=True, text=True, timeout=60
    )
    assert proc.returncode == 0
    assert "agents-host connect" in proc.stdout
    assert "enable-linger" in proc.stdout


def test_unknown_option_is_rejected(home):
    proc = run_install(home, "--nope")
    assert proc.returncode == 2
    assert "unknown option" in proc.stderr


def test_invalid_sandbox_kind_is_rejected(home):
    proc = run_install(home, "--sandbox", "vm", *SAFE_FLAGS)
    assert proc.returncode == 2


# ------------------------------------------------------------------ install


def test_install_creates_the_expected_layout(home):
    proc = run_install(home, *SAFE_FLAGS)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    root = state_dir(home)
    assert root.is_dir()
    for name in ("agents-host", "cowork-host"):
        assert launcher(home, name).is_file()
        assert os.access(launcher(home, name), os.X_OK)
    # The state directory holds the channel key: owner-only.
    assert (root.stat().st_mode & 0o777) == 0o700
    assert unit_path(home).is_file()


def test_install_never_writes_into_dot_agents(home):
    """~/.agents belongs to other tools (the skills CLI); the bug was sharing it."""
    (home / ".agents" / "skills").mkdir(parents=True)
    proc = run_install(home, *SAFE_FLAGS)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert sorted(p.name for p in (home / ".agents").iterdir()) == ["skills"]


def test_launcher_points_at_the_checkouts_venv(home):
    run_install(home, *SAFE_FLAGS)
    body = launcher(home).read_text(encoding="utf-8")
    assert str(REPO_ROOT / "agents" / "host" / ".venv" / "bin" / "agents-host") in body
    alias = launcher(home, "cowork-host").read_text(encoding="utf-8")
    assert str(launcher(home)) in alias


def test_unit_file_is_fully_substituted(home):
    run_install(home, *SAFE_FLAGS)
    unit = unit_path(home).read_text(encoding="utf-8")
    assert "@" not in unit.split("[Service]")[1], "a placeholder was left unsubstituted"
    assert f"ExecStart={launcher(home)} run " in unit
    assert "--sandbox docker" in unit
    assert "AGENTS_SANDBOX_IMAGE=agents-base:latest" in unit


def test_unit_survives_a_reboot_and_any_exit(home):
    run_install(home, *SAFE_FLAGS)
    unit = unit_path(home).read_text(encoding="utf-8")
    assert "WantedBy=default.target" in unit
    assert "Restart=always" in unit
    assert "Restart=on-failure" not in unit
    assert "StartLimitIntervalSec=0" in unit


def test_unit_carries_no_secret_and_no_default_state_path(home):
    """The Supabase settings come from the provisioned account token.

    The default state directory is left to the host, so the host (not the
    unit) decides it and migrates a legacy ~/.cowork into it.
    """
    run_install(home, *SAFE_FLAGS)
    unit = unit_path(home).read_text(encoding="utf-8")
    service = unit.split("[Service]")[1]
    assert "SUPABASE" not in service
    assert "ANON_KEY" not in service
    assert "--workspace" not in service
    assert "AGENTS_HOME" not in service
    assert ".agents" not in service
    assert "EnvironmentFile=-%h/.config/chuk-agents/host.env" in service


def test_unit_file_honours_the_sandbox_and_tag_flags(home):
    run_install(home, "--sandbox", "local", "--tag", "custom:9", *SAFE_FLAGS)
    unit = unit_path(home).read_text(encoding="utf-8")
    assert "--sandbox local" in unit
    assert "AGENTS_SANDBOX_IMAGE=custom:9" in unit


def test_prefix_moves_the_state_directory(home):
    prefix = home / "elsewhere" / "agents"
    proc = run_install(home, "--prefix", str(prefix), *SAFE_FLAGS)
    assert proc.returncode == 0, proc.stderr
    assert prefix.is_dir()
    assert not state_dir(home).exists()
    assert f"run --no-qr --workspace {prefix} --sandbox" in unit_path(home).read_text(
        encoding="utf-8"
    )


def test_bin_dir_moves_the_launchers(home):
    bin_dir = home / "tools"
    proc = run_install(home, "--bin-dir", str(bin_dir), *SAFE_FLAGS)
    assert proc.returncode == 0, proc.stderr
    assert (bin_dir / "agents-host").is_file()
    assert (bin_dir / "cowork-host").is_file()
    assert f"ExecStart={bin_dir}/agents-host run" in unit_path(home).read_text(encoding="utf-8")


# -------------------------------------------------------------- idempotence


def test_running_twice_changes_nothing(home):
    first = run_install(home, *SAFE_FLAGS)
    assert first.returncode == 0, first.stderr

    unit_before = unit_path(home).read_bytes()
    launcher_before = launcher(home).read_bytes()
    tree_before = sorted(p.relative_to(home) for p in home.rglob("*"))

    second = run_install(home, *SAFE_FLAGS)
    assert second.returncode == 0, second.stderr

    assert unit_path(home).read_bytes() == unit_before
    assert launcher(home).read_bytes() == launcher_before
    assert sorted(p.relative_to(home) for p in home.rglob("*")) == tree_before
    # ...and it says so instead of silently rewriting.
    assert "unchanged" in second.stdout
    assert "exists:" in second.stdout


def test_second_run_after_a_config_change_updates_the_unit(home):
    run_install(home, *SAFE_FLAGS)
    run_install(home, "--sandbox", "local", *SAFE_FLAGS)
    assert "--sandbox local" in unit_path(home).read_text(encoding="utf-8")


# ------------------------------------------------------------------ dry run


def test_dry_run_creates_nothing(home):
    proc = run_install(home, "--dry-run", *SAFE_FLAGS)
    assert proc.returncode == 0, proc.stderr
    assert not state_dir(home).exists()
    assert not launcher(home).exists()
    assert not unit_path(home).exists()
    assert "would run:" in proc.stdout or "would write:" in proc.stdout


def test_dry_run_after_a_real_install_still_changes_nothing(home):
    run_install(home, *SAFE_FLAGS)
    before = sorted((p.relative_to(home), p.stat().st_mtime) for p in home.rglob("*"))
    proc = run_install(home, "--dry-run", *SAFE_FLAGS)
    assert proc.returncode == 0
    after = sorted((p.relative_to(home), p.stat().st_mtime) for p in home.rglob("*"))
    assert before == after


# -------------------------------------------------------------- preflight


def test_a_missing_runtime_aborts_before_anything_is_created(home):
    """The half-install case the plan warns about: fail early, touch nothing."""
    proc = run_install(home, "--runtime", "definitely-not-a-real-binary", "--no-env", "--no-service")
    assert proc.returncode == 1
    assert "no container runtime found" in proc.stderr
    assert "stopped BEFORE changing anything" in proc.stderr
    assert not state_dir(home).exists()
    assert not unit_path(home).exists()


def test_all_problems_are_reported_at_once(home):
    proc = run_install(
        home, "--runtime", "definitely-not-a-real-binary", "--no-service"
    )
    assert proc.returncode == 1
    # Both the runtime and (when uv is absent) the env problem are listed; the
    # count line proves the script gathers them instead of dying on the first.
    assert "problem(s):" in proc.stderr


def test_no_env_flag_skips_the_python_environment(home):
    proc = run_install(home, *SAFE_FLAGS)
    assert "skipped (--no-env)" in proc.stdout
    assert "uv sync" not in proc.stdout


def test_no_service_flag_writes_the_unit_but_does_not_call_systemctl(home):
    proc = run_install(home, *SAFE_FLAGS)
    assert unit_path(home).is_file()
    assert "systemd not touched" in proc.stdout
    assert "daemon-reload" not in proc.stdout


def test_template_carries_no_leftover_placeholders():
    """Every @PLACEHOLDER@ in the template must be one install.sh substitutes."""
    script = INSTALL_SH.read_text(encoding="utf-8")
    # Comments are prose and may name placeholders in passing; only the directives
    # matter, and there a token looks like ``ExecStart=@EXEC@ run``.
    directives = [
        line
        for line in UNIT_TEMPLATE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    placeholders = set(re.findall(r"@[A-Z_]+@", "\n".join(directives)))
    assert placeholders, "the template lost its placeholders"
    for placeholder in placeholders:
        assert placeholder in script, f"{placeholder} is never substituted"


def _user_systemd_reachable() -> bool:
    try:
        proc = subprocess.run(
            ["systemctl", "--user", "show-environment"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


@pytest.mark.skipif(not _user_systemd_reachable(), reason="no systemd user instance here")
def test_dry_run_plans_to_enable_and_start_the_service(home):
    """The service path, planned only: ``--dry-run`` calls no mutating systemctl."""
    proc = run_install(home, "--dry-run", "--no-runtime", "--no-env", "--enable-linger")
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert "would run: systemctl --user daemon-reload" in proc.stdout
    assert "would run: systemctl --user enable agents-manager.service" in proc.stdout
    assert "would run: systemctl --user start agents-manager.service" in proc.stdout
    # Either linger is on already, or the plan turns it on.
    assert "linger: on" in proc.stdout or "would run: loginctl enable-linger" in proc.stdout
    assert not unit_path(home).exists()
    assert not state_dir(home).exists()
