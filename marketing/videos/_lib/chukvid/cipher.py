"""Real ciphertext in the app's envelope formats.

The key is random and thrown away: nobody can decrypt what the video shows.

encrypt_bytes   = EncryptionService.encryptBytes (lib/services/encryption_service.dart,
                  _encryptBytesInBackground): AES-256-GCM, random 12-byte nonce, and
                  jsonEncode({'v': '1', 'kv': 1, 'nonce', 'ciphertext', 'mac'}) with the
                  16-byte tag split off as "mac". Used for images and files in Storage
                  (image_storage_service.dart: utf8 of that JSON is the .enc object).
seal_chat       = sealChatPayload (envelope "v":"2"): v3 payload JSON, frame
                  0x00 | codec 1 (raw deflate) | uint32 LE length | data, then AES-GCM.
"""
import base64
import json
import os
import struct
import uuid
import zlib

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def new_key():
    return AESGCM.generate_key(bit_length=256)


def _seal(key, data, v):
    nonce = os.urandom(12)
    sealed = AESGCM(key).encrypt(nonce, data, None)
    assert AESGCM(key).decrypt(nonce, sealed, None) == data
    env = {
        "v": v,
        "kv": 1,
        "nonce": base64.b64encode(nonce).decode(),
        "ciphertext": base64.b64encode(sealed[:-16]).decode(),
        "mac": base64.b64encode(sealed[-16:]).decode(),
    }
    # Dart jsonEncode: insertion order, no spaces, '/' not escaped
    return env, json.dumps(env, separators=(",", ":"))


def encrypt_bytes(data, key=None):
    """(envelope dict, envelope JSON text) exactly as encryptBytes writes it."""
    return _seal(key or new_key(), bytes(data), "1")


def seal_chat(messages, key=None):
    """messages: [{"role": "user", "text": ...}, ...] -> (envelope, text) like sealChatPayload."""
    raw = json.dumps({"v": 3, "messages": messages}, ensure_ascii=False, separators=(",", ":")).encode()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    d = c.compress(raw) + c.flush()
    frame = bytes([0x00, 0x01]) + struct.pack("<I", len(raw)) + d
    return _seal(key or new_key(), frame, "2")


def uid():
    return str(uuid.uuid4())


def mask_uuid(u):
    return u[:4] + "····-····-····-····" + u[-4:]


def mask_uuid_short(u):
    return u[:4] + "····" + u[-4:]


def human_bytes(n):
    """lib/utils/format_bytes.dart formatBytes: one decimal below 10 of a unit, none above."""
    if n <= 0:
        return "0 B"
    if n < 1024:
        return f"{n} B"
    units = ["KB", "MB", "GB", "TB"]
    v, i = n / 1024.0, 0
    while v >= 1024 and i < len(units) - 1:
        v /= 1024
        i += 1
    return (f"{v:.1f}" if v < 10 else str(round(v))) + " " + units[i]
