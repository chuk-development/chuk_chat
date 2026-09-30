// Run errors and open streams (docs/WIRE_CONTRACT.md, "Agent permissions"):
// an error that names a thread ends that thread's stream only; an error that
// names none (a host from before the field) ends the open stream as before.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';

import '../support/fake_relay_controller.dart';

Future<void> _drain() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  ContentBlock.decodesFileBlocks = true;
  const sessionKey = 'thread-1';
  late FakeRelayController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    controller = FakeRelayController();
    AgentsRelayLink.instance.bind(controller);
    AgentsRelayLink.instance.sessionKey.value = sessionKey;
  });

  tearDown(() async {
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await VerboseService.instance.setEnabled(false);
  });

  Future<List<ChatStreamEvent>> run(List<AgentsRelayInbound> events) async {
    final seen = <ChatStreamEvent>[];
    final stream = AgentsChatTransport.sendStreamingChat(
      accessToken: 'token',
      message: 'do the thing',
      modelId: 'gpt-5',
      providerSlug: 'openai',
      chatId: sessionKey,
      reasoningEffort: 'low',
      history: const <Map<String, dynamic>>[],
      systemPrompt: 'ignored',
      maxTokens: 4096,
      temperature: 0.1,
      tools: const <Map<String, dynamic>>[],
    );
    final sub = stream.listen(seen.add);
    await _drain();
    for (final event in events) {
      controller.emit(event);
      await _drain();
    }
    await _drain();
    await sub.cancel();
    return seen;
  }

  test('an old-host error without session_key still ends the stream', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayRunError('loop failed: ValueError'),
    ]);
    expect(seen, hasLength(2));
    expect((seen.first as ErrorEvent).message, 'loop failed: ValueError');
    expect(seen.last, isA<DoneEvent>());
  });

  test('an error of another thread ends no stream', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayRunError('loop failed: ValueError', sessionKey: 'thread-2'),
      AgentsRelayDone(reason: 'finished', finalAnswer: 'all set'),
    ]);
    expect(seen.whereType<ErrorEvent>(), isEmpty);
    expect(seen.last, isA<DoneEvent>());
  });

  test('an error that names this thread still ends it', () async {
    final seen = await run(const <AgentsRelayInbound>[
      AgentsRelayRunError('loop failed: ValueError', sessionKey: sessionKey),
    ]);
    expect(seen, hasLength(2));
    expect((seen.first as ErrorEvent).message, 'loop failed: ValueError');
    expect(seen.last, isA<DoneEvent>());
  });
}
