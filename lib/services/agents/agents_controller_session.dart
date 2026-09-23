/// Account-pairing recovery with independent per-connection traffic keys.
/// The signing identity stays on this device; only encrypted pairing trust is
/// shared through the account. Python twin: controller_sessions.py.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'agents_pairing_store.dart';
import 'agents_reconnect.dart';

class AgentsControllerSession {
  AgentsControllerSession(this.deviceId, this.identity, this.trust);

  final String deviceId;
  final SimpleKeyPair identity;
  final AgentsStoredPairing trust;
  final String nonce = base64Encode(AgentsReconnectCrypto.randomNonce());
  String? connection;
  String? _public;
  List<int>? _transcript;
  Uint8List? trafficKey;
  bool authenticated = false;

  Future<Map<String, dynamic>> resume() async {
    _public = base64Encode((await identity.extractPublicKey()).bytes);
    return {
      'type': 'controller_resume',
      'channel': trust.channelId,
      'device_id': deviceId,
      'public_key': _public,
      'client_nonce': nonce,
    };
  }

  Future<Uint8List> _mac(List<int> key, String label) async =>
      Uint8List.fromList(
        (await Hmac.sha256().calculateMac([
          ...utf8.encode(label),
          ..._transcript!,
        ], secretKey: SecretKey(key))).bytes,
      );

  Future<Map<String, dynamic>?> challenge(Map<String, dynamic> message) async {
    if (message['device_id'] != deviceId || message['client_nonce'] != nonce) {
      return null;
    }
    if (connection != null || _public == null) return null;
    final host = message['host_nonce'] as String;
    if (base64Decode(host).length != 32) {
      throw const FormatException('host nonce');
    }
    final signed = utf8.encode(
      jsonEncode([trust.channelId, deviceId, _public, nonce, host]),
    );
    final valid = await Ed25519().verify(
      [...utf8.encode('cowork/controller/host/'), ...signed],
      signature: Signature(
        base64Decode(message['signature'] as String),
        publicKey: trust.peerPublicKey,
      ),
    );
    if (!valid) throw const FormatException('host signature');
    connection = message['connection'] as String;
    _transcript = signed;
    trafficKey = await _mac(trust.channelKey, 'cowork/controller/traffic/');
    final proof = await _mac(trust.channelKey, 'cowork/controller/approve/');
    final signature = await Ed25519().sign([
      ...utf8.encode('cowork/controller/device/'),
      ...signed,
    ], keyPair: identity);
    return {
      'type': 'controller_proof',
      'connection': connection,
      'proof': base64Encode(proof),
      'signature': base64Encode(signature.bytes),
    };
  }

  Future<bool> ready(Map<String, dynamic> message) async {
    if (connection == null ||
        message['connection'] != connection ||
        authenticated) {
      return false;
    }
    final actual = base64Decode(message['proof'] as String);
    final expected = await _mac(trafficKey!, 'cowork/controller/ready/');
    var difference = actual.length ^ expected.length;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ (i < actual.length ? actual[i] : 0);
    }
    if (difference != 0) throw const FormatException('host confirmation');
    authenticated = true;
    return true;
  }
}
