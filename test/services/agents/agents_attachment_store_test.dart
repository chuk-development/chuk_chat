import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_attachment_store.dart';

/// A file attached in an Agents thread is kept sealed on this device until
/// it is uploaded (docs/OFFLINE_SEND.md, "Agents").
void main() {
  late Directory root;
  final List<Uint8List> sealed = <Uint8List>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentsAttachmentStore.resetForTest();
    root = await Directory.systemTemp.createTemp('agents_att_store');
    AgentsAttachmentStore.rootOverride = () async => root.path;
    AgentsAttachmentStore.userOverride = () => 'u1';
    sealed.clear();
    // A stand-in cipher: reversible, and never the plaintext on disk.
    AgentsAttachmentStore.sealOverride = (Uint8List b) async {
      sealed.add(b);
      return 'sealed:${b.map((int x) => x ^ 0x5a).join(',')}';
    };
    AgentsAttachmentStore.openOverride = (String s) async => Uint8List.fromList(
      s
          .substring('sealed:'.length)
          .split(',')
          .where((String x) => x.isNotEmpty)
          .map((String x) => int.parse(x) ^ 0x5a)
          .toList(),
    );
  });

  tearDown(() async {
    AgentsAttachmentStore.resetForTest();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('put seals, read opens, meta survives a cold cache', () async {
    final Uint8List data = Uint8List.fromList('hello agent'.codeUnits);
    final String ref = await AgentsAttachmentStore.put(data, name: 'a.txt');
    expect(AgentsAttachmentStore.isRef(ref), isTrue);
    expect(ref, startsWith('agents-att://u1/'));
    // Nothing plaintext on disk.
    for (final FileSystemEntity f in root.listSync(recursive: true)) {
      if (f is File) {
        expect(f.readAsStringSync(), isNot(contains('hello agent')));
      }
    }
    final AgentsStoredAttachment? back = await AgentsAttachmentStore.read(ref);
    expect(back?.bytes, data);
    expect(back?.meta.name, 'a.txt');
    expect(back?.meta.mime, 'text/plain');
    expect(back?.meta.size, data.length);
  });

  test('delete and wipeUser remove the files', () async {
    final String a = await AgentsAttachmentStore.put(
      Uint8List.fromList(<int>[1]),
      name: 'a.bin',
    );
    final String b = await AgentsAttachmentStore.put(
      Uint8List.fromList(<int>[2]),
      name: 'b.bin',
    );
    await AgentsAttachmentStore.delete(a);
    expect(await AgentsAttachmentStore.read(a), isNull);
    expect(await AgentsAttachmentStore.read(b), isNotNull);
    await AgentsAttachmentStore.rememberBlob('blob1', b);
    expect(AgentsAttachmentStore.localPathOfBlob('blob1'), b);
    await AgentsAttachmentStore.wipeUser('u1');
    expect(await AgentsAttachmentStore.read(b), isNull);
    expect(AgentsAttachmentStore.localPathOfBlob('blob1'), isNull);
  });

  test('no user: nothing is kept', () async {
    AgentsAttachmentStore.userOverride = () => null;
    await expectLater(
      AgentsAttachmentStore.put(Uint8List(1), name: 'x'),
      throwsStateError,
    );
  });

  test('a ref with a path in it is not a ref', () {
    expect(AgentsAttachmentStore.isRef('agents-att://u1/../x'), isFalse);
    expect(AgentsAttachmentStore.isRef('offline://img/u1/x'), isFalse);
  });

  test('mime from name and from picture bytes', () {
    expect(agentsMimeForName('x.PDF'), 'application/pdf');
    expect(agentsMimeForName('noext'), 'application/octet-stream');
    expect(
      agentsSniffImageMime(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0])),
      'image/jpeg',
    );
    expect(agentsSniffImageMime(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });

  test('a sealed copy that falls out of the blob index is deleted '
      '(review of b8e3343c, finding 6)', () async {
    AgentsAttachmentStore.outboxPaths = () async =>
        (paths: <String>{}, complete: true);
    final String gone = await AgentsAttachmentStore.put(
      Uint8List.fromList('old'.codeUnits),
      name: 'old.txt',
    );
    final String queued = await AgentsAttachmentStore.put(
      Uint8List.fromList('queued'.codeUnits),
      name: 'queued.txt',
    );
    await AgentsAttachmentStore.rememberBlob('blob-gone', gone);
    await AgentsAttachmentStore.rememberBlob('blob-queued', queued);
    // A queued prompt still names one of them.
    AgentsAttachmentStore.outboxPaths = () async =>
        (paths: <String>{queued}, complete: true);
    for (int i = 0; i < 300; i++) {
      await AgentsAttachmentStore.rememberBlob('b$i', 'offline://img/u1/$i');
    }
    expect(AgentsAttachmentStore.localPathOfBlob('blob-gone'), isNull);
    expect(await AgentsAttachmentStore.read(gone), isNull);
    expect(await AgentsAttachmentStore.read(queued), isNotNull);
    expect(await AgentsAttachmentStore.indexedRefs(), isEmpty);
    final listed = await AgentsAttachmentStore.listRefs('u1');
    expect(listed.map((f) => f.path), <String>[queued]);
  });

  test(
    'an unreadable outbox row keeps evicted copies for the sweeper',
    () async {
      final String ref = await AgentsAttachmentStore.put(
        Uint8List.fromList('x'.codeUnits),
        name: 'x.txt',
      );
      AgentsAttachmentStore.outboxPaths = () async =>
          (paths: <String>{}, complete: false);
      await AgentsAttachmentStore.rememberBlob('first', ref);
      for (int i = 0; i < 300; i++) {
        await AgentsAttachmentStore.rememberBlob('b$i', 'offline://img/u1/$i');
      }
      expect(await AgentsAttachmentStore.read(ref), isNotNull);
    },
  );
}
