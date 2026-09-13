import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_reconnect.dart';

/// Reconnect handshake tests: the cross-language vector (byte-for-byte against
/// the Python twin), the full in-process mutual challenge, and the
/// imposter-rejection paths — a forged signature on either side is refused and
/// the session aborts with no channel resumed.
///
/// The vector fixture `test/fixtures/agents_reconnect_vectors.json` is generated
/// by `common/agents_crypto/tests/gen_reconnect_vectors.py`. Ed25519 is
/// deterministic from its private bytes (RFC 8032), so with the same fixed
/// nonces + seeds the Dart code must reproduce every proof byte the Python side
/// pinned.
void main() {
  Future<SimpleKeyPair> edFromSeed(String seedB64) =>
      AgentsDeviceKeys.fromSeed(base64Decode(seedB64));

  group('Agents reconnect cross-language vector', () {
    final Map<String, dynamic> vectors = jsonDecode(
      File('test/fixtures/agents_reconnect_vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final inputs = vectors['inputs'] as Map<String, dynamic>;
    final expected = vectors['expected'] as Map<String, dynamic>;

    test('the full handshake reproduces the pinned proofs', () async {
      final initId = await edFromSeed(inputs['initiator_ed25519_seed_b64'] as String);
      final joinId = await edFromSeed(inputs['joiner_ed25519_seed_b64'] as String);
      final initPub = await initId.extractPublicKey();
      final joinPub = await joinId.extractPublicKey();

      final initiator = AgentsReconnect.initiator(
        deviceId: inputs['initiator_device_id'] as String,
        deviceKeyPair: initId,
        peerDeviceId: inputs['joiner_device_id'] as String,
        peerPublicKey: joinPub,
        channelId: inputs['channel_id'] as String,
        nonce: base64Decode(inputs['initiator_nonce_b64'] as String),
      );
      final joiner = AgentsReconnect.joiner(
        deviceId: inputs['joiner_device_id'] as String,
        deviceKeyPair: joinId,
        peerDeviceId: inputs['initiator_device_id'] as String,
        peerPublicKey: initPub,
        channelId: inputs['channel_id'] as String,
        nonce: base64Decode(inputs['joiner_nonce_b64'] as String),
      );

      final hello = initiator.createHello();
      expect(hello, expected['hello_msg']);
      final response = await joiner.onHello(hello);
      expect(response['sig'], expected['proof_j_b64']);
      expect(response, expected['response_msg']);
      final confirm = await initiator.onResponse(response);
      expect(confirm['sig'], expected['proof_i_b64']);
      expect(confirm, expected['confirm_msg']);
      await joiner.onConfirm(confirm);

      expect(initiator.authenticated, isTrue);
      expect(joiner.authenticated, isTrue);
    });
  });

  group('Agents reconnect in-process', () {
    const channel = 'chan0001deadbeef';
    const hostId = 'cowork-host';
    const appId = 'desktop-01';

    Future<(AgentsReconnect, AgentsReconnect)> makePair() async {
      final hostId0 = await AgentsDeviceKeys.generate();
      final appId0 = await AgentsDeviceKeys.generate();
      final hostPub = await hostId0.extractPublicKey();
      final appPub = await appId0.extractPublicKey();
      final initiator = AgentsReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostId0,
        peerDeviceId: appId,
        peerPublicKey: appPub,
        channelId: channel,
      );
      final joiner = AgentsReconnect.joiner(
        deviceId: appId,
        deviceKeyPair: appId0,
        peerDeviceId: hostId,
        peerPublicKey: hostPub,
        channelId: channel,
      );
      return (initiator, joiner);
    }

    test('happy path mutually authenticates', () async {
      final (initiator, joiner) = await makePair();
      final hello = initiator.createHello();
      final response = await joiner.onHello(hello);
      final confirm = await initiator.onResponse(response);
      await joiner.onConfirm(confirm);
      expect(initiator.authenticated, isTrue);
      expect(joiner.authenticated, isTrue);
      expect(initiator.peerDeviceId, appId);
      expect(joiner.peerDeviceId, hostId);
    });

    test('imposter joiner without the private key is rejected', () async {
      final hostKp = await AgentsDeviceKeys.generate();
      final realAppKp = await AgentsDeviceKeys.generate();
      final imposterKp = await AgentsDeviceKeys.generate();
      final hostPub = await hostKp.extractPublicKey();
      final realAppPub = await realAppKp.extractPublicKey();

      final initiator = AgentsReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostKp,
        peerDeviceId: appId,
        peerPublicKey: realAppPub, // host trusts the REAL app key
        channelId: channel,
      );
      final imposter = AgentsReconnect.joiner(
        deviceId: appId,
        deviceKeyPair: imposterKp, // attacker's own key
        peerDeviceId: hostId,
        peerPublicKey: hostPub,
        channelId: channel,
      );

      final hello = initiator.createHello();
      final response = await imposter.onHello(hello);
      await expectLater(
        initiator.onResponse(response),
        throwsA(
          isA<AgentsReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            AgentsReconnectRejection.badSignature,
          ),
        ),
      );
      expect(initiator.state, AgentsReconnectState.aborted);
      expect(initiator.authenticated, isFalse);
    });

    test('imposter host without the private key is rejected', () async {
      final realHostKp = await AgentsDeviceKeys.generate();
      final appKp = await AgentsDeviceKeys.generate();
      final imposterKp = await AgentsDeviceKeys.generate();
      final realHostPub = await realHostKp.extractPublicKey();
      final appPub = await appKp.extractPublicKey();

      final joiner = AgentsReconnect.joiner(
        deviceId: appId,
        deviceKeyPair: appKp,
        peerDeviceId: hostId,
        peerPublicKey: realHostPub, // app trusts the REAL host key
        channelId: channel,
      );
      final imposter = AgentsReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: imposterKp,
        peerDeviceId: appId,
        peerPublicKey: appPub,
        channelId: channel,
      );

      final hello = imposter.createHello();
      final response = await joiner.onHello(hello);
      final confirm = await imposter.onResponse(response);
      await expectLater(
        joiner.onConfirm(confirm),
        throwsA(
          isA<AgentsReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            AgentsReconnectRejection.badSignature,
          ),
        ),
      );
      expect(joiner.state, AgentsReconnectState.aborted);
      expect(joiner.authenticated, isFalse);
    });

    test('a proof recorded in an earlier session does not replay', () async {
      // Same two long-term keys, two separate sessions. The nonces differ, so
      // the transcript differs, so yesterday's genuine signature is worthless.
      final hostKp = await AgentsDeviceKeys.generate();
      final appKp = await AgentsDeviceKeys.generate();
      final hostPub = await hostKp.extractPublicKey();
      final appPub = await appKp.extractPublicKey();

      AgentsReconnect freshInitiator() => AgentsReconnect.initiator(
            deviceId: hostId,
            deviceKeyPair: hostKp,
            peerDeviceId: appId,
            peerPublicKey: appPub,
            channelId: channel,
          );
      AgentsReconnect freshJoiner() => AgentsReconnect.joiner(
            deviceId: appId,
            deviceKeyPair: appKp,
            peerDeviceId: hostId,
            peerPublicKey: hostPub,
            channelId: channel,
          );

      // Session 1: record the app's genuine response off the wire.
      final captured = await freshJoiner().onHello(freshInitiator().createHello());

      // Session 2: a new challenge. Replaying the recording must not authenticate.
      final initiator2 = freshInitiator();
      initiator2.createHello();
      await expectLater(
        initiator2.onResponse(captured),
        throwsA(
          isA<AgentsReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            AgentsReconnectRejection.badSignature,
          ),
        ),
      );
      expect(initiator2.state, AgentsReconnectState.aborted);
      expect(initiator2.authenticated, isFalse);
    });

    test('one role\'s proof cannot be reflected as the other role\'s', () async {
      // An imposter host holds no private key. All it has is the proof_j the app
      // just sent, over this very transcript. Bouncing it back as the confirm
      // must fail: the roles sign under different labels.
      final (initiator, joiner) = await makePair();
      final hello = initiator.createHello();
      final response = await joiner.onHello(hello);

      await expectLater(
        joiner.onConfirm(<String, dynamic>{
          'type': 'reconnect-confirm',
          'sig': response['sig'],
        }),
        throwsA(
          isA<AgentsReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            AgentsReconnectRejection.badSignature,
          ),
        ),
      );
      expect(joiner.state, AgentsReconnectState.aborted);
      expect(joiner.authenticated, isFalse);
    });

    test('the host\'s own proof cannot be reused as the app\'s', () async {
      // The mirror image, with the nonce pinned so the transcript matches
      // exactly — the strongest form of the swap. It still fails on the label.
      final hostKp = await AgentsDeviceKeys.generate();
      final appKp = await AgentsDeviceKeys.generate();
      final hostPub = await hostKp.extractPublicKey();
      final appPub = await appKp.extractPublicKey();

      final initiator1 = AgentsReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostKp,
        peerDeviceId: appId,
        peerPublicKey: appPub,
        channelId: channel,
      );
      final joiner1 = AgentsReconnect.joiner(
        deviceId: appId,
        deviceKeyPair: appKp,
        peerDeviceId: hostId,
        peerPublicKey: hostPub,
        channelId: channel,
      );
      final hello1 = initiator1.createHello();
      final response1 = await joiner1.onHello(hello1);
      final confirm1 = await initiator1.onResponse(response1);

      final initiator2 = AgentsReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostKp,
        peerDeviceId: appId,
        peerPublicKey: appPub,
        channelId: channel,
        nonce: base64Decode(hello1['nonce'] as String),
      );
      initiator2.createHello();
      final forged = Map<String, dynamic>.from(response1)
        ..['sig'] = confirm1['sig'];
      await expectLater(
        initiator2.onResponse(forged),
        throwsA(
          isA<AgentsReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            AgentsReconnectRejection.badSignature,
          ),
        ),
      );
      expect(initiator2.state, AgentsReconnectState.aborted);
    });

    test('a channel-id mismatch is rejected', () async {
      final (initiator, _) = await makePair();
      final otherApp = await AgentsDeviceKeys.generate();
      final hostPub =
          await (await AgentsDeviceKeys.generate()).extractPublicKey();
      final joiner = AgentsReconnect.joiner(
        deviceId: appId,
        deviceKeyPair: otherApp,
        peerDeviceId: hostId,
        peerPublicKey: hostPub,
        channelId: 'a-different-channel',
      );
      final hello = initiator.createHello();
      await expectLater(
        joiner.onHello(hello),
        throwsA(
          isA<AgentsReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            AgentsReconnectRejection.channelMismatch,
          ),
        ),
      );
    });

    test('a wrong peer device id is rejected', () async {
      final hostKp = await AgentsDeviceKeys.generate();
      final appKp = await AgentsDeviceKeys.generate();
      final hostPub = await hostKp.extractPublicKey();
      final appPub = await appKp.extractPublicKey();
      final initiator = AgentsReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostKp,
        peerDeviceId: appId,
        peerPublicKey: appPub,
        channelId: channel,
      );
      final joiner = AgentsReconnect.joiner(
        deviceId: 'someone-else',
        deviceKeyPair: appKp,
        peerDeviceId: hostId,
        peerPublicKey: hostPub,
        channelId: channel,
      );
      final hello = initiator.createHello();
      final response = await joiner.onHello(hello);
      await expectLater(
        initiator.onResponse(response),
        throwsA(
          isA<AgentsReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            AgentsReconnectRejection.wrongPeer,
          ),
        ),
      );
    });

    test('an authenticated session refuses reuse', () async {
      final (initiator, joiner) = await makePair();
      final hello = initiator.createHello();
      final response = await joiner.onHello(hello);
      final confirm = await initiator.onResponse(response);
      await joiner.onConfirm(confirm);
      expect(
        () => initiator.createHello(),
        throwsA(isA<AgentsReconnectException>()),
      );
    });
  });
}
