// test/services/voice_outbox_preparer_test.dart
//
// VoiceOutboxPreparer: a queued voice row is transcribed before the send.
// The transcription call, the session and the bubble edit are faked.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/voice_outbox_preparer.dart';
import 'package:chuk_chat/services/voice_spool_service.dart';

QueuedMessage _row(
  String path, {
  String text = '',
  bool autoSend = true,
  String kind = OutboxKind.voice,
}) => QueuedMessage(
  id: 'q1',
  chatId: 'c1',
  sendPayload: <String, dynamic>{
    'chatId': 'c1',
    'messageText': text,
    'modelId': 'm',
    'providerSlug': 'p',
    'voicePath': path,
    'voiceDurationMs': 1200,
    if (!autoSend) 'autoSend': false,
  },
  attemptCount: 0,
  createdAt: 0,
  updatedAt: 0,
  kind: kind,
);

void main() {
  late Directory tmp;
  late List<String> applied;

  setUpAll(() {
    sqfliteFfiInit();
    OfflineQueueService.debugDatabaseFactory = databaseFactoryFfi;
    OfflineQueueService.debugDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voice_prep_test');
    VoiceSpoolService.baseDir = () async => tmp.path;
    applied = <String>[];
    VoiceOutboxPreparer.accessToken = () async => 'token';
    VoiceOutboxPreparer.applyTranscript = (chatId, queueId, text) async {
      applied.add('$chatId/$queueId/$text');
      return true;
    };
  });

  tearDown(() async {
    VoiceOutboxPreparer.reset();
    VoiceSpoolService.reset();
    OutboxCipher.reset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> saved() =>
      VoiceSpoolService.saveWav(Uint8List.fromList([1, 2, 3]), userId: 'u');

  group('appliesTo', () {
    test('voice row without text and with a path', () async {
      expect(VoiceOutboxPreparer.appliesTo(_row('/x.wav')), isTrue);
    });
    test('not once the text is there', () {
      expect(VoiceOutboxPreparer.appliesTo(_row('/x.wav', text: 'hi')), isFalse);
    });
    test('not for a text row or without a path', () {
      expect(
        VoiceOutboxPreparer.appliesTo(_row('/x.wav', kind: OutboxKind.text)),
        isFalse,
      );
      expect(VoiceOutboxPreparer.appliesTo(_row('')), isFalse);
    });
  });

  group('prepare', () {
    test('success puts the transcript in the payload and the bubble',
        () async {
      final path = await saved();
      VoiceOutboxPreparer.transcribe = (wav) async {
        expect(wav, Uint8List.fromList([1, 2, 3]));
        return '  hello world  ';
      };
      final r = await VoiceOutboxPreparer.prepare(_row(path));
      expect(r.success, isTrue);
      expect(r.hold, isFalse);
      expect(r.payload!['messageText'], 'hello world');
      expect(r.payload!['modelId'], 'm');
      expect(applied, ['c1/q1/hello world']);
      // The file stays until the row is gone (onDone).
      expect(File(path).existsSync(), isTrue);
    });

    test('auto-send off holds the row', () async {
      final path = await saved();
      VoiceOutboxPreparer.transcribe = (_) async => 'hi';
      final r = await VoiceOutboxPreparer.prepare(_row(path, autoSend: false));
      expect(r.success, isTrue);
      expect(r.hold, isTrue);
    });

    test('no session defers', () async {
      final path = await saved();
      VoiceOutboxPreparer.accessToken = () async => null;
      var called = false;
      VoiceOutboxPreparer.transcribe = (_) async {
        called = true;
        return 'x';
      };
      final r = await VoiceOutboxPreparer.prepare(_row(path));
      expect(r.success, isFalse);
      expect(r.deferred, isTrue);
      expect(called, isFalse);
    });

    test('network failure keeps the file and says network', () async {
      final path = await saved();
      VoiceOutboxPreparer.transcribe = (_) async => throw const SocketException(
        'Failed host lookup',
      );
      final r = await VoiceOutboxPreparer.prepare(_row(path));
      expect(r.success, isFalse);
      expect(r.deferred, isFalse);
      expect(r.error, startsWith('network:'));
      expect(File(path).existsSync(), isTrue);
      expect(applied, isEmpty);
    });

    test('a 5xx counts as network', () async {
      final path = await saved();
      VoiceOutboxPreparer.transcribe = (_) async =>
          throw const TranscriptionException('down', statusCode: 503);
      final r = await VoiceOutboxPreparer.prepare(_row(path));
      expect(r.error, startsWith('network:'));
    });

    test('a 400 is a hard failure', () async {
      final path = await saved();
      VoiceOutboxPreparer.transcribe = (_) async =>
          throw const TranscriptionException('bad audio', statusCode: 400);
      final r = await VoiceOutboxPreparer.prepare(_row(path));
      expect(r.success, isFalse);
      expect(r.error, isNot(startsWith('network')));
      expect(File(path).existsSync(), isTrue);
    });

    test('empty transcript fails', () async {
      final path = await saved();
      VoiceOutboxPreparer.transcribe = (_) async => '   ';
      final r = await VoiceOutboxPreparer.prepare(_row(path));
      expect(r.error, 'empty transcription');
    });

    test('missing recording fails', () async {
      final r = await VoiceOutboxPreparer.prepare(
        _row('${tmp.path}/gone.wav'),
      );
      expect(r.error, 'recording missing');
    });
  });

  test('onDone deletes the recording', () async {
    final path = await saved();
    await VoiceOutboxPreparer.onDone(_row(path));
    expect(File(path).existsSync(), isFalse);
    // Twice is fine.
    await VoiceOutboxPreparer.onDone(_row(path));
  });

  group('with the retry manager', () {
    setUp(() async {
      OutboxCipher.useFake(userId: 'u');
      await OfflineQueueService.instance.debugReset();
      await OfflineQueueService.instance.init();
      await OfflineQueueService.instance.debugClearAll();
      OfflineRetryManager.instance.debugReset();
      VoiceOutboxPreparer.register();
    });

    tearDown(() {
      OfflineRetryManager.instance.debugReset();
    });

    Future<String> enqueueVoice(String path, {bool autoSend = true}) =>
        OfflineQueueService.instance.enqueue(
          chatId: 'c1',
          sendPayload: _row(path, autoSend: autoSend).sendPayload,
          kind: OutboxKind.voice,
          userId: 'u',
        );

    test('transcribes, sends the text, deletes the file', () async {
      final path = await saved();
      final id = await enqueueVoice(path);
      VoiceOutboxPreparer.transcribe = (_) async => 'hello';
      final sent = <String>[];
      OfflineRetryManager.instance.registerExecutor((msg) async {
        sent.add(msg.sendPayload['messageText'] as String);
        return const SendExecutorResult.success();
      });

      await OfflineRetryManager.instance.debugDrain(manual: true);

      expect(sent, ['hello']);
      expect(await OfflineQueueService.instance.getById(id), isNull);
      expect(File(path).existsSync(), isFalse);
    });

    test('network failure keeps row queued and file on disk', () async {
      final path = await saved();
      final id = await enqueueVoice(path);
      VoiceOutboxPreparer.transcribe = (_) async =>
          throw const SocketException('Network is unreachable');
      var sends = 0;
      OfflineRetryManager.instance.registerExecutor((msg) async {
        sends++;
        return const SendExecutorResult.success();
      });

      await OfflineRetryManager.instance.debugDrain(manual: true);

      final row = await OfflineQueueService.instance.getById(id);
      expect(row, isNotNull);
      expect(row!.state, OutboxState.queued);
      expect(row.lastError, startsWith('network:'));
      expect(sends, 0);
      expect(File(path).existsSync(), isTrue);
    });

    test('auto-send off: row is held with the transcript', () async {
      final path = await saved();
      final id = await enqueueVoice(path, autoSend: false);
      VoiceOutboxPreparer.transcribe = (_) async => 'later';
      var sends = 0;
      OfflineRetryManager.instance.registerExecutor((msg) async {
        sends++;
        return const SendExecutorResult.success();
      });

      await OfflineRetryManager.instance.debugDrain(manual: true);

      final row = await OfflineQueueService.instance.getById(id);
      expect(row!.state, OutboxState.held);
      expect(row.sendPayload['messageText'], 'later');
      expect(sends, 0);
      expect(File(path).existsSync(), isTrue);
    });
  });
}
