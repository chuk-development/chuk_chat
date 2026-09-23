// In the Agents build the chat screen is mounted again on every agent switch,
// so the decoded message payloads are kept in one process-wide cache instead
// of one per screen. With the flag off each screen keeps its own, as upstream.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

List<Map<String, String>> _messages() => <Map<String, String>>[
  <String, String>{
    'sender': 'ai',
    'text': 'done',
    'toolCalls': jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'c1',
        'name': 'shell',
        'arguments': <String, dynamic>{'command': 'ls'},
        'result': 'ok',
        'status': 'completed',
        'startedAt': '2026-09-20T10:00:00.000Z',
      },
    ]),
  },
];

void main() {
  tearDown(() {
    debugAgentsChatCoreOverride = null;
    MessageRenderCache.debugClearShared();
  });

  MessageRenderData render(MessageRenderCache cache) =>
      cache.build(messages: _messages(), index: 0, isStreaming: false);

  test('Agents: a new screen reuses what the last one decoded', () {
    debugAgentsChatCoreOverride = true;
    final first = MessageRenderCache();
    final decoded = render(first).toolCalls;
    expect(decoded, hasLength(1));

    // The switch: the old screen clears its cache and a new one mounts.
    first.clear();
    final second = MessageRenderCache();
    expect(identical(render(second).toolCalls, decoded), isTrue);
  });

  test('flag off: every screen decodes for itself', () {
    debugAgentsChatCoreOverride = false;
    final first = render(MessageRenderCache()).toolCalls;
    final second = render(MessageRenderCache()).toolCalls;
    expect(first, hasLength(1));
    expect(identical(first, second), isFalse);
  });

  test('stale-call recovery still heals a running call on every load', () {
    final running = jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'c1',
        'name': 'shell',
        'arguments': <String, dynamic>{},
        'status': 'running',
        'startedAt': '2026-09-20T10:00:00.000Z',
      },
    ]);
    for (int load = 0; load < 2; load++) {
      final message = <String, String>{'sender': 'ai', 'toolCalls': running};
      expect(ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message), isTrue);
      expect(message['toolCalls'], contains('"status":"error"'));
    }
    // A payload with nothing to heal stays untouched, first time and after.
    for (int load = 0; load < 2; load++) {
      final message = _messages().single;
      final before = message['toolCalls'];
      expect(ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message), isFalse);
      expect(message['toolCalls'], before);
    }
  });
}
