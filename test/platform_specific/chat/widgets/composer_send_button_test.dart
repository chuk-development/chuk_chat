// The composer's primary target (bead chuk_chat-05dn): voice while the field
// is empty, send as soon as it holds something, stop while a reply streams.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/widgets/composer_send_button.dart';

import '../../../support/icon_finder.dart';

final Finder _voiceGlyph = find.byKey(
  const ValueKey<String>('composer-voice-glyph'),
);
final Finder _sendGlyph = findIcon(Icons.north_rounded);
final Finder _stopGlyph = findIcon(Icons.stop_rounded);

// The face is told by the glyph; the target keeps one key across faces.
Finder _target(ComposerSendFace face) =>
    find.byKey(const ValueKey<String>('composer-send-target'));

class _Taps {
  int send = 0;
  int voice = 0;
  int stop = 0;
}

void main() {
  late TextEditingController controller;
  late _Taps taps;

  setUp(() {
    controller = TextEditingController();
    taps = _Taps();
  });

  tearDown(() => controller.dispose());

  Future<void> pump(
    WidgetTester tester, {
    bool voice = true,
    bool stopping = false,
    bool hasOtherContent = false,
    double width = 38,
    double height = 38,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              TextField(controller: controller),
              ComposerSendButton(
                controller: controller,
                hasOtherContent: hasOtherContent,
                stopping: stopping,
                onSend: () => taps.send++,
                onStop: () => taps.stop++,
                onVoice: voice ? () => taps.voice++ : null,
                width: width,
                height: height,
                radius: height / 2,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty field: voice glyph, a tap starts voice', (tester) async {
    await pump(tester);

    expect(_voiceGlyph, findsOneWidget);
    expect(_sendGlyph, findsNothing);
    await tester.tap(_target(ComposerSendFace.voice));
    expect(taps.voice, 1);
    expect(taps.send, 0);
  });

  testWidgets('typed text: send glyph, a tap sends', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'hallo');
    await tester.pumpAndSettle();

    expect(_sendGlyph, findsOneWidget);
    expect(_voiceGlyph, findsNothing);
    await tester.tap(_target(ComposerSendFace.send));
    expect(taps.send, 1);
    expect(taps.voice, 0);
  });

  testWidgets('cleared text: voice again', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'hallo');
    await tester.pumpAndSettle();
    expect(_sendGlyph, findsOneWidget);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pumpAndSettle();
    expect(_voiceGlyph, findsOneWidget);
    expect(_sendGlyph, findsNothing);
  });

  testWidgets('the swap animates for about 150 ms', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    // Mid-swap both faces are drawn: the old one fades out, the new one in.
    expect(_voiceGlyph, findsOneWidget);
    expect(_sendGlyph, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_voiceGlyph, findsNothing);
    expect(_sendGlyph, findsOneWidget);
  });

  testWidgets('an attachment counts as content', (tester) async {
    await pump(tester, hasOtherContent: true);

    expect(_sendGlyph, findsOneWidget);
    expect(_voiceGlyph, findsNothing);
    await tester.tap(_target(ComposerSendFace.send));
    expect(taps.send, 1);
  });

  testWidgets('no voice: send glyph, disabled while empty', (tester) async {
    await pump(tester, voice: false);

    expect(_sendGlyph, findsOneWidget);
    expect(_voiceGlyph, findsNothing);
    final InkWell ink = tester.widget<InkWell>(_target(ComposerSendFace.send));
    expect(ink.onTap, isNull);
    await tester.tap(_target(ComposerSendFace.send), warnIfMissed: false);
    expect(taps.send, 0);

    await tester.enterText(find.byType(TextField), 'hallo');
    await tester.pumpAndSettle();
    await tester.tap(_target(ComposerSendFace.send));
    expect(taps.send, 1);
  });

  testWidgets('streaming: stop glyph, a tap stops', (tester) async {
    await pump(tester, stopping: true);

    expect(_stopGlyph, findsOneWidget);
    expect(_voiceGlyph, findsNothing);
    await tester.tap(_target(ComposerSendFace.stop));
    expect(taps.stop, 1);
    expect(taps.voice, 0);

    // Typing while it streams keeps the stop target.
    await tester.enterText(find.byType(TextField), 'next');
    await tester.pumpAndSettle();
    expect(_stopGlyph, findsOneWidget);
    expect(_sendGlyph, findsNothing);
  });

  for (final Size box in const <Size>[Size(38, 38), Size(44, 36)]) {
    testWidgets('glyphs sit in the centre of a ${box.width}x${box.height} '
        'button', (tester) async {
      await pump(tester, width: box.width, height: box.height);

      void expectCentred(Finder glyph) {
        final Rect button = tester.getRect(
          find.descendant(
            of: find.byType(ComposerSendButton),
            matching: find.byType(AnimatedContainer),
          ),
        );
        final Rect drawn = tester.getRect(glyph);
        expect(button.size, box);
        expect((drawn.center.dx - button.center.dx).abs(), lessThan(0.5));
        expect((drawn.center.dy - button.center.dy).abs(), lessThan(0.5));
      }

      expectCentred(_voiceGlyph);
      await tester.enterText(find.byType(TextField), 'hallo');
      await tester.pumpAndSettle();
      expectCentred(_sendGlyph);
    });
  }

  testWidgets('the fill is flat: no shadow', (tester) async {
    await pump(tester);

    final AnimatedContainer box = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(ComposerSendButton),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final BoxDecoration decoration = box.decoration! as BoxDecoration;
    expect(decoration.boxShadow, isNull);
  });

  test('face order: loading, stop, content, voice', () {
    expect(
      ComposerSendButton.faceFor(
        hasContent: true,
        voiceAvailable: true,
        stopping: true,
        loading: true,
      ),
      ComposerSendFace.loading,
    );
    expect(
      ComposerSendButton.faceFor(
        hasContent: false,
        voiceAvailable: true,
        stopping: true,
      ),
      ComposerSendFace.stop,
    );
    expect(
      ComposerSendButton.faceFor(hasContent: true, voiceAvailable: true),
      ComposerSendFace.send,
    );
    expect(
      ComposerSendButton.faceFor(hasContent: false, voiceAvailable: true),
      ComposerSendFace.voice,
    );
    expect(
      ComposerSendButton.faceFor(hasContent: false, voiceAvailable: false),
      ComposerSendFace.send,
    );
  });
}
