import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/chat_debug_export.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/utils/debug_chat_formatter.dart';

/// The debug copy has to be the size chuk_chat's is. A thread that carries a
/// long answer, a long reasoning block, a tool that returned a file and an
/// attachment must not turn one tap into megabytes on the clipboard.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ChatStorageService.reset();
    await AgentsChatStore.reset();
  });

  tearDown(() async {
    await AgentsChatStore.reset();
    await ChatStorageService.reset();
  });

  test('every long field is cut to the chuk_chat length', () async {
    final long = 'x' * 9000;
    await AgentsChatStore.replaceThread('agent-1', <Map<String, dynamic>>[
      <String, dynamic>{
        'sender': 'ai',
        'text': long,
        'reasoning': long,
        'toolCalls': jsonEncode([
          {
            'id': 't1',
            'name': 'read_file',
            'arguments': {'path': long},
            'result': long,
            'status': 'success',
            'startedAt': DateTime.utc(2026).toIso8601String(),
          },
        ]),
        'contentBlocks': jsonEncode([
          {
            'type': 'sandboxArtifact',
            'sandboxArtifact': {
              'storagePath': 'p',
              'filename': 'report.pdf',
              'mime': 'application/pdf',
              'sizeBytes': 9000,
              'document': {'id': 'file:report.pdf', 'data': long},
            },
          },
        ]),
      },
    ]);

    final blob = await ChatDebugExport.build(threadKey: 'agent-1');
    final entry = (blob['transcript'] as List).first as Map<String, dynamic>;

    expect(
      (entry['text'] as String).length,
      lessThan(DebugChatFormatter.maxMessageTextChars + 40),
    );
    expect(entry['text'], contains('(9000 chars total)'));
    expect(
      (entry['reasoning'] as String).length,
      lessThan(DebugChatFormatter.maxReasoningChars + 40),
    );

    final call = (entry['tool_calls'] as List).first as Map<String, dynamic>;
    expect(
      (call['arguments'] as String).length,
      lessThan(DebugChatFormatter.maxToolArgsChars + 40),
    );
    expect(
      (call['result'] as String).length,
      lessThan(DebugChatFormatter.maxToolResultChars + 40),
    );

    // The bytes of an attached file never travel on the clipboard.
    final block = (entry['content_blocks'] as List).first as Map;
    final document = (block['sandboxArtifact'] as Map)['document'] as Map;
    expect(document['data'], '(omitted)');
    expect(document['id'], 'file:report.pdf');

    // The whole copy stays in the same order of size as the upstream one.
    final json = await ChatDebugExport.buildJson(threadKey: 'agent-1');
    expect(json.length, lessThan(9000));
  });
}
