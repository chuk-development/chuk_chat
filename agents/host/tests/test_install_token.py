"""The install token: ``agents-host connect --token <P>-<D>``.

The Chuk app mints the token and shows one install command. These tests hold
the host to the contract the app implements:

- the format is strict (64 lower-case hex, a dash, 8 digits);
- a token replaces a stored pairing, the same as ``--pair``;
- ``P`` is the relay pairing channel AND the §15 channel id, so the pairing
  code is the token itself;
- when the relay drops the unclaimed channel, the host parks on the SAME
  channel again, with the same code;
- the default wait is 30 minutes;
- the token, ``P`` and ``D`` never show in the output or in a log line.
"""

from __future__ import annotations

import secrets
import uuid

import pytest

from chuk_agents_host import LocalHost
from chuk_agents_host import cli as cli_module
from chuk_agents_host.account_store import AccountStore
from chuk_agents_host.cli import (
    DEFAULT_CONNECT_TIMEOUT,
    DEFAULT_TOKEN_CONNECT_TIMEOUT,
    EXIT_USAGE,
    cmd_connect,
)
from chuk_agents_host.cloud_relay import TYPE_PAIR_EXPIRED, CloudRelayTransport
from chuk_agents_host.install_token import (
    InstallToken,
    InvalidInstallToken,
    parse_install_token,
)
from chuk_agents_host.pairing_store import HostPairingStore

from test_cli import FakeHost, FakeService, connect_args, run_connect, write_trust
from test_cloud_host import ACCOUNT_TOKEN
from test_cloud_relay import FakeWebSocket, _connector
from test_local_run import ControllerDouble, _scripted_model


def make_token() -> tuple[str, str, str]:
    """A fresh token the way the app mints one: ``(token, P, D)``."""
    channel = secrets.token_hex(32)
    digits = f"{secrets.randbelow(10**8):08d}"
    return f"{channel}-{digits}", channel, digits


def assert_no_secret(text: str, *secrets_: str) -> None:
    for secret in secrets_:
        assert secret not in text, "a token part leaked into the output"


# ------------------------------------------------------------------ parsing


def test_a_valid_token_parses_into_channel_and_digits():
    token, channel, digits = make_token()
    parsed = parse_install_token(token)
    assert parsed.channel == channel
    assert parsed.digits == digits
    assert parsed.pairing_code == token


def test_surrounding_white_space_is_ignored():
    token, _, _ = make_token()
    assert parse_install_token(f"  {token}\n").pairing_code == token


@pytest.mark.parametrize(
    "bad",
    [
        "",
        "   ",
        "a" * 64,  # no digits
        "a" * 64 + "-",  # empty digits
        "a" * 63 + "-12345678",  # channel too short
        "a" * 65 + "-12345678",  # channel too long
        "A" * 64 + "-12345678",  # upper case is not what the app makes
        "g" * 64 + "-12345678",  # not hex
        "a" * 64 + "-1234567",  # 7 digits
        "a" * 64 + "-123456789",  # 9 digits
        "a" * 64 + "-1234567a",  # not decimal
        "a" * 64 + "--12345678",
        "a" * 32 + "-" + "a" * 31 + "-12345678",  # a dash inside the channel
        "a" * 64 + "-12345678 extra",
        "a" * 64 + "-١٢٣٤٥٦٧٨",  # non-ASCII digits
    ],
)
def test_a_malformed_token_is_refused_without_echoing_it(bad):
    with pytest.raises(InvalidInstallToken) as caught:
        parse_install_token(bad)
    if bad.strip():
        assert bad.strip() not in str(caught.value)


def test_a_missing_token_is_refused():
    with pytest.raises(InvalidInstallToken):
        parse_install_token(None)


def test_repr_hides_the_secret_parts():
    token, channel, digits = make_token()
    parsed = parse_install_token(token)
    assert_no_secret(repr(parsed), channel, digits)
    assert_no_secret(str(parsed), channel, digits)


# ------------------------------------------------------------------ argv


def test_the_parser_takes_both_token_spellings():
    token, _, _ = make_token()
    parser = cli_module._build_parser()
    assert parser.parse_args(["connect", f"--token={token}"]).token == token
    assert parser.parse_args(["connect", "--token", token]).token == token


def test_timeout_is_unset_until_connect_picks_the_default():
    parser = cli_module._build_parser()
    assert parser.parse_args(["connect"]).timeout is None
    assert parser.parse_args(["connect", "--timeout", "7"]).timeout == 7


# ------------------------------------------------------------------ connect


def test_connect_with_a_bad_token_exits_2_and_does_not_echo_it(tmp_path, capsys):
    bad = secrets.token_hex(32) + "-1234"
    host = FakeHost()
    service = FakeService(active=True)
    code = run_connect(connect_args(tmp_path, token=bad), host, service)
    assert code == EXIT_USAGE
    assert host.started == 0
    # Nothing was stopped: the check runs before the service handover.
    assert service.actions == []
    out = capsys.readouterr()
    assert "wrong format" in out.err
    assert_no_secret(out.out + out.err, bad, bad.split("-")[0])


def test_connect_token_with_local_relay_is_a_usage_error(tmp_path, capsys):
    token, channel, digits = make_token()
    host = FakeHost()
    code = run_connect(
        connect_args(tmp_path, token=token, local_relay=True), host, FakeService()
    )
    assert code == EXIT_USAGE
    assert host.started == 0
    out = capsys.readouterr()
    assert_no_secret(out.out + out.err, channel, digits)


def test_connect_token_waits_30_minutes_by_default(tmp_path):
    token, _, _ = make_token()
    args = connect_args(tmp_path, token=token, timeout=None)
    run_connect(args, FakeHost(pair_after=1), FakeService())
    assert args.timeout == DEFAULT_TOKEN_CONNECT_TIMEOUT == 1800.0


def test_connect_without_token_keeps_the_old_default(tmp_path):
    args = connect_args(tmp_path, timeout=None)
    run_connect(args, FakeHost(pair_after=1), FakeService())
    assert args.timeout == DEFAULT_CONNECT_TIMEOUT


def test_an_explicit_timeout_wins_over_the_token_default(tmp_path):
    token, _, _ = make_token()
    args = connect_args(tmp_path, token=token, timeout=12.0)
    run_connect(args, FakeHost(pair_after=1), FakeService())
    assert args.timeout == 12.0


def test_connect_token_re_pairs_an_already_paired_host(tmp_path, capsys):
    """A fresh install command is a clear intent: the old pairing goes."""
    write_trust(tmp_path)
    token, channel, digits = make_token()
    host = FakeHost(pair_after=1)
    service = FakeService(active=True)
    seen: list = []

    def factory(args):
        seen.append(args)
        return host

    code = cmd_connect(
        connect_args(tmp_path, token=token, timeout=None),
        host_factory=factory,
        service=service,
        sleep=lambda _s: setattr(host, "polls", host.polls + 1),
        monotonic=lambda: float(host.polls),
    )
    assert code == 0
    assert host.started == 1
    assert service.actions == ["stop", "start"]
    # The host is built with the parsed token, which implies the re-pair.
    assert isinstance(seen[0].install_token, InstallToken)
    assert seen[0].install_token.pairing_code == token
    out = capsys.readouterr().out
    assert "Waiting for the Chuk app to confirm this computer" in out
    assert "Paired with your Chuk account." in out
    # No code, no QR, no link.
    assert "cowork://" not in out
    assert "enter code" not in out
    assert "Scan this" not in out
    assert_no_secret(out, channel, digits)


def test_connect_token_timeout_says_the_command_expired(tmp_path, capsys):
    token, channel, digits = make_token()
    host = FakeHost(pair_after=None)
    service = FakeService(active=True)
    code = run_connect(connect_args(tmp_path, token=token, timeout=1.0), host, service)
    assert code == 1
    assert host.stopped == 1
    assert service.actions == ["stop", "start"]
    out = capsys.readouterr().out
    assert "The install command expired. Create a new one in the Chuk app." in out
    assert_no_secret(out, channel, digits)


def test_build_host_passes_the_token_on(tmp_path, monkeypatch):
    token, _, _ = make_token()
    captured: dict = {}

    class Recorder:
        def __init__(self, **kwargs):
            captured.update(kwargs)

        def set_pairing_reset_listener(self, _listener):
            pass

    monkeypatch.setattr(cli_module, "LocalHost", Recorder)
    args = connect_args(tmp_path, token=token)
    args.install_token = parse_install_token(token)
    cli_module._build_host(args)
    assert captured["install_token"] is args.install_token
    assert captured["transport"] == "cloud"


# ------------------------------------------------------------------ the host


def _token_host(tmp_path, token: str, logs: list[str]) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="token-worker",
        transport="cloud",
        install_token=parse_install_token(token),
        model_factory_override=_scripted_model,
        logger=logs.append,
    )


def test_the_token_is_the_channel_the_channel_id_and_the_code(tmp_path):
    token, channel, _ = make_token()
    logs: list[str] = []
    host = _token_host(tmp_path, token, logs)
    try:
        assert host.uses_install_token
        assert host.pairing_code == token
        assert host.pairing_channel == channel
        assert host.channel_id == channel
        transport, _, _ = host._build_transport()
        assert transport.credential() == ("pairing_channel", channel)
    finally:
        host.stop()


def test_a_token_drops_the_stored_pairing_and_the_account_token(tmp_path):
    first, _, _ = make_token()
    logs: list[str] = []
    old = _token_host(tmp_path, first, logs)
    try:
        old._persist_account_token(ACCOUNT_TOKEN)
    finally:
        old.stop()
    write_trust(tmp_path)
    assert HostPairingStore(tmp_path / "paired.json").load() is not None

    token, channel, _ = make_token()
    host = _token_host(tmp_path, token, logs)
    try:
        assert not host.has_stored_pairing
        assert HostPairingStore(tmp_path / "paired.json").load() is None
        assert AccountStore(tmp_path / "account.json").token() is None
        transport, _, _ = host._build_transport()
        assert transport.credential() == ("pairing_channel", channel)
    finally:
        host.stop()


def test_an_expired_channel_is_parked_on_again_not_replaced(tmp_path):
    token, channel, digits = make_token()
    logs: list[str] = []
    resets: list[bool] = []
    host = _token_host(tmp_path, token, logs)
    host.set_pairing_reset_listener(lambda: resets.append(True))
    try:
        for _ in range(3):
            host._on_pairing_channel_expired()
            assert host.pairing_code == token
            assert host.pairing_channel == channel
        # Nothing new to print: the app still holds the same token.
        assert resets == []
        transport, _, _ = host._build_transport()
        assert transport.credential() == ("pairing_channel", channel)
        assert_no_secret("\n".join(logs), channel, digits)
    finally:
        host.stop()


def test_a_used_token_is_not_brought_back_by_a_late_expiry(tmp_path):
    token, _, _ = make_token()
    host = _token_host(tmp_path, token, [])
    try:
        host._burn_pairing_code()
        host._on_pairing_channel_expired()
        assert host.pairing_code is None
        assert host.pairing_channel is None
    finally:
        host.stop()


def test_without_a_token_an_expiry_still_mints_a_fresh_channel(tmp_path):
    """The old path must not change."""
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="plain-worker",
        transport="cloud",
        model_factory_override=_scripted_model,
    )
    try:
        assert not host.uses_install_token
        first = host.pairing_channel
        host._on_pairing_channel_expired()
        assert host.pairing_channel != first
    finally:
        host.stop()


def test_the_parked_link_logs_no_token_part_and_warns_nothing(tmp_path):
    """The relay link with a fixed channel: dial, park, expire. The log must
    hold no token part, and no "scan it now" warning is armed."""
    token, channel, digits = make_token()
    logs: list[str] = []
    host = _token_host(tmp_path, token, logs)
    try:
        ws = FakeWebSocket([{"type": "auth_ok", "mode": "pairing", "expires_in": 300}])
        transport = CloudRelayTransport(
            device_id=str(uuid.uuid4()),
            channel_id=host.channel_id,
            pairing_channel_provider=lambda: host.pairing_channel,
            on_pairing_expired=host._on_pairing_channel_expired,
            fixed_pairing_channel=True,
            logger=logs.append,
            connect=_connector(ws),
        )
        link = transport.open()
        assert link._warning is None
        assert ws.sent[0]["pairing_channel"] == channel
        link.handle_frame({"type": TYPE_PAIR_EXPIRED})
        assert host.pairing_channel == channel
        assert any("parking on it again" in line for line in logs)
        assert not any("fresh" in line for line in logs)
        assert_no_secret("\n".join(logs), channel, digits)
    finally:
        host.stop()


def test_a_real_pairing_with_the_token_code_stores_the_token_channel(tmp_path):
    """The §15 ceremony end to end with an 8-digit code on a 64-hex channel,
    over the loopback relay (the pipe does not change the ceremony). The app
    side joins with the token string as its pairing code."""
    token, channel, _ = make_token()
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="token-worker",
        install_token=parse_install_token(token),
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        controller = ControllerDouble(host.url, host.channel_id, token, replay_key="t-1")
        controller.run("unused: this double asks for a replay, not a run")
        assert host.has_stored_pairing, "the pairing never completed"
        assert host.pairing_code is None
        assert host.pairing_channel is None
    finally:
        host.stop()
    trust = HostPairingStore(tmp_path / "paired.json").load()
    assert trust is not None
    assert trust.channel_id == channel


# ------------------------------------------------- the old pairing survives


ACCOUNT_JSON = b'{"version": 1, "device_id": "old-device", "token": {"access_token": "old"}}'


def _paired_workspace(tmp_path):
    write_trust(tmp_path, channel="oldchannel")
    (tmp_path / "account.json").write_bytes(ACCOUNT_JSON)
    (tmp_path / "account.json").chmod(0o600)
    return (tmp_path / "paired.json").read_bytes()


def _backups(tmp_path) -> list[str]:
    return sorted(p.name for p in tmp_path.glob("*.before-token"))


class ClearingHost(FakeHost):
    """Does what LocalHost does for a token: clears the stored trust at once,
    so the old pairing is never offered while the new ceremony runs."""

    def __init__(self, workspace, *, pair_after=None, new_trust=False, on_start=None):
        super().__init__(pair_after=pair_after)
        self.workspace = workspace
        self.new_trust = new_trust
        self.on_start = on_start
        (workspace / "paired.json").unlink(missing_ok=True)
        (workspace / "account.json").write_text('{"device_id": "old-device"}')
        self.backups_at_build = _backups(workspace)

    def start(self):
        super().start()
        if self.on_start is not None:
            self.on_start()

    @property
    def has_stored_pairing(self) -> bool:
        done = FakeHost.has_stored_pairing.fget(self)
        if done and self.new_trust and not (self.workspace / "paired.json").exists():
            write_trust(self.workspace, channel="newchannel")
        return done


def test_a_token_that_never_pairs_gives_the_old_pairing_back(tmp_path):
    old = _paired_workspace(tmp_path)
    built: list[ClearingHost] = []

    def factory(_args):
        built.append(ClearingHost(tmp_path))
        return built[0]

    token, _, _ = make_token()
    service = FakeService(active=True)
    code = cmd_connect(
        connect_args(tmp_path, token=token, timeout=1.0),
        host_factory=factory,
        service=service,
        sleep=lambda _s: setattr(built[0], "polls", built[0].polls + 1),
        monotonic=lambda: float(built[0].polls) * 0.5 if built else 0.0,
    )
    assert code == 1
    assert built[0].backups_at_build == ["account.json.before-token", "paired.json.before-token"]
    assert (tmp_path / "paired.json").read_bytes() == old
    assert (tmp_path / "account.json").read_bytes() == ACCOUNT_JSON
    assert _backups(tmp_path) == []
    # The service comes back with the old pairing.
    assert service.actions == ["stop", "start"]


def test_backups_are_owner_only(tmp_path):
    _paired_workspace(tmp_path)
    assert cli_module.backup_trust(str(tmp_path)) is True
    for name in _backups(tmp_path):
        assert (tmp_path / name).stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("error", [KeyboardInterrupt, RuntimeError])
def test_cancel_or_error_gives_the_old_pairing_back(tmp_path, error):
    old = _paired_workspace(tmp_path)

    def boom():
        raise error("stop")

    def factory(_args):
        return ClearingHost(tmp_path, on_start=boom)

    token, _, _ = make_token()
    run = lambda: cmd_connect(  # noqa: E731
        connect_args(tmp_path, token=token, timeout=1.0),
        host_factory=factory,
        service=FakeService(active=True),
        sleep=lambda _s: None,
        monotonic=lambda: 0.0,
    )
    if error is KeyboardInterrupt:
        assert run() == 1
    else:
        with pytest.raises(RuntimeError):
            run()
    assert (tmp_path / "paired.json").read_bytes() == old
    assert (tmp_path / "account.json").read_bytes() == ACCOUNT_JSON
    assert _backups(tmp_path) == []


def test_a_new_pairing_drops_the_backup(tmp_path):
    _paired_workspace(tmp_path)
    built: list[ClearingHost] = []

    def factory(_args):
        built.append(ClearingHost(tmp_path, pair_after=1, new_trust=True))
        return built[0]

    token, _, _ = make_token()
    code = cmd_connect(
        connect_args(tmp_path, token=token, timeout=5.0),
        host_factory=factory,
        service=FakeService(active=True),
        sleep=lambda _s: setattr(built[0], "polls", built[0].polls + 1),
        monotonic=lambda: float(built[0].polls) if built else 0.0,
    )
    assert code == 0
    assert "newchannel" in (tmp_path / "paired.json").read_text()
    assert _backups(tmp_path) == []


def test_a_pairing_stored_while_the_host_stops_still_counts(tmp_path):
    _paired_workspace(tmp_path)

    class LateHost(ClearingHost):
        def stop(self):
            super().stop()
            write_trust(self.workspace, channel="newchannel")

    token, _, _ = make_token()
    host_box: list[LateHost] = []

    def factory(_args):
        host_box.append(LateHost(tmp_path))
        return host_box[0]

    code = cmd_connect(
        connect_args(tmp_path, token=token, timeout=1.0),
        host_factory=factory,
        service=FakeService(active=True),
        sleep=lambda _s: setattr(host_box[0], "polls", host_box[0].polls + 1),
        monotonic=lambda: float(host_box[0].polls) if host_box else 0.0,
    )
    assert code == 0
    assert "newchannel" in (tmp_path / "paired.json").read_text()
    assert _backups(tmp_path) == []


def test_a_backup_left_by_a_killed_run_is_restored(tmp_path, capsys):
    old = _paired_workspace(tmp_path)
    cli_module.backup_trust(str(tmp_path))
    (tmp_path / "paired.json").unlink()  # the killed run had cleared it
    host = FakeHost()
    code = run_connect(connect_args(tmp_path), host, FakeService(active=True))
    # Plain connect: the pairing is back, so it is already paired.
    assert code == 0
    assert host.started == 0
    assert (tmp_path / "paired.json").read_bytes() == old
    assert _backups(tmp_path) == []
    assert "already paired" in capsys.readouterr().out


def test_a_backup_left_after_a_completed_pairing_is_dropped(tmp_path):
    _paired_workspace(tmp_path)
    cli_module.backup_trust(str(tmp_path))
    write_trust(tmp_path, channel="newchannel")
    run_connect(connect_args(tmp_path), FakeHost(), FakeService(active=True))
    assert "newchannel" in (tmp_path / "paired.json").read_text()
    assert _backups(tmp_path) == []


def test_the_real_host_clears_during_the_try_and_restores_after(tmp_path):
    """The real LocalHost with a token, on the loopback pipe (no network): the
    old trust is gone while it waits and back when nobody paired."""
    token, _, _ = make_token()
    old = _paired_workspace(tmp_path)
    seen: dict = {}

    def factory(_args):
        host = LocalHost(
            port=0,
            workspace_dir=str(tmp_path),
            agent_name="token-worker",
            install_token=parse_install_token(token),
            model_factory_override=_scripted_model,
        )
        seen["trust_during"] = (tmp_path / "paired.json").exists()
        seen["token_during"] = AccountStore(tmp_path / "account.json").token()
        return host

    polls = {"n": 0}
    code = cmd_connect(
        connect_args(tmp_path, token=token, timeout=1.0),
        host_factory=factory,
        service=FakeService(available=False),
        sleep=lambda _s: polls.__setitem__("n", polls["n"] + 1),
        monotonic=lambda: float(polls["n"]),
    )
    assert code == 1
    assert seen["trust_during"] is False
    assert seen["token_during"] is None
    assert (tmp_path / "paired.json").read_bytes() == old
    assert (tmp_path / "account.json").read_bytes() == ACCOUNT_JSON
    assert _backups(tmp_path) == []


# ------------------------------------------ the host waits for provisioning


def _provision(workspace, access="new-access"):
    """What ``_persist_account_token`` does when the app's sealed
    ``account_authentication`` frame arrives."""
    AccountStore(workspace / "account.json").save_token(
        {**ACCOUNT_TOKEN, "access_token": access, "refresh_token": access + "-r"}
    )


class ProvisioningHost(FakeHost):
    """Pairs after ``pair_after`` polls; the app's token arrives
    ``provision_after`` polls later (None: never)."""

    def __init__(self, workspace, *, pair_after=1, provision_after=None):
        super().__init__(pair_after=pair_after)
        self.workspace = workspace
        self.provision_after = provision_after
        self.polls_at_stop = None
        self.token_at_stop = None

    def tick(self):
        self.polls += 1
        if (
            self.provision_after is not None
            and self.polls == self._pair_after + self.provision_after
        ):
            _provision(self.workspace)

    def stop(self):
        super().stop()
        self.polls_at_stop = self.polls
        self.token_at_stop = AccountStore(self.workspace / "account.json").token()


def _connect(tmp_path, host, **overrides):
    return cmd_connect(
        connect_args(tmp_path, **overrides),
        host_factory=lambda _a: host,
        service=FakeService(active=True),
        sleep=lambda _s: host.tick(),
        monotonic=lambda: float(host.polls) * 0.5,
    )


def test_connect_keeps_the_host_up_until_the_account_token_arrives(tmp_path, capsys):
    host = ProvisioningHost(tmp_path, pair_after=1, provision_after=4)
    assert _connect(tmp_path, host, timeout=5.0) == 0
    # Stopped right after the token, not before it and not a full grace later.
    assert host.token_at_stop is not None
    assert host.token_at_stop["access_token"] == "new-access"
    assert host.polls_at_stop == 1 + 4
    assert "account token received" in capsys.readouterr().out


def test_connect_stops_after_the_grace_when_no_token_arrives(tmp_path, capsys):
    host = ProvisioningHost(tmp_path, pair_after=1, provision_after=None)
    code = _connect(tmp_path, host, timeout=5.0)
    # Still paired: the service parks on the heal channel and the app
    # provisions it when it connects again.
    assert code == 0
    grace_polls = int(cli_module.PROVISION_GRACE_SECONDS / 0.5)
    assert host.polls_at_stop >= 1 + grace_polls
    assert host.token_at_stop is None
    out = capsys.readouterr().out
    assert "did not send the account token" in out
    assert "Paired." in out


def test_an_old_token_on_disk_does_not_count_as_provisioning(tmp_path):
    """An unpaired workspace can still hold a stale token. Only a token that
    was not there when pairing started ends the wait."""
    _provision(tmp_path, access="stale-access")
    host = ProvisioningHost(tmp_path, pair_after=1, provision_after=3)
    assert _connect(tmp_path, host, timeout=5.0) == 0
    assert host.polls_at_stop == 1 + 3
    assert host.token_at_stop["access_token"] == "new-access"


def test_a_token_pairing_keeps_the_new_account_file_and_drops_the_backup(tmp_path):
    _paired_workspace(tmp_path)
    built: list = []

    class Host(ClearingHost):
        def tick(self):
            self.polls += 1
            if self.polls == 1 + 2:
                _provision(self.workspace)

    def factory(_args):
        built.append(Host(tmp_path, pair_after=1, new_trust=True))
        return built[0]

    token, _, _ = make_token()
    code = cmd_connect(
        connect_args(tmp_path, token=token, timeout=5.0),
        host_factory=factory,
        service=FakeService(active=True),
        sleep=lambda _s: built[0].tick(),
        monotonic=lambda: float(built[0].polls) * 0.5 if built else 0.0,
    )
    assert code == 0
    assert "newchannel" in (tmp_path / "paired.json").read_text()
    assert AccountStore(tmp_path / "account.json").token()["access_token"] == "new-access"
    assert _backups(tmp_path) == []


def test_real_connect_stays_up_until_the_app_provisioned(tmp_path):
    """The live failure: connect stopped the host right after the ceremony, so
    the app's account frame met a closed socket. Real LocalHost, real §15 and
    a real sealed ``account_authentication`` over the loopback relay."""
    import threading
    import time

    token, _, _ = make_token()
    errors: list[BaseException] = []
    stopped: dict = {}

    class Host(LocalHost):
        def start(self):
            super().start()

            def app():
                try:
                    ControllerDouble(self.url, self.channel_id, token, replay_key="t-1").run(
                        "unused: this double asks for a replay, not a run"
                    )
                except BaseException as exc:  # noqa: BLE001
                    errors.append(exc)

            threading.Thread(target=app, daemon=True).start()

        def stop(self):
            stopped["token"] = AccountStore(tmp_path / "account.json").token()
            super().stop()

    def factory(_args):
        return Host(
            port=0,
            workspace_dir=str(tmp_path),
            agent_name="token-worker",
            install_token=parse_install_token(token),
            model_factory_override=_scripted_model,
        )

    code = cmd_connect(
        connect_args(tmp_path, token=token, timeout=30.0),
        host_factory=factory,
        service=FakeService(available=False),
        sleep=time.sleep,
        monotonic=time.monotonic,
    )
    assert code == 0
    assert not errors, errors
    assert stopped["token"] is not None
    assert stopped["token"]["access_token"] == "mock-access"


# ------------------------------------------- the token from the environment


def _capture_factory(host):
    seen: list = []

    def factory(args):
        seen.append(args)
        return host

    return seen, factory


def test_connect_reads_the_token_from_the_environment_and_clears_it(tmp_path, monkeypatch):
    import os

    token, channel, digits = make_token()
    monkeypatch.setenv(cli_module.INSTALL_TOKEN_ENV, token)
    host = FakeHost(pair_after=1)
    seen, factory = _capture_factory(host)
    code = cmd_connect(
        connect_args(tmp_path, timeout=None),
        host_factory=factory,
        service=FakeService(),
        sleep=lambda _s: setattr(host, "polls", host.polls + 1),
        monotonic=lambda: float(host.polls),
    )
    assert code == 0
    assert seen[0].install_token.pairing_code == token
    assert seen[0].timeout == DEFAULT_TOKEN_CONNECT_TIMEOUT
    # Removed before the host (and anything it starts) exists.
    assert cli_module.INSTALL_TOKEN_ENV not in os.environ


def test_the_command_line_token_wins_and_the_variable_is_still_cleared(tmp_path, monkeypatch):
    import os

    argv_token, _, _ = make_token()
    env_token, _, _ = make_token()
    monkeypatch.setenv(cli_module.INSTALL_TOKEN_ENV, env_token)
    host = FakeHost(pair_after=1)
    seen, factory = _capture_factory(host)
    cmd_connect(
        connect_args(tmp_path, token=argv_token),
        host_factory=factory,
        service=FakeService(),
        sleep=lambda _s: setattr(host, "polls", host.polls + 1),
        monotonic=lambda: float(host.polls),
    )
    assert seen[0].install_token.pairing_code == argv_token
    assert cli_module.INSTALL_TOKEN_ENV not in os.environ


def test_a_bad_token_in_the_environment_exits_2_without_echo(tmp_path, monkeypatch, capsys):
    bad = secrets.token_hex(32) + "-12"
    monkeypatch.setenv(cli_module.INSTALL_TOKEN_ENV, bad)
    host = FakeHost()
    assert run_connect(connect_args(tmp_path), host, FakeService()) == EXIT_USAGE
    assert host.started == 0
    out = capsys.readouterr()
    assert bad not in out.out + out.err


def test_an_empty_variable_means_no_token(tmp_path, monkeypatch):
    monkeypatch.setenv(cli_module.INSTALL_TOKEN_ENV, "")
    write_trust(tmp_path)
    host = FakeHost()
    # Plain connect on a paired host: nothing to do, no token path.
    assert run_connect(connect_args(tmp_path), host, FakeService()) == 0
    assert host.started == 0
