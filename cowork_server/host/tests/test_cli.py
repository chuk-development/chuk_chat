"""CLI tests: subcommand routing, ``connect``, and the systemd handover.

``connect`` is driven with a fake host and a fake systemd service, so the
decisions are asserted without binding a port (8787 belongs to the user) and
without touching a real unit. The pairing persistence it reads is the real
:class:`~cowork_host.pairing_store.HostPairingStore`.
"""

from __future__ import annotations

import argparse
import base64
import json

import pytest

from cowork_host import cli as cli_module
from cowork_host.cli import cmd_connect, cmd_status, is_paired, normalize_argv
from cowork_host.pairing_store import TRUST_VERSION
from cowork_host.service import CommandResult, SystemdUserService

# ------------------------------------------------------------------ argv


def test_no_arguments_means_run():
    assert normalize_argv([]) == ["run"]


def test_bare_flags_still_mean_run():
    """The pre-subcommand CLI must keep working: ``cowork-host --pair``."""
    assert normalize_argv(["--pair"]) == ["run", "--pair"]
    assert normalize_argv(["--port", "9000"]) == ["run", "--port", "9000"]


def test_subcommands_are_passed_through():
    assert normalize_argv(["connect"]) == ["connect"]
    assert normalize_argv(["connect", "--pair"]) == ["connect", "--pair"]
    assert normalize_argv(["status"]) == ["status"]
    assert normalize_argv(["run", "--port", "1"]) == ["run", "--port", "1"]


def test_help_is_not_rewritten():
    assert normalize_argv(["--help"]) == ["--help"]


def test_parser_accepts_connect_and_run_flags():
    parser = cli_module._build_parser()
    args = parser.parse_args(["connect", "--pair", "--timeout", "3"])
    assert args.command == "connect"
    assert args.pair is True
    assert args.timeout == 3
    run_args = parser.parse_args(normalize_argv(["--pair"]))
    assert run_args.command == "run"
    assert run_args.pair is True


def test_run_defaults_sandbox_from_the_environment(monkeypatch):
    monkeypatch.setenv("COWORK_SANDBOX_KIND", "docker")
    parser = cli_module._build_parser()
    assert parser.parse_args(["run"]).sandbox == "docker"


def test_run_defaults_workspace_from_cowork_home(monkeypatch):
    monkeypatch.setenv("COWORK_HOME", "/srv/cowork")
    parser = cli_module._build_parser()
    assert parser.parse_args(["run"]).workspace == "/srv/cowork"


# ------------------------------------------------------------- pair state


def write_trust(workspace, *, channel="chan1") -> None:
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "paired.json").write_text(
        json.dumps(
            {
                "version": TRUST_VERSION,
                "channel_id": channel,
                "channel_key_b64": base64.b64encode(b"k" * 32).decode(),
                "peer": {
                    "device_id": "cowork-app",
                    "ed25519_pub_b64": base64.b64encode(b"p" * 32).decode(),
                },
            }
        ),
        encoding="utf-8",
    )


def test_is_paired_reads_the_trust_file(tmp_path):
    assert is_paired(str(tmp_path)) is False
    write_trust(tmp_path)
    assert is_paired(str(tmp_path)) is True


def test_is_paired_treats_a_corrupt_file_as_unpaired(tmp_path):
    (tmp_path / "paired.json").write_text("{not json", encoding="utf-8")
    assert is_paired(str(tmp_path)) is False


# --------------------------------------------------------------- fakes


class FakeHost:
    """A LocalHost stand-in that pairs after ``pair_after`` polls."""

    def __init__(self, *, pair_after: int | None = 2):
        self.started = 0
        self.stopped = 0
        self.polls = 0
        self._pair_after = pair_after
        self.url = "ws://127.0.0.1:8787"
        self.device_id = "cowork-host"
        self.pairing_code = "chan1-123456"
        self.agent = argparse.Namespace(name="ada", workspace_dir="/tmp/ada")
        self.estop_path = "/tmp/ada/ESTOP"

    def start(self):
        self.started += 1

    def stop(self):
        self.stopped += 1

    @property
    def has_stored_pairing(self) -> bool:
        if self._pair_after is None:
            return False
        return self.polls >= self._pair_after


class FakeService(SystemdUserService):
    def __init__(self, *, available=True, active=True, enabled=True):
        super().__init__(runner=lambda argv: CommandResult("", "", 0))
        self._available = available
        self._active = active
        self._enabled = enabled
        self.actions: list[str] = []

    def available(self) -> bool:
        return self._available

    def is_active(self) -> bool:
        return self._active

    def is_enabled(self) -> bool:
        return self._enabled

    def stop(self) -> bool:
        self.actions.append("stop")
        self._active = False
        return True

    def start(self) -> bool:
        self.actions.append("start")
        self._active = True
        return True


def connect_args(workspace, **overrides) -> argparse.Namespace:
    base = dict(
        port=8787,
        workspace=str(workspace),
        model="m",
        sandbox="local",
        agent_name=None,
        supabase_url=None,
        anon_key=None,
        pair=False,
        mock_model=False,
        timeout=5.0,
        no_service=False,
    )
    base.update(overrides)
    return argparse.Namespace(**base)


def run_connect(args, host: FakeHost | None, service: FakeService) -> int:
    host = host if host is not None else FakeHost()

    def sleep(_seconds: float) -> None:
        host.polls += 1

    return cmd_connect(
        args,
        host_factory=lambda _a: host,
        service=service,
        sleep=sleep,
        monotonic=lambda: 0.0 if host.polls == 0 else float(host.polls) * 0.5,
    )


# ------------------------------------------------------------- connect


def test_connect_pairs_and_hands_the_host_back_to_the_service(tmp_path):
    host = FakeHost(pair_after=2)
    service = FakeService(active=True)
    code = run_connect(connect_args(tmp_path), host, service)
    assert code == 0
    assert host.started == 1
    # The port must be free again for the service that takes over.
    assert host.stopped == 1
    assert service.actions == ["stop", "start"]


def test_connect_on_an_already_paired_host_changes_nothing(tmp_path):
    """Idempotence: re-running connect must not disturb a working install."""
    write_trust(tmp_path)
    host = FakeHost()
    service = FakeService(active=True)
    code = run_connect(connect_args(tmp_path), host, service)
    assert code == 0
    assert host.started == 0
    assert service.actions == []


def test_connect_pair_flag_re_pairs_even_when_a_trust_exists(tmp_path):
    write_trust(tmp_path)
    host = FakeHost(pair_after=1)
    service = FakeService(active=True)
    code = run_connect(connect_args(tmp_path, pair=True), host, service)
    assert code == 0
    assert host.started == 1
    assert service.actions == ["stop", "start"]


def test_connect_reports_failure_when_nobody_pairs(tmp_path):
    host = FakeHost(pair_after=None)
    service = FakeService(active=True)
    code = run_connect(connect_args(tmp_path, timeout=1.0), host, service)
    assert code == 1
    assert host.stopped == 1
    # The service is put back even when pairing failed.
    assert service.actions == ["stop", "start"]


def test_connect_leaves_a_stopped_but_enabled_service_started(tmp_path):
    host = FakeHost(pair_after=1)
    service = FakeService(active=False, enabled=True)
    assert run_connect(connect_args(tmp_path), host, service) == 0
    assert service.actions == ["start"]


def test_connect_does_not_start_a_disabled_service(tmp_path):
    host = FakeHost(pair_after=1)
    service = FakeService(active=False, enabled=False)
    assert run_connect(connect_args(tmp_path), host, service) == 0
    assert service.actions == []


def test_connect_no_service_flag_never_touches_systemd(tmp_path):
    host = FakeHost(pair_after=1)
    service = FakeService(active=True)
    assert run_connect(connect_args(tmp_path, no_service=True), host, service) == 0
    assert service.actions == []


def test_connect_works_where_no_service_is_installed(tmp_path):
    host = FakeHost(pair_after=1)
    service = FakeService(available=False)
    assert run_connect(connect_args(tmp_path), host, service) == 0
    assert service.actions == []


def test_connect_stops_the_host_even_if_pairing_raises(tmp_path):
    class Exploding(FakeHost):
        def start(self):
            raise KeyboardInterrupt

    host = Exploding(pair_after=None)
    service = FakeService(active=True)
    assert run_connect(connect_args(tmp_path), host, service) == 1
    assert host.stopped == 1


# --------------------------------------------------------------- status


def test_status_reports_pairing_and_service_state(tmp_path):
    lines: list[str] = []
    write_trust(tmp_path)
    code = cmd_status(
        argparse.Namespace(workspace=str(tmp_path)),
        service=FakeService(active=True),
        out=lambda *a: lines.append(" ".join(str(x) for x in a)),
    )
    assert code == 0
    body = "\n".join(lines)
    assert "Paired:" in body and "yes" in body
    assert "running" in body


def test_status_of_an_unpaired_host_points_at_connect(tmp_path):
    lines: list[str] = []
    cmd_status(
        argparse.Namespace(workspace=str(tmp_path)),
        service=FakeService(available=False),
        out=lambda *a: lines.append(" ".join(str(x) for x in a)),
    )
    body = "\n".join(lines)
    assert "Paired:" in body and "no" in body
    assert "cowork-host connect" in body


# -------------------------------------------------------------- service


def test_service_state_words():
    def runner(argv):
        # is-active fails, is-enabled succeeds
        if "is-active" in argv:
            return CommandResult("", "", 3)
        return CommandResult("", "", 0)

    service = SystemdUserService(runner=runner)
    service.available = lambda: True  # type: ignore[method-assign]
    assert service.state() == "enabled, stopped"


def test_service_state_is_not_installed_when_unavailable():
    service = SystemdUserService(runner=lambda argv: CommandResult("", "", 0))
    service.available = lambda: False  # type: ignore[method-assign]
    assert service.state() == "not installed"


def test_service_commands_use_the_user_instance():
    seen: list[list[str]] = []

    def runner(argv):
        seen.append(argv)
        return CommandResult("", "", 0)

    SystemdUserService(runner=runner).restart()
    assert seen == [["systemctl", "--user", "restart", "cowork-manager.service"]]


@pytest.mark.parametrize("method", ["start", "stop", "restart"])
def test_service_reports_failure(method):
    service = SystemdUserService(runner=lambda argv: CommandResult("", "nope", 1))
    assert getattr(service, method)() is False
