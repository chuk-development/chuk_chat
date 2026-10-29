import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_media_page.dart';
import 'package:chuk_chat/services/agents/media_index.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';

Map<String, dynamic> _fileRow(String path, String name, String mime) =>
    <String, dynamic>{
      'sender': 'ai',
      'timestamp': '2026-10-01T09:00:00.000Z',
      'contentBlocks': [
        {
          'sandboxArtifact': {
            'storagePath': path,
            'filename': name,
            'mime': mime,
            'sizeBytes': 2048,
          },
        },
      ],
    };

Map<String, dynamic> _pageRow(String id, String title, String kind, int v) =>
    <String, dynamic>{
      'sender': 'ai',
      'timestamp': '2026-10-02T09:00:00.000Z',
      'contentBlocks': [
        {
          'sandboxArtifact': {
            'storagePath': 'cowork://blob/$id-$v',
            'filename': '$title.json',
            'mime': kDocumentMime,
            'sizeBytes': 10,
            'document': {
              'id': id,
              'title': title,
              'kind': kind,
              'version': v,
              'text': kind == 'html' ? '<p>x</p>' : '# x',
            },
          },
        },
      ],
    };

Future<void> _pump(WidgetTester tester, MediaIndex index) async {
  tester.view.physicalSize = const Size(360 * 3, 780 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MobileMediaPage(
          index: index,
          agentNames: const <String, String>{'agent-a': 'Crypto Desk'},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  ContentBlock.decodesFileBlocks = true;

  testWidgets('three segments: pictures, files, pages', (tester) async {
    await _pump(tester, MediaIndex());
    for (final String label in kMediaSegments) {
      expect(find.text(label), findsOneWidget);
    }
    expect(kMediaSegments, <String>['Pictures', 'Files', 'Pages']);
    expect(find.text('No pictures yet'), findsOneWidget);
  });

  testWidgets('files and pages each have their own list and empty state', (
    tester,
  ) async {
    final MediaIndex index = MediaIndex()
      ..noteRows('agent-a', <Map<String, dynamic>>[
        _fileRow('p1', 'Quartalsbericht.pdf', 'application/pdf'),
        _pageRow('btc', 'BTC dashboard', 'html', 1),
        _pageRow('btc', 'BTC dashboard', 'html', 3),
        _pageRow('notes', 'Notes', 'markdown', 1),
      ]);
    await _pump(tester, index);

    await tester.tap(find.text('Files'));
    await tester.pump();
    expect(find.text('Quartalsbericht'), findsOneWidget);
    expect(find.text('.pdf'), findsOneWidget);
    // A document delivery is a page, never a file row.
    expect(find.text('BTC dashboard'), findsNothing);

    await tester.tap(find.text('Pages'));
    await tester.pump();
    // Three versions of one page are one row.
    expect(find.text('BTC dashboard'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.textContaining('HTML page · v3 · Crypto Desk'), findsOneWidget);
    expect(find.byType(MediaRow), findsNWidgets(2));
  });

  testWidgets('pages tab without pages says how to get one', (tester) async {
    await _pump(tester, MediaIndex());
    await tester.tap(find.text('Pages'));
    await tester.pump();
    expect(find.text('No pages yet'), findsOneWidget);
    expect(find.textContaining('Ask an agent to make a page'), findsOneWidget);
  });

  testWidgets('no overflow at 360 px and text scale 1.3', (tester) async {
    final MediaIndex index = MediaIndex()
      ..noteRows('agent-a', <Map<String, dynamic>>[
        _fileRow(
          'p2',
          'ein_sehr_langer_dateiname_fuer_den_bericht_2026.xlsx',
          'application/vnd.ms-excel',
        ),
      ]);
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 780),
            textScaler: TextScaler.linear(1.3),
          ),
          child: Scaffold(body: MobileMediaPage(index: index)),
        ),
      ),
    );
    await tester.tap(find.text('Files'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // The extension survives, the stem is cut.
    expect(find.text('.xlsx'), findsOneWidget);
  });

  group('row helpers', () {
    test('glyph follows the page kind and the file extension', () {
      MediaEntry page(String kind) => MediaEntry(
        kind: MediaKind.page,
        reference: 'r',
        name: 'n',
        threadKey: 't',
        pageKind: kind,
      );
      expect(mediaRowGlyph(page('html')), HugeIcons.globe02);
      expect(mediaRowGlyph(page('markdown')), HugeIcons.fileText);
      expect(mediaRowGlyph(page('table')), HugeIcons.sheet);
      expect(
        mediaRowGlyph(
          const MediaEntry(
            kind: MediaKind.file,
            reference: 'r',
            name: 'a.zip',
            threadKey: 't',
          ),
        ),
        HugeIcons.zip01,
      );
    });

    test('meta line: kind, size, agent, date', () {
      final MediaEntry file = MediaEntry(
        kind: MediaKind.file,
        reference: 'r',
        name: 'Bericht.pdf',
        threadKey: 't',
        sizeBytes: 2048,
        at: DateTime(2026, 3, 4, 10),
      );
      expect(
        mediaRowMeta(file, agentName: 'Desk', now: DateTime(2026, 10, 29)),
        'PDF · 2.0 KB · Desk · 4.3.',
      );
      final MediaEntry page = MediaEntry(
        kind: MediaKind.page,
        reference: 'r',
        name: 'Notes',
        threadKey: 't',
        pageKind: 'markdown',
        version: 1,
        at: DateTime(2026, 10, 29, 14, 5),
      );
      expect(
        mediaRowMeta(page, now: DateTime(2026, 10, 29, 18)),
        'Page · 14:05',
      );
    });
  });
}
