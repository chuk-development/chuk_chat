#!/usr/bin/env python3
"""Make the real ciphertext that the video shows.

Same layers as the app (docs/CHAT_PAYLOAD_FORMAT.md, lib/services/encryption_service.dart
sealChatPayload):
  messages -> payload JSON v3 -> frame 0x00|codec 1 (raw deflate)|uint32 LE length|data
  -> AES-256-GCM (random 256-bit key, random 12-byte nonce)
  -> envelope {"v":"2","kv":1,"nonce":...,"ciphertext":...,"mac":...}
The key is random and is thrown away. Nobody can decrypt the result, which is the point.
Run:  python3 _work/make_cipher.py   (from the project root) -> _work/cipher.json
"""
import base64
import json
import os
import struct
import uuid
import zlib
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

HERE = Path(__file__).resolve().parent

PROMPT = "my blood test says ferritin 9. should i be worried?"
ANSWER = [
    "A ferritin of 9 µg/L is low.",
    "It usually means your iron stores are empty, even before anaemia shows.",
    "It is common and treatable.",
    "Ask your doctor about an iron panel and the cause.",
]

payload = {
    "v": 3,
    "messages": [
        {"role": "user", "text": PROMPT},
        {"role": "assistant", "text": " ".join(ANSWER)},
    ],
}
raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
comp = zlib.compressobj(9, zlib.DEFLATED, -15)
data = comp.compress(raw) + comp.flush()
frame = bytes([0x00, 0x01]) + struct.pack("<I", len(raw)) + data

key = AESGCM.generate_key(bit_length=256)
nonce = os.urandom(12)
sealed = AESGCM(key).encrypt(nonce, frame, None)
ct, mac = sealed[:-16], sealed[-16:]

# self-test: decrypt and unframe again
plain = AESGCM(key).decrypt(nonce, sealed, None)
assert plain == frame
assert zlib.decompress(plain[6:], -15) == raw

envelope = {
    "v": "2",
    "kv": 1,
    "nonce": base64.b64encode(nonce).decode(),
    "ciphertext": base64.b64encode(ct).decode(),
    "mac": base64.b64encode(mac).decode(),
}
env_text = json.dumps(envelope, separators=(",", ":"))

# Three more rows of the same user, so the table has neighbours. Their text is never shown.
OTHERS = [
    "help me write a birthday card for my dad",
    "translate this lease clause into plain english",
    "how do i tell my boss i need a week off",
]


def seal(text):
    raw_o = json.dumps({"v": 3, "messages": [{"role": "user", "text": text}]},
                       separators=(",", ":")).encode()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    d = c.compress(raw_o) + c.flush()
    fr = bytes([0x00, 0x01]) + struct.pack("<I", len(raw_o)) + d
    n = os.urandom(12)
    sb = AESGCM(key).encrypt(n, fr, None)
    return json.dumps({"v": "2", "kv": 1, "nonce": base64.b64encode(n).decode(),
                       "ciphertext": base64.b64encode(sb[:-16]).decode(),
                       "mac": base64.b64encode(sb[-16:]).decode()}, separators=(",", ":"))


others = [{"id": str(uuid.uuid4()), "payload": seal(t)} for t in OTHERS]

out = {
    "others": others,
    "prompt": PROMPT,
    "answer": ANSWER,
    "envelope": envelope,
    "envelope_text": env_text,
    "row_id": str(uuid.uuid4()),
    "user_id": str(uuid.uuid4()),
    "plain_len": len(raw),
    "frame_len": len(frame),
}
(HERE / "cipher.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))
print(env_text)
print(len(env_text), "chars; plaintext", len(raw), "bytes, frame", len(frame), "bytes")
