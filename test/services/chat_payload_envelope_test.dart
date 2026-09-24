// The compressed chat envelope (v "2") and the payload frame, and what an
// app from before v3 does when it meets them.
//
// Old clients cannot read v3. That is accepted; what they must not do is
// misread a v3 chat or write something over it. The "old client" functions
// below are copied verbatim from the reader of the last release before v3
// (encryption_service.dart, local_chat_cache_native.dart and
// chat_storage_sync.dart at 81d21673).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/payload_compression.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── The old client (verbatim, v1 envelopes only) ──────────────────────────

const String _oldPayloadVersion = '1';

Future<String> _oldDecryptString(String encrypted, List<int> keyBytes) async {
  final cipher = AesGcm.with256bits();
  final secretKey = SecretKey(keyBytes);

  final Map<String, dynamic> payload = jsonDecode(encrypted);
  final version = payload['v'];
  if (version != _oldPayloadVersion) {
    throw StateError('Unsupported ciphertext version: $version');
  }

  final nonce = base64Decode(payload['nonce'] as String);
  final cipherText = base64Decode(payload['ciphertext'] as String);
  final mac = Mac(base64Decode(payload['mac'] as String));
  final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

  final cleartextBytes = await cipher.decrypt(secretBox, secretKey: secretKey);

  return utf8.decode(cleartextBytes);
}

Future<List<String?>> _oldDecryptBatch(
  List<String> encryptedList,
  List<int> keyBytes,
) async {
  final cipher = AesGcm.with256bits();
  final secretKey = SecretKey(keyBytes);
  final results = <String?>[];

  for (final encrypted in encryptedList) {
    try {
      final Map<String, dynamic> payload = jsonDecode(encrypted);
      final version = payload['v'];
      if (version != _oldPayloadVersion) {
        results.add(null);
        continue;
      }

      final nonce = base64Decode(payload['nonce'] as String);
      final cipherText = base64Decode(payload['ciphertext'] as String);
      final mac = Mac(base64Decode(payload['mac'] as String));
      final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

      final cleartextBytes = await cipher.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      results.add(utf8.decode(cleartextBytes));
    } catch (_) {
      results.add(null);
    }
  }

  return results;
}

final GZipCodec _oldCacheCodec = GZipCodec(level: 4);

String _oldDecodeCachePayload(Object? stored) {
  if (stored is String) return stored;
  if (stored is List<int>) {
    return utf8.decode(_oldCacheCodec.decode(stored));
  }
  throw StateError('Unsupported payload storage type: ${stored.runtimeType}');
}

// ─── Helpers ──────────────────────────────────────────────────────────────

List<int> _key() {
  final rng = Random.secure();
  return List<int>.generate(32, (_) => rng.nextInt(256));
}

/// A v1 envelope as every app writes it for titles and old chats.
Future<String> _sealV1(String text, List<int> keyBytes) async {
  final rng = Random.secure();
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(text),
    secretKey: SecretKey(keyBytes),
    nonce: List<int>.generate(12, (_) => rng.nextInt(256)),
  );
  return jsonEncode({
    'v': '1',
    'kv': 1,
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  });
}

String _chatJson({int rounds = 30}) {
  final calls = [
    for (var i = 0; i < rounds; i++)
      {
        'id': 'call_$i',
        'name': 'web_search',
        'arguments': '{"q":"frage $i"}',
        'status': 'completed',
        'result': List.filled(40, 'Ergebnis $i mit Text. ').join(),
      },
  ];
  return encodeChatPayload([
    ChatMessage(role: 'user', text: 'Hallo').toJson(),
    ChatMessage(
      role: 'assistant',
      text: 'Antwort',
      toolCalls: jsonEncode(calls),
      contentBlocks: jsonEncode([
        {'type': 'toolCalls', 'toolCalls': calls},
      ]),
    ).toJson(),
  ], customName: 'Test');
}

void main() {
  group('payload frame', () {
    test('strong frame round trips and picks the smaller codec', () {
      final text = _chatJson();
      final frame = compressPayloadStrong(text);
      expect(isPayloadFrame(frame), isTrue);
      expect(frame[1], anyOf(PayloadCodec.bzip2, PayloadCodec.deflate));
      expect(utf8.decode(decompressPayloadFrame(frame)), text);
      expect(frame.length, lessThan(utf8.encode(text).length ~/ 5));
    });

    test('deflate-only and fast frames round trip', () {
      final text = _chatJson(rounds: 3);
      final strong = compressPayloadStrong(text, allowBzip2: false);
      expect(strong[1], PayloadCodec.deflate);
      expect(decodeStoredPayload(strong), text);
      expect(decodeStoredPayload(compressPayloadFast(text)), text);
      expect(decodeStoredPayload(compressPayloadFast('')), '');
    });

    test('old cache rows (gzip, plain UTF-8) still read', () {
      const json = '{"v":2,"messages":[]}';
      expect(decodeStoredPayload(gzip.encode(utf8.encode(json))), json);
      expect(decodeStoredPayload(utf8.encode(json)), json);
    });

    test('an unknown codec or a wrong length is an error, not garbage', () {
      final frame = compressPayloadFast('{"v":3,"messages":[]}');
      final unknown = Uint8List.fromList(frame)..[1] = 9;
      expect(() => decompressPayloadFrame(unknown), throwsFormatException);
      final wrongLength = Uint8List.fromList(frame)..[2] = frame[2] + 1;
      expect(() => decompressPayloadFrame(wrongLength), throwsFormatException);
    });

    test('JSON text is never taken for a frame', () {
      for (final s in ['{"v":2}', '[1]', ' {"a":1}', '"x"']) {
        expect(isPayloadFrame(utf8.encode(s.padRight(8))), isFalse);
      }
    });
  });

  group('compressed envelope', () {
    test('seal and open round trip; the envelope says v "2"', () async {
      final key = _key();
      final json = _chatJson();
      final sealed = await sealChatPayload(
        json: json,
        keyBytes: key,
        keyVersion: 3,
      );
      expect(envelopeVersionOf(sealed), kCompressedEnvelopeVersion);
      expect(EncryptionService.extractKeyVersion(sealed), 3);
      expect(await openEnvelopeText(sealed, key), json);
      // Much smaller than the v1 envelope of the same JSON.
      expect(sealed.length, lessThan((await _sealV1(json, key)).length ~/ 4));
    });

    test('the new reader still opens v1 envelopes', () async {
      final key = _key();
      const v2Json = '{"v":2,"messages":[{"role":"user","text":"hi"}]}';
      expect(await openEnvelopeText(await _sealV1(v2Json, key), key), v2Json);
    });

    test('a wrong key fails authentication', () async {
      final sealed = await sealChatPayload(
        json: _chatJson(rounds: 2),
        keyBytes: _key(),
        keyVersion: 1,
      );
      expect(
        () => openEnvelopeText(sealed, _key()),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('convertChatEnvelopeToV3 proves and converts a v1/v2 chat', () async {
      final key = _key();
      final v2Json = jsonEncode({
        'v': 2,
        'messages': decodeChatPayload(_chatJson()).messages,
        'customName': 'Test',
      });
      final converted = await convertChatEnvelopeToV3(
        encrypted: await _sealV1(v2Json, key),
        keyBytes: key,
        keyVersion: 1,
      );
      expect(converted, isNotNull);
      expect(peekChatPayloadVersion(converted!.payloadJson), 3);
      expect(envelopeVersionOf(converted.envelope), kCompressedEnvelopeVersion);
      final back = decodeChatPayload(
        await openEnvelopeText(converted.envelope, key),
      );
      expect(chatPayloadsEquivalent(back, decodeChatPayload(v2Json)), isTrue);
    });
  });

  group('an old client meets v3', () {
    test('decrypt throws on the version check, before any bytes', () async {
      final key = _key();
      final sealed = await sealChatPayload(
        json: _chatJson(),
        keyBytes: key,
        keyVersion: 1,
      );
      await expectLater(
        _oldDecryptString(sealed, key),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Unsupported ciphertext version: 2',
          ),
        ),
      );
    });

    test('batch decrypt yields null: a locked placeholder, never a '
        'readable (and so writable) chat', () async {
      final key = _key();
      final v3 = await sealChatPayload(
        json: _chatJson(),
        keyBytes: key,
        keyVersion: 1,
      );
      final title = await _sealV1('Test', key);
      final results = await _oldDecryptBatch([v3, title], key);
      expect(results[0], isNull);
      // Titles stay v1 envelopes: the old sidebar still shows the name.
      expect(results[1], 'Test');
    });

    test('a v3 cache row fails to decode instead of being misread', () {
      // Every row is framed, even a short one (see
      // LocalChatCacheService._encodePayload), so an old app never gets
      // v3 JSON it would read as v1.
      final short = compressPayloadFast('{"v":3,"messages":[]}');
      final long = compressPayloadFast(_chatJson());
      expect(() => _oldDecodeCachePayload(short), throwsFormatException);
      expect(() => _oldDecodeCachePayload(long), throwsFormatException);
    });
  });
}
