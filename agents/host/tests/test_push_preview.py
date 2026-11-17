"""The sealed push preview (docs/agents/NOTIFICATIONS.md, "Test vector").
The Dart side asserts the same bytes from the same key, nonce and text."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
from types import SimpleNamespace

import pytest

from chuk_agents_host.push_preview import (
    open_preview,
    preview_plaintext,
    push_key,
    seal_for_trusts,
    seal_preview,
)

# The vector in docs/agents/NOTIFICATIONS.md. Change both or neither.
CHANNEL_KEY = bytes.fromhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
NONCE = bytes.fromhex("101112131415161718191a1b")
PLAINTEXT = (
    '{"v":1,"title":"Ada","body":"Die Summe ist 210. Schön!",'
    '"agent_id":"local:a1","session_key":"local:a1","run_id":"run-1"}'
)
PUSH_KEY_HEX = "bf24d707c4f25e9fcc144ddf730cac87c573cc2592c7fe4bf33d28f094122bb0"
SEALED = (
    "EBESExQVFhcYGRobFu8WALfXR0Ufwdw2EGA8/XP1RQSZwRI2J/aV1yljHdoStej4/sBOVhkBCnGV"
    "sSSD5teX4UQWLBhsNC+GYAj0zd1zvgZ1pcTzc7ZPvtfqyDKiY/i9jJkcbC2xk6z57JjqPIiRF4s9"
    "3fCfn55JMDKRVCM3NQCXvtFWItO+xmoed3IOPVDSDG7OYSw="
)


def test_the_push_key_is_hmac_of_the_label_under_the_channel_key():
    expected = hmac.new(CHANNEL_KEY, b"cowork/push/preview/v1", hashlib.sha256).digest()
    assert push_key(CHANNEL_KEY) == expected
    assert push_key(CHANNEL_KEY).hex() == PUSH_KEY_HEX


def test_the_plaintext_is_compact_utf8_json_in_a_fixed_key_order():
    plaintext = preview_plaintext(
        title="Ada", body="Die Summe ist 210. Schön!", agent_id="local:a1",
        session_key="local:a1", run_id="run-1",
    )
    assert plaintext == PLAINTEXT.encode("utf-8")


def test_the_fixed_vector_seals_to_the_documented_bytes():
    assert seal_preview(CHANNEL_KEY, PLAINTEXT.encode("utf-8"), nonce=NONCE) == SEALED
    raw = base64.b64decode(SEALED)
    # nonce || ciphertext || 16-byte tag
    assert raw[:12] == NONCE
    assert len(raw) == 12 + len(PLAINTEXT.encode("utf-8")) + 16
    assert open_preview(CHANNEL_KEY, SEALED) == PLAINTEXT.encode("utf-8")


def test_a_normal_seal_uses_a_fresh_random_nonce():
    a = seal_preview(CHANNEL_KEY, b"x")
    b = seal_preview(CHANNEL_KEY, b"x")
    assert a != b
    assert open_preview(CHANNEL_KEY, a) == b"x" == open_preview(CHANNEL_KEY, b)


def test_another_key_cannot_open_it():
    other = bytes(32)
    with pytest.raises(Exception):
        open_preview(other, SEALED)


def test_one_seal_per_trust_record_keyed_by_channel_id():
    trusts = [
        SimpleNamespace(channel_id="ch-1", channel_key=CHANNEL_KEY),
        SimpleNamespace(channel_id="ch-2", channel_key=bytes(32)),
        SimpleNamespace(channel_id="", channel_key=CHANNEL_KEY),  # skipped
        SimpleNamespace(channel_id="ch-3", channel_key=b"short"),  # skipped
    ]
    sealed = seal_for_trusts(trusts, b'{"v":1}')
    assert sorted(sealed) == ["ch-1", "ch-2"]
    assert json.loads(open_preview(CHANNEL_KEY, sealed["ch-1"])) == {"v": 1}
    assert open_preview(bytes(32), sealed["ch-2"]) == b'{"v":1}'
