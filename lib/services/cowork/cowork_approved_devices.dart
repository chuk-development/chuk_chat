import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';

/// The executor's **local** set of device public keys it will accept frames
/// from. This is the CoWork trust boundary.
///
/// ## Why this exists rather than a server flag
///
/// A device's approval state also lives in Supabase (`cowork_devices`), which
/// is *not* end-to-end encrypted: the backend can read it and, if compromised,
/// write it. If the desktop trusted that flag, taking the server would be
/// enough to drive somebody's laptop. So the server's copy is a UX convenience
/// and a first-line filter, and **this** — a set of keys the desktop recorded
/// itself, after a local human approval — is what actually authorises a frame.
///
/// A compromised backend can flip `approved` in the table all it likes. It
/// cannot add a key here, it cannot produce an Ed25519 signature verifying
/// under a key that is here, and without the account key it cannot read or
/// write a payload. That is the property the whole design rests on.
///
/// ## Default deny
///
/// An empty store rejects every frame. There is no fallback to "the server says
/// this device is fine", and [CoworkFrameOpener] takes no overload that skips
/// the lookup — the only way to accept a frame is for its key to be in here.
///
/// Storage-agnostic by design: [toBase64Map] / [CoworkApprovedDevices.fromBase64Map]
/// hand the caller a plain map to persist wherever it likes (secure storage, a
/// `0600` file, SQLite). This class never touches disk.
class CoworkApprovedDevices {
  CoworkApprovedDevices([Map<String, SimplePublicKey>? approved])
    : _approved = <String, SimplePublicKey>{...?approved};

  /// An empty store. Rejects everything until something is explicitly approved.
  CoworkApprovedDevices.empty() : _approved = <String, SimplePublicKey>{};

  /// Restores a store from persisted `deviceId -> base64 public key` entries.
  ///
  /// Throws [FormatException] if any entry is not a valid Ed25519 public key,
  /// rather than silently dropping it: a trust store that half-loaded would
  /// deny a legitimate device with no explanation.
  factory CoworkApprovedDevices.fromBase64Map(Map<String, String> entries) {
    final approved = <String, SimplePublicKey>{};
    for (final entry in entries.entries) {
      approved[entry.key] = CoworkDeviceKeys.publicKeyFromBase64(entry.value);
    }
    return CoworkApprovedDevices(approved);
  }

  final Map<String, SimplePublicKey> _approved;

  bool get isEmpty => _approved.isEmpty;

  bool get isNotEmpty => _approved.isNotEmpty;

  int get length => _approved.length;

  /// Device ids currently approved, for a "Devices" UI listing.
  Set<String> get deviceIds => Set<String>.unmodifiable(_approved.keys);

  /// The approved key for [deviceId], or null if this device has never
  /// approved it. Null means reject — never "ask the server".
  SimplePublicKey? lookup(String deviceId) => _approved[deviceId];

  bool isApproved(String deviceId) => _approved.containsKey(deviceId);

  /// Records a local human approval of [deviceId] holding [publicKey].
  ///
  /// Re-approving the same device with a *different* key throws
  /// [StateError]. Silently overwriting would turn any code path that can call
  /// `approve` into a key-substitution primitive; swapping a device's key must
  /// go through an explicit [revoke] so it is a deliberate act.
  void approve(String deviceId, SimplePublicKey publicKey) {
    if (deviceId.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
    if (publicKey.type != KeyPairType.ed25519 ||
        publicKey.bytes.length != CoworkDeviceKeys.publicKeyLength) {
      throw ArgumentError.value(
        publicKey,
        'publicKey',
        'must be a ${CoworkDeviceKeys.publicKeyLength}-byte Ed25519 key',
      );
    }
    final existing = _approved[deviceId];
    if (existing != null && !_sameKey(existing, publicKey)) {
      throw StateError(
        'Device $deviceId is already approved with a different key. '
        'Revoke it before approving a new key.',
      );
    }
    _approved[deviceId] = publicKey;
  }

  /// Removes [deviceId]. Returns true if it had been approved.
  ///
  /// This is kill switch #1: after this returns, every frame from that device
  /// is rejected, with no server round-trip and nothing the server can do to
  /// undo it.
  bool revoke(String deviceId) => _approved.remove(deviceId) != null;

  /// Removes every device — the tray "panic" wipe.
  void revokeAll() => _approved.clear();

  /// Persistable snapshot: `deviceId -> base64 public key`.
  Map<String, String> toBase64Map() => <String, String>{
    for (final entry in _approved.entries)
      entry.key: base64EncodePublicKey(entry.value),
  };

  static String base64EncodePublicKey(SimplePublicKey publicKey) =>
      base64.encode(publicKey.bytes);

  static bool _sameKey(SimplePublicKey a, SimplePublicKey b) {
    if (a.bytes.length != b.bytes.length) return false;
    var diff = 0;
    for (var i = 0; i < a.bytes.length; i++) {
      diff |= a.bytes[i] ^ b.bytes[i];
    }
    return diff == 0;
  }
}
