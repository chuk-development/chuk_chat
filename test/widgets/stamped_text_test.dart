import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/ui/expressive/message_stamp.dart';
import 'package:cowork/widgets/message_bubble.dart';
import 'package:cowork/widgets/stamped_text.dart';

/// The test font draws every glyph as a square of the font size, so a line of
/// [n] characters at size 10 is exactly `n * 10` wide. That makes "does the
/// stamp still fit on the last line" an exact question.
const double kFontSize = 10;
const TextStyle kStyle = TextStyle(fontSize: kFontSize, height: 1);

/// A stand-in stamp with a width the test can do arithmetic with.
const Widget kStamp = SizedBox(width: 40, height: 8);

/// Reserved footprint: the default gap plus the stamp.
const double kReserved = 8 + 40;

Widget host(Widget child, {double width = 300}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: width, child: child),
  ),
);

Widget wrapApp(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('StampedText', () {
    testWidgets('the stamp rides on the last line when it fits', (
      tester,
    ) async {
      // 20 glyphs = 200 px; 200 + 48 = 248 fits inside 300.
      await tester.pumpWidget(
        host(
          const StampedText(
            text: 'aaaaaaaaaaaaaaaaaaaa',
            style: kStyle,
            stamp: kStamp,
            fillWidth: true,
          ),
        ),
      );
      final Size size = tester.getSize(find.byType(StampedText));
      expect(size.height, kFontSize, reason: 'the bubble must not grow a line');
      // The stamp sits inside that single line, at its end.
      final Rect stamp = tester.getRect(find.byWidget(kStamp).last);
      final Rect box = tester.getRect(find.byType(StampedText));
      expect(stamp.right, closeTo(box.right, 0.01));
      expect(stamp.bottom, closeTo(box.bottom, 0.01));
      expect(stamp.top, greaterThanOrEqualTo(box.top));
    });

    testWidgets('the stamp drops to its own line when it does not fit', (
      tester,
    ) async {
      // 28 glyphs = 280 px; 280 + 48 = 328 does not fit inside 300.
      await tester.pumpWidget(
        host(
          const StampedText(
            text: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            style: kStyle,
            stamp: kStamp,
            fillWidth: true,
          ),
        ),
      );
      final Size size = tester.getSize(find.byType(StampedText));
      expect(size.height, greaterThan(kFontSize));
      expect(
        size.height,
        closeTo(2 * kFontSize, 0.01),
        reason: 'the stamp line must stay tight to the text',
      );
      final Rect stamp = tester.getRect(find.byWidget(kStamp).last);
      final Rect box = tester.getRect(find.byType(StampedText));
      expect(stamp.right, closeTo(box.right, 0.01));
      expect(stamp.bottom, closeTo(box.bottom, 0.01));
      // Below the first line of text, not beside it.
      expect(stamp.top, greaterThanOrEqualTo(box.top + kFontSize - 0.01));
    });

    testWidgets('a short message shrink-wraps instead of stretching', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const Align(
            alignment: Alignment.topLeft,
            child: StampedText(
              text: 'aaaaaaaaaa',
              style: kStyle,
              stamp: kStamp,
            ),
          ),
        ),
      );
      final Size size = tester.getSize(find.byType(StampedText));
      expect(size.width, closeTo(10 * kFontSize + kReserved, 0.01));
      expect(size.height, kFontSize);
    });

    testWidgets('right-to-left puts the stamp on the leading edge', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: const StampedText(
                text: 'aaaaaaaaaaaaaaaaaaaa',
                style: kStyle,
                stamp: kStamp,
                fillWidth: true,
              ),
            ),
          ),
        ),
      );
      final Rect stamp = tester.getRect(find.byWidget(kStamp).last);
      final Rect box = tester.getRect(find.byType(StampedText));
      expect(stamp.left, closeTo(box.left, 0.01));
      expect(tester.getSize(find.byType(StampedText)).height, kFontSize);
    });

    testWidgets('without a stamp it is just text', (tester) async {
      await tester.pumpWidget(
        host(const StampedText(text: 'hello', style: kStyle)),
      );
      expect(find.byType(Stack), findsNothing);
      expect(find.text('hello'), findsOneWidget);
    });
  });

  group('isPlainStampableText', () {
    test('plain prose is stampable', () {
      expect(isPlainStampableText('Hey! What can I do for you?'), isTrue);
      expect(isPlainStampableText('Hallo, ich bin da. 😊'), isTrue);
      expect(isPlainStampableText('Zeile eins\nZeile zwei'), isTrue);
    });

    test('anything the Markdown renderer owns is not', () {
      for (final String markup in <String>[
        '',
        '   ',
        '# Heading',
        '- a list item',
        '1. a numbered item',
        'some **bold** text',
        'some `code` text',
        'a [link](https://example.com)',
        'see https://example.com',
        'see www.example.com',
        '| a | b |',
        '> quoted',
        'a <b>tag</b>',
        r'latex $x$',
        'first paragraph\n\nsecond paragraph',
        '    indented code',
        'call me on +49 176 1234567',
      ]) {
        expect(
          isPlainStampableText(markup),
          isFalse,
          reason: 'must keep the Markdown renderer: $markup',
        );
      }
    });
  });

  group('MessageBubble', () {
    testWidgets('a short coworker answer keeps its stamp on the text line', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapApp(
          MessageBubble(
            message: 'Hey! What can I do for you?',
            isUser: false,
            messengerMode: true,
            showToolCalls: false,
            sentAt: DateTime(2026, 9, 11, 6, 2),
          ),
        ),
      );
      await tester.pump();

      // Two copies: the invisible one that reserves the room at the end of
      // the text, and the real one painted over it.
      expect(find.byType(MessageStamp), findsNWidgets(2));
      final Finder stamp = find.descendant(
        of: find.byType(Positioned),
        matching: find.byType(MessageStamp),
      );
      expect(stamp, findsOneWidget);
      expect(tester.widget<MessageStamp>(stamp).time, '06:02');
      final Finder body = find.byWidgetPredicate(
        (Widget widget) => widget is Text && widget.textSpan != null,
      );
      expect(body, findsOneWidget);
      // One line of text, and the stamp ends on it.
      expect(
        tester.getRect(stamp).bottom,
        closeTo(tester.getRect(body).bottom, 0.5),
      );
    });

    testWidgets('a Markdown answer keeps the stamp under the text', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapApp(
          MessageBubble(
            message: '# Heading\n\nA list:\n\n- one\n- two',
            isUser: false,
            messengerMode: true,
            showToolCalls: false,
            sentAt: DateTime(2026, 9, 11, 6, 2),
          ),
        ),
      );
      await tester.pump();
      // One copy only: nothing is reserved inside the rendered Markdown, so
      // the stamp still hangs under the body.
      expect(find.byType(MessageStamp), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Positioned),
          matching: find.byType(MessageStamp),
        ),
        findsNothing,
      );
    });
  });
}
