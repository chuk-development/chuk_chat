// Per-chat routing of the chat core in the Agents build (bead chuk_chat-w9n5).
//
// The Agents build carries both kinds of chat. A chuk_chat chat (UUID id)
// runs exactly as in chuk_chat: hosted API, client-side tool loop, idle
// timeout, chuk_chat's list and chat search. An Agents thread (session key)
// runs the Agents way: relay to the host, the host's tools, no idle timeout,
// its own roster. Without the Agents build every chat is a chuk_chat chat.
//
// No network: the hosted send is faked through its test seam and the relay
// through FakeRelayController.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_tool_call_handler.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/streaming_manager_io.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/tool_handlers/chat_search_tools.dart';

import '../../support/fake_relay_controller.dart';

const String chukChatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b';
const String threadKey = 'amber-otter-2';

StoredChat _chat(String id, String text) => StoredChat(
  id: id,
  messages: <ChatMessage>[
    ChatMessage(role: 'user', text: text),
  ],
  createdAt: DateTime.utc(2026, 9, 28),
  isStarred: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRelayController controller;
  late List<String?> hostedSends;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    await VerboseService.instance.setEnabled(false);
    ChatOrigin.reset();
    await ChatStorageService.reset();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    controller = FakeRelayController();
    AgentsRelayLink.instance.bind(controller);
    // The thread on screen is NOT the chat that sends: a chuk_chat send must
    // not fall back to it.
    AgentsRelayLink.instance.sessionKey.value = threadKey;
    hostedSends = <String?>[];
    WebSocketChatService.debugHostedSend = (String? chatId) {
      hostedSends.add(chatId);
      return Stream<ChatStreamEvent>.fromIterable(const <ChatStreamEvent>[
        ChatStreamEvent.content('hosted'),
        ChatStreamEvent.done(),
      ]);
    };
  });

  tearDown(() async {
    WebSocketChatService.debugHostedSend = null;
    AgentsChatTransport.withdrawStopIntent();
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    await ChatStorageService.reset();
    ChatOrigin.reset();
    await VerboseService.instance.setEnabled(false);
  });

  Future<void> send(String? chatId) async {
    final sub = WebSocketChatService.sendStreamingChat(
      accessToken: 'token',
      message: 'hello',
      modelId: 'm1',
      providerSlug: 'p1',
      chatId: chatId,
    ).listen((_) {});
    await _drain();
    await sub.cancel();
    await _drain();
  }

  group('transport', () {
    test('Agents build: a chuk_chat chat goes to the hosted API', () async {
      ChatOrigin.agentsEnabled = true;
      expect(WebSocketChatService.usesAgentsTransport(chukChatId), isFalse);

      await send(chukChatId);

      expect(hostedSends, <String?>[chukChatId]);
      expect(controller.tasks, isEmpty);
    });

    test('Agents build: an Agents thread goes to the host', () async {
      ChatOrigin.agentsEnabled = true;
      expect(WebSocketChatService.usesAgentsTransport(threadKey), isTrue);

      await send(threadKey);

      expect(hostedSends, isEmpty);
      expect(controller.tasks, <String>['hello']);
      expect(controller.taskSessionKeys, <String>[threadKey]);
    });

    test('Agents build: a send with no chat id is hosted', () async {
      // Title generation, the offline executor and the assistant overlay.
      ChatOrigin.agentsEnabled = true;
      expect(WebSocketChatService.usesAgentsTransport(null), isFalse);

      await send(null);

      expect(hostedSends, <String?>[null]);
      expect(controller.tasks, isEmpty);
    });

    test('Agents build: a claimed key goes to the host whatever its shape',
        () async {
      ChatOrigin.agentsEnabled = true;
      const uuidShapedKey = '11111111-2222-4333-8444-555555555555';
      ChatOrigin.claimAgentsThread(uuidShapedKey);

      await send(uuidShapedKey);

      expect(hostedSends, isEmpty);
      expect(controller.taskSessionKeys, <String>[uuidShapedKey]);
    });

    test('chuk_chat build: every chat is hosted', () async {
      ChatOrigin.agentsEnabled = false;

      await send(chukChatId);
      await send(threadKey);

      expect(hostedSends, <String?>[chukChatId, threadKey]);
      expect(controller.tasks, isEmpty);
    });

    test('a stop is declared for an Agents thread only', () {
      ChatOrigin.agentsEnabled = true;
      WebSocketChatService.declareStopIntent(chukChatId);
      WebSocketChatService.declareStopIntent(threadKey);
      expect(AgentsChatTransport.hasStopIntent(chukChatId), isFalse);
      expect(AgentsChatTransport.hasStopIntent(threadKey), isTrue);

      // A chuk_chat chat's page going away does not take the thread's back.
      WebSocketChatService.withdrawStopIntent(chukChatId);
      expect(AgentsChatTransport.hasStopIntent(threadKey), isTrue);
      WebSocketChatService.withdrawStopIntent(threadKey);
      expect(AgentsChatTransport.hasStopIntent(threadKey), isFalse);
    });

    test('chuk_chat build: no stop is ever declared', () {
      ChatOrigin.agentsEnabled = false;
      WebSocketChatService.declareStopIntent(threadKey);
      expect(AgentsChatTransport.hasStopIntent(threadKey), isFalse);
    });
  });

  group('tool loop', () {
    test('Agents build: a chuk_chat chat runs the client-side loop', () {
      ChatOrigin.agentsEnabled = true;
      final handler = ToolCallHandler.forChat(chukChatId);
      expect(handler, isNot(isA<AgentsToolCallHandler>()));
      expect(handler, same(ToolCallHandler()));
    });

    test('Agents build: an Agents thread gets the host fold', () {
      ChatOrigin.agentsEnabled = true;
      expect(
        ToolCallHandler.forChat(threadKey),
        same(AgentsToolCallHandler.instance),
      );
    });

    test('Agents build: a chat with no id yet runs the client-side loop', () {
      ChatOrigin.agentsEnabled = true;
      expect(ToolCallHandler.forChat(null), same(ToolCallHandler()));
    });

    test('chuk_chat build: every chat runs the client-side loop', () {
      ChatOrigin.agentsEnabled = false;
      expect(ToolCallHandler.forChat(threadKey), same(ToolCallHandler()));
      expect(ToolCallHandler.forChat(chukChatId), same(ToolCallHandler()));
    });

    test('the client-side loop keeps its tools for a chuk_chat chat', () {
      ChatOrigin.agentsEnabled = true;
      final handler = ToolCallHandler.forChat(chukChatId);
      final session = handler.createSession(
        initialUserMessage: 'what is the weather',
        history: const <Map<String, dynamic>>[],
        accessToken: 'token',
        discoveryContextKey: chukChatId,
        nativeToolCalling: true,
      );
      // The host fold sends no tools at all; upstream's loop sends its
      // catalog, so the model can call a tool.
      expect(handler.nativeToolDefinitions(session), isNotEmpty);
      expect(
        AgentsToolCallHandler.instance.nativeToolDefinitions(session),
        isEmpty,
      );
    });
  });

  group('idle timeout', () {
    test('Agents build: kept for a chuk_chat chat, off for a thread', () {
      ChatOrigin.agentsEnabled = true;
      expect(StreamingManager.idleTimeoutEnabledFor(chukChatId), isTrue);
      expect(StreamingManager.idleTimeoutEnabledFor(threadKey), isFalse);
    });

    test('chuk_chat build: on for every chat', () {
      ChatOrigin.agentsEnabled = false;
      expect(StreamingManager.idleTimeoutEnabledFor(chukChatId), isTrue);
      expect(StreamingManager.idleTimeoutEnabledFor(threadKey), isTrue);
    });
  });

  group('lists', () {
    setUp(() {
      ChatStorageState.chatsById[chukChatId] = _chat(chukChatId, 'weekly plan');
      ChatStorageState.chatsById[threadKey] = _chat(threadKey, 'weekly plan');
    });

    test("Agents build: chuk_chat's list holds no Agents thread", () {
      ChatOrigin.agentsEnabled = true;
      expect(
        ChatStorageService.savedChats.map((c) => c.id),
        <String>[chukChatId],
      );
    });

    test("chuk_chat build: chuk_chat's list holds every chat", () {
      ChatOrigin.agentsEnabled = false;
      expect(
        ChatStorageService.savedChats.map((c) => c.id).toSet(),
        <String>{chukChatId, threadKey},
      );
    });

    test('Agents build: chat search finds chuk_chat chats only', () async {
      ChatOrigin.agentsEnabled = true;
      final found = await executeSearchChats(<String, dynamic>{
        'action': 'find_chats',
        'query': 'weekly plan',
      });
      expect(found, contains(chukChatId));
      expect(found, isNot(contains(threadKey)));

      final inThread = await executeSearchChats(<String, dynamic>{
        'action': 'search_in_chat',
        'chat_id': threadKey,
        'query': 'weekly',
      });
      expect(inThread, startsWith('Error:'));
    });

    test('chuk_chat build: chat search finds every chat', () async {
      ChatOrigin.agentsEnabled = false;
      final found = await executeSearchChats(<String, dynamic>{
        'action': 'find_chats',
        'query': 'weekly plan',
      });
      expect(found, contains(chukChatId));
      expect(found, contains(threadKey));
    });
  });

  group('sync', () {
    tearDown(ChatSyncService.stop);

    test('Agents build: the tick is chuk_chat\'s sync, not an MCP-only tick',
        () async {
      // Before, the Agents build ran an MCP-only tick that marked the first
      // sync done at once. chuk_chat's sync first waits for the sidebar cache,
      // which this test never loads, so nothing is marked done.
      ChatOrigin.agentsEnabled = true;
      ChatSyncService.start();
      await ChatSyncService.syncNow();
      expect(ChatSyncService.hasCompletedFirstSync, isFalse);
      expect(ChatSyncService.lastSyncOutcome, isNot('agents: mcp only'));
    });
  });
}

Future<void> _drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
