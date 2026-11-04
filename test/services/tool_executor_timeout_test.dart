// Item 24: a hung tool returns an error result instead of hanging the turn.

import 'dart:async';

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

  test('a tool that finishes in time keeps its result', () async {
    final result = await ToolExecutor.runWithTimeout(
      () async => const ToolExecutionResult(output: 'ok', isError: false),
      const Duration(seconds: 5),
    );
    expect(result.output, 'ok');
    expect(result.isError, isFalse);
  });

  test('no limit (MCP) waits for the tool', () async {
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
      executor.timeoutFor('fetch_files')!,
      greaterThan(const Duration(minutes: 3)),
    );
    expect(
      executor.timeoutFor('generate_image')!,
      greaterThan(const Duration(seconds: 120)),
    );
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
