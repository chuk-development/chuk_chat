"""The host's secret vault at rest (docs/WIRE_CONTRACT.md, "Secrets"): the
set survives a host restart with no app attached, the file is ciphertext
under the identity-derived key, and a foreign key reads as an empty set."""

from __future__ import annotations

import json
import os

from chuk_agents_crypto import DeviceIdentity
from chuk_agents_executor import SecretsVault, secrets_payload

from chuk_agents_host.host import LocalHost
from chuk_agents_host.identity import load_or_create_identity
from chuk_agents_host.secrets_key import secrets_at_rest_key

VALUE = "pexels-0123456789abcdef"


def test_key_is_deterministic_per_identity():
    a = DeviceIdentity.generate()
    b = DeviceIdentity.generate()
    assert secrets_at_rest_key(a) == secrets_at_rest_key(a)
    assert secrets_at_rest_key(a) != secrets_at_rest_key(b)
    assert len(secrets_at_rest_key(a)) == 32


def test_vault_round_trips_through_the_file(tmp_path):
    key = secrets_at_rest_key(DeviceIdentity.generate())
    path = tmp_path / "secrets.enc"
    vault = SecretsVault(path=path, key=key)
    frame = secrets_payload({"PEXELS_API_KEY": VALUE, "SHORT": "ab"}, revision=4)
    assert vault.replace(frame["entries"], revision=frame["revision"], user_id="u1") == 2

    raw = path.read_text(encoding="utf-8")
    assert VALUE not in raw and "PEXELS_API_KEY" not in raw
    assert json.loads(raw)["version"] == 1
    assert oct(path.stat().st_mode & 0o777) == "0o600"

    again = SecretsVault(path=path, key=key)
    assert again.load() == 2
    assert again.env() == {"PEXELS_API_KEY": VALUE, "SHORT": "ab"}
    assert again.revision == 4 and again.user_id == "u1"
    assert again.status(["PEXELS_API_KEY", "X"]) == {"PEXELS_API_KEY": "set", "X": "missing"}


def test_a_foreign_key_reads_as_empty_and_keeps_the_file(tmp_path):
    path = tmp_path / "secrets.enc"
    SecretsVault(path=path, key=os.urandom(32)).replace({"A": VALUE})
    other = SecretsVault(path=path, key=os.urandom(32))
    assert other.load() == 0
    assert other.env() == {}
    assert path.exists()


def test_replace_drops_bad_entries_and_last_frame_wins(tmp_path):
    vault = SecretsVault()
    vault.replace(
        [{"name": "OK", "value": VALUE}, {"name": "bad-name", "value": "x"}, {"name": "EMPTY", "value": ""}, "junk"],
        revision="7",
    )
    assert vault.names() == ["OK"] and vault.revision == 7
    vault.replace([{"name": "B", "value": "12345678"}], revision=3)
    assert vault.names() == ["B"]  # complete replacement, lower revision still wins
    vault.clear()
    assert len(vault) == 0


def test_the_host_loads_its_vault_at_start_and_exposes_it(tmp_path):
    def make():
        return LocalHost(
            port=0,
            workspace_dir=str(tmp_path),
            agent_name="t",
            channel_id="testchannel00",
            digits="428913",
            model_factory_override=lambda: None,
        )

    first = make()
    assert first.secrets_vault.env() == {}
    first.secrets_vault.replace({"PEXELS_API_KEY": VALUE}, revision=1)
    assert (tmp_path / "secrets.enc").exists()

    # A new host process over the same workspace: same identity, same key.
    second = make()
    assert second.secrets_vault.env() == {"PEXELS_API_KEY": VALUE}
    identity = load_or_create_identity(tmp_path / "host_device.key")
    assert secrets_at_rest_key(identity) == second.secrets_vault._key


def test_the_pending_nudge_is_names_only(tmp_path):
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="t",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=lambda: None,
    )
    sent: list[tuple[str, str]] = []

    class _Toast:
        def notify(self, title, body):
            sent.append((title, body))
            return True

    host._desktop_notifier = _Toast()  # type: ignore[assignment]
    host._on_secret_request_pending({"names": ["PEXELS_API_KEY"], "request_id": "r1"})
    assert sent == [("t needs an API key", "Open the app to enter: PEXELS_API_KEY")]
