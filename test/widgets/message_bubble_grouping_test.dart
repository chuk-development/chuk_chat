// A run of messages from one sender is ONE group.
//
// The messenger thread draws chuk_chat's bubbles: the user's accent bubble
// has full 16 px corners and a 5 px tail only on the last bubble of a run,
// the answer has no bubble at all, and the gap inside a run is far tighter
// than the gap between two runs. These pins hold that geometry in the
// messenger mode, so a thread cannot drift back to a look of its own.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/widgets/chat_document_inline.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

const Radius full = Radius.circular(16);
const Radius tail = Radius.circular(5);

/// chuk_chat's bubble margins: 10 above the first bubble of a run, 2 above
/// the others, 2 below every bubble.
const double gapInRun = 2 + 2;
const double gapBetweenRuns = 2 + 10;

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

final Finder decoratedBoxes = find.byWidgetPredicate(
  (Widget widget) => widget is Container && widget.decoration is BoxDecoration,
);

/// The painted rectangle of the bubble at [index] — the decorated box, not the
/// margin box, so the distance between two of them IS the gap.
Rect paintedBubble(WidgetTester tester, int index) {
  final Element element = tester.element(decoratedBoxes.at(index));
  final Finder decorated = find.descendant(
    of: find.byElementPredicate((Element e) => e == element),
    matching: find.byType(DecoratedBox),
  );
  return tester.getRect(decorated.first);
}

BorderRadius radiusOf(WidgetTester tester, int index) {
  final Container container = tester.widget<Container>(
    decoratedBoxes.at(index),
  );
  return (container.decoration! as BoxDecoration).borderRadius!
      as BorderRadius;
}

void main() {
  // Agents delivers files as file blocks; decode them as the Agents build
  // does (the default follows FEATURE_AGENTS, which tests leave off).
  ContentBlock.decodesFileBlocks = true;
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('the user\'s run: full corners, the tail only at its end', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(threeMessageRun(isUser: true)));
    await tester.pump();

    for (int i = 0; i < 4; i++) {
      final BorderRadius radius = radiusOf(tester, i);
      expect(radius.topLeft, full);
      expect(radius.topRight, full);
      expect(radius.bottomLeft, full);
    }
    expect(radiusOf(tester, 0).bottomRight, full);
    expect(radiusOf(tester, 1).bottomRight, full);
    expect(radiusOf(tester, 2).bottomRight, tail);
    expect(radiusOf(tester, 3).bottomRight, tail);
  });

  testWidgets('the gap inside a run is tighter than between two runs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(threeMessageRun(isUser: true)));
    await tester.pump();

    final Rect first = paintedBubble(tester, 0);
    final Rect middle = paintedBubble(tester, 1);
    final Rect last = paintedBubble(tester, 2);
    final Rect nextRun = paintedBubble(tester, 3);

    expect(middle.top - first.bottom, gapInRun);
    expect(last.top - middle.bottom, gapInRun);
    expect(nextRun.top - last.bottom, gapBetweenRuns);
  });

  testWidgets('a coworker\'s run draws no bubble at all', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(threeMessageRun(isUser: false)));
    await tester.pump();

    expect(decoratedBoxes, findsNothing);
    // The run gap lives in the margin above the answer's column.
    double marginTop(int index) {
      final Container box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(MessageBubble).at(index),
              matching: find.byWidgetPredicate(
                (Widget widget) => widget is Container && widget.margin != null,
              ),
            )
            .first,
      );
      return (box.margin! as EdgeInsets).top;
    }

    expect(marginTop(0), 10);
    expect(marginTop(1), 2);
    expect(marginTop(2), 2);
    expect(marginTop(3), 10);
  });

  testWidgets('a document under an answer is its own card', (
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

    // The document is drawn inline, under the answer, in the card radius.
    final Container documentBox = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(InlineChatDocument),
            matching: decoratedBoxes,
          )
          .first,
    );
    expect(
      (documentBox.decoration! as BoxDecoration).borderRadius,
      kBorderRadiusCard,
    );
    final Rect text = tester.getRect(
      find.text('Erledigt: das Dokument steht.').first,
    );
    final Rect block = tester.getRect(find.byType(InlineChatDocument));
    expect(block.top, greaterThan(text.bottom));

    // No clock stamp on the answer.
    expect(find.text('02:29'), findsNothing);
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
