import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/media_index.dart';
import 'package:chuk_chat/models/content_block.dart';

void main() {
  // Agents delivers files as file blocks; decode them as the Agents build
  // does (the default follows FEATURE_AGENTS, which tests leave off).
  ContentBlock.decodesFileBlocks = true;
  test('files and pictures are indexed out of the rows', () {
    final index = MediaIndex()
      ..noteRows('t1', <Map<String, dynamic>>[
        {
          'sender': 'ai',
          'timestamp': '2026-09-11T10:00:00.000Z',
          'images': ['cowork://blob/abc'],
        },
        {
          'sender': 'ai',
          'timestamp': '2026-09-11T11:00:00.000Z',
          'contentBlocks': [
            {
              'sandboxArtifact': {
                'storagePath': 'cowork://blob/def',
                'filename': 'Bericht.md',
                'mime': 'text/markdown',
                'sizeBytes': 2048,
              },
            },
          ],
        },
      ]);

    expect(index.entries(kind: MediaKind.image).single.name, 'abc');
    final file = index.entries(kind: MediaKind.file).single;
    expect(file.name, 'Bericht.md');
    expect(file.sizeBytes, 2048);
    expect(index.entries().length, 2);
  });

  test('a relayed row keeps its blocks as a string and is still read', () {
    final index = MediaIndex()
      ..noteRows('t2', <Map<String, dynamic>>[
        {
          'sender': 'ai',
          'contentBlocks':
              '[{"type":"sandboxArtifact","sandboxArtifact":'
              '{"storagePath":"p1","filename":"Tabelle.xlsx",'
              '"mime":"application/vnd.ms-excel","sizeBytes":9}}]',
        },
      ]);
    expect(index.entries(kind: MediaKind.file).single.name, 'Tabelle.xlsx');
  });

  test('an image sent as a sandbox file counts as a picture', () {
    final index = MediaIndex()
      ..noteRows('t3', <Map<String, dynamic>>[
        {
          'contentBlocks': [
            {
              'sandboxArtifact': {
                'storagePath': 'p2',
                'filename': 'plot.png',
                'mime': 'image/png',
                'sizeBytes': 4,
              },
            },
          ],
        },
      ]);
    expect(index.entries(kind: MediaKind.image).single.name, 'plot.png');
    expect(index.entries(kind: MediaKind.file), isEmpty);
  });

  test('the same file twice is one entry', () {
    final rows = <Map<String, dynamic>>[
      {
        'contentBlocks': [
          {
            'sandboxArtifact': {
              'storagePath': 'same',
              'filename': 'a.md',
              'mime': 'text/markdown',
              'sizeBytes': 1,
            },
          },
        ],
      },
    ];
    final index = MediaIndex()
      ..noteRows('t4', rows)
      ..noteRows('t4', rows);
    expect(index.entries().length, 1);
  });

  test('newest first', () {
    final index = MediaIndex()
      ..noteRows('t5', <Map<String, dynamic>>[
        {
          'timestamp': '2026-09-01T10:00:00.000Z',
          'images': ['cowork://blob/old'],
        },
        {
          'timestamp': '2026-09-11T10:00:00.000Z',
          'images': ['cowork://blob/new'],
        },
      ]);
    expect(index.entries().first.name, 'new');
  });

  group('pages', () {
    Map<String, dynamic> pageRow(int version, String text, {String? at}) =>
        <String, dynamic>{
          'sender': 'ai',
          'timestamp': at ?? '2026-10-29T10:0$version:00.000Z',
          'contentBlocks': [
            {
              'sandboxArtifact': {
                'storagePath': 'cowork://blob/page-v$version',
                'filename': 'BTC.html',
                'mime': kDocumentMime,
                'sizeBytes': text.length,
                'document': {
                  'id': 'btc',
                  'title': 'BTC dashboard',
                  'kind': 'html',
                  'version': version,
                  'text': text,
                },
              },
            },
          ],
        };

    test('every version of a page is one page entry, not a file', () {
      final rows = [pageRow(1, '<p>1</p>'), pageRow(2, '<p>2</p>')];
      final index = MediaIndex()..noteRows('agent-a', rows);
      expect(index.entries(kind: MediaKind.file), isEmpty);
      final page = index.entries(kind: MediaKind.page).single;
      expect(page.name, 'BTC dashboard');
      expect(page.pageId, 'btc');
      expect(page.pageKind, 'html');
      expect(page.version, 2);
      expect(page.reference, MediaEntry.pageReference('agent-a', 'btc'));
    });

    test('an older version arriving late does not win', () {
      final index = MediaIndex()
        ..noteRows('agent-a', [pageRow(3, '<p>3</p>')])
        ..noteRows('agent-a', [pageRow(1, '<p>1</p>')]);
      expect(index.entries(kind: MediaKind.page).single.version, 3);
    });

    test('two agents with the same page id keep two pages', () {
      final index = MediaIndex()
        ..noteRows('agent-a', [pageRow(1, 'a')])
        ..noteRows('agent-b', [pageRow(1, 'b')]);
      expect(index.entries(kind: MediaKind.page).length, 2);
    });

    test('the newest snapshot is read back out of the rows', () {
      final rows = [pageRow(2, '<p>2</p>'), pageRow(1, '<p>1</p>')];
      expect(latestPageIn(rows, 'btc')!['text'], '<p>2</p>');
      expect(latestPageIn(rows, 'missing'), isNull);
    });

    test(
      'a page survives the json round trip; a legacy document file does not',
      () {
        final index = MediaIndex()..noteRows('agent-a', [pageRow(4, 'x')]);
        final json = index.entries(kind: MediaKind.page).single.toJson();
        final back = MediaEntry.fromJson(json)!;
        expect(back.kind, MediaKind.page);
        expect(back.version, 4);
        expect(back.pageKind, 'html');
        expect(
          MediaEntry.fromJson(<String, dynamic>{
            'kind': 'file',
            'ref': 'cowork://blob/old',
            'name': 'notes.json',
            'mime': kDocumentMime,
          }),
          isNull,
        );
      },
    );
  });
  test('a page stamp outside the DateTime range does not drop the thread', () {
    final index = MediaIndex()
      ..noteRows('agent-x', <Map<String, dynamic>>[
        {
          'contentBlocks': [
            {
              'sandboxArtifact': {
                'storagePath': 'cowork://blob/micro',
                'filename': 'micro.json',
                'mime': kDocumentMime,
                'sizeBytes': 1,
                // A microsecond epoch where seconds are expected.
                'document': {
                  'id': 'micro',
                  'title': 'Micro',
                  'kind': 'markdown',
                  'version': 1,
                  'updated_at': 1.7e15,
                  'text': 'x',
                },
              },
            },
            {
              'sandboxArtifact': {
                'storagePath': 'p10',
                'filename': 'ok.pdf',
                'mime': 'application/pdf',
                'sizeBytes': 3,
              },
            },
          ],
        },
      ]);
    expect(index.entries(kind: MediaKind.page).single.name, 'Micro');
    expect(index.entries(kind: MediaKind.file).single.name, 'ok.pdf');
  });
  test('a page with a malformed version or stamp does not drop the thread', () {
    final index = MediaIndex()
      ..noteRows('agent-x', <Map<String, dynamic>>[
        {
          'contentBlocks': [
            {
              'sandboxArtifact': {
                'storagePath': 'cowork://blob/bad',
                'filename': 'bad.json',
                'mime': kDocumentMime,
                'sizeBytes': 1,
                'document': {
                  'id': 'bad',
                  'title': 'Bad',
                  'kind': 'markdown',
                  'version': 'two',
                  'updated_at': 'now',
                  'text': 'x',
                },
              },
            },
            {
              'sandboxArtifact': {
                'storagePath': 'p9',
                'filename': 'ok.pdf',
                'mime': 'application/pdf',
                'sizeBytes': 3,
              },
            },
          ],
        },
      ]);
    expect(index.entries(kind: MediaKind.page).single.version, 0);
    expect(index.entries(kind: MediaKind.file).single.name, 'ok.pdf');
    expect(
      latestPageIn(<Map<String, dynamic>>[
        {
          'contentBlocks': [
            {
              'sandboxArtifact': {
                'document': {'id': 'bad', 'version': 'x', 'text': 't'},
              },
            },
          ],
        },
      ], 'bad')!['text'],
      't',
    );
  });
}
