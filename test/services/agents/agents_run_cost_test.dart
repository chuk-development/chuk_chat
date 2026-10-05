import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';

const Map<String, dynamic> _block = <String, dynamic>{
  'currency': 'EUR',
  'eur': 0.002345,
  'input_tokens': 5000,
  'output_tokens': 150,
  'cached_tokens': 3000,
  'lines': <Map<String, dynamic>>[
    <String, dynamic>{
      'kind': 'run',
      'model': 'z-ai/glm-5.3-flash',
      'provider': 'deepinfra/fp4',
      'input_tokens': 1000,
      'output_tokens': 100,
      'cached_tokens': 0,
      'calls': 1,
      'eur': 0.002,
    },
    <String, dynamic>{
      'kind': 'aux',
      'model': 'deepseek/deepseek-v4-flash-0731',
      'input_tokens': 4000,
      'output_tokens': 50,
      'cached_tokens': 3000,
      'calls': 1,
      'eur': 0.000345,
    },
  ],
};

AgentsRelayApprovalRequest _action({
  String? decision,
  String? scope,
  List<String> options = const <String>[
    'once',
    'always_this_agent',
    'always_this_site',
    'deny',
  ],
}) => AgentsRelayApprovalRequest(
  approvalId: 'ap-7',
  action: 'action_approval',
  path: '',
  name: '',
  fileCount: 0,
  totalBytes: 0,
  baseUrl: '',
  public: false,
  sessionKey: 'thread-1',
  actionClass: 'browser_act',
  options: options,
  summary: 'Click "Buy now" on shop.example',
  site: 'shop.example',
  details: const <String, dynamic>{'element': 'Buy now'},
  decision: decision,
  decisionScope: scope,
);

void main() {
  group('the cost block', () {
    test('parses totals and lines; the total needs every line priced', () {
      final cost = AgentsRunCost.fromJson(_block)!;
      expect(cost.eur, closeTo(0.002345, 1e-9));
      expect(cost.totalTokens, 5150);
      expect(cost.cachedTokens, 3000);
      expect(cost.lines.map((l) => l.kind), <String>['run', 'aux']);
      expect(cost.lines.first.provider, 'deepinfra/fp4');

      final unpriced = AgentsRunCost.fromJson(<String, dynamic>{
        'currency': 'EUR',
        'input_tokens': 10,
        'output_tokens': 2,
        'lines': <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'run',
            'input_tokens': 10,
            'output_tokens': 2,
          },
        ],
      })!;
      expect(unpriced.eur, isNull);
      expect(unpriced.lines.single.eur, isNull);
      expect(AgentsRunCost.fromJson(null), isNull);
      expect(AgentsRunCost.fromJson(<String, dynamic>{}), isNull);
      // A bool is not a price.
      expect(
        AgentsRunCost.fromJson(<String, dynamic>{
          'eur': true,
          'input_tokens': 1,
        })!.eur,
        isNull,
      );
    });

    test('formats the meta line figures', () {
      expect(formatRunCostEur(0.41), '€0.41');
      expect(formatRunCostEur(0.002345), '< €0.01');
      expect(formatRunCostEur(1.5, locale: 'de'), contains('1,50'));
      expect(formatRunCostLineEur(0.000345), '€0.0003');
      expect(formatTokenCount(950), '950');
      expect(formatTokenCount(5150), '5.2k');
      expect(formatTokenCount(5000), '5k');
      expect(formatTokenCount(5150, locale: 'de'), '5,2k');
      expect(formatTokenCount(1250000), '1.3M');
    });
  });

  group('the answer keeps the run meta as one call', () {
    test('split lifts it off the calls and the blocks', () {
      final meta = runMetaCall(
        cost: AgentsRunCost.fromJson(_block),
        runId: 'run-1',
      )!;
      final shell = ToolCall(name: 'shell', status: ToolCallStatus.completed);
      final split = splitRunMeta(
        <ToolCall>[shell, meta],
        <ContentBlock>[
          const ContentBlock.text('answer'),
          ContentBlock.toolCalls(<ToolCall>[meta]),
          ContentBlock.toolCalls(<ToolCall>[shell, meta]),
        ],
      );
      expect(split.toolCalls!.map((c) => c.name), <String>['shell']);
      expect(split.contentBlocks, hasLength(2));
      expect(split.contentBlocks!.last.toolCalls!.single.name, 'shell');
      expect(split.cost!.totalTokens, 5150);
      expect(split.runId, 'run-1');
    });

    test('a row without it passes through unchanged', () {
      final calls = <ToolCall>[ToolCall(name: 'shell')];
      final blocks = <ContentBlock>[const ContentBlock.text('x')];
      final split = splitRunMeta(calls, blocks);
      expect(identical(split.toolCalls, calls), isTrue);
      expect(identical(split.contentBlocks, blocks), isTrue);
      expect(split.cost, isNull);
      expect(split.runId, isNull);
    });

    test('it survives the JSON round trip the cache does', () {
      final meta = runMetaCall(cost: AgentsRunCost.fromJson(_block))!;
      final back = ToolCall.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );
      expect(
        splitRunMeta(<ToolCall>[back], null).cost!.eur,
        closeTo(0.002345, 1e-9),
      );
    });

    test('the ledger keeps one meta call across two finishes', () {
      final ledger = AgentsRunLedger.instance;
      ledger.reset();
      ledger.begin('thread-1');
      ledger.finish(
        'thread-1',
        reason: 'finished',
        runId: 'run-1',
        cost: AgentsRunCost.fromJson(_block),
      );
      // The thread view closes the run again, with no cost.
      ledger.finish('thread-1', reason: 'finished', runId: 'run-1');
      final run = ledger.take('thread-1')!;
      final metas = run.toolCalls.where((c) => c.name == kAgentsRunMetaTool);
      expect(metas, hasLength(1));
      final split = splitRunMeta(run.toolCalls, null);
      expect(split.cost!.eur, closeTo(0.002345, 1e-9));
      expect(split.runId, 'run-1');
      ledger.reset();
    });
  });

  group('the approval transcript line', () {
    test('an open action approval offers nothing to tap', () {
      final call = approvalCallFromRelay(_action());
      expect(call.name, 'ask_user');
      expect(call.arguments.containsKey('options'), isFalse);
      expect(call.arguments['offered_options'], <String>[
        'Allow once',
        'Always for this coworker',
        'Always on shop.example',
        'Deny',
      ]);
      expect(call.arguments['question'], 'Click "Buy now" on shop.example');
      // The details stay out of the stored line.
      expect(jsonEncode(call.arguments).contains('Buy now"}'), isFalse);
      expect(call.arguments.containsKey('decision'), isFalse);
    });

    test('a replayed decided row says what the answer covered', () {
      final call = approvalCallFromRelay(
        _action(decision: 'approved', scope: 'always_this_site'),
      );
      expect(call.arguments['decision'], 'Allowed always on shop.example');
      expect(call.arguments['decision_scope'], 'always_this_site');
      final denied = approvalCallFromRelay(
        _action(decision: 'denied', scope: 'deny'),
      );
      expect(denied.arguments['decision'], 'Denied');
    });

    test('the ledger records a live answer on the open line', () {
      final ledger = AgentsRunLedger.instance;
      ledger.reset();
      ledger.begin('thread-1');
      ledger.approval('thread-1', _action());
      ledger.decideApproval(
        'thread-1',
        'ap-7',
        approved: true,
        scope: 'always_this_agent',
      );
      final call = ledger
          .runFor('thread-1')!
          .toolCalls
          .singleWhere((c) => c.name == 'ask_user');
      expect(call.arguments['decision'], 'Allowed always for this coworker');
      expect(call.arguments['decision_scope'], 'always_this_agent');
      ledger.reset();
    });
  });

  group('budget notices and the override', () {
    setUp(() {
      AgentsBudgetNotices.instance.reset();
      AgentsBudgetOverride.reset();
    });

    test('one notice per coworker, week and level', () {
      AgentsBudgetWarning w(String level) =>
          AgentsBudgetWarning.fromPayload(<String, dynamic>{
            'agent_id': 'host:pc',
            'session_key': 'thread-1',
            'level': level,
            'spent_eur': 4.02,
            'budget_eur': 5.0,
            'week_starts_at': 1759701600.0,
          })!;
      final notices = AgentsBudgetNotices.instance;
      expect(notices.add(w('warning')), isTrue);
      expect(notices.add(w('warning')), isFalse);
      expect(notices.add(w('exceeded')), isTrue);
      expect(notices.forThread('thread-1')!.isExceeded, isTrue);
      notices.dismiss('thread-1');
      expect(notices.forThread('thread-1'), isNull);
      expect(
        AgentsBudgetWarning.fromPayload(<String, dynamic>{
          'agent_id': 'x',
          'level': 'nope',
        }),
        isNull,
      );
    });

    test('the override is spent by the first task of its thread', () {
      AgentsBudgetOverride.arm('thread-1');
      expect(AgentsBudgetOverride.consume('thread-2'), isFalse);
      expect(AgentsBudgetOverride.consume('thread-1'), isTrue);
      expect(AgentsBudgetOverride.consume('thread-1'), isFalse);
    });
  });
}
