import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/media_index.dart';

void main() {
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
}
