// A run of messages from one sender is ONE group.
//
// Two things say so, and both are pinned here because both were wrong on the
// phone: the corners where two blocks touch go small while the outer corners
// stay full, and the gap inside a run is far tighter than the gap between two
// runs. The numbers live in `ui/expressive/bubble_shape.dart` and nowhere else
// — a screen that types its own 10 or 18 breaks the grouping without failing a
// test, so the test reads the constants and checks the geometry they produce.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/ui/expressive/bubble_shape.dart';
import 'package:chuk_chat/ui/expressive/message_stamp.dart';
import 'package:chuk_chat/widgets/chat_document_inline.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

const Radius big = Radius.circular(kBubbleRadiusBig);
const Radius small = Radius.circular(kBubbleRadiusSmall);

Widget wrap(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
  ),
);

/// A run of three messages from the same sender, followed by one message that
/// opens the next run.
Widget threeMessageRun({required bool isUser}) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: <Widget>[
    for (final (bool starts, bool ends) flags in <(bool, bool)>[
      (true, false),
      (false, false),
      (false, true),
      (true, true),
    ])
      MessageBubble(
        message: 'Zeile ${flags.$1}${flags.$2}',
        isUser: isUser,
        messengerMode: true,
        startsNewGroup: flags.$1,
        endsGroup: flags.$2,
      ),
  ],
);

/// The painted rectangle of the bubble at [index] — the decorated box, not the
/// margin box, so the distance between two of them IS the gap.
Rect paintedBubble(WidgetTester tester, int index) {
  final Finder boxes = find.byWidgetPredicate(
    (Widget widget) =>
        widget is Container && widget.decoration is BoxDecoration,
  );
  final Element element = tester.element(boxes.at(index));
  final Finder decorated = find.descendant(
    of: find.byElementPredicate((Element e) => e == element),
    matching: find.byType(DecoratedBox),
  );
  return tester.getRect(decorated.first);
}

BorderRadius radiusOf(WidgetTester tester, int index) {
  final Finder boxes = find.byWidgetPredicate(
    (Widget widget) =>
        widget is Container && widget.decoration is BoxDecoration,
  );
  final Container container = tester.widget<Container>(boxes.at(index));
  return (container.decoration! as BoxDecoration).borderRadius!
      as BorderRadius;
}

void main() {
  // Agents delivers files as file blocks; decode them as the Agents build
  // does (the default follows FEATURE_AGENTS, which tests leave off).
  ContentBlock.decodesFileBlocks = true;
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('a coworker run: small corners inside, full corners outside', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(threeMessageRun(isUser: false)));
    await tester.pump();

    // First of the run: open at the top, connected downwards. A coworker sits
    // on the left, so the left edge is the one that carries the joins.
    expect(radiusOf(tester, 0).topLeft, big);
    expect(radiusOf(tester, 0).topRight, big);
    expect(radiusOf(tester, 0).bottomLeft, small);
    expect(radiusOf(tester, 0).bottomRight, big);

    // Middle: joined on both ends.
    expect(radiusOf(tester, 1).topLeft, small);
    expect(radiusOf(tester, 1).bottomLeft, small);
    expect(radiusOf(tester, 1).topRight, big);
    expect(radiusOf(tester, 1).bottomRight, big);

    // Last: joined upwards, open at the bottom.
    expect(radiusOf(tester, 2).topLeft, small);
    expect(radiusOf(tester, 2).bottomLeft, big);

    // The next run starts over with every corner full.
    expect(radiusOf(tester, 3).topLeft, big);
    expect(radiusOf(tester, 3).bottomLeft, big);
  });

  testWidgets('the gap inside a run is far tighter than between two runs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(threeMessageRun(isUser: false)));
    await tester.pump();

    final Rect first = paintedBubble(tester, 0);
    final Rect middle = paintedBubble(tester, 1);
    final Rect last = paintedBubble(tester, 2);
    final Rect nextRun = paintedBubble(tester, 3);

    expect(middle.top - first.bottom, kBubbleGapInGroup);
    expect(last.top - middle.bottom, kBubbleGapInGroup);
    expect(nextRun.top - last.bottom, kBubbleGapBetweenGroups);
    // Not just different — different enough to read at a glance.
    expect(kBubbleGapBetweenGroups, greaterThan(kBubbleGapInGroup * 4));
  });

  testWidgets('the user\'s own messages group the same way', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(threeMessageRun(isUser: true)));
    await tester.pump();

    // The user sits on the right, so the right edge carries the joins.
    expect(radiusOf(tester, 0).bottomRight, small);
    expect(radiusOf(tester, 0).bottomLeft, big);
    expect(radiusOf(tester, 1).topRight, small);
    expect(radiusOf(tester, 1).bottomRight, small);
    expect(radiusOf(tester, 2).topRight, small);
    expect(radiusOf(tester, 2).bottomRight, big);
    expect(radiusOf(tester, 3).topRight, big);

    expect(
      paintedBubble(tester, 1).top - paintedBubble(tester, 0).bottom,
      kBubbleGapInGroup,
    );
    expect(
      paintedBubble(tester, 3).top - paintedBubble(tester, 2).bottom,
      kBubbleGapBetweenGroups,
    );
  });

  testWidgets('a document under an answer belongs to the same run', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Erledigt: das Dokument steht.',
          isUser: false,
          messengerMode: true,
          sentAt: DateTime(2026, 9, 12, 2, 29),
          contentBlocks: <ContentBlock>[
            const ContentBlock.text('Erledigt: das Dokument steht.'),
            ContentBlock.sandboxArtifact(
              const SandboxArtifactPayload(
                storagePath: 'cowork://document/test-md',
                filename: 'test-md.json',
                mime: 'application/vnd.cowork.document+json',
                sizeBytes: 512,
                document: <String, dynamic>{
                  'id': 'test-md',
                  'title': 'Testbericht',
                  'kind': 'markdown',
                  'version': 1,
                  'text': 'Die Anfaenge in der Antike\n\nSchon Heron.',
                },
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // Two blocks, one run: the answer keeps its top corners and gives up its
    // bottom-left, the document picks that join up and closes the run.
    final BorderRadius answer = radiusOf(tester, 0);
    expect(answer.topLeft, big);
    expect(answer.bottomLeft, small);

    final Container documentBox = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(InlineChatDocument),
            matching: find.byWidgetPredicate(
              (Widget widget) =>
                  widget is Container && widget.decoration is BoxDecoration,
            ),
          )
          .first,
    );
    final BorderRadius document =
        (documentBox.decoration! as BoxDecoration).borderRadius!
            as BorderRadius;
    expect(document.topLeft, small);
    expect(document.bottomLeft, big);
    expect(document.bottomRight, big);

    // And it hangs on the answer, not below it.
    final Rect bubble = paintedBubble(tester, 0);
    final Rect block = tester.getRect(find.byType(InlineChatDocument));
    expect(block.top - bubble.bottom, kBubbleGapInGroup);

    // The clock belongs to the last block of the run. The document carries its
    // own version-and-time line, so the answer above it shows no stamp.
    expect(find.byType(MessageStamp), findsNothing);
  });

  group('what breaks a run', () {
    Map<String, String> row(String sender, String at) => <String, String>{
      'sender': sender,
      'text': 'x',
      'sentAt': at,
    };

    test('the same sender, seconds apart, is one run', () {
      final List<Map<String, String>> messages = <Map<String, String>>[
        row('ai', '2026-09-12T02:29:00Z'),
        row('ai', '2026-09-12T02:29:30Z'),
      ];
      expect(messageStartsRun(messages, 1), isFalse);
      expect(messageEndsRun(messages, 0), isFalse);
      expect(messageEndsRun(messages, 1), isTrue);
    });

    test('the other sender breaks it', () {
      final List<Map<String, String>> messages = <Map<String, String>>[
        row('ai', '2026-09-12T02:29:00Z'),
        row('user', '2026-09-12T02:29:10Z'),
      ];
      expect(messageStartsRun(messages, 1), isTrue);
    });

    test('a long pause breaks it', () {
      final List<Map<String, String>> messages = <Map<String, String>>[
        row('ai', '2026-09-12T02:29:00Z'),
        row('ai', '2026-09-12T03:10:00Z'),
      ];
      expect(messageStartsRun(messages, 1), isTrue);
    });

    test('a new day breaks it, and the divider agrees', () {
      final List<Map<String, String>> messages = <Map<String, String>>[
        // Local wall clock, no Z: the divider reads the local day.
        row('ai', '2026-09-11T23:58:00'),
        row('ai', '2026-09-12T00:01:00'),
      ];
      expect(messageOpensDay(messages[0], messages[1]), isTrue);
      expect(messageStartsRun(messages, 1), isTrue);
    });

    test('undated rows fall back to the sender alone', () {
      final List<Map<String, String>> messages = <Map<String, String>>[
        <String, String>{'sender': 'ai', 'text': 'a'},
        <String, String>{'sender': 'ai', 'text': 'b'},
      ];
      expect(messageStartsRun(messages, 1), isFalse);
      expect(messageOpensDay(messages[0], messages[1]), isFalse);
    });
  });
}
