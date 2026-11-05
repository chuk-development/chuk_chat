// Item 1 leftovers of the Agents UI round: the tool row title and `+a -r`,
// the stats rename, live context chips, wait labels across a restart, and
// the automation card's "skipped N" / "retry at".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_context_rows.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/services/agents/agents_tool_row_info.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automation_ledger.dart';
import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/agents_live_status.dart';
import 'package:chuk_chat/widgets/automation_card.dart';

void main() {
  group('(a) tool row title and +a -r', () {
    test('a described host call reads as its description', () {
      final ToolCall call = ToolCall(
        name: 'run_command',
        arguments: <String, dynamic>{
          'command': 'flutter test',
          'description': 'Run the unit tests',
        },
        status: ToolCallStatus.completed,
      );
      final AgentActivityEntry entry = buildAgentActivityEntries(<ToolCall>[
        call,
      ]).single;
      expect(entry.label, 'Run the unit tests');
      expect(entry.detail, isNull);
      expect(entry.diffLabel, isNull);
    });

    test('a failed described call says so', () {
      final ToolCall call = ToolCall(
        name: 'run_command',
        arguments: <String, dynamic>{'description': 'Run the unit tests'},
        status: ToolCallStatus.error,
      );
      expect(
        buildAgentActivityEntries(<ToolCall>[call]).single.label,
        'Failed: Run the unit tests',
      );
    });

    test('an edit carries its +a -r', () {
      final ToolCall call = ToolCall(
        name: 'edit_file',
        arguments: <String, dynamic>{
          'path': 'a.dart',
          'description': 'Fix the parser',
          kToolDiffAddedKey: 3,
          kToolDiffRemovedKey: 1,
        },
        status: ToolCallStatus.completed,
      );
      final AgentActivityEntry entry = buildAgentActivityEntries(<ToolCall>[
        call,
      ]).single;
      expect(entry.label, 'Fix the parser');
      expect(entry.diffLabel, '+3 -1');
    });

    test('a call without description keeps the old wording', () {
      final ToolCall call = ToolCall(
        name: 'run_command',
        arguments: <String, dynamic>{'command': 'ls'},
        status: ToolCallStatus.completed,
      );
      final AgentActivityEntry entry = buildAgentActivityEntries(<ToolCall>[
        call,
      ]).single;
      expect(entry.label, 'Ran run command');
      expect(entry.detail, 'ls');
    });
  });

  group('(b) ChatTurnStats.rename', () {
    final ChatTurnStats stats = ChatTurnStats.instance;
    setUp(stats.debugReset);

    test('moves the numbers to the new id', () {
      stats.recordTps('old', 42);
      stats.rename('old', 'new');
      expect(stats.of('old'), isNull);
      expect(stats.of('new')?.tps, 42);
    });

    test('a rename to the same id keeps the numbers', () {
      stats.recordTps('same', 10);
      stats.rename('same', 'same');
      expect(stats.of('same')?.tps, 10);
    });
  });

  group('(d) live context rows', () {
    const String key = 'thread-ctx';
    final AgentsRunLedger ledger = AgentsRunLedger.instance;
    setUp(ledger.reset);
    tearDown(ledger.reset);

    test('a live context row is a chip row, not a step', () {
      ledger.begin(key);
      ledger.context(
        key,
        const AgentsRelayContext(source: 'skill', text: 'loaded pdf skill'),
      );
      ledger.openTool(key, 'web_search');
      final AgentsLiveStatus live = AgentsLiveStatus.forTest(
        key,
        ledger: ledger,
        streamPhase: (_) => null,
      );
      expect(live.contextRows().single.source, 'skill');
      expect(live.contextRows().single.text, 'loaded pdf skill');
      final steps = live.steps();
      expect(
        steps.any((s) => s.toolCall?.name == kAgentsContextToolName),
        isFalse,
      );
      expect(steps.single.toolCall?.name, 'web_search');
    });
  });

  group('(e) wait labels across a restart', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('encode / decode round trip; junk is dropped', () {
      final String raw = AgentsThreadModes.encodeWaits(<String, AgentsWaitKind>{
        'a': AgentsWaitKind.approval,
        'b': AgentsWaitKind.answer,
      });
      expect(AgentsThreadModes.decodeWaits(raw), <String, AgentsWaitKind>{
        'a': AgentsWaitKind.approval,
        'b': AgentsWaitKind.answer,
      });
      expect(AgentsThreadModes.decodeWaits('{"x":"nope"}'), isEmpty);
      expect(AgentsThreadModes.decodeWaits('not json'), isEmpty);
    });

    test('a label survives a new store; a live frame replaces it', () async {
      final AgentsThreadModes before = AgentsThreadModes(send: (_) async {});
      await before.loadWaits();
      before.ingest(<String, dynamic>{
        'type': 'approval_request',
        'session_key': 't1',
        'approval_id': 'ap1',
      });
      expect(before.waitKindOf('t1'), AgentsWaitKind.approval);
      await Future<void>.delayed(Duration.zero);

      // The app restarts: a fresh store, nothing from the host yet.
      final AgentsThreadModes after = AgentsThreadModes(send: (_) async {});
      expect(after.waitKindOf('t1'), isNull);
      await after.loadWaits();
      expect(after.waitKindOf('t1'), AgentsWaitKind.approval);
      expect(after.waitKindOfAny(<String>['x', 't1']), AgentsWaitKind.approval);

      // The replay says nothing runs: the stored label goes.
      after.ingest(<String, dynamic>{
        'type': 'run_state',
        'session_key': 't1',
        'state': 'idle',
      });
      expect(after.waitKindOf('t1'), isNull);
      await Future<void>.delayed(Duration.zero);
      final AgentsThreadModes third = AgentsThreadModes(send: (_) async {});
      await third.loadWaits();
      expect(third.waitKindOf('t1'), isNull);
    });
  });

  group('(f) automation skipped / retry', () {
    AgentsAutomation automation({int skipped = 0, DateTime? retryAt}) =>
        AgentsAutomation.fromPayload(<String, dynamic>{
          'id': 'ab12cd34',
          'session_key': 'thread-1',
          'kind': 'schedule',
          'name': 'inbox check',
          'state': 'active',
          'spec': <String, dynamic>{'every': 300},
          'prompt': 'check',
          'skipped_count': ?(skipped > 0 ? skipped : null),
          'retry_at': ?(retryAt == null
              ? null
              : retryAt.millisecondsSinceEpoch / 1000),
        })!;

    testWidgets('the card shows skipped N and retry in …', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AutomationCard(
              automation: automation(
                skipped: 2,
                retryAt: DateTime.now().add(const Duration(minutes: 15)),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('skipped 2'), findsOneWidget);
      expect(find.textContaining('retry in 14m'), findsOneWidget);
    });

    testWidgets('a past retry time is not shown', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AutomationCard(
              automation: automation(
                retryAt: DateTime.now().subtract(const Duration(minutes: 1)),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('retry'), findsNothing);
      expect(find.textContaining('skipped'), findsNothing);
    });

    test('the transcript line names skipped and retry events', () {
      AgentsRelayAutomation event(String name, AgentsAutomation a) =>
          AgentsRelayAutomation.fromPayload(<String, dynamic>{
            'type': 'automation',
            'event': name,
            ...a.toJson(),
          })!;
      expect(
        automationEventText(event('skipped', automation(skipped: 1))),
        startsWith('Skipped a late run: inbox check'),
      );
      final DateTime at = DateTime(2026, 11, 5, 9, 7);
      expect(
        automationEventText(event('retry', automation(retryAt: at))),
        startsWith('Will retry at 09:07: inbox check'),
      );
    });
  });
}
