import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/cowork/cowork_approved_devices.dart';
import 'package:chuk_chat/services/cowork/cowork_device_keys.dart';
import 'package:chuk_chat/services/cowork/cowork_pairing.dart';

/// Pairing tests: the cross-language vector (byte-for-byte against the Python
/// twin), a full in-process joiner+initiator handshake, and the MITM / abort /
/// expiry / single-use paths.
///
/// The vector fixture `test/fixtures/cowork_pairing_vectors.json` is generated
/// by `common/cowork_crypto/tests/gen_pairing_vectors.py`. X25519 and Ed25519
/// are deterministic from their private bytes, so with the same fixed inputs
/// the Dart pairing code must reproduce every derived value the Python side
/// pinned. If the two ever diverge on the wire, the vector test fails on the
/// exact differing field.
void main() {
  const int ts = 1723478400000;
  int fixedClock() => ts;

  final Map<String, dynamic> vectors =
      jsonDecode(
            File(
              'test/fixtures/cowork_pairing_vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final Map<String, dynamic> inputs = vectors['inputs'] as Map<String, dynamic>;
  final Map<String, dynamic> expected =
      vectors['expected'] as Map<String, dynamic>;

  Future<SimpleKeyPair> x25519FromSeed(String seedB64) =>
      CoworkPairingCrypto.x25519.newKeyPairFromSeed(base64Decode(seedB64));

  Future<SimpleKeyPair> edFromSeed(String seedB64) =>
      CoworkDeviceKeys.fromSeed(base64Decode(seedB64));

  group('CoWork pairing cross-language vector', () {
    test('X25519 public keys derived from the seeds match the fixture', () async {
      final a = await x25519FromSeed(inputs['initiator_x25519_seed_b64'] as String);
      final b = await x25519FromSeed(inputs['joiner_x25519_seed_b64'] as String);
      expect(
        base64Encode((await a.extractPublicKey()).bytes),
        inputs['initiator_x25519_public_b64'],
      );
      expect(
        base64Encode((await b.extractPublicKey()).bytes),
        inputs['joiner_x25519_public_b64'],
      );
    });

    test('commitment over A matches the fixture', () async {
      final commitment = CoworkPairingCrypto.commitment(
        base64Decode(inputs['initiator_x25519_public_b64'] as String),
      );
      expect(base64Encode(commitment), expected['commitment_b64']);
    });

    test('full handshake reproduces SAS, MACs and channel key byte-for-byte',
        () async {
      final initiator = await CoworkPairing.initiator(
        deviceId: inputs['initiator_device_id'] as String,
        deviceKeyPair: await edFromSeed(inputs['initiator_ed25519_seed_b64'] as String),
        sasDigits: inputs['sas_digits'] as int,
        nowMs: fixedClock,
        ephemeralKeyPair:
            await x25519FromSeed(inputs['initiator_x25519_seed_b64'] as String),
        channelId: inputs['channel_id'] as String,
        digits: inputs['digits'] as String,
      );
      final joiner = await CoworkPairing.joiner(
        deviceId: inputs['joiner_device_id'] as String,
        deviceKeyPair: await edFromSeed(inputs['joiner_ed25519_seed_b64'] as String),
        pairingCode: inputs['pairing_code'] as String,
        nowMs: fixedClock,
        ephemeralKeyPair:
            await x25519FromSeed(inputs['joiner_x25519_seed_b64'] as String),
      );

      final commit = initiator.createCommit();
      expect(commit['commitment'], expected['commitment_b64']);

      joiner.onCommit(commit);
      final pubkey = joiner.createPubkey();
      final reveal = await initiator.onPubkey(pubkey);
      final confirmD = await joiner.onReveal(reveal);
      // Byte-exact MAC_d from the Python side.
      expect(confirmD['mac'], expected['mac_d_b64']);

      final confirmC = await initiator.onConfirmD(confirmD);
      expect(confirmC['mac'], expected['mac_c_b64']);

      await joiner.onConfirmC(confirmC);

      // SAS and the derived channel key match the pinned values on both sides.
      expect(initiator.sas, expected['sas']);
      expect(joiner.sas, expected['sas']);
      expect(base64Encode(initiator.channelKey), expected['channel_key_b64']);
      expect(base64Encode(joiner.channelKey), expected['channel_key_b64']);

      // Device-key exchange: both sides end mutually approved.
      final devJoiner = await joiner.createDeviceKey();
      await initiator.onPeerDeviceKey(devJoiner);
      final devInitiator = await initiator.createDeviceKey();
      await joiner.onPeerDeviceKey(devInitiator);

      expect(initiator.state, CoworkPairingState.completed);
      expect(joiner.state, CoworkPairingState.completed);
      expect(
        joiner.approvedDevices.isApproved(inputs['initiator_device_id'] as String),
        isTrue,
      );
      expect(
        initiator.approvedDevices.isApproved(inputs['joiner_device_id'] as String),
        isTrue,
      );
    });

    test('the fixture device-key message from the joiner verifies + approves',
        () async {
      // Drive to CONFIRMED using the fixed keys, then feed the exact device-key
      // message the Python side emitted and confirm the initiator approves it.
      final initiator = await CoworkPairing.initiator(
        deviceId: inputs['initiator_device_id'] as String,
        deviceKeyPair: await edFromSeed(inputs['initiator_ed25519_seed_b64'] as String),
        sasDigits: inputs['sas_digits'] as int,
        nowMs: fixedClock,
        ephemeralKeyPair:
            await x25519FromSeed(inputs['initiator_x25519_seed_b64'] as String),
        channelId: inputs['channel_id'] as String,
        digits: inputs['digits'] as String,
      );
      final joiner = await CoworkPairing.joiner(
        deviceId: inputs['joiner_device_id'] as String,
        deviceKeyPair: await edFromSeed(inputs['joiner_ed25519_seed_b64'] as String),
        pairingCode: inputs['pairing_code'] as String,
        nowMs: fixedClock,
        ephemeralKeyPair:
            await x25519FromSeed(inputs['joiner_x25519_seed_b64'] as String),
      );
      final commit = initiator.createCommit();
      joiner.onCommit(commit);
      final reveal = await initiator.onPubkey(joiner.createPubkey());
      final confirmD = await joiner.onReveal(reveal);
      await initiator.onConfirmD(confirmD);

      final fixtureDeviceKey =
          (expected['device_key_from_joiner'] as Map).cast<String, dynamic>();
      await initiator.onPeerDeviceKey(fixtureDeviceKey);
      expect(
        initiator.approvedDevices.isApproved(inputs['joiner_device_id'] as String),
        isTrue,
      );
    });
  });

  group('CoWork pairing state machine', () {
    Future<List<CoworkPairing>> freshPair({
      String initiatorDigits = '428913',
      String? joinerCode,
      CoworkApprovedDevices? initiatorStore,
      CoworkApprovedDevices? joinerStore,
    }) async {
      final initiator = await CoworkPairing.initiator(
        deviceId: 'client-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        nowMs: fixedClock,
        channelId: 'chan0001',
        digits: initiatorDigits,
        approvedDevices: initiatorStore,
      );
      final joiner = await CoworkPairing.joiner(
        deviceId: 'desktop-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        pairingCode: joinerCode ?? initiator.pairingCode,
        nowMs: fixedClock,
        approvedDevices: joinerStore,
      );
      return [initiator, joiner];
    }

    Future<void> runToConfirmed(
      CoworkPairing initiator,
      CoworkPairing joiner,
    ) async {
      final commit = initiator.createCommit();
      joiner.onCommit(commit);
      final reveal = await initiator.onPubkey(joiner.createPubkey());
      final confirmD = await joiner.onReveal(reveal);
      final confirmC = await initiator.onConfirmD(confirmD);
      await joiner.onConfirmC(confirmC);
    }

    test('happy path: same key + SAS, mutual device trust', () async {
      final initStore = CoworkApprovedDevices.empty();
      final joinStore = CoworkApprovedDevices.empty();
      final pair = await freshPair(initiatorStore: initStore, joinerStore: joinStore);
      final initiator = pair[0];
      final joiner = pair[1];

      await runToConfirmed(initiator, joiner);

      // No human SAS comparison: PC folded into the MACs already authenticated
      // the channel, so the happy path never calls confirmPeerSas.
      expect(base64Encode(initiator.channelKey), base64Encode(joiner.channelKey));
      expect(initiator.channelKey.length, 32);

      final devJoiner = await joiner.createDeviceKey();
      await initiator.onPeerDeviceKey(devJoiner);
      final devInitiator = await initiator.createDeviceKey();
      await joiner.onPeerDeviceKey(devInitiator);

      expect(initiator.state, CoworkPairingState.completed);
      expect(joiner.state, CoworkPairingState.completed);
      expect(initStore.isApproved('desktop-01'), isTrue);
      expect(joinStore.isApproved('client-01'), isTrue);
    });

    test('channel key is hidden before confirmation', () async {
      final pair = await freshPair();
      final initiator = pair[0];
      final joiner = pair[1];
      final commit = initiator.createCommit();
      joiner.onCommit(commit);
      await initiator.onPubkey(joiner.createPubkey());
      // SAS exposed, channel key not.
      expect(initiator.sas, isA<String>());
      expect(
        () => initiator.channelKey,
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.wrongState,
          ),
        ),
      );
    });

    test(
        'a relaying MITM controlling both ECDH legs but not PC cannot forge a '
        'confirm MAC', () async {
      // The attacker sits in the middle and runs two ECDH legs with its own
      // ephemeral keys, so it learns both shared secrets and both transcripts
      // off the wire. The only thing it never sees is the pairing code PC,
      // which is typed one way into the desktop. Because PC is folded into the
      // confirm MAC, the attacker cannot produce a MAC the honest initiator
      // accepts, so the ceremony aborts with no channel key.
      const realDigits = '428913';
      final initiator = await CoworkPairing.initiator(
        deviceId: 'client-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        nowMs: fixedClock,
        channelId: 'chan0001',
        digits: realDigits,
      );
      final joiner = await CoworkPairing.joiner(
        deviceId: 'desktop-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        pairingCode: initiator.pairingCode, // user typed the real code
        nowMs: fixedClock,
      );

      final atkLegToInitiator = await CoworkPairingCrypto.x25519.newKeyPair();
      final atkLegToJoiner = await CoworkPairingCrypto.x25519.newKeyPair();
      final atkPubToInitiator =
          (await atkLegToInitiator.extractPublicKey()).bytes;
      final atkPubToJoiner = (await atkLegToJoiner.extractPublicKey()).bytes;

      // 1. Initiator commits to A; attacker forges its own commit to the joiner
      //    over its ephemeral M, reusing the channel id so the typed code routes.
      final commit = initiator.createCommit();
      joiner.onCommit(<String, dynamic>{
        'type': 'commit',
        'channel_id': commit['channel_id'],
        'commitment': base64.encode(CoworkPairingCrypto.commitment(atkPubToJoiner)),
        'expires_at': commit['expires_at'],
        'sas_digits': commit['sas_digits'],
      });

      // 2. Joiner sends real B (swallowed); initiator gets the attacker's B'.
      joiner.createPubkey();
      final reveal = await initiator.onPubkey(<String, dynamic>{
        'type': 'pubkey',
        'pubkey': base64.encode(atkPubToInitiator),
      });

      // 3. Initiator reveals A on the wire; attacker reveals M to the joiner.
      final realA = base64Decode(reveal['pubkey'] as String);
      await joiner.onReveal(<String, dynamic>{
        'type': 'reveal',
        'pubkey': base64.encode(atkPubToJoiner),
      });

      // The attacker now knows leg 1 completely: K1 == DH(a, B'), T1 == A ‖ B'.
      final k1Secret = await CoworkPairingCrypto.x25519.sharedSecretKey(
        keyPair: atkLegToInitiator,
        remotePublicKey: SimplePublicKey(realA, type: KeyPairType.x25519),
      );
      final k1 = await k1Secret.extractBytes();
      final t1 = CoworkPairingCrypto.transcript(realA, atkPubToInitiator);

      // 4. The attacker can only guess PC. A wrong guess is rejected.
      final guessed = await CoworkPairingCrypto.deriveConfirmMac(
        k1,
        CoworkPairingCrypto.confirmDLabel,
        t1,
        '000000',
      );
      await expectLater(
        initiator.onConfirmD(<String, dynamic>{
          'type': 'confirm-d',
          'mac': base64.encode(guessed),
        }),
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.macMismatch,
          ),
        ),
      );
      expect(initiator.state, CoworkPairingState.aborted);
      expect(() => initiator.channelKey, throwsA(isA<CoworkPairingException>()));

      // Positive control: over the same (K1, T1), the MAC built with the real
      // code differs from the guess — PC alone is the accept/reject line.
      final withRealPc = await CoworkPairingCrypto.deriveConfirmMac(
        k1,
        CoworkPairingCrypto.confirmDLabel,
        t1,
        initiator.pairingCode,
      );
      expect(base64Encode(withRealPc) == base64Encode(guessed), isFalse);
    });

    test('MITM swapping A is caught by the commitment', () async {
      final pair = await freshPair();
      final initiator = pair[0];
      final joiner = pair[1];
      final commit = initiator.createCommit();
      joiner.onCommit(commit);
      await initiator.onPubkey(joiner.createPubkey());

      final attacker = await CoworkPairingCrypto.x25519.newKeyPair();
      final forgedReveal = <String, dynamic>{
        'type': 'reveal',
        'pubkey': base64.encode((await attacker.extractPublicKey()).bytes),
      };
      await expectLater(
        joiner.onReveal(forgedReveal),
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.commitmentMismatch,
          ),
        ),
      );
      expect(joiner.state, CoworkPairingState.aborted);
    });

    test('wrong pairing code aborts at the confirm MAC, no human step',
        () async {
      final initiator = await CoworkPairing.initiator(
        deviceId: 'client-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        nowMs: fixedClock,
        channelId: 'chan0001',
        digits: '111111',
      );
      final joiner = await CoworkPairing.joiner(
        deviceId: 'desktop-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        pairingCode: 'chan0001-222222', // wrong digits
        nowMs: fixedClock,
      );
      final commit = initiator.createCommit();
      joiner.onCommit(commit);
      final reveal = await initiator.onPubkey(joiner.createPubkey());
      // PC is folded into MAC_d: the joiner builds it over its (wrong) code, the
      // initiator verifies over its own -> mismatch -> abort, no human compare.
      final confirmD = await joiner.onReveal(reveal);
      await expectLater(
        initiator.onConfirmD(confirmD),
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.macMismatch,
          ),
        ),
      );
      expect(initiator.state, CoworkPairingState.aborted);
      expect(() => initiator.channelKey, throwsA(isA<CoworkPairingException>()));
      expect(initiator.sas == joiner.sas, isFalse);
    });

    test('forged device-key MAC is rejected', () async {
      final pair = await freshPair();
      final initiator = pair[0];
      final joiner = pair[1];
      await runToConfirmed(initiator, joiner);
      final devJoiner = await joiner.createDeviceKey();
      devJoiner['mac'] = base64.encode(List<int>.filled(32, 0));
      await expectLater(
        initiator.onPeerDeviceKey(devJoiner),
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.macMismatch,
          ),
        ),
      );
      expect(initiator.state, CoworkPairingState.aborted);
    });

    test('expired session is rejected', () async {
      var now = ts;
      final initiator = await CoworkPairing.initiator(
        deviceId: 'client-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        nowMs: () => now,
        channelId: 'chan0001',
        digits: '428913',
      );
      final joiner = await CoworkPairing.joiner(
        deviceId: 'desktop-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        pairingCode: initiator.pairingCode,
        nowMs: () => now,
      );
      final commit = initiator.createCommit();
      now = ts + 120001; // just past the 2-minute window
      expect(
        () => joiner.onCommit(commit),
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.expired,
          ),
        ),
      );
    });

    test('single-use: a completed session rejects reuse', () async {
      final pair = await freshPair();
      final initiator = pair[0];
      final joiner = pair[1];
      await runToConfirmed(initiator, joiner);
      final devJoiner = await joiner.createDeviceKey();
      await initiator.onPeerDeviceKey(devJoiner);
      final devInitiator = await initiator.createDeviceKey();
      await joiner.onPeerDeviceKey(devInitiator);
      expect(joiner.state, CoworkPairingState.completed);
      await expectLater(
        joiner.createDeviceKey(),
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.consumed,
          ),
        ),
      );
    });

    test('channel id mismatch is rejected', () async {
      final initiator = await CoworkPairing.initiator(
        deviceId: 'client-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        nowMs: fixedClock,
        channelId: 'chan0001',
        digits: '428913',
      );
      final commit = initiator.createCommit();
      final wrongJoiner = await CoworkPairing.joiner(
        deviceId: 'desktop-01',
        deviceKeyPair: await CoworkDeviceKeys.generate(),
        pairingCode: 'different-428913',
        nowMs: fixedClock,
      );
      expect(
        () => wrongJoiner.onCommit(commit),
        throwsA(
          isA<CoworkPairingException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkPairingRejection.channelMismatch,
          ),
        ),
      );
    });
  });
}
