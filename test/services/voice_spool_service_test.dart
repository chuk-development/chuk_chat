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
    VoiceSpoolService.useFakeCipher();
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
    expect(path, endsWith(VoiceSpoolService.sealedSuffix));
    expect(File(path).existsSync(), isTrue);
    expect(await VoiceSpoolService.read(path), wav);
    expect(await VoiceSpoolService.exists(path), isTrue);
  });

  test('the file on disk is sealed, never the plain WAV', () async {
    final wav = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final path = await VoiceSpoolService.saveWav(wav, userId: 'u1');
    final onDisk = File(path).readAsBytesSync();
    expect(onDisk, isNot(wav));
    expect(onDisk.first, 0x53); // the fake cipher's mark
    expect(await VoiceSpoolService.read(path), wav);
  });

  test('without a key the recording waits in memory, then is sealed',
      () async {
    VoiceSpoolService.useFakeCipher(withKey: false);
    final wav = Uint8List.fromList([9, 8, 7]);
    final path = await VoiceSpoolService.saveWav(wav, userId: 'u1');

    expect(File(path).existsSync(), isFalse); // nothing plain on disk
    expect(VoiceSpoolService.isPending(path), isTrue);
    expect(await VoiceSpoolService.exists(path), isTrue);
    expect(await VoiceSpoolService.read(path), wav);
    expect(await VoiceSpoolService.sealPending(), 0); // still no key

    VoiceSpoolService.useFakeCipher();
    expect(await VoiceSpoolService.sealPending(), 1);
    expect(VoiceSpoolService.isPending(path), isFalse);
    expect(File(path).readAsBytesSync().first, 0x53);
    expect(await VoiceSpoolService.read(path), wav);
  });

  test('a recording waiting for the key goes with delete and wipe', () async {
    VoiceSpoolService.useFakeCipher(withKey: false);
    final a = await VoiceSpoolService.saveWav(Uint8List.fromList([1]));
    final b = await VoiceSpoolService.saveWav(
      Uint8List.fromList([2]),
      userId: 'u2',
    );
    await VoiceSpoolService.delete(a);
    expect(await VoiceSpoolService.exists(a), isFalse);
    await VoiceSpoolService.wipeUser('u2');
    expect(await VoiceSpoolService.exists(b), isFalse);
  });

  test('listFiles finds sealed recordings', () async {
    final path = await VoiceSpoolService.saveWav(
      Uint8List.fromList([1]),
      userId: 'u1',
    );
    final listed = await VoiceSpoolService.listFiles('u1');
    expect(listed.map((f) => f.path), [path]);
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
