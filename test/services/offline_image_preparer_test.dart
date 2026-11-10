import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/offline_image_preparer.dart';
import 'package:chuk_chat/utils/exponential_backoff.dart';

const String _user = 'user-1';
const String _a = 'offline://img/$_user/aaaa-1111';
const String _b = 'offline://img/$_user/bbbb-2222';

QueuedMessage _row(Map<String, dynamic> payload) => QueuedMessage(
  id: 'q1',
  chatId: 'c1',
  sendPayload: payload,
  attemptCount: 0,
  createdAt: 1,
  updatedAt: 1,
);

Map<String, dynamic> _payload() => <String, dynamic>{
  'chatId': 'c1',
  'messageText': 'hi',
  'modelId': 'm',
  'providerSlug': 'p',
  'imagesJson': jsonEncode(<String>[_a, 'user-1/old.enc', _b]),
  'attachedFilesJson': jsonEncode(<Map<String, dynamic>>[
    <String, dynamic>{'id': 'f1', 'encryptedImagePath': _a},
    <String, dynamic>{'id': 'f2', 'encryptedImagePath': _b},
  ]),
};

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('offline_img_test');
    ImageStorageService.offlineRootOverride = () async => tmp.path;
    ImageStorageService.currentUserIdOverride = () => _user;
    ImageStorageService.uploadOverride = null;
  });

  tearDown(() async {
    OfflineImagePreparer.resetForTesting();
    OfflineImageAttach.resetForTesting();
    ImageStorageService.offlineRootOverride = null;
    ImageStorageService.currentUserIdOverride = null;
    ImageStorageService.uploadOverride = null;
    ImageStorageService.clearCache();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> writeOffline(String id, List<int> bytes) async {
    final dir = Directory('${tmp.path}/$_user');
    await dir.create(recursive: true);
    return File('${dir.path}/$id.enc').writeAsBytes(bytes);
  }

  group('isOfflinePath', () {
    test('only the offline scheme counts', () {
      expect(ImageStorageService.isOfflinePath(_a), isTrue);
      expect(ImageStorageService.isOfflinePath('user-1/x.enc'), isFalse);
      expect(ImageStorageService.isOfflinePath('cowork://blob/x'), isFalse);
      expect(ImageStorageService.isOfflinePath(''), isFalse);
    });

    test('paths are found inside payload JSON', () {
      expect(OfflineImagePreparer.offlinePathsIn(_payload()), [_a, _b]);
      expect(OfflineImagePreparer.appliesTo(_row(_payload())), isTrue);
      expect(
        OfflineImagePreparer.appliesTo(
          _row(<String, dynamic>{'imagesJson': '["user-1/x.enc"]'}),
        ),
        isFalse,
      );
    });

    test('a malformed path never leaves the store', () async {
      await expectLater(
        ImageStorageService.promoteOfflineImage('offline://img/../../etc'),
        throwsA(isA<OfflineImageMissingException>()),
      );
    });
  });

  group('prepare', () {
    test('uploads, rewrites the payload and the bubble', () async {
      final calls = <String>[];
      Map<String, String>? bubbleMapping;
      OfflineImagePreparer.promote = (p) async {
        calls.add(p);
        return '$_user/${p.split('/').last}.enc';
      };
      OfflineImagePreparer.replaceImages = (chatId, queueId, mapping) async {
        expect(chatId, 'c1');
        expect(queueId, 'q1');
        bubbleMapping = mapping;
        return true;
      };

      final result = await OfflineImagePreparer.prepare(_row(_payload()));

      expect(result.success, isTrue);
      expect(calls, [_a, _b]);
      expect(bubbleMapping, {
        _a: '$_user/aaaa-1111.enc',
        _b: '$_user/bbbb-2222.enc',
      });
      final payload = result.payload!;
      expect(jsonDecode(payload['imagesJson'] as String), [
        '$_user/aaaa-1111.enc',
        'user-1/old.enc',
        '$_user/bbbb-2222.enc',
      ]);
      expect(
        payload['attachedFilesJson'] as String,
        isNot(contains('offline://')),
      );
      expect(payload[kPromotedOfflineImagesKey], [_a, _b]);
      expect(OfflineImagePreparer.offlinePathsIn(payload), isEmpty);
    });

    test('a network failure is a retryable failure', () async {
      OfflineImagePreparer.promote = (_) async => throw Exception(
        'Failed to upload encrypted image: ClientException with '
        'SocketException: Failed host lookup',
      );
      var replaced = false;
      OfflineImagePreparer.replaceImages = (_, _, _) async => replaced = true;

      final result = await OfflineImagePreparer.prepare(_row(_payload()));

      expect(result.success, isFalse);
      expect(result.deferred, isFalse);
      expect(result.error, startsWith('network'));
      expect(ExponentialBackoff.shouldRetryError(result.error), isTrue);
      expect(replaced, isFalse);
    });

    test('a missing file fails for good', () async {
      OfflineImagePreparer.promote = (_) async =>
          throw const OfflineImageMissingException();
      final result = await OfflineImagePreparer.prepare(_row(_payload()));
      expect(result.success, isFalse);
      expect(result.error, contains('image missing'));
      expect(ExponentialBackoff.shouldRetryError(result.error), isFalse);
    });

    test('no session defers', () async {
      OfflineImagePreparer.promote = (_) async =>
          throw StateError('not signed in');
      final result = await OfflineImagePreparer.prepare(_row(_payload()));
      expect(result.deferred, isTrue);
    });
  });

  group('onDone', () {
    test('deletes leftover files and markers', () async {
      final leftover = await writeOffline('aaaa-1111', [1, 2, 3]);
      final marker = File('${tmp.path}/$_user/bbbb-2222.promoted');
      await marker.writeAsString('$_user/bbbb-2222.enc');
      final unrelated = await writeOffline('cccc-3333', [9]);

      await OfflineImagePreparer.onDone(
        _row(<String, dynamic>{
          'imagesJson': jsonEncode(<String>[_a, '$_user/bbbb-2222.enc']),
          kPromotedOfflineImagesKey: <String>[_b],
        }),
      );

      expect(await leftover.exists(), isFalse);
      expect(await marker.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
    });
  });

  group('promoteOfflineImage', () {
    test('uploads the stored bytes as they are, once', () async {
      final bytes = utf8.encode('{"ciphertext":"x"}');
      final file = await writeOffline('aaaa-1111', bytes);
      final uploads = <String, Uint8List>{};
      ImageStorageService.uploadOverride = (path, data) async {
        uploads[path] = data;
      };

      final first = await ImageStorageService.promoteOfflineImage(_a);
      final second = await ImageStorageService.promoteOfflineImage(_a);

      expect(first, '$_user/aaaa-1111.enc');
      expect(second, first);
      expect(uploads.keys, [first]);
      expect(uploads[first], bytes);
      expect(await file.exists(), isFalse);
      expect(await ImageStorageService.promotedPathOf(_a), first);
    });

    test('a failed upload keeps the file', () async {
      final file = await writeOffline('aaaa-1111', [1]);
      ImageStorageService.uploadOverride = (_, _) async =>
          throw const SocketException('down');
      await expectLater(
        ImageStorageService.promoteOfflineImage(_a),
        throwsA(isA<Exception>()),
      );
      expect(await file.exists(), isTrue);
    });

    test('another account cannot promote it', () async {
      await writeOffline('aaaa-1111', [1]);
      ImageStorageService.currentUserIdOverride = () => 'someone-else';
      await expectLater(
        ImageStorageService.promoteOfflineImage(_a),
        throwsA(isA<StateError>()),
      );
    });

    test('wipe removes the user folder', () async {
      final file = await writeOffline('aaaa-1111', [1]);
      await ImageStorageService.wipeOfflineImages(_user);
      expect(await file.exists(), isFalse);
    });
  });

  group('uploadOrKeep', () {
    final bytes = Uint8List.fromList([1, 2, 3]);

    setUp(() {
      OfflineImageAttach.canStore = () => true;
      OfflineImageAttach.store = (_) async => _a;
    });

    test('offline: keeps the image, no upload', () async {
      OfflineImageAttach.isOnline = () => false;
      OfflineImageAttach.upload = (_) async => fail('no upload offline');
      expect(await OfflineImageAttach.uploadOrKeep(bytes), _a);
    });

    test('online upload broken by the network: keeps the image', () async {
      OfflineImageAttach.isOnline = () => true;
      OfflineImageAttach.upload = (_) async =>
          throw Exception('SocketException: Network is unreachable');
      expect(await OfflineImageAttach.uploadOrKeep(bytes), _a);
    });

    test('any other failure is thrown as before', () async {
      OfflineImageAttach.isOnline = () => true;
      OfflineImageAttach.upload = (_) async =>
          throw Exception('Unsupported image format');
      await expectLater(
        OfflineImageAttach.uploadOrKeep(bytes),
        throwsA(isA<Exception>()),
      );
    });

    test('without key or session the upload path is unchanged', () async {
      OfflineImageAttach.isOnline = () => false;
      OfflineImageAttach.canStore = () => false;
      OfflineImageAttach.upload = (_) async => 'cowork://blob/x';
      expect(await OfflineImageAttach.uploadOrKeep(bytes), 'cowork://blob/x');
    });
  });

  group('OfflineAttachmentWatcher', () {
    test('swaps the path when the network comes back', () async {
      final online = ValueNotifier<bool>(false);
      final files = <AttachedFile>[
        AttachedFile(
          id: 'f1',
          fileName: 'a.jpg',
          localPath: '',
          isImage: true,
          encryptedImagePath: _a,
        ),
      ];
      var changes = 0;
      final watcher = OfflineAttachmentWatcher(
        attachments: () => files,
        onChanged: () => changes++,
        online: online,
        promote: (p) async => '$_user/aaaa-1111.enc',
      );
      watcher.track();
      expect(watcher.isListening, isTrue);

      online.value = true;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(files.single.encryptedImagePath, '$_user/aaaa-1111.enc');
      expect(changes, 1);
      expect(watcher.isListening, isFalse);
      watcher.dispose();
    });
  });
}
