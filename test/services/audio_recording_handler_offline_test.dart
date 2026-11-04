// test/services/audio_recording_handler_offline_test.dart
//
// AudioRecordingHandler.finishWav: the recording is on disk before the
// transcription runs. A network failure keeps it (queueable); success and a
// hard failure delete it.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'
    show TranscriptionException;
import 'package:chuk_chat/platform_specific/chat/handlers/audio_recording_handler.dart';
import 'package:chuk_chat/services/voice_spool_service.dart';

void main() {
  late Directory tmp;
  final wav = Uint8List.fromList([1, 2, 3, 4]);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voice_handler_test');
    VoiceSpoolService.baseDir = () async => tmp.path;
    VoiceSpoolService.useFakeCipher();
  });

  tearDown(() async {
    VoiceSpoolService.reset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> saved() => VoiceSpoolService.saveWav(wav, userId: 'u');

  Future<TranscriptionResult> run(
    String? path,
    Future<String> Function(Uint8List, String) upload, {
    String? token = 'tok',
    Future<String?> Function()? refresh,
  }) => AudioRecordingHandler.finishWav(
    wav: wav,
    savedPath: path,
    durationMs: 1500,
    accessToken: token,
    upload: upload,
    refreshToken: refresh,
  );

  test('success returns the text and deletes the file', () async {
    final path = await saved();
    final r = await run(path, (_, _) async => ' hi ');
    expect(r.success, isTrue);
    expect(r.text, 'hi');
    expect(r.queueable, isFalse);
    expect(r.durationMs, 1500);
    expect(File(path).existsSync(), isFalse);
  });

  test('no token keeps the file and is queueable', () async {
    final path = await saved();
    var called = false;
    final r = await run(path, (_, _) async {
      called = true;
      return 'x';
    }, token: null);
    expect(called, isFalse);
    expect(r.success, isFalse);
    expect(r.queueable, isTrue);
    expect(r.savedPath, path);
    expect(r.durationMs, 1500);
    expect(File(path).existsSync(), isTrue);
  });

  test('socket error keeps the file', () async {
    final path = await saved();
    final r = await run(
      path,
      (_, _) async => throw const TranscriptionException(
        'Network error: SocketException: Failed host lookup',
      ),
    );
    expect(r.queueable, isTrue);
    expect(r.savedPath, path);
    expect(File(path).existsSync(), isTrue);
  });

  test('timeout and 503 keep the file', () async {
    final p1 = await saved();
    final r1 = await run(p1, (_, _) async => throw TimeoutException('t'));
    expect(r1.queueable, isTrue);
    final p2 = await saved();
    final r2 = await run(
      p2,
      (_, _) async =>
          throw const TranscriptionException('down', statusCode: 503),
    );
    expect(r2.queueable, isTrue);
    expect(File(p2).existsSync(), isTrue);
  });

  test('400 deletes the file and is not queueable', () async {
    final path = await saved();
    final r = await run(
      path,
      (_, _) async =>
          throw const TranscriptionException('bad audio', statusCode: 400),
    );
    expect(r.success, isFalse);
    expect(r.queueable, isFalse);
    expect(r.error, 'bad audio');
    expect(File(path).existsSync(), isFalse);
  });

  test('empty transcript deletes the file', () async {
    final path = await saved();
    final r = await run(path, (_, _) async => '  ');
    expect(r.error, 'No text found');
    expect(r.queueable, isFalse);
    expect(File(path).existsSync(), isFalse);
  });

  test('401 retries once with a fresh token', () async {
    final path = await saved();
    final tokens = <String>[];
    final r = await run(
      path,
      (_, t) async {
        tokens.add(t);
        if (t == 'tok') {
          throw const TranscriptionException('expired', statusCode: 401);
        }
        return 'ok';
      },
      refresh: () async => 'fresh',
    );
    expect(tokens, ['tok', 'fresh']);
    expect(r.text, 'ok');
    expect(File(path).existsSync(), isFalse);
  });

  test('401 without a fresh token keeps the file', () async {
    final path = await saved();
    final r = await run(
      path,
      (_, _) async =>
          throw const TranscriptionException('expired', statusCode: 401),
      refresh: () async => null,
    );
    expect(r.queueable, isTrue);
    expect(File(path).existsSync(), isTrue);
  });

  test('without a saved file a network failure is a plain error', () async {
    final r = await run(
      null,
      (_, _) async => throw const SocketException('Network is unreachable'),
    );
    expect(r.success, isFalse);
    expect(r.queueable, isFalse);
    expect(r.savedPath, isNull);
  });
}
