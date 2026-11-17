/// Opens the sealed answer preview of a push (docs/agents/NOTIFICATIONS.md,
/// "Sealed preview").
///
/// The push goes through Supabase and FCM (or a UnifiedPush distributor).
/// That path is not end-to-end, so the host seals the preview with a key
/// that only the paired devices hold:
///
/// ```
/// push_key = HMAC-SHA256(channel_key, utf8("cowork/push/preview/v1"))
/// sealed   = base64(nonce(12) || ciphertext || tag(16))   AES-256-GCM, no AAD
/// ```
///
/// The data map of the push carries `preview_sealed`: a JSON object (or its
/// JSON text) from channel id to sealed value. This file is pure Dart, so the
/// background isolate and the tests can use it without a platform channel.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The HMAC label of the push key. Must match the host.
const String kPushPreviewLabel = 'cowork/push/preview/v1';

const int _kNonceLength = 12;
const int _kTagLength = 16;

/// The opened plaintext of a sealed preview.
class SealedPreview {
  const SealedPreview({
    required this.title,
    required this.body,
    this.agentId,
    this.sessionKey,
    this.runId,
  });

  final String title;
  final String body;
  final String? agentId;
  final String? sessionKey;
  final String? runId;

  /// Reads the plaintext JSON. Returns null when it is not version 1 or
  /// when the title or body is missing.
  static SealedPreview? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    if (decoded['v'] != 1) return null;
    final Object? title = decoded['title'];
    final Object? body = decoded['body'];
    if (title is! String || body is! String) return null;
    return SealedPreview(
      title: title,
      body: body,
      agentId: _text(decoded['agent_id']),
      sessionKey: _text(decoded['session_key']),
      runId: _text(decoded['run_id']),
    );
  }

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

/// The push key of a pairing: HMAC-SHA256 over the label, keyed with the
/// 32-byte channel key.
Future<Uint8List> derivePushPreviewKey(List<int> channelKey) async {
  final Mac mac = await Hmac.sha256().calculateMac(
    utf8.encode(kPushPreviewLabel),
    secretKey: SecretKey(List<int>.of(channelKey)),
  );
  return Uint8List.fromList(mac.bytes);
}

/// Opens one sealed value with [channelKey]. Returns null on any failure:
/// bad base64, a short value, a wrong key (tag check) or bad plaintext.
Future<SealedPreview?> openSealedPreview(
  String sealed,
  List<int> channelKey,
) async {
  try {
    final Uint8List raw = base64.decode(sealed.trim());
    if (raw.length < _kNonceLength + _kTagLength) return null;
    final Uint8List key = await derivePushPreviewKey(channelKey);
    final SecretBox box = SecretBox(
      raw.sublist(_kNonceLength, raw.length - _kTagLength),
      nonce: raw.sublist(0, _kNonceLength),
      mac: Mac(raw.sublist(raw.length - _kTagLength)),
    );
    final List<int> clear = await AesGcm.with256bits().decrypt(
      box,
      secretKey: SecretKey(key),
    );
    return SealedPreview.fromJson(jsonDecode(utf8.decode(clear)));
  } catch (_) {
    // Any failure means "cannot open". The caller shows the generic text.
    return null;
  }
}

/// Finds the sealed value for [channelId] in the push [data] and opens it.
/// `preview_sealed` can be a map or the JSON text of a map (FCM data values
/// are strings). Returns null when there is no value for this channel or it
/// does not open.
Future<SealedPreview?> openPreviewFromPushData(
  Map<Object?, Object?> data, {
  required String channelId,
  required List<int> channelKey,
}) async {
  final Map<Object?, Object?>? sealedByChannel = _sealedMap(
    data['preview_sealed'],
  );
  final Object? sealed = sealedByChannel?[channelId];
  if (sealed is! String || sealed.isEmpty) return null;
  return openSealedPreview(sealed, channelKey);
}

Map<Object?, Object?>? _sealedMap(Object? value) {
  if (value is Map) return value;
  if (value is String && value.isNotEmpty) {
    try {
      final Object? decoded = jsonDecode(value);
      if (decoded is Map) return decoded;
    } catch (_) {
      return null;
    }
  }
  return null;
}
