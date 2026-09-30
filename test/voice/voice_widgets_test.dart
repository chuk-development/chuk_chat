import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call.dart';

final DateTime _t0 = DateTime(2026, 9, 29, 14, 5);

/// A 360 px column that scrolls, like the chat the widgets live in.
Widget _host(Widget child, {double width = 360, double textScale = 1.0}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: width,
                child: Padding(padding: const EdgeInsets.all(8), child: child),
              ),
            ),
          ),
        ),
      ),
    );

List<VoiceTurn> _turns() => <VoiceTurn>[
  VoiceTurn(role: 'user', text: 'What is on my list?', at: _t0, isFinal: true),
  VoiceTurn(
    role: 'assistant',
    text:
        'Milk, bread and a very long line about the thing you asked for '
        'that wraps over several lines on a narrow phone.',
    at: _t0.add(const Duration(seconds: 2)),
    isFinal: true,
  ),
  VoiceTurn(
    role: 'user',
    text: 'And the',
    at: _t0.add(const Duration(seconds: 9)),
    isFinal: false,
  ),
];

List<VoiceCard> _cards() => <VoiceCard>[
  VoiceCard(
    id: 'w',
    kind: 'weather',
    title: 'Kiel, a place name long enough to need two lines here',
    source: 'Open-Meteo',
    data: <String, dynamic>{
      'temperature': 14,
      'condition': 'Cloudy',
      'apparent': 12,
      'humidity': 80,
      'wind': 20,
      'hourly': <Map<String, dynamic>>[
        for (int h = 13; h < 20; h++)
          <String, dynamic>{'time': '2026-09-29T$h:00', 'temp': h},
      ],
      'daily': <Map<String, dynamic>>[
        <String, dynamic>{
          'date': 'Tue',
          'condition': 'Rain',
          'min': 9,
          'max': 15,
        },
      ],
    },
    at: _t0.add(const Duration(seconds: 3)),
  ),
  VoiceCard(
    id: 's',
    kind: 'search',
    title: 'Results',
    data: <String, dynamic>{
      'answer': 'Yes.',
      'results': <Map<String, dynamic>>[
        <String, dynamic>{
          'title': 'A page',
          'url': 'https://example.com',
          'snippet': 'Snippet',
          'source': 'example.com',
        },
      ],
    },
    at: _t0.add(const Duration(seconds: 4)),
  ),
  VoiceCard(
    id: 'g',
    kind: 'unknown_kind',
    title: 'Something new',
    data: <String, dynamic>{'a': 1, 'b': 'two'},
    at: _t0.add(const Duration(seconds: 5)),
  ),
];

void main() {
  group('describeVoiceCall', () {
    VoiceCallRecord rec(Duration d, int turns) => VoiceCallRecord(
      chatId: 'c',
      mode: VoiceCallMode.chat,
      startedAt: _t0,
      endedAt: _t0.add(d),
      turns: <VoiceTurn>[
        for (int i = 0; i < turns; i++)
          VoiceTurn(role: 'user', text: 't$i', at: _t0, isFinal: true),
      ],
    );

    test('minutes and turns', () {
      expect(
        describeVoiceCall(rec(const Duration(minutes: 3, seconds: 10), 12)),
        'Voice call · 3 min · 12 turns',
      );
    });

    test('under a minute in seconds, one turn singular', () {
      expect(
        describeVoiceCall(rec(const Duration(seconds: 45), 1)),
        'Voice call · 45 s · 1 turn',
      );
    });
  });

  test('timeline puts cards between turns by time', () {
    final VoiceCallRecord record = VoiceCallRecord(
      chatId: 'c',
      mode: VoiceCallMode.chat,
      startedAt: _t0,
      endedAt: _t0.add(const Duration(minutes: 1)),
      turns: _turns(),
      cards: _cards(),
    );
    final List<Object> timeline = voiceCallTimeline(record);
    expect(timeline, hasLength(6));
    expect(timeline[0], isA<VoiceTurn>());
    expect(timeline[1], isA<VoiceTurn>());
    expect((timeline[2] as VoiceCard).id, 'w');
    expect((timeline[3] as VoiceCard).id, 's');
    expect((timeline[4] as VoiceCard).id, 'g');
    expect((timeline[5] as VoiceTurn).text, 'And the');
  });

  test('formatVoiceCallClock', () {
    expect(formatVoiceCallClock(const Duration(seconds: 5)), '00:05');
    expect(
      formatVoiceCallClock(const Duration(minutes: 12, seconds: 3)),
      '12:03',
    );
    expect(
      formatVoiceCallClock(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
    expect(formatVoiceCallClock(const Duration(seconds: -3)), '00:00');
  });

  group('VoiceCallRecordCard', () {
    VoiceCallRecord record() => VoiceCallRecord(
      chatId: 'c',
      mode: VoiceCallMode.agents,
      startedAt: _t0,
      endedAt: _t0.add(const Duration(minutes: 3)),
      turns: _turns(),
      cards: _cards(),
    );

    testWidgets('collapsed shows the summary, a tap opens the transcript', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(VoiceCallRecordCard(record())));
      expect(find.text('Voice call · 3 min · 3 turns'), findsOneWidget);
      expect(find.byType(VoiceTurnLine), findsNothing);
      expect(find.byType(VoiceAgentCard), findsNothing);

      await tester.tap(find.text('Voice call · 3 min · 3 turns'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(VoiceTurnLine), findsNWidgets(3));
      expect(find.byType(VoiceAgentCard), findsNWidgets(3));
      expect(
        find.textContaining('What is on my list?', findRichText: true),
        findsOneWidget,
      );
      // Agents mode labels the agent's lines "Agent".
      expect(find.textContaining('Agent', findRichText: true), findsWidgets);

      await tester.tap(find.text('Voice call · 3 min · 3 turns'));
      await tester.pumpAndSettle();
      expect(find.byType(VoiceTurnLine), findsNothing);
    });

    testWidgets('fits 360 px at 1.3 text scale, expanded', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          VoiceCallRecordCard(record(), initiallyExpanded: true),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('VoiceCallPanel', () {
    late VoiceCallController controller;

    setUp(() => controller = VoiceCallController.forTesting());
    tearDown(() => controller.dispose());

    testWidgets('hidden when no call runs, or the call is another chat', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(VoiceCallPanel(chatId: 'c1', controller: controller)),
      );
      expect(find.text('Hang up'), findsNothing);
      expect(find.byTooltip('Hang up'), findsNothing);

      controller.debugSetState(phase: VoiceCallPhase.live, chatId: 'other');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Hang up'), findsNothing);
    });

    testWidgets('live: status, transcript, tool line, cards, controls', (
      WidgetTester tester,
    ) async {
      controller.debugSetState(
        phase: VoiceCallPhase.live,
        chatId: 'c1',
        mode: VoiceCallMode.chat,
        turns: _turns(),
        cards: _cards(),
        runningTools: <VoiceToolActivity>[
          VoiceToolActivity(
            callId: 'k',
            name: 'search_web',
            status: 'running',
            at: _t0,
          ),
        ],
        agentSpeaking: true,
        startedAt: DateTime.now(),
      );
      await tester.pumpWidget(
        _host(
          VoiceCallPanel(chatId: 'c1', controller: controller),
          textScale: 1.3,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('Speaking'), findsOneWidget);
      expect(find.text('Searching the web…'), findsOneWidget);
      // The transcript is lazy and pinned to the newest line.
      expect(
        find.textContaining('And the', findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(VoiceAgentCard), findsWidgets);
      expect(find.byTooltip('Mute'), findsOneWidget);
      expect(find.byTooltip('Hang up'), findsOneWidget);

      // The speaking bars stop moving when the agent stops.
      controller.debugSetState(
        phase: VoiceCallPhase.live,
        chatId: 'c1',
        turns: _turns(),
        startedAt: DateTime.now(),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Listening'), findsOneWidget);
      expect(find.byType(VoiceAgentCard), findsNothing);
      // Unmount so the clock's ticker stops.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('muted shows Unmute and the Muted status', (
      WidgetTester tester,
    ) async {
      controller.debugSetState(
        phase: VoiceCallPhase.live,
        chatId: 'c1',
        micMuted: true,
      );
      await tester.pumpWidget(
        _host(VoiceCallPanel(chatId: 'c1', controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Unmute'), findsOneWidget);
      expect(find.text('Muted'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('failed shows the error; dismiss returns to idle', (
      WidgetTester tester,
    ) async {
      controller.debugSetState(
        phase: VoiceCallPhase.failed,
        chatId: 'c1',
        error: 'The voice agent did not answer',
      );
      await tester.pumpWidget(
        _host(
          VoiceCallPanel(chatId: 'c1', controller: controller),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('The voice agent did not answer'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(controller.phase, VoiceCallPhase.idle);
      expect(find.text('The voice agent did not answer'), findsNothing);
    });

    testWidgets('waiting for the agent before it joins', (
      WidgetTester tester,
    ) async {
      controller.debugSetState(
        phase: VoiceCallPhase.live,
        chatId: 'c1',
        agentPresent: false,
      );
      await tester.pumpWidget(
        _host(VoiceCallPanel(chatId: 'c1', controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Waiting for the agent…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('VoiceCallButton calls back on tap', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(_host(VoiceCallButton(onPressed: () => taps++)));
    await tester.tap(find.byType(VoiceCallButton));
    expect(taps, 1);
    expect(find.byTooltip('Voice call'), findsOneWidget);
  });
}
