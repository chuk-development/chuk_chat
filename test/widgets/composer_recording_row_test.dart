// The microphone must not make the composer taller.
//
// Tapping the microphone used to insert a row of its own height above the
// text field, so the box grew and the thread above it jumped. The recording
// state now draws over the field instead. These tests pin that: the row has
// the same height with and without recording, and what it draws is the
// waveform.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/chat/widgets/mobile_chat_widgets.dart';
import 'package:cowork/ui/expressive/waveform.dart';

void main() {
  Widget host({required bool isRecording, List<double>? levels}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: ComposerInputRow(
              isRecording: isRecording,
              audioLevels: levels ?? List<double>.filled(32, 0.0),
              accentColor: Colors.red,
              timeColor: Colors.black,
              child: const TextField(
                minLines: 1,
                maxLines: 8,
                style: TextStyle(fontSize: 15, height: 1.35),
                decoration: InputDecoration(
                  hintText: 'Ask me anything',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.only(
                    left: 8,
                    top: 6,
                    bottom: 6,
                    right: 6,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the composer row keeps its height while recording', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(isRecording: false));
    final double atRest = tester.getSize(find.byType(ComposerInputRow)).height;

    await tester.pumpWidget(host(isRecording: true));
    final double whileRecording = tester
        .getSize(find.byType(ComposerInputRow))
        .height;

    expect(whileRecording, atRest);
    expect(atRest, greaterThan(0));

    // Let the widget go, so the elapsed-time timer is cancelled.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recording draws the waveform, not a row of its own', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(isRecording: false));
    expect(find.byType(LiveWaveform), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    await tester.pumpWidget(
      host(
        isRecording: true,
        levels: List<double>.generate(32, (int i) => (i % 8) / 8),
      ),
    );
    expect(find.byType(LiveWaveform), findsOneWidget);

    // The waveform has to fit in the room the field already had.
    final double row = tester.getSize(find.byType(ComposerInputRow)).height;
    expect(
      tester.getSize(find.byType(LiveWaveform)).height,
      lessThanOrEqualTo(row),
    );

    // The elapsed time is there, and nothing else is.
    expect(find.text('0:00'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
