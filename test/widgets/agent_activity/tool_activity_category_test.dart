import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/min_duration_hold.dart';
import 'package:chuk_chat/widgets/agent_activity/tool_activity_category.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 5, 10);

ToolCall _call(
  String name, {
  Map<String, dynamic> args = const {},
  ToolCallStatus status = ToolCallStatus.completed,
  int start = 0,
}) => ToolCall(
  name: name,
  arguments: args,
  status: status,
  startedAt: _t0.add(Duration(seconds: start)),
);

void main() {
  group('classification', () {
    test('uses the exact tool name', () {
      expect(
        toolActivityCategoryOf('web_search'),
        ToolActivityCategory.webSearch,
      );
      expect(
        toolActivityCategoryOf('web_crawl'),
        ToolActivityCategory.webFetch,
      );
      expect(
        toolActivityCategoryOf('run_command'),
        ToolActivityCategory.commands,
      );
      expect(toolActivityCategoryOf('bash'), ToolActivityCategory.commands);
      expect(
        toolActivityCategoryOf('terminal_send'),
        ToolActivityCategory.commands,
      );
      expect(toolActivityCategoryOf('python'), ToolActivityCategory.code);
      expect(toolActivityCategoryOf('read_file'), ToolActivityCategory.read);
      expect(toolActivityCategoryOf('edit_file'), ToolActivityCategory.edit);
      expect(
        toolActivityCategoryOf('browser_open'),
        ToolActivityCategory.webFetch,
      );
      // No case folding and no guess from a similar name.
      expect(toolActivityCategoryOf('Web_Search'), ToolActivityCategory.tools);
      expect(
        toolActivityCategoryOf('mcp__github__x'),
        ToolActivityCategory.tools,
      );
    });
  });

  group('group titles', () {
    test('one category: its closed label, no count', () {
      final calls = [_call('web_search'), _call('web_search')];
      expect(closedGroupTitle(calls), 'Searched the web');
    });

    test('two categories join with "and", ranked by count', () {
      final calls = [_call('read_file'), _call('bash'), _call('bash')];
      expect(closedGroupTitle(calls), 'Ran commands and read files');
    });

    test('ties keep the order of first use', () {
      expect(
        closedGroupTitle([_call('bash'), _call('read_file')]),
        'Ran commands and read files',
      );
      expect(
        closedGroupTitle([_call('read_file'), _call('bash')]),
        'Read files and ran commands',
      );
    });

    test('three categories with commas, more than three add etc.', () {
      expect(
        closedGroupTitle([
          _call('web_search'),
          _call('web_crawl'),
          _call('bash'),
        ]),
        'Searched the web, read pages, ran commands',
      );
      expect(
        closedGroupTitle([
          _call('web_search'),
          _call('web_crawl'),
          _call('bash'),
          _call('python'),
        ]),
        'Searched the web, read pages, ran commands, etc.',
      );
    });

    test('a call counted twice by id counts once', () {
      final shared = _call('bash');
      expect(
        rankedCategories([
          shared,
          shared,
          _call('read_file'),
          _call('read_file'),
        ]),
        [ToolActivityCategory.read, ToolActivityCategory.commands],
      );
    });

    test('running title follows the newest call still in flight', () {
      final calls = [
        _call('bash', status: ToolCallStatus.running, start: 1),
        _call('read_file', status: ToolCallStatus.running, start: 2),
      ];
      expect(runningGroupTitle(calls), 'Reading files');
      calls[1].status = ToolCallStatus.completed;
      expect(runningGroupTitle(calls), 'Running commands');
      calls[0].status = ToolCallStatus.completed;
      expect(runningGroupTitle(calls), 'Analyzing the request');
    });

    test('live detail is the first usable argument, cut at 160', () {
      final calls = [
        _call(
          'run_command',
          args: {'description': '  ', 'command': 'pnpm   test', 'path': 'x'},
          status: ToolCallStatus.running,
        ),
      ];
      expect(liveDetail(calls), 'pnpm test');
      final long = _call(
        'web_search',
        args: {'query': 'a' * 300},
        status: ToolCallStatus.running,
      );
      final String detail = liveDetail([long])!;
      expect(detail.runes.length, kMaxLiveDetailChars);
      expect(detail.endsWith('…'), isTrue);
      expect(
        callDetail(
          _call(
            'web_search',
            args: {
              'queries': ['react', 'hooks'],
            },
          ),
        ),
        'react, hooks',
      );
    });
  });

  group('preparing rows', () {
    test('an edit names the file and the KB it sends', () {
      final call = _call(
        'edit_file',
        args: {
          'path': 'docs/intro.md',
          'old_string': 'a' * 600,
          'new_string': 'b' * 600,
        },
        status: ToolCallStatus.pending,
      );
      expect(preparingLabel(call), 'Preparing: Edit intro.md 2KB');
    });

    test('a command names what it runs', () {
      final call = _call(
        'bash',
        args: {'command': 'ls -la'},
        status: ToolCallStatus.pending,
      );
      expect(preparingLabel(call), 'Preparing: Run ls -la');
    });

    test('only a pending call is preparing', () {
      expect(preparingLabel(_call('bash', args: {'command': 'ls'})), isNull);
    });
  });

  group('grouping', () {
    test('two or more consecutive calls fold into one group', () {
      final entries = groupAgentActivityEntries(
        buildAgentActivityEntries([
          _call('web_search', args: {'query': 'a'}),
          _call('web_crawl', args: {'url': 'https://a.example'}),
        ]),
      );
      expect(entries, hasLength(1));
      expect(entries.single.isGroup, isTrue);
      expect(entries.single.groupCalls, hasLength(2));
    });

    test('a single call stays a plain line', () {
      final entries = groupAgentActivityEntries(
        buildAgentActivityEntries([
          _call('web_search', args: {'query': 'a'}),
        ]),
      );
      expect(entries.single.isGroup, isFalse);
      expect(entries.single.detail, 'a');
    });

    test('a thinking note breaks a run', () {
      final entries = groupAgentActivityEntries(
        buildAgentActivityEntriesFromSteps([
          AgentActivityStep.tool(_call('web_search')),
          AgentActivityStep.tool(_call('web_search')),
          const AgentActivityStep.reasoning('Now I check the page.'),
          AgentActivityStep.tool(_call('web_crawl')),
        ]),
      );
      expect(entries.map((e) => e.isGroup), [true, false, false]);
      expect(entries[1].kind, AgentActivityKind.thinking);
    });

    test('a failure inside a group marks the group', () {
      final group = groupAgentActivityEntries(
        buildAgentActivityEntries([
          _call('web_search'),
          _call('web_search', status: ToolCallStatus.error),
        ]),
      ).single;
      expect(group.anyError, isTrue);
    });
  });

  group('MinDurationHold', () {
    test('a title stays for 150 ms, the newest waiting one wins', () {
      final hold = MinDurationHold<String>();
      expect(hold.show('A', _t0), 'A');
      final t1 = _t0.add(const Duration(milliseconds: 50));
      expect(hold.show('B', t1), 'A');
      expect(hold.show('C', t1), 'A');
      expect(hold.pending, 'C');
      expect(hold.waitFor(t1), const Duration(milliseconds: 100));
      final t2 = _t0.add(const Duration(milliseconds: 160));
      expect(hold.show('C', t2), 'C');
      expect(hold.pending, isNull);
    });

    test('the same title never waits', () {
      final hold = MinDurationHold<String>();
      hold.show('A', _t0);
      expect(hold.show('A', _t0.add(const Duration(milliseconds: 1))), 'A');
      expect(hold.waitFor(_t0), isNull);
    });
  });
}
