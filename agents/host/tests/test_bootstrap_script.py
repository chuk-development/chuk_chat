"""scripts/agents-bootstrap.sh — the script behind the app's install command.

Every run gets its own HOME, XDG_CONFIG_HOME and AGENTS_HOME, copies the source
from this checkout (``--source``, no download), and passes the flags that would
reach outside (``--no-runtime``, ``--no-env``, ``--no-service``). Nothing here
touches the real machine or the network.
"""

from __future__ import annotations

import os
import secrets
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
BOOTSTRAP = REPO_ROOT / "scripts" / "agents-bootstrap.sh"

SAFE_FLAGS = ["--no-runtime", "--no-env", "--no-service"]

pytestmark = pytest.mark.skipif(
    not BOOTSTRAP.exists(), reason="scripts/agents-bootstrap.sh missing from this checkout"
)


def run_bootstrap(home: Path, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["AGENTS_HOME"] = str(home / "state")
    for leaked in ("COWORK_HOME", "XDG_DATA_HOME", "AGENTS_SANDBOX_IMAGE", "AGENTS_SANDBOX_KIND"):
        env.pop(leaked, None)
    if stdin is not None:
        # The way the app's command runs it: the script arrives on stdin.
        command = ["bash", "-s", "--", *args]
    else:
        command = ["bash", str(BOOTSTRAP), *args]
    return subprocess.run(
        command,
        input=stdin,
        capture_output=True,
        text=True,
        timeout=180,
        env=env,
        cwd=str(home),
    )


@pytest.fixture()
def home(tmp_path) -> Path:
    path = tmp_path / "home"
    path.mkdir()
    return path


def test_install_only_copies_the_source_and_writes_the_launcher(home):
    result = run_bootstrap(home, "--source", str(REPO_ROOT), "--no-connect", *SAFE_FLAGS)
    assert result.returncode == 0, result.stderr
    src = home / "state" / "src"
    assert (src / "scripts" / "install.sh").is_file()
    assert (src / "agents" / "host" / "pyproject.toml").is_file()
    # Only what the installer needs, and no build litter.
    assert not (src / "lib").exists()
    assert not list(src.rglob("__pycache__"))
    launcher = home / ".local" / "bin" / "agents-host"
    assert launcher.is_file()
    assert str(src / "agents" / "host" / ".venv") in launcher.read_text()
    assert "Pairing is skipped" in result.stdout
    # The staging directory is gone.
    assert sorted(p.name for p in (home / "state").iterdir()) == ["src"]


def test_a_second_run_updates_in_place_and_keeps_the_venv(home):
    first = run_bootstrap(home, "--source", str(REPO_ROOT), "--no-connect", *SAFE_FLAGS)
    assert first.returncode == 0, first.stderr
    venv = home / "state" / "src" / "agents" / "host" / ".venv"
    venv.mkdir()
    (venv / "marker").write_text("kept", encoding="utf-8")
    second = run_bootstrap(home, "--source", str(REPO_ROOT), "--no-connect", *SAFE_FLAGS)
    assert second.returncode == 0, second.stderr
    assert (venv / "marker").read_text(encoding="utf-8") == "kept"
    assert "unchanged:" in second.stdout


def test_the_script_runs_from_stdin_like_curl_pipe_bash(home):
    result = run_bootstrap(
        home,
        "--source", str(REPO_ROOT), "--no-connect", *SAFE_FLAGS,
        stdin=BOOTSTRAP.read_text(encoding="utf-8"),
    )
    assert result.returncode == 0, result.stderr
    assert (home / "state" / "src" / "scripts" / "install.sh").is_file()


def test_a_truncated_download_runs_nothing(home):
    """All code is in functions and main is called on the last line."""
    text = BOOTSTRAP.read_text(encoding="utf-8")
    lines = text.rstrip("\n").split("\n")
    assert lines[-1] == 'main "$@"'
    cut = "\n".join(lines[: len(lines) // 2]) + "\n"
    result = run_bootstrap(home, "--source", str(REPO_ROOT), "--no-connect", stdin=cut)
    assert not (home / "state").exists()
    assert not (home / ".local").exists()
    assert result.stdout == ""


def test_a_missing_token_is_refused(home):
    result = run_bootstrap(home, "--source", str(REPO_ROOT), *SAFE_FLAGS)
    assert result.returncode != 0
    assert "no install token" in result.stderr
    assert not (home / "state").exists()


def test_a_bad_ref_is_refused(home):
    result = run_bootstrap(home, "--ref", "x;rm -rf ~", "--no-connect", *SAFE_FLAGS)
    assert result.returncode != 0
    assert "--ref" in result.stderr


def test_a_dry_run_hides_the_token_and_changes_nothing(home):
    token = f"{secrets.token_hex(32)}-{secrets.randbelow(10**8):08d}"
    result = run_bootstrap(
        home, "--source", str(REPO_ROOT), f"--token={token}", "--dry-run", *SAFE_FLAGS
    )
    assert result.returncode == 0, result.stderr
    out = result.stdout + result.stderr
    assert "AGENTS_INSTALL_TOKEN=<hidden>" in out
    assert out.rstrip().endswith("agents-host connect --no-service")
    assert token not in out
    assert token.split("-")[0] not in out
    assert not (home / "state").exists()
    assert not (home / ".local" / "bin" / "agents-host").exists()


def test_a_dry_run_without_source_downloads_nothing(home):
    result = run_bootstrap(home, "--no-connect", "--dry-run", *SAFE_FLAGS)
    assert result.returncode == 0, result.stderr
    assert "would download the host source (master)" in result.stdout
    assert not (home / "state").exists()


def test_a_dry_run_reads_an_existing_source_tree_and_leaves_it_alone(home):
    first = run_bootstrap(home, "--source", str(REPO_ROOT), "--no-connect", *SAFE_FLAGS)
    assert first.returncode == 0, first.stderr
    src = home / "state" / "src"
    marker = src / "local-marker"
    marker.write_text("mine", encoding="utf-8")
    before = sorted(p.name for p in src.iterdir())
    token = f"{secrets.token_hex(32)}-{secrets.randbelow(10**8):08d}"
    result = run_bootstrap(home, f"--token={token}", "--dry-run", *SAFE_FLAGS)
    assert result.returncode == 0, result.stderr
    assert "Downloading" not in result.stdout
    assert "would download" not in result.stdout
    assert "AGENTS_INSTALL_TOKEN=<hidden>" in result.stdout
    assert token not in result.stdout + result.stderr
    assert marker.read_text(encoding="utf-8") == "mine"
    assert sorted(p.name for p in src.iterdir()) == before


# ------------------------------------------- the token stays off argv


def _fake_tree(tmp_path: Path) -> tuple[Path, Path, Path]:
    """A source tree whose install.sh only records what it can see, and a
    launcher that records how connect was started."""
    src = tmp_path / "fake-src"
    (src / "agents" / "host").mkdir(parents=True)
    (src / "agents" / "host" / "pyproject.toml").write_text("[project]\nname='x'\n")
    (src / "scripts").mkdir()
    report = tmp_path / "report"
    report.mkdir()
    install = src / "scripts" / "install.sh"
    install.write_text(
        "#!/usr/bin/env bash\n"
        f'printf "%s" "${{AGENTS_INSTALL_TOKEN:-}}" > "{report}/install-env"\n'
        f'printf "%s" "$PPID" > "{report}/install-ppid"\n'
        f'tr "\\0" " " < "/proc/$PPID/cmdline" > "{report}/parent-cmdline"\n'
    )
    install.chmod(0o755)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    launcher = bindir / "agents-host"
    launcher.write_text(
        "#!/usr/bin/env bash\n"
        f'printf "%s" "$$" > "{report}/connect-pid"\n'
        f'printf "%s" "$*" > "{report}/connect-args"\n'
        f'printf "%s" "${{AGENTS_INSTALL_TOKEN:-}}" > "{report}/connect-env"\n'
        f'tr "\\0" " " < "/proc/$$/cmdline" > "{report}/connect-cmdline"\n'
    )
    launcher.chmod(0o755)
    return src, bindir, report


@pytest.mark.skipif(not Path("/proc/self/cmdline").exists(), reason="needs /proc")
def test_the_token_never_rides_a_command_line_and_connect_replaces_the_script(home, tmp_path):
    src, bindir, report = _fake_tree(tmp_path)
    token = f"{secrets.token_hex(32)}-{secrets.randbelow(10**8):08d}"
    env = dict(os.environ)
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), AGENTS_HOME=str(home / "state"))
    env.pop("AGENTS_INSTALL_TOKEN", None)
    proc = subprocess.Popen(
        ["bash", "-s", "--", f"--token={token}", "--source", str(src),
         "--bin-dir", str(bindir), *SAFE_FLAGS],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        cwd=str(home),
    )
    out, err = proc.communicate(BOOTSTRAP.read_text(encoding="utf-8"), timeout=120)
    assert proc.returncode == 0, err

    read = lambda name: (report / name).read_text()  # noqa: E731
    # The installer ran under the restarted script: same pid, no token on its
    # command line, and no token in the installer's environment.
    assert read("install-ppid") == str(proc.pid)
    assert token not in read("parent-cmdline")
    # The restarted script (``bash -c <functions> agents-bootstrap ...``).
    assert " agents-bootstrap --source " in read("parent-cmdline")
    assert read("install-env") == ""
    # connect IS the bootstrap process now (exec), with the token only in env.
    assert read("connect-pid") == str(proc.pid)
    assert read("connect-args") == "connect --no-service"
    assert token not in read("connect-cmdline")
    assert read("connect-env") == token
    assert token not in out + err


def test_the_token_can_come_from_the_environment(home, tmp_path):
    src, bindir, report = _fake_tree(tmp_path)
    token = f"{secrets.token_hex(32)}-{secrets.randbelow(10**8):08d}"
    env = dict(os.environ)
    env.update(
        HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
        AGENTS_HOME=str(home / "state"), AGENTS_INSTALL_TOKEN=token,
    )
    result = subprocess.run(
        ["bash", str(BOOTSTRAP), "--source", str(src), "--bin-dir", str(bindir), *SAFE_FLAGS],
        capture_output=True, text=True, timeout=120, env=env, cwd=str(home),
    )
    assert result.returncode == 0, result.stderr
    assert (report / "install-env").read_text() == ""
    assert (report / "connect-env").read_text() == token
