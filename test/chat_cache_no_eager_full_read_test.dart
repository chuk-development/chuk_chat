// Guards the rule that made a large chat history unusable:
//
// Startup must never read every chat payload. A mature cache holds tens of
// megabytes; one query over all of it exceeds what a platform-channel
// result can allocate on Android (OutOfMemoryError in
// StandardMethodCodec.encodeSuccessEnvelope) and, even where it fits, it
// parks the whole history in memory.
//
// The cache therefore exposes metadata (`loadMeta`), single chats
// (`loadById`) and SQL search (`search`) — and deliberately no "give me
// every payload" call. These tests fail if one comes back.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

File _lib(String relative) => File('lib/$relative');

Iterable<File> _dartFilesIn(String directory) sync* {
  final dir = Directory(directory);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

void main() {
  test('no cache implementation exposes a full-payload load', () {
    for (final relative in const [
      'services/local_chat_cache_native.dart',
      'services/local_chat_cache_web.dart',
    ]) {
      final source = _lib(relative).readAsStringSync();
      expect(
        source.contains('> load(String userId)'),
        isFalse,
        reason:
            '$relative declares load(userId) again. Reading every payload '
            'at once is what crashed Android startup — use loadMeta for '
            'sidebar data, loadById for one chat, search for queries.',
      );
    }
  });

  test('nothing calls LocalChatCacheService.load', () {
    final offenders = <String>[];

    for (final file in _dartFilesIn('lib')) {
      final lines = file.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains('LocalChatCacheService.load(')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These call sites read the whole chat cache at once: '
          '${offenders.join(', ')}',
    );
  });

  test('the startup path reads cache metadata, not payloads', () {
    final source = _lib('services/chat_storage_crud.dart').readAsStringSync();

    expect(
      source.contains('LocalChatCacheService.loadMeta('),
      isTrue,
      reason:
          'chat_storage_crud no longer builds the sidebar from cache '
          'metadata. Startup must not touch payloads.',
    );
  });
}
