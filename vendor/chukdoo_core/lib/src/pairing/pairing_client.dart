import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../credentials.dart';
import '../crypto/pairing_crypto.dart';

/// Pairing failed for good (expired, unknown, bad payload).
class PairingException implements Exception {
  final String message;
  const PairingException(this.message);
  @override
  String toString() => 'PairingException: $message';
}

/// Device side of pairing.
///
/// ```dart
/// final client = PairingClient(supabaseUrl: url, anonKey: key);
/// final session = await client.start(deviceName: 'Claude Code', deviceKind: 'mcp');
/// print(session.displayCode); // user types this into the app
/// final creds = await session.waitForApproval();
/// ```
class PairingClient {
  final String supabaseUrl;
  final String anonKey;
  final SupabaseRpc _rpc;

  PairingClient({
    required this.supabaseUrl,
    required this.anonKey,
    http.Client? client,
  }) : _rpc = SupabaseRpc(
          supabaseUrl: supabaseUrl,
          anonKey: anonKey,
          client: client,
        );

  /// Creates a key pair, registers the request and returns the session that
  /// holds the code to show.
  Future<PairingSession> start({
    required String deviceName,
    String deviceKind = 'mcp',
  }) async {
    // A code collision is astronomically unlikely, but retry once anyway.
    for (var attempt = 0; attempt < 3; attempt++) {
      final keyPair = await PairingCrypto.newKeyPair();
      final publicKey = (await keyPair.extractPublicKey()).bytes;
      final code = PairingCrypto.codeForPublicKey(publicKey);
      final pollSecret = PairingCrypto.randomHex(32);
      try {
        final result = await _rpc.call('pairing_open', {
          'code_hash': PairingCrypto.codeHash(code),
          'public_key': base64Encode(publicKey),
          'device_name': deviceName,
          'device_kind': deviceKind,
          'poll_hash': PairingCrypto.sha256Hex(pollSecret),
        });
        final expires = DateTime.tryParse(
                (result as Map?)?['expires_at']?.toString() ?? '') ??
            DateTime.now().add(const Duration(minutes: 10));
        return PairingSession._(
          client: this,
          keyPair: keyPair,
          code: code,
          pollSecret: pollSecret,
          deviceName: deviceName,
          expiresAt: expires.toLocal(),
        );
      } on ChukdooApiException catch (e) {
        if (e.code == '23505' && attempt < 2) continue;
        rethrow;
      }
    }
    throw const PairingException('Could not open a pairing request.');
  }

  void close() => _rpc.close();
}

/// Lifecycle states reported while waiting.
enum PairingStatus { pending, approved, expired, unknown }

class PairingSession {
  final PairingClient _client;
  final SimpleKeyPair _keyPair;
  final String _pollSecret;

  /// Normalized code, e.g. `7K3QZ9M2XA`.
  final String code;
  final String deviceName;
  final DateTime expiresAt;

  PairingSession._({
    required PairingClient client,
    required SimpleKeyPair keyPair,
    required this.code,
    required String pollSecret,
    required this.deviceName,
    required this.expiresAt,
  })  : _client = client,
        _keyPair = keyPair,
        _pollSecret = pollSecret;

  /// The code as the user should see and type it: `7K3QZ-9M2XA`.
  String get displayCode => PairingCrypto.formatCode(code);

  /// Polls until the user approves in the app, then opens the sealed data
  /// key and returns the credentials. Throws [PairingException] on expiry.
  Future<ChukdooCredentials> waitForApproval({
    Duration interval = const Duration(seconds: 2),
    Duration? timeout,
    void Function(PairingStatus status)? onStatus,
  }) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    final codeHash = PairingCrypto.codeHash(code);
    var transientErrors = 0;
    while (true) {
      if (deadline != null && DateTime.now().isAfter(deadline)) {
        throw const PairingException('Timed out waiting for approval.');
      }
      Map<String, dynamic> result;
      try {
        result = Map<String, dynamic>.from(await _client._rpc.call(
          'pairing_poll',
          {'code_hash': codeHash, 'poll_secret': _pollSecret},
        ) as Map);
        transientErrors = 0;
      } on ChukdooApiException {
        rethrow;
      } catch (_) {
        // Network hiccup: keep trying for a while.
        if (++transientErrors > 15) rethrow;
        await Future<void>.delayed(interval);
        continue;
      }
      switch (result['status']) {
        case 'approved':
          onStatus?.call(PairingStatus.approved);
          return _finish(result);
        case 'expired':
          onStatus?.call(PairingStatus.expired);
          throw const PairingException(
              'The pairing code expired. Run setup again.');
        case 'unknown':
          onStatus?.call(PairingStatus.unknown);
          throw const PairingException(
              'The pairing request is gone (expired or already used).');
        default:
          onStatus?.call(PairingStatus.pending);
      }
      await Future<void>.delayed(interval);
    }
  }

  Future<ChukdooCredentials> _finish(Map<String, dynamic> result) async {
    final sealed = result['sealed_payload'] as String?;
    final token = result['device_token'] as String?;
    final deviceId = result['device_id']?.toString();
    if (sealed == null || token == null || deviceId == null) {
      throw const PairingException('Approval response is incomplete.');
    }
    final Map<String, dynamic> payload;
    try {
      payload = await PairingCrypto.open(sealed, _keyPair);
    } catch (e) {
      throw PairingException('Could not open the sealed key: $e');
    }
    final userId = payload['user_id'] as String?;
    final dataKey = payload['data_key'] as String?;
    if (userId == null || dataKey == null || base64Decode(dataKey).length != 32) {
      throw const PairingException('Sealed payload is malformed.');
    }
    return ChukdooCredentials(
      supabaseUrl: _client.supabaseUrl,
      anonKey: _client.anonKey,
      userId: userId,
      deviceId: deviceId,
      deviceToken: token,
      dataKey: dataKey,
      deviceName: deviceName,
      pairedAt: DateTime.now().toUtc(),
    );
  }
}

/// App side of pairing: verify the code against the public key the server
/// returned, then seal the data key to it. Transport-free so the Flutter app
/// can call the RPCs with its own authenticated Supabase client.
class PairingApprover {
  const PairingApprover._();

  /// Throws [PairingException] if [typedCode] does not belong to
  /// [publicKeyBase64] (a swapped key), else returns the sealed payload for
  /// `pairing_approve`.
  static Future<String> sealDataKey({
    required String typedCode,
    required String publicKeyBase64,
    required String userId,
    required List<int> dataKey,
  }) async {
    final List<int> publicKey;
    try {
      publicKey = base64Decode(publicKeyBase64);
    } on FormatException {
      throw const PairingException('The device key is malformed.');
    }
    if (publicKey.length != 32 ||
        !PairingCrypto.codeMatchesPublicKey(typedCode, publicKey)) {
      throw const PairingException(
          'The code does not match the device key. Do not approve.');
    }
    if (dataKey.length != 32) {
      throw const PairingException('The data key is not 32 bytes.');
    }
    return PairingCrypto.seal(
      PairingCrypto.buildKeyPayload(userId: userId, dataKey: dataKey),
      publicKey,
    );
  }
}
