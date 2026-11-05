import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_attachments.dart';

/// docs/WIRE_CONTRACT.md, "Attachments to Agents": 256 KiB chunks, the
/// sha256 of the whole file, at most four chunks in flight, a retry per
/// chunk, a restart from chunk 0 on a hash mismatch, 25 MiB and 10 files.
void main() {
  Uint8List bytesOf(int n) =>
      Uint8List.fromList(List<int>.generate(n, (i) => i % 251));

  group('chunking', () {
    test('count is ceil(size / 262144)', () {
      expect(agentsChunkCount(0), 0);
      expect(agentsChunkCount(1), 1);
      expect(agentsChunkCount(kAgentsChunkBytes), 1);
      expect(agentsChunkCount(kAgentsChunkBytes + 1), 2);
      expect(agentsChunkCount(3 * kAgentsChunkBytes), 3);
    });

    test('every chunk but the last is exactly 256 KiB', () {
      final Uint8List data = bytesOf(2 * kAgentsChunkBytes + 10);
      expect(agentsChunk(data, 0).length, kAgentsChunkBytes);
      expect(agentsChunk(data, 1).length, kAgentsChunkBytes);
      expect(agentsChunk(data, 2).length, 10);
      expect(agentsChunk(data, 2).first, data[2 * kAgentsChunkBytes]);
      expect(() => agentsChunk(data, 3), throwsRangeError);
    });

    test('a one-byte file is one chunk of one byte', () {
      expect(agentsChunk(bytesOf(1), 0).length, 1);
    });

    test('sha256 is lower-case hex of the whole file', () {
      expect(
        agentsSha256Hex(Uint8List.fromList(utf8.encode('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('an upload id is 22 base64url characters', () {
      final String id = mintAgentsUploadId();
      expect(id, hasLength(22));
      expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id), isTrue);
      expect(mintAgentsUploadId(), isNot(id));
    });
  });

  group('uploader', () {
    late StreamController<Map<String, dynamic>> acks;
    late List<Map<String, dynamic>> sent;

    setUp(() {
      acks = StreamController<Map<String, dynamic>>.broadcast(sync: true);
      sent = <Map<String, dynamic>>[];
    });

    tearDown(() => acks.close());

    /// A host that acks every chunk; it says `complete` once it has all.
    Future<void> Function(Map<String, dynamic>) honestHost({
      bool Function(Map<String, dynamic> frame, int attempt)? drop,
      Map<String, dynamic>? Function(Map<String, dynamic> frame, int attempt)?
      answer,
      void Function(int inFlight)? onSend,
    }) {
      final Map<String, Set<int>> got = <String, Set<int>>{};
      final Map<String, int> attempts = <String, int>{};
      int inFlight = 0;
      return (Map<String, dynamic> frame) async {
        sent.add(frame);
        inFlight++;
        onSend?.call(inFlight);
        final String key = '${frame['upload_id']}#${frame['index']}';
        final int attempt = attempts[key] = (attempts[key] ?? 0) + 1;
        scheduleMicrotask(() {
          inFlight--;
          if (drop?.call(frame, attempt) ?? false) return;
          final Map<String, dynamic>? custom = answer?.call(frame, attempt);
          if (custom != null) {
            acks.add(custom);
            return;
          }
          final Set<int> have = got.putIfAbsent(
            frame['upload_id'] as String,
            () => <int>{},
          )..add(frame['index'] as int);
          final bool complete = have.length == frame['count'];
          acks.add(<String, dynamic>{
            'type': 'attachment_ack',
            'ok': true,
            'upload_id': frame['upload_id'],
            'index': frame['index'],
            'received': have.length,
            'count': frame['count'],
            'complete': complete,
            if (complete) 'blob_id': frame['upload_id'],
            if (complete) 'path': '.agents/inbox/x/${frame['name']}',
            if (complete) 'kind': 'file',
          });
        });
      };
    }

    test('sends ceil(size/CHUNK) frames, waits for acks, reports progress',
        () async {
      final Uint8List data = bytesOf(3 * kAgentsChunkBytes + 7);
      final List<AgentsUploadProgress> progress = <AgentsUploadProgress>[];
      final AgentsUploadedAttachment done = await AgentsAttachmentUploader(
        send: honestHost(),
        acks: acks.stream,
      ).upload(
        AgentsOutgoingAttachment(name: 'a.pdf', mime: 'application/pdf', bytes: data),
        sessionKey: 's',
        onProgress: progress.add,
      );
      expect(sent, hasLength(4));
      final Map<String, dynamic> first = sent.first;
      expect(first['type'], 'attachment_put');
      expect(first['session_key'], 's');
      expect(first['size'], data.length);
      expect(first['count'], 4);
      expect(first['sha256'], agentsSha256Hex(data));
      expect(base64Decode(first['data'] as String).length, kAgentsChunkBytes);
      expect(
        base64Decode(sent.firstWhere((f) => f['index'] == 3)['data'] as String)
            .length,
        7,
      );
      expect(done.blobId, first['upload_id']);
      expect(done.path, '.agents/inbox/x/a.pdf');
      expect(progress.first.received, 0);
      expect(progress.last.complete, isTrue);
      expect(progress.last.received, 4);
    });

    test('never has more than four chunks in flight', () async {
      int most = 0;
      await AgentsAttachmentUploader(
        send: honestHost(onSend: (n) => most = n > most ? n : most),
        acks: acks.stream,
      ).upload(
        AgentsOutgoingAttachment(
          name: 'big.bin',
          mime: 'application/octet-stream',
          bytes: bytesOf(10 * kAgentsChunkBytes),
        ),
        sessionKey: 's',
      );
      expect(sent, hasLength(10));
      expect(most, lessThanOrEqualTo(kAgentsChunksInFlight));
      expect(most, greaterThan(1));
    });

    test('a chunk with no ack is sent again', () async {
      final AgentsUploadedAttachment done = await AgentsAttachmentUploader(
        send: honestHost(drop: (f, attempt) => f['index'] == 0 && attempt == 1),
        acks: acks.stream,
        ackTimeout: const Duration(milliseconds: 20),
      ).upload(
        AgentsOutgoingAttachment(name: 'a', mime: 'x/y', bytes: bytesOf(10)),
        sessionKey: 's',
      );
      expect(sent.where((f) => f['index'] == 0), hasLength(2));
      expect(done.blobId, isNotEmpty);
    });

    test('an ok:false is retried', () async {
      await AgentsAttachmentUploader(
        send: honestHost(
          answer: (f, attempt) => attempt == 1
              ? <String, dynamic>{
                  'type': 'attachment_ack',
                  'ok': false,
                  'upload_id': f['upload_id'],
                  'index': f['index'],
                  'error': 'busy',
                }
              : null,
        ),
        acks: acks.stream,
      ).upload(
        AgentsOutgoingAttachment(name: 'a', mime: 'x/y', bytes: bytesOf(10)),
        sessionKey: 's',
      );
      expect(sent, hasLength(2));
      expect(sent[0]['upload_id'], sent[1]['upload_id']);
    });

    test('a hash mismatch restarts the file from chunk 0, new id', () async {
      bool failedOnce = false;
      final AgentsUploadedAttachment done = await AgentsAttachmentUploader(
        send: honestHost(
          answer: (f, _) {
            if (failedOnce || f['index'] != 1) return null;
            failedOnce = true;
            return <String, dynamic>{
              'type': 'attachment_ack',
              'ok': false,
              'upload_id': f['upload_id'],
              'index': f['index'],
              'error': 'sha256 mismatch: send it again',
            };
          },
        ),
        acks: acks.stream,
      ).upload(
        AgentsOutgoingAttachment(
          name: 'a',
          mime: 'x/y',
          bytes: bytesOf(2 * kAgentsChunkBytes),
        ),
        sessionKey: 's',
      );
      final Set<Object?> ids = sent.map((f) => f['upload_id']).toSet();
      expect(ids, hasLength(2));
      final List<Map<String, dynamic>> second = sent
          .where((f) => f['upload_id'] == done.blobId)
          .toList();
      expect(second.map((f) => f['index']).toSet(), <int>{0, 1});
    });

    test('a chunk that never gets an ack fails after the attempts', () async {
      await expectLater(
        AgentsAttachmentUploader(
          send: honestHost(drop: (_, _) => true),
          acks: acks.stream,
          ackTimeout: const Duration(milliseconds: 5),
          maxChunkAttempts: 2,
        ).upload(
          AgentsOutgoingAttachment(name: 'a', mime: 'x/y', bytes: bytesOf(5)),
          sessionKey: 's',
        ),
        throwsA(
          isA<AgentsAttachmentException>().having(
            (e) => e.failure,
            'failure',
            AgentsAttachmentFailure.refused,
          ),
        ),
      );
      expect(sent, hasLength(2));
    });

    test('a link that refuses the frame is notSent', () async {
      await expectLater(
        AgentsAttachmentUploader(
          send: (_) async => throw StateError('down'),
          acks: acks.stream,
        ).upload(
          AgentsOutgoingAttachment(name: 'a', mime: 'x/y', bytes: bytesOf(5)),
          sessionKey: 's',
        ),
        throwsA(
          isA<AgentsAttachmentException>()
              .having((e) => e.failure, 'f', AgentsAttachmentFailure.notSent)
              .having((e) => e.isUserFixable, 'fixable', isFalse),
        ),
      );
    });
  });

  group('caps, before anything goes out', () {
    AgentsOutgoingAttachment file(int size, [String name = 'f']) =>
        AgentsOutgoingAttachment(
          name: name,
          mime: 'x/y',
          bytes: Uint8List(size),
        );

    test('25 MiB is fine, one byte more is not', () {
      checkAgentsAttachmentCaps(<AgentsOutgoingAttachment>[
        file(kAgentsAttachmentMaxBytes),
      ]);
      expect(
        () => checkAgentsAttachmentCaps(<AgentsOutgoingAttachment>[
          file(kAgentsAttachmentMaxBytes + 1, 'big.mov'),
        ]),
        throwsA(
          isA<AgentsAttachmentException>()
              .having((e) => e.failure, 'f', AgentsAttachmentFailure.tooLarge)
              .having((e) => e.name, 'name', 'big.mov')
              .having((e) => e.isUserFixable, 'fixable', isTrue),
        ),
      );
    });

    test('ten files are fine, eleven are not', () {
      checkAgentsAttachmentCaps(List.generate(10, (_) => file(1)));
      expect(
        () => checkAgentsAttachmentCaps(List.generate(11, (_) => file(1))),
        throwsA(
          isA<AgentsAttachmentException>().having(
            (e) => e.failure,
            'f',
            AgentsAttachmentFailure.tooMany,
          ),
        ),
      );
    });

    test('an empty file is refused', () {
      expect(
        () => checkAgentsAttachmentCaps(<AgentsOutgoingAttachment>[file(0)]),
        throwsA(isA<AgentsAttachmentException>()),
      );
    });

    test('uploadAll sends nothing for a selection over the cap', () async {
      final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
      await expectLater(
        AgentsAttachmentUploader(
          send: (f) async => frames.add(f),
          acks: const Stream<Map<String, dynamic>>.empty(),
        ).uploadAll(
          <AgentsOutgoingAttachment>[file(1), file(kAgentsAttachmentMaxBytes + 1)],
          sessionKey: 's',
        ),
        throwsA(isA<AgentsAttachmentException>()),
      );
      expect(frames, isEmpty);
    });
  });

  test('replayed user.attachments are read, malformed entries skipped', () {
    final List<AgentsAttachmentInfo> items = AgentsAttachmentInfo.listFromJson(
      jsonEncode(<Object>[
        <String, Object>{
          'blob_id': 'b1',
          'name': 'r.jpg',
          'mime': 'image/jpeg',
          'size': 2048,
          'kind': 'image',
          'path': '.agents/inbox/b1/r.jpg',
        },
        'junk',
      ]),
    );
    expect(items, hasLength(1));
    expect(items.single.isImage, isTrue);
    expect(items.single.blobId, 'b1');
    expect(agentsAttachmentSize(2048), '2 KB');
    expect(isUnknownAttachmentError("attachments: unknown attachment 'x'"), isTrue);
  });
}
