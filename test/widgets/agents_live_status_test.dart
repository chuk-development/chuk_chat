import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:chuk_chat/widgets/agent_activity/agents_live_status.dart';
import 'package:chuk_chat/widgets/agent_activity/turn_status.dart';

import '../support/fake_relay_controller.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

/// The status line above a running Agents answer (research item 4): it says
/// within a frame that the host has the message, which phase the run is in,
/// with the clock, and offers Retry when the computer cannot be reached.
void main() {
  const key = 'thread-1';
  final ledger = AgentsRunLedger.instance;
  final link = AgentsRelayLink.instance;
  late FakeRelayController controller;

  setUp(() {
    ledger.reset();
    link.reset();
    controller = FakeRelayController();
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'host',
      ),
    );
    link.bind(controller);
  });

  tearDown(() {
    ledger.reset();
    link.reset();
  });

  group('TurnStatus.liveVerb', () {
    test('a live phase prints with a dot, not "for"', () {
      const status = TurnStatus(
        isRunning: true,
        hasToolCalls: false,
        liveVerb: 'Preparing',
        elapsed: Duration(seconds: 41),
      );
      expect(status.label, 'Preparing · 41s');
    });

    test('under a second the phase stands alone', () {
      const status = TurnStatus(
        isRunning: true,
        hasToolCalls: false,
        liveVerb: 'Got it',
        elapsed: Duration(milliseconds: 300),
      );
      expect(status.label, 'Got it');
    });

    test('a settled turn ignores the live phase', () {
      const status = TurnStatus(
        isRunning: false,
        hasToolCalls: true,
        liveVerb: 'Writing',
        elapsed: Duration(seconds: 12),
      );
      expect(status.label, 'Worked for 12s');
    });
  });

  AgentsLiveStatus source({Future<void> Function()? retry}) =>
      AgentsLiveStatus.forTest(
        key,
        ledger: ledger,
        link: link,
        streamPhase: (_) => null,
        retry: retry,
      );

  Widget timeline(AgentsLiveStatus live, {DateTime? startedAt}) =>
      AgentActivityTimeline(
        toolCalls: const <ToolCall>[],
        steps: const [],
        isRunning: true,
        startedAt: startedAt,
        liveVerb: live.verb,
        liveTrailing: live.trailing,
        liveListenable: live.listenable,
      );

  testWidgets('the host ack shows within one frame, not on the next tick', (
    tester,
  ) async {
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    await tester.pumpWidget(_app(timeline(source())));
    await tester.pump();
    expect(find.text('Sending'), findsOneWidget);

    ledger.taskAcknowledged(key, taskId: 't-1');
    await tester.pump();
    expect(find.text('Got it'), findsOneWidget);

    ledger.heartbeat(key);
    await tester.pump();
    expect(find.text('Preparing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the clock runs next to the phase', (tester) async {
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    ledger.taskAcknowledged(key, taskId: 't-1');
    ledger.heartbeat(key);
    await tester.pumpWidget(
      _app(
        timeline(
          source(),
          startedAt: DateTime.now().subtract(const Duration(seconds: 41)),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Preparing · 4\ds$')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('German wording comes from the app strings', (tester) async {
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    ledger.taskAcknowledged(key, taskId: 't-1');
    await tester.pumpWidget(
      _app(timeline(source()), locale: const Locale('de')),
    );
    await tester.pump();
    expect(find.text('Angekommen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an offline computer says so and offers Retry', (tester) async {
    var retries = 0;
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.closed));
    await tester.pumpWidget(
      _app(timeline(source(retry: () async => retries++))),
    );
    await tester.pump();
    expect(find.text('Your computer is offline'), findsOneWidget);
    final retry = find.byKey(const ValueKey<String>('agents-status-retry'));
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pump(const Duration(milliseconds: 400));
    expect(retries, 1);

    // Back online: the Retry goes away with the next repaint.
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'host',
      ),
    );
    ledger.taskAcknowledged(key, taskId: 't-1');
    await tester.pump();
    expect(find.text('Got it'), findsOneWidget);
    expect(retry, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the line fits a 360 px phone at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.error));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          textScaler: TextScaler.linear(1.3),
        ),
        child: _app(
          timeline(
            source(retry: () async {}),
            startedAt: DateTime.now().subtract(const Duration(minutes: 3)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('agents-status-retry')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the phone typing pill carries the phase of an adopted run', (
    tester,
  ) async {
    ledger.adoptRunning(
      key,
      runId: 'r-1',
      prompt: 'tidy the inbox',
      startedAt: DateTime.now().subtract(const Duration(seconds: 12)),
    );
    await tester.pumpWidget(
      _app(AgentsLiveStatusLine(sessionKey: key, ledger: ledger, link: link)),
    );
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Working · 1\ds$')), findsOneWidget);
    ledger.openTool(key, 'web_search');
    await tester.pump();
    expect(
      find.textContaining(RegExp(r'^Searching the web · 1\ds$')),
      findsOneWidget,
    );
    // Nothing runs: the line is gone, not frozen.
    ledger.finish(key, finalAnswer: 'done', reason: 'finished');
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('agents-live-status-line')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
