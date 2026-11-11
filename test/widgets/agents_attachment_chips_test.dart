import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_attachment_store.dart';
import 'package:chuk_chat/services/agents/agents_attachments.dart';
import 'package:chuk_chat/widgets/agents_attachment_chips.dart';

import '../support/test_app.dart';

/// The files on a user bubble of an Agents thread, and the upload strip
/// above the composer (docs/WIRE_CONTRACT.md, "Attachments to Agents").
void main() {
  const List<AgentsAttachmentInfo> items = <AgentsAttachmentInfo>[
    AgentsAttachmentInfo(
      name: 'a-very-long-receipt-name-from-the-shop-2026-11-05.pdf',
      mime: 'application/pdf',
      size: 734003,
      kind: 'file',
      blobId: 'b1',
    ),
    AgentsAttachmentInfo(
      name: 'photo.jpg',
      mime: 'image/jpeg',
      size: 2048,
      kind: 'image',
      blobId: 'b2',
    ),
  ];

  Widget host(Widget child) => testApp(
    Scaffold(
      body: Align(
        alignment: Alignment.topRight,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );

  for (final double width in <double>[360, 1280]) {
    testWidgets('rows show name and size at $width px, no overflow', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: host(const AgentsAttachmentChips(items: items)),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('agents-attachment-b1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('agents-attachment-b2')),
        findsOneWidget,
      );
      expect(find.text('717 KB'), findsOneWidget);
      expect(find.text('2 KB'), findsOneWidget);
      // A row never grows past the bubble lane.
      final Size row = tester.getSize(
        find.byKey(const ValueKey<String>('agents-attachment-b1')),
      );
      expect(row.width, lessThanOrEqualTo(320));
      expect(row.width, lessThanOrEqualTo(width - 32));
    });
  }

  testWidgets('a live send names its sealed files from the store', (
    WidgetTester tester,
  ) async {
    AgentsAttachmentStore.resetForTest();
    addTearDown(AgentsAttachmentStore.resetForTest);
    AgentsAttachmentStore.userOverride = () => 'u1';
    AgentsAttachmentStore.sealOverride = (Uint8List b) async =>
        String.fromCharCodes(b);
    AgentsAttachmentStore.openOverride = (String s) async =>
        Uint8List.fromList(s.codeUnits);
    AgentsAttachmentStore.rootOverride = () async =>
        '${Directory.systemTemp.path}/agents_att_chips_test';
    final String ref =
        await tester.runAsync(
          () => AgentsAttachmentStore.put(
            Uint8List.fromList(<int>[1, 2, 3]),
            name: 'notes.txt',
          ),
        ) ??
        '';
    final List<AgentsAttachmentInfo> live = AgentsAttachmentChips.forMessage(
      paths: <String>['offline://img/u1/x', ref],
    );
    // The picture is the bubble's image grid; only the file is a row.
    expect(live, hasLength(1));
    expect(live.single.name, 'notes.txt');
    expect(live.single.size, 3);

    // The host's replayed list wins over the live paths.
    final List<AgentsAttachmentInfo> replayed =
        AgentsAttachmentChips.forMessage(
          replayed: '[{"blob_id":"b9","name":"r.pdf","size":10}]',
          paths: <String>[ref],
        );
    expect(replayed.single.blobId, 'b9');
  });

  for (final double width in <double>[360, 1280]) {
    testWidgets('the upload strip shows progress per file at $width px', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AgentsUploadTracker tracker = AgentsUploadTracker.instance;
      addTearDown(() => tracker.clear('s'));
      await tester.pumpWidget(
        testApp(const Scaffold(body: AgentsUploadStrip(sessionKey: 's'))),
      );
      expect(
        find.byKey(const ValueKey<String>('agents-upload-strip')),
        findsNothing,
      );
      tracker.set(
        's',
        0,
        const AgentsUploadProgress(
          name: 'a-very-long-file-name-that-goes-on-and-on.zip',
          received: 1,
          count: 3,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('agents-upload-strip')),
        findsOneWidget,
      );
      expect(find.text('1 of 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tracker.clear('s');
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('agents-upload-strip')),
        findsNothing,
      );
    });
  }

  test('the refusal sentence names the file', () {
    expect(
      agentsAttachmentRefusalLabel(
        null,
        AgentsAttachmentFailure.tooLarge,
        name: 'x.mov',
      ),
      contains('x.mov'),
    );
    expect(
      agentsAttachmentRefusalLabel(null, AgentsAttachmentFailure.tooMany),
      contains('10'),
    );
  });
}
