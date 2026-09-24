// Proof of payload v3 on a real chat history, and the sizes it gives.
//
// Opt-in: reads the read-only copy of a production chat cache under
// `_scratch/dbcopy/chat_cache.db` (not in git). Run it with
//
//   CHUK_REAL_DATA=1 flutter test test/manual/chat_payload_v3_real_data_test.dart
//
// For every chat: v2 -> messages must equal v2 -> v3 -> sealed -> opened ->
// messages. Prints counts and sizes only, never content.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/payload_compression.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _dbPath = '_scratch/dbcopy/chat_cache.db';

String _stats(List<int> sizes) {
  final xs = [...sizes]..sort();
  final n = xs.length;
  final total = xs.fold<int>(0, (a, b) => a + b);
  String kb(num v) => (v / 1000).toStringAsFixed(1);
  return 'avg ${kb(total / n)} kB, p90 ${kb(xs[(n * 0.9).floor()])} kB, '
      'max ${kb(xs.last)} kB, total ${(total / 1e6).toStringAsFixed(2)} MB';
}

Future<String> _sealV1(String text, List<int> key) async {
  final rng = Random.secure();
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(text),
    secretKey: SecretKey(key),
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

List<String> _inMemory(DecodedChatPayload p) => [
  for (final m in p.messages) jsonEncode(ChatMessage.fromJson(m).toJson()),
];

void main() {
  final enabled =
      Platform.environment['CHUK_REAL_DATA'] == '1' &&
      File(_dbPath).existsSync();

  test(
    'v3 is lossless on every real chat, and this is what it saves',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(
        File(_dbPath).absolute.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final rows = await db.rawQuery('SELECT payload FROM chat_cache');
      final rng = Random.secure();
      final key = List<int>.generate(32, (_) => rng.nextInt(256));

      final v2Json = <int>[], v3Json = <int>[];
      final cloudBefore = <int>[], cloudAfter = <int>[];
      final cacheBefore = <int>[], cacheAfter = <int>[];
      final codecs = <int, int>{};
      var mismatches = 0, failures = 0;
      final clock = Stopwatch()..start();

      for (final row in rows) {
        try {
          final stored = row['payload'];
          final original = stored is String
              ? stored
              : decodeStoredPayload(stored as List<int>);
          final decoded = decodeChatPayload(original);
          final messages = [
            for (final m in decoded.messages) ChatMessage.fromJson(m).toJson(),
          ];
          final v2 = jsonEncode({
            'v': 2,
            'messages': messages,
            'customName': ?decoded.customName,
          });
          final v3 = encodeChatPayload(
            messages,
            customName: decoded.customName,
          );

          final sealed = await sealChatPayload(
            json: v3,
            keyBytes: key,
            keyVersion: 1,
          );
          final opened = decodeChatPayload(await openEnvelopeText(sealed, key));
          final reference = decodeChatPayload(v2);
          if (jsonEncode(_inMemory(opened)) !=
                  jsonEncode(_inMemory(reference)) ||
              opened.customName != reference.customName) {
            mismatches++;
          }

          final codec = compressPayloadStrong(v3)[1];
          codecs[codec] = (codecs[codec] ?? 0) + 1;
          v2Json.add(utf8.encode(v2).length);
          v3Json.add(utf8.encode(v3).length);
          cloudBefore.add((await _sealV1(v2, key)).length);
          cloudAfter.add(sealed.length);
          cacheBefore.add(GZipCodec(level: 4).encode(utf8.encode(v2)).length);
          cacheAfter.add(compressPayloadFast(v3).length);
        } catch (e) {
          failures++;
          print('failure: ${e.runtimeType}');
        }
      }
      await db.close();

      print(
        'chats: ${rows.length}, mismatches: $mismatches, '
        'failures: $failures, ${clock.elapsed.inSeconds} s',
      );
      print('codec chosen for the cloud (1 = deflate, 2 = bzip2): $codecs');
      print('plaintext v2 JSON      ${_stats(v2Json)}');
      print('plaintext v3 JSON      ${_stats(v3Json)}');
      print('cloud before (v1 env.) ${_stats(cloudBefore)}');
      print('cloud after  (v2 env.) ${_stats(cloudAfter)}');
      print('cache before (gzip 4)  ${_stats(cacheBefore)}');
      print('cache after  (frame)   ${_stats(cacheAfter)}');

      expect(mismatches, 0);
      expect(failures, 0);
    },
    skip: enabled ? false : 'set CHUK_REAL_DATA=1 and provide $_dbPath',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
