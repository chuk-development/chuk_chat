import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/thread_preview_store.dart';

void main() {
  test('the preview is the last line that says something', () {
    final store = ThreadPreviewStore();
    store.noteRows('t1', <Map<String, dynamic>>[
      {'role': 'user', 'text': 'moin'},
      {'role': 'assistant', 'text': 'Fertig! **Der Bericht** steht.'},
      {'role': 'assistant', 'text': '   '},
    ]);
    final preview = store.of('t1');
    expect(preview, isNotNull);
    expect(preview!.text, 'Fertig! Der Bericht steht.');
    expect(preview.fromUser, isFalse);
  });

  test('markdown markers do not reach the roster', () {
    final store = ThreadPreviewStore();
    store.noteRows('t2', <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'text':
            '## Endstand\n\n- **Partei A** 31,2 %\n- `code` und '
            '[ein Link](https://example.org)',
      },
    ]);
    expect(
      store.of('t2')!.text,
      'Endstand Partei A 31,2 % code und ein Link',
    );
  });

  test('a line the user wrote is marked as theirs', () {
    final store = ThreadPreviewStore();
    store.noteRows('t3', <Map<String, dynamic>>[
      {'role': 'user', 'text': 'mach mir eine Tabelle'},
    ]);
    expect(store.of('t3')!.fromUser, isTrue);
  });

  test('a row with only a file is described by its file name', () {
    final store = ThreadPreviewStore();
    store.noteRows('t4', <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'text': '',
        'contentBlocks': [
          {
            'sandboxArtifact': {'filename': 'Marktdaten.xlsx'},
          },
        ],
      },
    ]);
    expect(store.of('t4')!.text, 'Marktdaten.xlsx');
  });

  test('the newest of several threads wins the roster line', () {
    final store = ThreadPreviewStore();
    store.noteRows('a', <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'text': 'older',
        'timestamp': '2026-09-10T10:00:00.000Z',
      },
    ]);
    store.noteRows('b', <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'text': 'newer',
        'timestamp': '2026-09-11T10:00:00.000Z',
      },
    ]);
    expect(store.newestOf(<String>['a', 'b'])!.text, 'newer');
  });

  test('blocks that arrive as a JSON string are read too', () {
    final store = ThreadPreviewStore();
    store.noteRows('t5', <Map<String, dynamic>>[
      {
        'sender': 'ai',
        'text': '',
        'contentBlocks':
            '[{"type":"sandboxArtifact","sandboxArtifact":'
            '{"storagePath":"p","filename":"Bericht.md","mime":"text/markdown",'
            '"sizeBytes":12}}]',
      },
    ]);
    expect(store.of('t5')!.text, 'Bericht.md');
  });
}
