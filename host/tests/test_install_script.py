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

REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALL_SH = REPO_ROOT / "scripts" / "install.sh"
UNIT_TEMPLATE = REPO_ROOT / "scripts" / "cowork-manager.service"

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
    for leaked in ("COWORK_HOME", "COWORK_SANDBOX_IMAGE", "COWORK_SANDBOX_KIND", "COWORK_RUNTIME"):
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
    return home / ".config" / "systemd" / "user" / "cowork-manager.service"


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
    assert "cowork-host connect" in proc.stdout


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
    root = home / ".cowork"
    assert (root / "agents").is_dir()
    assert (root / "logs").is_dir()
    launcher = root / "bin" / "cowork-host"
    assert launcher.is_file()
    assert os.access(launcher, os.X_OK)
    # The state directory holds the channel key: owner-only.
    assert (root.stat().st_mode & 0o777) == 0o700
    assert unit_path(home).is_file()


def test_launcher_points_at_the_checkouts_venv(home):
    run_install(home, *SAFE_FLAGS)
    body = (home / ".cowork" / "bin" / "cowork-host").read_text(encoding="utf-8")
    assert str(REPO_ROOT / "host" / ".venv" / "bin" / "cowork-host") in body


def test_unit_file_is_fully_substituted(home):
    run_install(home, *SAFE_FLAGS)
    unit = unit_path(home).read_text(encoding="utf-8")
    assert "@" not in unit.split("[Service]")[1], "a placeholder was left unsubstituted"
    assert f"ExecStart={home}/.cowork/bin/cowork-host run" in unit
    assert "--sandbox docker" in unit
    assert "COWORK_SANDBOX_IMAGE=cowork-base:latest" in unit
    assert "WantedBy=default.target" in unit


def test_unit_file_honours_the_sandbox_and_tag_flags(home):
    run_install(home, "--sandbox", "local", "--tag", "custom:9", *SAFE_FLAGS)
    unit = unit_path(home).read_text(encoding="utf-8")
    assert "--sandbox local" in unit
    assert "COWORK_SANDBOX_IMAGE=custom:9" in unit


def test_prefix_moves_the_install_root(home):
    prefix = home / "elsewhere" / "cowork"
    proc = run_install(home, "--prefix", str(prefix), *SAFE_FLAGS)
    assert proc.returncode == 0, proc.stderr
    assert (prefix / "agents").is_dir()
    assert f"ExecStart={prefix}/bin/cowork-host run" in unit_path(home).read_text(
        encoding="utf-8"
    )


# -------------------------------------------------------------- idempotence


def test_running_twice_changes_nothing(home):
    first = run_install(home, *SAFE_FLAGS)
    assert first.returncode == 0, first.stderr

    unit_before = unit_path(home).read_bytes()
    launcher = home / ".cowork" / "bin" / "cowork-host"
    launcher_before = launcher.read_bytes()
    tree_before = sorted(p.relative_to(home) for p in home.rglob("*"))

    second = run_install(home, *SAFE_FLAGS)
    assert second.returncode == 0, second.stderr

    assert unit_path(home).read_bytes() == unit_before
    assert launcher.read_bytes() == launcher_before
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
    assert not (home / ".cowork").exists()
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
    assert not (home / ".cowork").exists()
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
