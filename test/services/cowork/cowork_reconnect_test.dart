import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_reconnect.dart';

/// Reconnect handshake tests: the cross-language vector (byte-for-byte against
/// the Python twin), the full in-process mutual challenge, and the
/// imposter-rejection paths — a forged signature on either side is refused and
/// the session aborts with no channel resumed.
///
/// The vector fixture `test/fixtures/cowork_reconnect_vectors.json` is generated
/// by `common/cowork_crypto/tests/gen_reconnect_vectors.py`. Ed25519 is
/// deterministic from its private bytes (RFC 8032), so with the same fixed
/// nonces + seeds the Dart code must reproduce every proof byte the Python side
/// pinned.
void main() {
  Future<SimpleKeyPair> edFromSeed(String seedB64) =>
      CoworkDeviceKeys.fromSeed(base64Decode(seedB64));

  group('CoWork reconnect cross-language vector', () {
    final Map<String, dynamic> vectors = jsonDecode(
      File('test/fixtures/cowork_reconnect_vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final inputs = vectors['inputs'] as Map<String, dynamic>;
    final expected = vectors['expected'] as Map<String, dynamic>;

    test('the full handshake reproduces the pinned proofs', () async {
      final initId = await edFromSeed(inputs['initiator_ed25519_seed_b64'] as String);
      final joinId = await edFromSeed(inputs['joiner_ed25519_seed_b64'] as String);
      final initPub = await initId.extractPublicKey();
      final joinPub = await joinId.extractPublicKey();

      final initiator = CoworkReconnect.initiator(
        deviceId: inputs['initiator_device_id'] as String,
        deviceKeyPair: initId,
        peerDeviceId: inputs['joiner_device_id'] as String,
        peerPublicKey: joinPub,
        channelId: inputs['channel_id'] as String,
        nonce: base64Decode(inputs['initiator_nonce_b64'] as String),
      );
      final joiner = CoworkReconnect.joiner(
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

  group('CoWork reconnect in-process', () {
    const channel = 'chan0001deadbeef';
    const hostId = 'cowork-host';
    const appId = 'desktop-01';

    Future<(CoworkReconnect, CoworkReconnect)> makePair() async {
      final hostId0 = await CoworkDeviceKeys.generate();
      final appId0 = await CoworkDeviceKeys.generate();
      final hostPub = await hostId0.extractPublicKey();
      final appPub = await appId0.extractPublicKey();
      final initiator = CoworkReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostId0,
        peerDeviceId: appId,
        peerPublicKey: appPub,
        channelId: channel,
      );
      final joiner = CoworkReconnect.joiner(
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
      final hostKp = await CoworkDeviceKeys.generate();
      final realAppKp = await CoworkDeviceKeys.generate();
      final imposterKp = await CoworkDeviceKeys.generate();
      final hostPub = await hostKp.extractPublicKey();
      final realAppPub = await realAppKp.extractPublicKey();

      final initiator = CoworkReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostKp,
        peerDeviceId: appId,
        peerPublicKey: realAppPub, // host trusts the REAL app key
        channelId: channel,
      );
      final imposter = CoworkReconnect.joiner(
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
          isA<CoworkReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkReconnectRejection.badSignature,
          ),
        ),
      );
      expect(initiator.state, CoworkReconnectState.aborted);
      expect(initiator.authenticated, isFalse);
    });

    test('imposter host without the private key is rejected', () async {
      final realHostKp = await CoworkDeviceKeys.generate();
      final appKp = await CoworkDeviceKeys.generate();
      final imposterKp = await CoworkDeviceKeys.generate();
      final realHostPub = await realHostKp.extractPublicKey();
      final appPub = await appKp.extractPublicKey();

      final joiner = CoworkReconnect.joiner(
        deviceId: appId,
        deviceKeyPair: appKp,
        peerDeviceId: hostId,
        peerPublicKey: realHostPub, // app trusts the REAL host key
        channelId: channel,
      );
      final imposter = CoworkReconnect.initiator(
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
          isA<CoworkReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkReconnectRejection.badSignature,
          ),
        ),
      );
      expect(joiner.state, CoworkReconnectState.aborted);
      expect(joiner.authenticated, isFalse);
    });

    test('a channel-id mismatch is rejected', () async {
      final (initiator, _) = await makePair();
      final otherApp = await CoworkDeviceKeys.generate();
      final hostPub =
          await (await CoworkDeviceKeys.generate()).extractPublicKey();
      final joiner = CoworkReconnect.joiner(
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
          isA<CoworkReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkReconnectRejection.channelMismatch,
          ),
        ),
      );
    });

    test('a wrong peer device id is rejected', () async {
      final hostKp = await CoworkDeviceKeys.generate();
      final appKp = await CoworkDeviceKeys.generate();
      final hostPub = await hostKp.extractPublicKey();
      final appPub = await appKp.extractPublicKey();
      final initiator = CoworkReconnect.initiator(
        deviceId: hostId,
        deviceKeyPair: hostKp,
        peerDeviceId: appId,
        peerPublicKey: appPub,
        channelId: channel,
      );
      final joiner = CoworkReconnect.joiner(
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
          isA<CoworkReconnectException>().having(
            (e) => e.rejection,
            'rejection',
            CoworkReconnectRejection.wrongPeer,
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
        throwsA(isA<CoworkReconnectException>()),
      );
    });
  });
}
