# cowork_crypto

The byte-identical Python twin of the Dart CoWork frame crypto in chuk_chat
(`lib/services/cowork/cowork_frame*.dart`). It seals and opens the frames that
cross the blind relay between a phone (controller) and a laptop (executor).

Same wire format as the Dart side, matched field-for-field:

- frame JSON `{v, kv, device_id, seq, ts, nonce, ciphertext, sig}`
- length-prefixed header (4-byte big-endian length + bytes per field), used
  verbatim as AES-256-GCM AAD and as the prefix of the signed bytes
- AES-256-GCM, ciphertext = cipher text followed by the 16-byte tag
- Ed25519 signature over `(header, nonce, ciphertext)`, verified **before**
  decrypt (fail-closed)
- `seq` + `ts` replay guard, strictly monotonic seq inside a freshness window
- default-deny local approved-device set (an empty set rejects every frame)

## Key handling (plan §14)

The symmetric key is **not** the chat account key. It is a fresh CoWork
**channel key**, established at pairing by X25519 ECDH between controller and
executor, then run through HKDF-SHA256. See `channel_key.py`. This keeps the
chat account-key derivation out of Python and off the headless host.

```
shared      = X25519(my_private, their_public)              # 32 raw bytes
channel_key = HKDF-SHA256(ikm=shared, salt="", info=b"chuk.cowork.channel-key.v1", length=32)
```

Both peers derive the identical 32-byte AES-256 key because ECDH is symmetric.

## Public API

```python
from cowork_crypto import (
    DeviceIdentity, ApprovedDevices, ReplayGuard,
    CoworkFrameSealer, CoworkFrameOpener, seal, open,
    derive_channel_key, generate_x25519_keypair, fingerprint,
)

# per-device Ed25519 identity
ident = DeviceIdentity.generate()          # or .from_seed(bytes32) / .from_seed_base64(str)
ident.export_private_seed()                # 32-byte seed (secret)
ident.export_public_key_base64()           # publishable
ident.fingerprint()                        # "5647-5AA7-5463-474C-0285" (80-bit)

# default-deny trust store
approved = ApprovedDevices.empty()
approved.approve("executor-01", ident.public_key)

# seal / open
sealer = CoworkFrameSealer(channel_key=k, key_version=1,
                           device_id="executor-01", signing_identity=ident)
frame_bytes = sealer.seal(b"payload")      # -> wire bytes
opener = CoworkFrameOpener(channel_key=k, key_version=1, approved_devices=approved)
plaintext = opener.open(frame_bytes)       # -> b"payload", or raises CoworkFrameRejected

# one-shot free functions with the same names
frame_bytes = seal(b"payload", channel_key=k, key_version=1,
                   device_id="executor-01", signing_identity=ident)
plaintext   = open(frame_bytes, channel_key=k, key_version=1, approved_devices=approved)
```

`open` raises `CoworkFrameRejected` with a `.rejection` of type
`CoworkFrameRejection` on any failure: `MALFORMED`, `UNSUPPORTED_VERSION`,
`DEVICE_NOT_APPROVED`, `BAD_SIGNATURE`, `KEY_VERSION_MISMATCH`,
`TIMESTAMP_OUT_OF_WINDOW`, `REPLAYED_SEQUENCE`, `DECRYPTION_FAILED`.

State to persist across a daemon restart: `sealer.next_seq` (outbound counter)
and `opener.last_seq_by_device` (inbound high-water marks). Pass the latter back
via the `last_seq_by_device=` argument.

## Cross-language test vector — the Dart side MUST be verified against this

`tests/fixtures/test_vectors.json` is a **shared** fixture. It fixes the
Ed25519 seed, the channel key, the nonce, and all header fields, then records
the expected `header_b64`, `signed_b64`, `ciphertext_b64`, `sig_b64` and the
full `frame_json`. Ed25519 is deterministic (RFC 8032) and AES-GCM under a fixed
nonce is deterministic, so the whole frame is reproducible with no RNG.

`tests/test_vectors.py` proves the Python side reproduces those bytes exactly.

**A matching Dart test still has to be written on the chuk_chat side.** It must:

1. load the same JSON fixture,
2. build a `CoworkFrameSealer` from `ed25519_seed_b64` and `channel_key_b64`,
   inject the fixed `nonce`, `seq`, `ts`, `device_id`, `kv`,
3. seal `plaintext_utf8`, and
4. assert its `headerBytes`, `signedBytes`, `ciphertext`, `sig` and
   `toJsonString()` equal the `expected` values, then open it back.

Until that Dart test exists and passes, byte-compatibility is verified on the
Python side only — treat it as unconfirmed on the wire. The Dart `cowork_frame*`
primitives also still need repointing from the account key to the channel key
(plan §14, "cheap, not yet wired").

Regenerate the fixture after any intentional wire change:
`uv run python tests/gen_vectors.py`.

## Develop

```bash
uv run pytest
```
