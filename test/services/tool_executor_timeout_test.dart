// Item 24: a hung tool returns an error result instead of hanging the turn.

import 'dart:async';

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('a tool that never finishes times out with an error result', () async {
    final never = Completer<ToolExecutionResult>();
    final result = await ToolExecutor.runWithTimeout(
      () => never.future,
      const Duration(milliseconds: 50),
    );
    expect(result.isError, isTrue);
    expect(result.output, 'Error: tool call timed out after 50ms');
  });

  // Regression: the deadline used to drop the result and leave the MCP
  // request running. onTimeout is how execute() aborts it.
  test('the deadline fires onTimeout so the tool can be cancelled', () async {
    var fired = 0;
    final never = Completer<ToolExecutionResult>();
    final result = await ToolExecutor.runWithTimeout(
      () => never.future,
      const Duration(milliseconds: 50),
      onTimeout: () => fired++,
    );
    expect(result.isError, isTrue);
    expect(fired, 1);
  });

  test('a tool that finishes in time does not fire onTimeout', () async {
    var fired = 0;
    final result = await ToolExecutor.runWithTimeout(
      () async => const ToolExecutionResult(output: 'ok', isError: false),
      const Duration(seconds: 5),
      onTimeout: () => fired++,
    );
    expect(result.output, 'ok');
    expect(fired, 0);
  });

  test('a tool that finishes in time keeps its result', () async {
    final result = await ToolExecutor.runWithTimeout(
      () async => const ToolExecutionResult(output: 'ok', isError: false),
      const Duration(seconds: 5),
    );
    expect(result.output, 'ok');
    expect(result.isError, isFalse);
  });

  test('no limit waits for the tool', () async {
    final result = await ToolExecutor.runWithTimeout(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return const ToolExecutionResult(output: 'late', isError: false);
    }, null);
    expect(result.output, 'late');
  });

  test('limits: 120 s by default, longer for tools with own deadlines', () {
    final executor = ToolExecutor();
    expect(ToolExecutor.defaultToolTimeout, const Duration(seconds: 120));
    expect(executor.timeoutFor('calculate'), ToolExecutor.defaultToolTimeout);
    expect(
      executor.timeoutFor('fetch_files'),
      greaterThan(const Duration(minutes: 3)),
    );
    expect(
      executor.timeoutFor('generate_image'),
      greaterThan(const Duration(seconds: 120)),
    );
  });

  test('MCP tools get a finite outer limit above the client 60 s', () {
    final executor = ToolExecutor()
      ..registerTool(
        ClientTool(
          name: 'mcp_svc__search',
          description: 'Svc: search',
          parameters: const <String, dynamic>{},
          type: ToolType.mcp,
        ),
      );
    final limit = executor.timeoutFor('mcp_svc__search');
    expect(limit, ToolExecutor.mcpToolTimeout);
    expect(limit, greaterThan(const Duration(seconds: 60)));
    expect(limit, lessThan(ToolExecutor.defaultToolTimeout));
  });

  test('execute still runs a normal tool', () async {
    // ToolCallHandler registers the built-in tools on its executor.
    final result = await ToolCallHandler().toolExecutor.execute('calculate', {
      'expression': '2+2',
    });
    expect(result.isError, isFalse);
    expect(result.output, contains('4'));
  });
}
