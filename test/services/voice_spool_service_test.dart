// test/services/voice_spool_service_test.dart
//
// VoiceSpoolService keeps voice recordings on disk until they are
// transcribed: save, read, delete and the per-user wipe on sign-out.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/voice_spool_service.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voice_spool_test');
    VoiceSpoolService.baseDir = () async => tmp.path;
  });

  tearDown(() async {
    VoiceSpoolService.reset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('saveWav writes under voice_spool/<user> and read returns bytes',
      () async {
    final wav = Uint8List.fromList(List<int>.generate(100, (i) => i));
    final path = await VoiceSpoolService.saveWav(wav, userId: 'u1');

    expect(path, startsWith('${tmp.path}/voice_spool/u1/'));
    expect(path, endsWith('.wav'));
    expect(File(path).existsSync(), isTrue);
    expect(await VoiceSpoolService.read(path), wav);
    expect(await VoiceSpoolService.exists(path), isTrue);
  });

  test('no user id goes to the anon folder', () async {
    final path = await VoiceSpoolService.saveWav(Uint8List.fromList([1, 2]));
    expect(path, contains('/voice_spool/anon/'));
  });

  test('a user id cannot leave the spool folder', () async {
    final path = await VoiceSpoolService.saveWav(
      Uint8List.fromList([1]),
      userId: '../../evil',
    );
    expect(path, startsWith('${tmp.path}/voice_spool/'));
    expect(path, isNot(contains('..')));
  });

  test('delete removes the file and does not throw when missing', () async {
    final path = await VoiceSpoolService.saveWav(
      Uint8List.fromList([1, 2, 3]),
      userId: 'u1',
    );
    await VoiceSpoolService.delete(path);
    expect(File(path).existsSync(), isFalse);
    await VoiceSpoolService.delete(path);
    await VoiceSpoolService.delete('${tmp.path}/nope.wav');
  });

  test('read of a missing file throws', () async {
    expect(
      () => VoiceSpoolService.read('${tmp.path}/missing.wav'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('wipeUser deletes only that user', () async {
    final a = await VoiceSpoolService.saveWav(
      Uint8List.fromList([1]),
      userId: 'a',
    );
    final b = await VoiceSpoolService.saveWav(
      Uint8List.fromList([2]),
      userId: 'b',
    );
    await VoiceSpoolService.wipeUser('a');
    expect(File(a).existsSync(), isFalse);
    expect(File(b).existsSync(), isTrue);
    // A second wipe of a missing folder is fine.
    await VoiceSpoolService.wipeUser('a');
  });
}
