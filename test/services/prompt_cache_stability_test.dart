// Prompt cache stability: within a chat, every request must be an exact
// extension of the one before it — system prompt, tools[], then the history
// up to the previous request's length, byte for byte. Providers cache the
// prefix; the first changed byte makes the rest a cache miss at full price.
//
// The request is modelled as the server builds it: system prompt, tools,
// then the history followed by the `message` as a trailing user turn.

import 'dart:convert';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/prompt_cache/image_budget.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CacheRequest {
  CacheRequest({
    required this.system,
    required this.tools,
    required this.history,
    required this.message,
  });

  final String system;
  final List<Map<String, dynamic>> tools;
  final List<Map<String, dynamic>> history;
  final String message;

  List<Map<String, dynamic>> get messages => [
    ...history,
    if (message.isNotEmpty) {'role': 'user', 'content': message},
  ];
}

/// Asserts that [next] starts with every byte of [previous].
void expectPrefixStable(CacheRequest previous, CacheRequest next) {
  expect(next.system, previous.system, reason: 'system prompt changed');
  expect(
    jsonEncode(next.tools),
    jsonEncode(previous.tools),
    reason: 'tools[] changed',
  );
  final prev = previous.messages;
  final now = next.messages;
  expect(now.length, greaterThanOrEqualTo(prev.length));
  for (var i = 0; i < prev.length; i++) {
    expect(
      jsonEncode(now[i]),
      jsonEncode(prev[i]),
      reason: 'history entry $i changed',
    );
  }
}

const String _sentAt1 = '2026-11-04T14:32:05.123456';
const String _sentAt2 = '2026-11-04T14:40:00.000001';

Map<String, String> _user(String text, String sentAt) => {
  'sender': 'user',
  'text': text,
  'sentAt': sentAt,
};

/// What a save + reload does to a UI map: the in-memory context is stored
/// on the message, the message goes through ChatMessage and back.
Map<String, String> _persistAndReload(Map<String, String> map) {
  final isUser = map['sender'] == 'user';
  final message = ChatMessage(
    role: isUser ? 'user' : 'assistant',
    text: map['text'] ?? '',
    images: map['images'],
    toolCalls: map['toolCalls'],
    sentAt: map['sentAt'],
    modelContext: isUser ? PromptContextLedger.contextOf(map) : null,
  );
  return ChatUiHelpers.messageToRawMap(
    ChatMessage.fromJson(jsonDecode(jsonEncode(message.toJson()))),
  );
}

/// Memory as the notes tool leaves it on a device without a signed-in user
/// (the local copy the prompt reads).
Future<void> setMemory(String text) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('identity_memory', text);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ToolCallHandler handler;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PromptContextLedger.clearForTesting();
    handler = ToolCallHandler();
    await setMemory('');
  });

  Future<(ToolLoopSession, CacheRequest)> startTurn(
    List<Map<String, String>> messages,
    String text,
    String sentAt, {
    String chatId = 'chat-1',
  }) async {
    final history = await ChatHistoryBuilder.build(
      messages: messages,
      pendingUserText: text,
    );
    final session = handler.createSession(
      initialUserMessage: text,
      userSentAt: sentAt,
      history: history,
      accessToken: 'test-token',
      discoveryContextKey: chatId,
      toolCallingEnabled: true,
      discoveryMode: false,
      nativeToolCalling: true,
    );
    final system = await handler.buildInitialSystemPrompt(session);
    return (
      session,
      CacheRequest(
        system: system,
        tools: handler.nativeToolDefinitions(session),
        history: history,
        message: session.firstPassMessage,
      ),
    );
  }

  CacheRequest nextRequest(ToolLoopSession session, ToolLoopResult result) {
    final step = result.nextStep!;
    return CacheRequest(
      system: step.systemPrompt ?? '',
      tools: handler.nativeToolDefinitions(session),
      history: step.history,
      message: step.message,
    );
  }

  NativeToolCall calc(String id) => NativeToolCall(
    id: id,
    name: 'calculate',
    arguments: jsonEncode({'expression': '2+2'}),
  );

  group('the [Sent: …] line', () {
    test('is made from the stored string, never from the clock', () {
      expect(sentStampLine(_sentAt1), '[Sent: Wed 2026-11-04 14:32]');
      expect(
        sentStampLine('2026-11-04T13:32:05.000Z'),
        '[Sent: Wed 2026-11-04 13:32 UTC]',
      );
      expect(
        sentStampLine('2026-11-04T14:32:05+01:00'),
        '[Sent: Wed 2026-11-04 14:32 UTC+01:00]',
      );
      expect(sentStampLine(null), isNull);
      expect(sentStampLine('not a date'), isNull);
    });

    test('a message without a stamp is sent as it is', () {
      expect(renderUserTurnForModel(text: ' hi '), 'hi');
    });

    test(
      'the system prompt has no date, the user message has its stamp',
      () async {
        final (session, request) = await startTurn(
          [_user('what is 2+2', _sentAt1)],
          'what is 2+2',
          _sentAt1,
        );
        expect(request.system, isNot(contains('Today is')));
        expect(request.system, contains(kSentStampSystemLine));
        expect(
          session.firstPassMessage,
          '[Sent: Wed 2026-11-04 14:32]\nwhat is 2+2',
        );
      },
    );
  });

  group('two requests of one chat share the prefix', () {
    test('a tool loop pass', () async {
      final (session, first) = await startTurn(
        [_user('what is 2+2', _sentAt1)],
        'what is 2+2',
        _sentAt1,
      );
      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('c-1')],
      );
      final second = nextRequest(session, result);
      expectPrefixStable(first, second);

      // And a third pass after it.
      final result2 = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('c-2')],
      );
      expectPrefixStable(second, nextRequest(session, result2));
    });

    test('a memory change during the turn (notes tool write)', () async {
      final (session, first) = await startTurn(
        [_user('remember tea', _sentAt1)],
        'remember tea',
        _sentAt1,
      );
      await setMemory('The user likes tea.');
      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('c-1')],
      );
      final second = nextRequest(session, result);
      expectPrefixStable(first, second);
      expect(second.system, isNot(contains('The user likes tea.')));
    });

    test('a forced final pass keeps tools[] and the system prompt', () async {
      final (session, first) = await startTurn(
        [_user('go', _sentAt1)],
        'go',
        _sentAt1,
      );
      var previous = first;
      session.finalAnswerRequested = true;
      final result = await handler.processAssistantResponse(
        session: session,
        content: '',
        reasoning: '',
        nativeToolCalls: [calc('c-1')],
      );
      final forced = nextRequest(session, result);
      expect(forced.message, kForcedFinalAnswerNote);
      expectPrefixStable(previous, forced);
    });

    test(
      'a skill activation appends <skill_content>, message 0 stays',
      () async {
        // The `skill` tool only registers with FEATURE_SKILLS; register it
        // here when the build left it out.
        if (!handler.toolExecutor.allTools.any((t) => t.name == 'skill')) {
          handler.toolExecutor.registerTool(
            ClientTool(name: 'skill', description: 'Load a skill'),
          );
        }
        final (session, first) = await startTurn(
          [_user('weather in Kiel', _sentAt1)],
          'weather in Kiel',
          _sentAt1,
        );
        final result = await handler.processAssistantResponse(
          session: session,
          content: '',
          reasoning: '',
          nativeToolCalls: [
            NativeToolCall(
              id: 's-1',
              name: 'skill',
              arguments: jsonEncode({'name': 'weather-cards'}),
            ),
          ],
        );
        final second = nextRequest(session, result);
        expectPrefixStable(first, second);
        expect(second.system, isNot(contains('## ACTIVE SKILL')));
        final last = second.history.last;
        expect(last['role'], 'user');
        expect(
          last['content'] as String,
          startsWith('<skill_content name="weather-cards">'),
        );

        // Stored with the turn: the next turn's history carries it again, at
        // the same place, after a restart too.
        final reloaded = _persistAndReload(_user('weather in Kiel', _sentAt1));
        PromptContextLedger.clearForTesting();
        final history = await ChatHistoryBuilder.build(
          messages: [
            reloaded,
            {'sender': 'ai', 'text': 'Sunny.'},
          ],
          pendingUserText: 'and tomorrow?',
        );
        expect(
          history.any(
            (e) =>
                e['content'] is String &&
                (e['content'] as String).startsWith(
                  '<skill_content name="weather-cards">',
                ),
          ),
          isTrue,
        );
      },
    );

    test('the next turn after an app restart', () async {
      final user1 = _user('hello', _sentAt1);
      final (_, first) = await startTurn([user1], 'hello', _sentAt1);

      // Restart: the in-memory ledger is gone, only the stored chat is left.
      final stored = [
        _persistAndReload(user1),
        _persistAndReload({'sender': 'ai', 'text': 'Hi! How can I help?'}),
      ];
      PromptContextLedger.clearForTesting();

      final user2 = _user('tell me more', _sentAt2);
      final (_, second) = await startTurn(
        [...stored, user2],
        'tell me more',
        _sentAt2,
      );
      expectPrefixStable(first, second);
    });

    test('a memory change between turns becomes a note, not a new system '
        'prompt', () async {
      final user1 = _user('hello', _sentAt1);
      final (_, first) = await startTurn([user1], 'hello', _sentAt1);
      final stored = [
        _persistAndReload(user1),
        _persistAndReload({'sender': 'ai', 'text': 'Hi!'}),
      ];

      await setMemory('The user lives in Kiel.');
      final user2 = _user('weather?', _sentAt2);
      final (session2, second) = await startTurn(
        [...stored, user2],
        'weather?',
        _sentAt2,
      );
      expectPrefixStable(first, second);
      expect(second.message, startsWith('[memory updated]'));
      expect(second.message, contains('The user lives in Kiel.'));
      expect(second.message, contains('[Sent: Wed 2026-11-04 14:40]'));

      // Turn 3 replays turn 2's note byte for byte and adds none.
      final stored2 = [
        ...stored,
        _persistAndReload(user2),
        _persistAndReload({'sender': 'ai', 'text': 'Sunny.'}),
      ];
      PromptContextLedger.clearForTesting();
      final (_, third) = await startTurn(
        [...stored2, _user('thanks', '2026-11-04T15:00:00.000001')],
        'thanks',
        '2026-11-04T15:00:00.000001',
      );
      expectPrefixStable(second, third);
      expect(third.message, isNot(contains('[memory updated]')));
      expect(session2.turnContext.notes, hasLength(1));
    });

    test('an MCP server change becomes a connectors note', () async {
      // The chat's stored snapshot still lists a connected server that is
      // gone now (a disconnect, or a connect seen from the other side).
      final first = _user('hello', _sentAt1)
        ..['modelContext'] = TurnPromptContext(
          snapshot: PromptState(
            identity: true,
            mcpConnected: const ['Linear'],
            mcpUnconnected: [kMcpCatalogue.first.id],
          ),
        ).encode();
      final (_, second) = await startTurn(
        [
          first,
          {'sender': 'ai', 'text': 'Hi!'},
          _user('list my issues', _sentAt2),
        ],
        'list my issues',
        _sentAt2,
      );
      // The system prompt is built from the snapshot, not the live state.
      expect(second.system, contains('Linear'));
      expect(second.message, contains('[connectors updated]'));
    });

    test('an MCP reconnect does not reorder tools[]', () async {
      final executor = handler.toolExecutor;
      ClientTool mcp(String name) => ClientTool(
        name: name,
        description: 'MCP tool $name',
        type: ToolType.mcp,
      );
      executor.registerTool(mcp('mcp_b_search'));
      executor.registerTool(mcp('mcp_a_list'));
      final (session, _) = await startTurn(
        [_user('hi', _sentAt1)],
        'hi',
        _sentAt1,
      );
      final before = jsonEncode(handler.nativeToolDefinitions(session));

      // Reconnect: unregistered and registered again, the other way round.
      executor.unregisterTool('mcp_a_list');
      executor.unregisterTool('mcp_b_search');
      executor.registerTool(mcp('mcp_a_list'));
      executor.registerTool(mcp('mcp_b_search'));
      expect(jsonEncode(handler.nativeToolDefinitions(session)), before);

      final names = executor.allTools.map((t) => t.name).toList();
      expect(
        names.indexOf('mcp_a_list'),
        lessThan(names.indexOf('mcp_b_search')),
      );
      expect(
        names.lastIndexWhere(
          (n) => executor.tools[n]!.type == ToolType.builtin,
        ),
        lessThan(names.indexOf('mcp_a_list')),
      );
      executor.unregisterTool('mcp_a_list');
      executor.unregisterTool('mcp_b_search');
    });
  });

  group('images over many turns', () {
    Future<String?> resolve(String url) async =>
        'data:image/png;base64,${base64Encode(utf8.encode(url))}';

    List<Map<String, String>> chatWithImages(int turns) => [
      for (var i = 0; i < turns; i++) ...[
        {
          'sender': 'user',
          'text': 'photo $i',
          'images': jsonEncode(['u/img-$i.enc']),
          'sentAt': '2026-11-04T10:${(i % 60).toString().padLeft(2, '0')}:00',
        },
        {'sender': 'ai', 'text': 'nice $i'},
      ],
    ];

    Future<List<Map<String, dynamic>>> send(
      int turns,
      ImageLimits limits,
    ) async {
      final messages = chatWithImages(turns);
      final history = await ChatHistoryBuilder.build(
        messages: messages,
        pendingUserText: '',
      );
      return ImageBudget.apply(history, limits: limits, resolve: resolve);
    }

    test('images stay in history: each turn extends the last', () async {
      const limits = ImageLimits(maxImages: 50, maxChars: 1 << 30);
      var previous = await send(1, limits);
      var cuts = 0;
      for (var turns = 2; turns <= 120; turns++) {
        final next = await send(turns, limits);
        var stable = true;
        for (var i = 0; i < previous.length; i++) {
          if (jsonEncode(next[i]) != jsonEncode(previous[i])) {
            stable = false;
            break;
          }
        }
        if (!stable) cuts++;
        previous = next;
      }
      // 120 images, limit 50, step 25: the cut point moved only a few
      // times, never on every turn as the old 10-turn window did.
      expect(cuts, lessThanOrEqualTo(4));
      final omitted = jsonEncode(previous).split('[image omitted:').length - 1;
      final kept = jsonEncode(previous).split('"type":"image_url"').length - 1;
      expect(kept, lessThanOrEqualTo(50));
      expect(omitted + kept, 120);
      // The oldest go first.
      expect(
        jsonEncode(previous.first),
        contains('[image omitted: img-0.enc]'),
      );
      expect(jsonEncode(previous[previous.length - 2]), contains('image_url'));
    });

    test('a byte limit cuts the oldest in the same steps', () async {
      final history = await ChatHistoryBuilder.build(
        messages: chatWithImages(10),
        pendingUserText: '',
      );
      final one = (await resolve('u/img-0.enc'))!.length;
      final out = await ImageBudget.apply(
        history,
        limits: ImageLimits(maxImages: 10, maxChars: one * 7),
        resolve: resolve,
      );
      final text = jsonEncode(out);
      // Step 5: 10 images over 7 -> the oldest 5 omitted.
      expect(text.split('[image omitted:').length - 1, 5);
      expect(text, contains('[image omitted: img-4.enc]'));
      expect(text, isNot(contains('[image omitted: img-5.enc]')));
    });

    test('a text-only model gets placeholders for every image', () async {
      final history = await ChatHistoryBuilder.build(
        messages: chatWithImages(3),
        pendingUserText: '',
      );
      final out = await ImageBudget.apply(
        history,
        limits: ImageBudget.fallback,
        resolve: resolve,
        textOnly: true,
      );
      expect(jsonEncode(out), isNot(contains('image_url')));
      expect(jsonEncode(out).split('[image omitted:').length - 1, 3);
    });

    test('limits per model family', () {
      expect(
        ImageBudget.limitsFor('anthropic/claude-sonnet-4.5').maxImages,
        100,
      );
      expect(ImageBudget.limitsFor('openai/gpt-5').maxImages, 500);
      expect(ImageBudget.limitsFor('google/gemini-3-pro').maxImages, 3000);
      expect(
        ImageBudget.limitsFor('deepseek/deepseek-v4-flash-0731').maxImages,
        50,
      );
    });
  });

  group('request metadata', () {
    test('x_chuk carries a chat hash, never the id', () {
      final meta = xChukMetadata(purpose: 'chat', chatId: 'chat-1', pass: 2);
      expect(meta['purpose'], 'chat');
      expect(meta['pass'], 2);
      expect(meta['chat_hash'], hasLength(16));
      expect(jsonEncode(meta), isNot(contains('chat-1')));
      expect(xChukMetadata(purpose: 'title').containsKey('chat_hash'), isFalse);
    });
  });
}
