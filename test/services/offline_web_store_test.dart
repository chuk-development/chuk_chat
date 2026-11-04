// test/services/offline_web_store_test.dart
//
// Web keeps voice recordings and offline images too (docs/OFFLINE_SEND.md,
// "Web"): in IndexedDB instead of files. The same service code runs its
// web branch here against an in-memory store. The native listing used by
// the startup sweep is tested against a temp directory.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/offline_blob_handle.dart';
import 'package:chuk_chat/services/voice_spool_service.dart';

class _MemBlobs implements OfflineBlobHandle {
  _MemBlobs({this.supported = true});

  final bool supported;
  final Map<String, Uint8List> data = <String, Uint8List>{};
  final Map<String, DateTime> at = <String, DateTime>{};

  @override
  bool get isSupported => supported;
  @override
  Future<void> put(String key, Uint8List bytes) async {
    data[key] = bytes;
    at[key] = DateTime(2026, 1, 1);
  }

  @override
  Future<Uint8List?> get(String key) async => data[key];
  @override
  Future<bool> exists(String key) async => data.containsKey(key);
  @override
  Future<void> delete(String key) async {
    data.remove(key);
    at.remove(key);
  }

  @override
  Future<void> deletePrefix(String prefix) async =>
      data.keys.where((k) => k.startsWith(prefix)).toList().forEach(data.remove);
  @override
  Future<List<({String key, DateTime modified})>> list(String prefix) async => [
    for (final k in data.keys)
      if (k.startsWith(prefix)) (key: k, modified: at[k]!),
  ];
}

const String _user = 'user-1';

void main() {
  group('voice spool on web', () {
    late _MemBlobs blobs;

    setUp(() {
      blobs = _MemBlobs();
      VoiceSpoolService.forceWeb = true;
      VoiceSpoolService.blobs = blobs;
    });

    tearDown(VoiceSpoolService.reset);

    test('save, read, list, delete and wipe go through the store', () async {
      final wav = Uint8List.fromList([1, 2, 3]);
      final path = await VoiceSpoolService.saveWav(wav, userId: 'u1');
      expect(path, startsWith('idb:voice_spool/u1/'));
      expect(VoiceSpoolService.isSupported, isTrue);
      expect(await VoiceSpoolService.exists(path), isTrue);
      expect(await VoiceSpoolService.read(path), wav);

      final listed = await VoiceSpoolService.listFiles('u1');
      expect(listed.single.path, path);

      await VoiceSpoolService.delete(path);
      expect(await VoiceSpoolService.exists(path), isFalse);
      await expectLater(VoiceSpoolService.read(path), throwsStateError);

      await VoiceSpoolService.saveWav(wav, userId: 'u1');
      await VoiceSpoolService.saveWav(wav, userId: 'u2');
      await VoiceSpoolService.wipeUser('u1');
      expect(blobs.data.keys.single, startsWith('voice_spool/u2/'));
    });

    test('a browser without IndexedDB is not supported', () async {
      VoiceSpoolService.blobs = _MemBlobs(supported: false);
      expect(VoiceSpoolService.isSupported, isFalse);
      await expectLater(
        VoiceSpoolService.saveWav(Uint8List.fromList([1])),
        throwsUnsupportedError,
      );
    });
  });

  group('offline images on web', () {
    late _MemBlobs blobs;
    const String path = 'offline://img/$_user/aaaa-1111';

    setUp(() {
      blobs = _MemBlobs();
      ImageStorageService.offlineForceWeb = true;
      ImageStorageService.offlineBlobs = blobs;
      ImageStorageService.currentUserIdOverride = () => _user;
    });

    tearDown(() {
      ImageStorageService.offlineForceWeb = null;
      ImageStorageService.offlineBlobs = const OfflineBlobHandle();
      ImageStorageService.currentUserIdOverride = null;
      ImageStorageService.uploadOverride = null;
      ImageStorageService.clearCache();
    });

    test('promote uploads the stored bytes and leaves a marker', () async {
      final bytes = Uint8List.fromList(utf8.encode('{"ciphertext":"x"}'));
      await blobs.put('offline_images/$_user/aaaa-1111.enc', bytes);
      expect(await ImageStorageService.imageExists(path), isTrue);
      expect(await ImageStorageService.getImageSize(path), bytes.length);
      final listed = await ImageStorageService.listOfflineImages(_user);
      expect(listed.single.path, path);

      final uploads = <String, Uint8List>{};
      ImageStorageService.uploadOverride = (p, d) async => uploads[p] = d;
      final first = await ImageStorageService.promoteOfflineImage(path);

      expect(first, '$_user/aaaa-1111.enc');
      expect(uploads[first], bytes);
      expect(
        blobs.data.containsKey('offline_images/$_user/aaaa-1111.enc'),
        isFalse,
      );
      expect(await ImageStorageService.promotedPathOf(path), first);
      // Uploaded: nothing left for the sweep to list.
      expect(await ImageStorageService.listOfflineImages(_user), isEmpty);
    });

    test('delete and wipe remove the entries', () async {
      await blobs.put('offline_images/$_user/aaaa-1111.enc', Uint8List(1));
      await blobs.put('offline_images/$_user/bbbb-2222.enc', Uint8List(1));
      await blobs.put('offline_images/other/cccc-3333.enc', Uint8List(1));
      await ImageStorageService.deleteOfflineImage(path);
      expect(blobs.data.length, 2);
      await ImageStorageService.wipeOfflineImages(_user);
      expect(blobs.data.keys.single, 'offline_images/other/cccc-3333.enc');
    });
  });

  group('native listing for the sweep', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('offline_list_test');
      VoiceSpoolService.baseDir = () async => tmp.path;
      ImageStorageService.offlineRootOverride = () async => '${tmp.path}/img';
    });

    tearDown(() async {
      VoiceSpoolService.reset();
      ImageStorageService.offlineRootOverride = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('voice files of the user and of anon are listed', () async {
      final a = await VoiceSpoolService.saveWav(
        Uint8List.fromList([1]),
        userId: 'u1',
      );
      final b = await VoiceSpoolService.saveWav(Uint8List.fromList([2]));
      await VoiceSpoolService.saveWav(Uint8List.fromList([3]), userId: 'u2');
      final listed = (await VoiceSpoolService.listFiles(
        'u1',
      )).map((f) => f.path).toSet();
      expect(listed, {a, b});
    });

    test('offline images are listed as offline paths, markers are not',
        () async {
      final dir = Directory('${tmp.path}/img/$_user')
        ..createSync(recursive: true);
      File('${dir.path}/aaaa-1111.enc').writeAsBytesSync([1]);
      File('${dir.path}/bbbb-2222.promoted').writeAsStringSync('x');
      final listed = await ImageStorageService.listOfflineImages(_user);
      expect(listed.map((f) => f.path), ['offline://img/$_user/aaaa-1111']);
    });
  });
}
