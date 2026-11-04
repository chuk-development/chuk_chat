// test/services/offline_file_sweeper_test.dart
//
// Files a crash left behind (bead chuk_chat-khct, docs/OFFLINE_SEND.md):
// a voice recording or an offline image that no outbox row names is
// deleted once it is older than the grace period; a file a row names is
// kept at any age; a row that cannot be opened stops the sweep.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_file_sweeper.dart';

QueuedMessage _row(
  String id,
  Map<String, dynamic> payload, {
  String? userId = 'u1',
  bool locked = false,
}) => QueuedMessage(
  id: id,
  chatId: 'c1',
  sendPayload: payload,
  attemptCount: 0,
  createdAt: 0,
  updatedAt: 0,
  userId: userId,
  locked: locked,
);

void main() {
  final now = DateTime(2026, 11, 4, 12);
  final old = now.subtract(const Duration(days: 2));
  final fresh = now.subtract(const Duration(minutes: 5));
  late List<QueuedMessage> rows;
  late List<SweptFile> voice;
  late List<SweptFile> images;
  final deletedVoice = <String>[];
  final deletedImages = <String>[];

  setUp(() {
    deletedVoice.clear();
    deletedImages.clear();
    rows = [];
    voice = [];
    images = [];
    OfflineFileSweeper.currentUser = () => 'u1';
    OfflineFileSweeper.canOpen = () => true;
    OfflineFileSweeper.now = () => now;
    OfflineFileSweeper.rows = () async => rows;
    OfflineFileSweeper.voiceFiles = (_) async => voice;
    OfflineFileSweeper.imageFiles = (_) async => images;
    OfflineFileSweeper.deleteVoice = (p) async => deletedVoice.add(p);
    OfflineFileSweeper.deleteImage = (p) async => deletedImages.add(p);
  });

  tearDown(OfflineFileSweeper.resetSeams);

  test('old files no row names go; named and fresh files stay', () async {
    rows = [
      _row('q1', {'voicePath': '/s/u1/kept.wav'}),
      _row('q2', {
        'imagesJson': '["offline://img/u1/keptimg"]',
        'attachedFilesJson':
            '[{"encryptedImagePath":"offline://img/u1/keptfile"}]',
      }),
    ];
    voice = [
      (path: '/s/u1/kept.wav', modified: old),
      (path: '/s/u1/orphan.wav', modified: old),
      (path: '/s/anon/new.wav', modified: fresh),
    ];
    images = [
      (path: 'offline://img/u1/keptimg', modified: old),
      (path: 'offline://img/u1/keptfile', modified: old),
      (path: 'offline://img/u1/orphan', modified: old),
      (path: 'offline://img/u1/justattached', modified: fresh),
    ];

    final n = await OfflineFileSweeper.instance.sweep('u1');

    expect(n, 2);
    expect(deletedVoice, ['/s/u1/orphan.wav']);
    expect(deletedImages, ['offline://img/u1/orphan']);
  });

  test('a row that cannot be opened stops the sweep', () async {
    rows = [_row('q1', {}, locked: true)];
    voice = [(path: '/s/u1/orphan.wav', modified: old)];
    expect(await OfflineFileSweeper.instance.sweep('u1'), 0);
    expect(deletedVoice, isEmpty);
  });

  test("another user's rows do not protect this user's files", () async {
    rows = [
      _row('q1', {'voicePath': '/s/u1/x.wav'}, userId: 'u2'),
    ];
    voice = [(path: '/s/u1/x.wav', modified: old)];
    expect(await OfflineFileSweeper.instance.sweep('u1'), 1);
  });

  test('sweepOnce runs once per user and only with a key', () async {
    voice = [(path: '/s/u1/orphan.wav', modified: old)];
    OfflineFileSweeper.canOpen = () => false;
    OfflineFileSweeper.instance.sweepOnce();
    await Future<void>.delayed(Duration.zero);
    expect(deletedVoice, isEmpty);

    OfflineFileSweeper.canOpen = () => true;
    OfflineFileSweeper.instance.sweepOnce();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(deletedVoice, ['/s/u1/orphan.wav']);

    OfflineFileSweeper.instance.sweepOnce();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(deletedVoice, hasLength(1));
  });
}
