import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/ui/expressive/agent_status.dart';

CoworkAgent agentWith({bool running = false}) => CoworkAgent(
  id: 'a1',
  name: 'Chief of Staff',
  running: running,
  threads: const <CoworkThreadInfo>[
    CoworkThreadInfo(key: 'a1-main', title: 'General'),
  ],
);

void main() {
  group('humanToolLabel', () {
    test('reads an id as words and keeps the tool, not the routing', () {
      expect(humanToolLabel('read_file'), 'Read file');
      expect(humanToolLabel('browser-click'), 'Browser click');
      expect(
        humanToolLabel('mcp__playwright__browser_navigate'),
        'Browser navigate',
      );
      expect(humanToolLabel('  '), 'working');
    });
  });

  group('workInProgressLabel', () {
    test('an idle coworker has no work in progress', () {
      expect(workInProgressLabel(agentWith(), null), isNull);
    });

    test('a run with no open tool still says it is working', () {
      final CoworkRun run = CoworkRun('a1-main')..running = true;
      expect(workInProgressLabel(agentWith(running: true), run), 'working');
    });

    test('the open tool is what it is doing', () {
      final CoworkRun run = CoworkRun('a1-main')..running = true;
      run.toolCalls.add(
        ToolCall(name: 'read_file', status: ToolCallStatus.completed),
      );
      run.toolCalls.add(
        ToolCall(name: 'write_file', status: ToolCallStatus.running),
      );
      expect(workInProgressLabel(agentWith(running: true), run), 'Write file');
    });

    test('a run adopted from the host names the task it picked up', () {
      final CoworkRun run = CoworkRun('a1-main')
        ..running = true
        ..detachedPrompt = 'check the seat projection';
      expect(
        workInProgressLabel(agentWith(), run),
        'check the seat projection',
      );
    });

    test('a long adopted task is cut, never wrapped into the header', () {
      final CoworkRun run = CoworkRun('a1-main')
        ..running = true
        ..detachedPrompt = 'a' * 80;
      final String? label = workInProgressLabel(agentWith(), run);
      expect(label, isNotNull);
      expect(label!.length, 42);
      expect(label.endsWith('…'), isTrue);
    });
  });
}
