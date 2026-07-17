import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/cowork/cowork_approved_devices.dart';
import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';
import 'package:chuk_chat/services/cowork/cowork_frame.dart';
import 'package:chuk_chat/services/cowork/cowork_replay_guard.dart';

/// AES-256-GCM — the same primitive, and the same per-user account key, that
/// `EncryptionService` already uses for chat payloads. Nothing here derives or
/// stores key material; it is handed the key that service owns.
final AesGcm _cipher = AesGcm.with256bits();

/// Seals outgoing CoWork frames: AES-256-GCM under the account key, then an
/// Ed25519 signature with this device's own key.
///
/// One sealer per outbound stream. It owns the `seq` counter, which must be
/// strictly monotonic for the peer's replay guard to accept anything — so a
/// daemon restart must restore [nextSeq] from storage rather than start over.
///
/// ## Where the account key comes from
///
/// [accountKey] and [accountKeyVersion] are the pair `EncryptionService` owns:
/// pass `EncryptionService`'s cached per-user key and its `currentKeyVersion`.
/// They are injected rather than read here so this class stays pure and
/// testable, and — more importantly — so the caller owns the rotation
/// lifecycle.
///
/// They are a **snapshot**, not a live view. A password change rotates the
/// account key, and a sealer built before it keeps sealing under the old one.
/// The wiring layer must rebuild sealers on rotation.
///
/// Read the two together, in one synchronous step. `rotateKeyForPasswordChange`
/// publishes the new key *before* it awaits the chat migration and only bumps
/// the version afterwards, so a caller that reads them across an `await` can
/// pair a new key with a stale version and mislabel `kv`.
class CoworkFrameSealer {
  CoworkFrameSealer({
    required SecretKey accountKey,
    required int accountKeyVersion,
    required String deviceId,
    required SimpleKeyPair signingKeyPair,
    int nextSeq = 0,
    DateTime Function()? clock,
    Random? random,
  }) : _accountKey = accountKey,
       _accountKeyVersion = accountKeyVersion,
       _deviceId = deviceId,
       _signingKeyPair = signingKeyPair,
       _nextSeq = nextSeq,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure() {
    // Not an assert: nextSeq is restored from storage, and asserts are stripped
    // in release builds — exactly where a corrupted counter would land.
    if (nextSeq < 0) {
      throw ArgumentError.value(nextSeq, 'nextSeq', 'must be non-negative');
    }
  }

  final SecretKey _accountKey;
  final int _accountKeyVersion;
  final String _deviceId;
  final SimpleKeyPair _signingKeyPair;
  final DateTime Function() _clock;
  final Random _random;

  int _nextSeq;

  /// The `seq` the next [seal] will use. Persist this across restarts.
  int get nextSeq => _nextSeq;

  String get deviceId => _deviceId;

  /// Seals [plaintext] into a frame ready for the relay.
  Future<CoworkFrame> seal(List<int> plaintext) async {
    final seq = _nextSeq++;
    final ts = _clock().toUtc().millisecondsSinceEpoch;
    final nonce = Uint8List.fromList(
      List<int>.generate(kCoworkFrameNonceLength, (_) => _random.nextInt(256)),
    );

    // The header is AAD, not payload: it travels in the clear but is bound into
    // the tag, so a ciphertext cannot be lifted onto a different seq/ts/device.
    final header = CoworkFrame.buildHeaderBytes(
      version: kCoworkFrameVersion,
      keyVersion: _accountKeyVersion,
      deviceId: _deviceId,
      seq: seq,
      ts: ts,
    );

    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: _accountKey,
      nonce: nonce,
      aad: header,
    );

    // GCM output as one field: cipher text followed by its tag.
    final ciphertext =
        Uint8List(secretBox.cipherText.length + secretBox.mac.bytes.length)
          ..setAll(0, secretBox.cipherText)
          ..setAll(secretBox.cipherText.length, secretBox.mac.bytes);

    final signature = await CoworkDeviceKeys.algorithm.sign(
      CoworkFrame.buildSignedBytes(
        header: header,
        nonce: nonce,
        ciphertext: ciphertext,
      ),
      keyPair: _signingKeyPair,
    );

    return CoworkFrame(
      version: kCoworkFrameVersion,
      keyVersion: _accountKeyVersion,
      deviceId: _deviceId,
      seq: seq,
      ts: ts,
      nonce: nonce,
      ciphertext: ciphertext,
      sig: Uint8List.fromList(signature.bytes),
    );
  }

  Future<CoworkFrame> sealText(String plaintext) =>
      seal(utf8.encode(plaintext));
}

/// Opens incoming CoWork frames, in this order:
///
///  1. **Local approval** — is `device_id` in [approvedDevices]? A store this
///     device wrote itself, never the server's flag. Unknown device ⇒ reject.
///  2. **Signature** — Ed25519 against that locally approved key, before any
///     decryption. A cheap fail-closed gate that a hostile relay cannot pass.
///  3. **Key version** — `kv` must name the key this receiver holds.
///  4. **Replay** — `ts` window, then strictly monotonic `seq` per device.
///  5. **Decryption** — AES-256-GCM under the account key, header as AAD.
///
/// Every step is a hard reject; there is no path that accepts a frame whose
/// signing key is not in [approvedDevices], and no overload that skips it.
class CoworkFrameOpener {
  CoworkFrameOpener({
    required SecretKey accountKey,
    required int accountKeyVersion,
    required CoworkApprovedDevices approvedDevices,
    Duration replayWindow = const Duration(seconds: 60),
    DateTime Function()? clock,
    Map<String, int>? lastSeqByDevice,
  }) : _accountKey = accountKey,
       _accountKeyVersion = accountKeyVersion,
       _approvedDevices = approvedDevices,
       _replayWindow = replayWindow,
       _clock = clock ?? DateTime.now,
       _guards = <String, CoworkReplayGuard>{
         for (final entry in (lastSeqByDevice ?? const <String, int>{}).entries)
           entry.key: CoworkReplayGuard(
             window: replayWindow,
             clock: clock ?? DateTime.now,
             lastSeq: entry.value,
           ),
       };

  final SecretKey _accountKey;
  final int _accountKeyVersion;
  final CoworkApprovedDevices _approvedDevices;
  final Duration _replayWindow;
  final DateTime Function() _clock;
  final Map<String, CoworkReplayGuard> _guards;

  /// The live local trust store. Revoking here takes effect on the next frame.
  CoworkApprovedDevices get approvedDevices => _approvedDevices;

  /// Highest accepted `seq` per device. Persist to survive a daemon restart;
  /// pass back via `lastSeqByDevice`.
  Map<String, int> get lastSeqByDevice => <String, int>{
    for (final entry in _guards.entries)
      if (entry.value.lastSeq != null) entry.key: entry.value.lastSeq!,
  };

  /// Verifies and decrypts [frame], or throws [CoworkFrameRejectedException].
  Future<Uint8List> open(CoworkFrame frame) async {
    if (frame.version != kCoworkFrameVersion) {
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.unsupportedVersion,
      );
    }

    // 1. Local approval. Default deny: an empty store has no entries, so every
    //    lookup misses and every frame dies here.
    final publicKey = _approvedDevices.lookup(frame.deviceId);
    if (publicKey == null) {
      _logReject(CoworkFrameRejection.deviceNotApproved);
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.deviceNotApproved,
      );
    }

    // 2. Signature, before decryption.
    final signatureValid = await CoworkDeviceKeys.algorithm.verify(
      frame.signedBytes,
      signature: Signature(frame.sig, publicKey: publicKey),
    );
    if (!signatureValid) {
      _logReject(CoworkFrameRejection.badSignature);
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.badSignature,
      );
    }

    // 3. Key version. Only meaningful now the signature has vouched for it —
    //    `kv` is attacker-controlled bytes until then. This receiver holds one
    //    account key, so anything else cannot be opened; say that outright
    //    rather than letting it surface as a puzzling decryption failure.
    if (frame.keyVersion != _accountKeyVersion) {
      _logReject(CoworkFrameRejection.keyVersionMismatch);
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.keyVersionMismatch,
      );
    }

    // 4. Replay: ts window, then monotonic seq. Checked, not yet committed.
    final guard = _guards.putIfAbsent(
      frame.deviceId,
      () => CoworkReplayGuard(window: _replayWindow, clock: _clock),
    );
    try {
      guard.check(frame);
    } on CoworkFrameRejectedException catch (e) {
      _logReject(e.rejection);
      rethrow;
    }

    // 5. Decrypt. The header must match bit for bit or the tag fails.
    final cipherTextLength = frame.ciphertext.length - kCoworkFrameMacLength;
    final secretBox = SecretBox(
      Uint8List.sublistView(frame.ciphertext, 0, cipherTextLength),
      nonce: frame.nonce,
      mac: Mac(Uint8List.sublistView(frame.ciphertext, cipherTextLength)),
    );
    final List<int> cleartext;
    try {
      cleartext = await _cipher.decrypt(
        secretBox,
        secretKey: _accountKey,
        aad: frame.headerBytes,
      );
    } on SecretBoxAuthenticationError {
      _logReject(CoworkFrameRejection.decryptionFailed);
      throw const CoworkFrameRejectedException(
        CoworkFrameRejection.decryptionFailed,
      );
    }

    // 6. Burn the sequence only now the frame is genuinely deliverable. A
    //    frame that failed step 5 never reached the executor, so it must not
    //    consume a seq. The re-check inside commit() closes the race between
    //    two frames decrypting concurrently.
    try {
      guard.commit(frame);
    } on CoworkFrameRejectedException catch (e) {
      _logReject(e.rejection);
      rethrow;
    }
    return Uint8List.fromList(cleartext);
  }

  Future<String> openText(CoworkFrame frame) async =>
      utf8.decode(await open(frame));

  /// Rejections are worth seeing while debugging, but a frame is attacker
  /// controlled: log the reason only. Never the payload, key, nonce or device.
  void _logReject(CoworkFrameRejection rejection) {
    if (kDebugMode) {
      debugPrint('[CoWork] frame rejected: ${rejection.name}');
    }
  }
}
