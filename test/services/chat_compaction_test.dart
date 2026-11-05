import 'dart:convert';
import 'dart:typed_data';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_compaction.dart';
import 'package:chuk_chat/services/chat_compaction_runner.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'package:chuk_chat/utils/image_token_estimator.dart';
import 'package:chuk_chat/utils/token_estimator.dart';
import 'package:chuk_chat/widgets/compaction_divider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _user(String text) => {'sender': 'user', 'text': text};
Map<String, String> _ai(String text, {String? usage, String? model}) => {
  'sender': 'ai',
  'text': text,
  'usage': ?usage,
  'modelId': ?model,
  if (model != null) 'provider': 'old-provider',
};

Stream<ChatStreamEvent> _reply(String text) =>
    Stream<ChatStreamEvent>.fromIterable(<ChatStreamEvent>[
      ChatStreamEvent.content(text),
      const ChatStreamEvent.done(),
    ]);

void main() {
  group('budget', () {
    test('large window: min(W*0.8, W-O-65536)', () {
      final b = ChatCompaction.budgetFor(
        contextWindow: 1000000,
        maxOutput: 32000,
      )!;
      expect(b.threshold, 800000);
      expect(b.retain, (968000 * 0.16).floor());
      final b2 = ChatCompaction.budgetFor(
        contextWindow: 200000,
        maxOutput: 32000,
      )!;
      expect(b2.threshold, 200000 - 32000 - 65536);
    });

    test('small window: headroom at most half of W-O', () {
      final b = ChatCompaction.budgetFor(
        contextWindow: 128000,
        maxOutput: 32000,
      )!;
      expect(b.threshold, 48000);
      expect(b.retain, 15360);
      expect(
        ChatCompaction.budgetFor(contextWindow: null, maxOutput: 1),
        isNull,
      );
      expect(ChatCompaction.budgetFor(contextWindow: 1000, maxOutput: 500), isNull);
    });
  });

  group('record', () {
    test('round trip and bad input', () {
      const r = CompactionRecord(summary: 'S', madeAt: 7, modelId: 'm');
      final back = CompactionRecord.decode(r.encode())!;
      expect(back.summary, 'S');
      expect(back.madeAt, 7);
      expect(back.modelId, 'm');
      expect(CompactionRecord.decode('{'), isNull);
      expect(CompactionRecord.decode('{"summary":"  "}'), isNull);
      expect(CompactionRecord.decode(null), isNull);
    });

    test('ChatMessage keeps usage and compactSummary; old JSON loads', () {
      final msg = ChatMessage(
        role: 'user',
        text: 'hi',
        compactSummary: '{"summary":"S","madeAt":3}',
      );
      final back = ChatMessage.fromJson(jsonDecode(jsonEncode(msg.toJson())));
      expect(back.compactSummary, msg.compactSummary);
      final raw = ChatUiHelpers.messageToRawMap(back);
      expect(raw['compactSummary'], msg.compactSummary);

      final answer = ChatMessage(
        role: 'assistant',
        text: 'a',
        usage: '{"prompt_tokens":10,"completion_tokens":2}',
      );
      final rawAnswer = ChatUiHelpers.messageToRawMap(
        ChatMessage.fromJson(jsonDecode(jsonEncode(answer.toJson()))),
      );
      expect(rawAnswer['usage'], answer.usage);

      final old = ChatMessage.fromJson({'role': 'user', 'text': 'x'});
      expect(old.usage, isNull);
      expect(old.compactSummary, isNull);
      expect(old.toJson().containsKey('usage'), isFalse);
    });
  });

  group('tail and history', () {
    test('tail keeps the newest user turns that fit', () {
      final messages = [
        _user('a' * 4000),
        _ai('b' * 4000),
        _user('c' * 40),
        _ai('d' * 40),
        _user('e' * 40),
        _ai('f' * 40),
      ];
      expect(
        ChatCompaction.chooseTailStart(
          messages,
          end: messages.length,
          retainTokens: 100,
        ),
        2,
      );
      // The last user turn is always kept, even over the budget.
      expect(
        ChatCompaction.chooseTailStart(
          messages,
          end: messages.length,
          retainTokens: 1,
        ),
        4,
      );
      // Nothing before the only turn: nothing to summarize.
      expect(
        ChatCompaction.chooseTailStart(
          [_user('x'), _ai('y')],
          end: 2,
          retainTokens: 1,
        ),
        isNull,
      );
    });

    test('the builder starts with the summary and the kept tail', () async {
      final messages = [
        _user('old'),
        _ai('old answer'),
        {
          ..._user('kept'),
          ChatCompaction.fieldKey: const CompactionRecord(
            summary: 'SUMMARY',
            madeAt: 4,
          ).encode(),
        },
        _ai('kept answer'),
      ];
      final starts = <int>[];
      final history = await ChatHistoryBuilder.build(
        messages: messages,
        pendingUserText: 'next',
        messageStarts: starts,
      );
      expect(history, hasLength(3));
      expect(history[0]['content'], contains('<compacted-summary>\nSUMMARY'));
      expect(history[1]['content'], 'kept');
      expect(history[2]['content'], 'kept answer');
      expect(starts, [1, 1, 1, 2]);
      expect(jsonEncode(history), isNot(contains('old answer')));
    });
  });

  group('maybeCompact', () {
    final messages = [
      _user('q1 ${'x' * 2000}'),
      _ai('a1 ${'y' * 2000}'),
      _user('q2'),
      _ai('a2'),
    ];
    Future<List<Map<String, dynamic>>> build(
      List<Map<String, String>> m,
      List<int> starts,
    ) => ChatHistoryBuilder.build(
      messages: m,
      pendingUserText: 'q3',
      messageStarts: starts,
    );

    test('below the trigger: nothing is sent', () async {
      var sent = false;
      final out = await ChatCompaction.maybeCompact(
        messages: List.of(messages),
        end: 4,
        estimatedPromptTokens: 10,
        budget: const CompactionBudget(threshold: 100, retain: 5),
        madeAt: 4,
        summaryModelId: 'm',
        summaryProviderSlug: 'p',
        buildHistory: (s) => build(messages, s),
        send:
            ({
              required instruction,
              required history,
              required modelId,
              required providerSlug,
            }) {
              sent = true;
              return _reply('x');
            },
      );
      expect(out.status, CompactionStatus.notNeeded);
      expect(sent, isFalse);
    });

    test('stores the summary on the first kept message', () async {
      final list = List.of(messages);
      final out = await ChatCompaction.maybeCompact(
        messages: list,
        end: 4,
        estimatedPromptTokens: 1000,
        budget: const CompactionBudget(threshold: 100, retain: 5),
        madeAt: 4,
        summaryModelId: 'm',
        summaryProviderSlug: 'p',
        buildHistory: (s) => build(list, s),
        send:
            ({
              required instruction,
              required history,
              required modelId,
              required providerSlug,
            }) => _reply('<think>hmm</think>## Primary Request\n- q1'),
      );
      expect(out.compacted, isTrue);
      final record = CompactionRecord.decode(list[2][ChatCompaction.fieldKey])!;
      expect(record.summary, '## Primary Request\n- q1');
      expect(record.madeAt, 4);
      expect(ChatCompaction.latestCompactionIndex(list), 2);
    });

    test('rejects a summary that is not smaller, and errors', () async {
      for (final reply in <Stream<ChatStreamEvent>>[
        _reply('z' * 20000),
        Stream<ChatStreamEvent>.fromIterable(const [
          ChatStreamEvent.error('boom'),
          ChatStreamEvent.done(),
        ]),
        _reply('   '),
      ]) {
        final list = List.of(messages);
        final out = await ChatCompaction.maybeCompact(
          messages: list,
          end: 4,
          estimatedPromptTokens: 1000,
          budget: const CompactionBudget(threshold: 100, retain: 5),
          madeAt: 4,
          summaryModelId: 'm',
          summaryProviderSlug: 'p',
          buildHistory: (s) => build(list, s),
          send:
              ({
                required instruction,
                required history,
                required modelId,
                required providerSlug,
              }) => reply,
        );
        expect(out.status, CompactionStatus.failed);
        expect(list[2].containsKey(ChatCompaction.fieldKey), isFalse);
      }
    });
  });

  group('runner', () {
    tearDown(() {
      ChatCompactionRunner.debugSend = null;
      ChatCompactionRunner.debugContextWindow = null;
    });

    test('a switch to a smaller window summarizes with the old model', () async {
      final windows = {'big': 1000000, 'small': 4000};
      ChatCompactionRunner.debugContextWindow = (id, _) async => windows[id];
      String? usedModel;
      ChatCompactionRunner.debugSend =
          ({
            required instruction,
            required history,
            required modelId,
            required providerSlug,
          }) {
            usedModel = modelId;
            return _reply('short');
          };
      final list = <Map<String, String>>[
        _user('q1 ${'x' * 8000}'),
        _ai('a1 ${'y' * 8000}', model: 'big'),
        _user('q2'),
        _ai('a2', model: 'big'),
        _user('q3'),
      ];
      final history = await ChatHistoryBuilder.build(
        messages: list.sublist(0, 4),
        pendingUserText: 'q3',
      );
      final out = await ChatCompactionRunner.beforeSend(
        messages: list,
        end: 4,
        chatId: 'chat-1',
        modelId: 'small',
        providerSlug: 'p',
        accessToken: 't',
        systemPrompt: 'sys',
        tools: const [],
        history: history,
        pendingMessage: 'q3',
        buildHistory: (s) => ChatHistoryBuilder.build(
          messages: list.sublist(0, 4),
          pendingUserText: 'q3',
          messageStarts: s,
        ),
      );
      expect(out.compacted, isTrue, reason: out.reason);
      expect(usedModel, 'big');
    });

    test('below the trigger nothing happens', () async {
      ChatCompactionRunner.debugContextWindow = (_, _) async => 1000000;
      ChatCompactionRunner.debugSend =
          ({
            required instruction,
            required history,
            required modelId,
            required providerSlug,
          }) => throw StateError('must not send');
      final list = [_user('q1'), _ai('a1'), _user('q2')];
      final out = await ChatCompactionRunner.beforeSend(
        messages: list,
        end: 2,
        chatId: 'chat-1',
        modelId: 'm',
        providerSlug: 'p',
        accessToken: 't',
        systemPrompt: 'sys',
        tools: const [],
        history: const [],
        pendingMessage: 'q2',
        buildHistory: (s) async => const [],
      );
      expect(out.status, CompactionStatus.notNeeded);
    });

    test('/compact (compactNow) runs below the trigger', () async {
      ChatCompactionRunner.debugContextWindow = (_, _) async => 1000000;
      List<Map<String, dynamic>>? sentHistory;
      ChatCompactionRunner.debugSend =
          ({
            required instruction,
            required history,
            required modelId,
            required providerSlug,
          }) {
            sentHistory = history;
            return _reply('short');
          };
      final list = <Map<String, String>>[
        _user('q1 ${'x' * 4000}'),
        _ai('a1 ${'y' * 4000}'),
        _user('q2'),
        _ai('a2'),
      ];
      final out = await ChatCompactionRunner.compactNow(
        messages: list,
        chatId: 'chat-1',
        modelId: 'm',
        providerSlug: 'p',
        accessToken: 't',
        systemPrompt: 'sys',
        tools: const [],
        buildHistory: (s) => ChatHistoryBuilder.build(
          messages: list,
          pendingUserText: '',
          messageStarts: s,
        ),
      );
      expect(out.compacted, isTrue, reason: out.reason);
      // The last user turn stays; the summary sits on it.
      expect(out.tailStart, 2);
      expect(list[2][ChatCompaction.fieldKey], isNotNull);
      // Only the span before the kept tail went out.
      expect(sentHistory, hasLength(2));
    });

    test('/compact with an unknown window keeps a fixed tail', () async {
      ChatCompactionRunner.debugContextWindow = (_, _) async => null;
      ChatCompactionRunner.debugSend =
          ({
            required instruction,
            required history,
            required modelId,
            required providerSlug,
          }) => _reply('short');
      final list = <Map<String, String>>[
        _user('q1 ${'x' * 4000}'),
        _ai('a1 ${'y' * 4000}'),
        _user('q2'),
        _ai('a2'),
      ];
      final out = await ChatCompactionRunner.compactNow(
        messages: list,
        chatId: 'chat-1',
        modelId: 'm',
        providerSlug: 'p',
        accessToken: 't',
        systemPrompt: 'sys',
        tools: const [],
        buildHistory: (s) => ChatHistoryBuilder.build(
          messages: list,
          pendingUserText: '',
          messageStarts: s,
        ),
      );
      expect(out.compacted, isTrue, reason: out.reason);
    });

    test('/compact with one turn has nothing to summarize', () async {
      ChatCompactionRunner.debugContextWindow = (_, _) async => 1000000;
      ChatCompactionRunner.debugSend =
          ({
            required instruction,
            required history,
            required modelId,
            required providerSlug,
          }) => throw StateError('must not send');
      final list = <Map<String, String>>[_user('q1'), _ai('a1')];
      final out = await ChatCompactionRunner.compactNow(
        messages: list,
        chatId: 'chat-1',
        modelId: 'm',
        providerSlug: 'p',
        accessToken: 't',
        systemPrompt: 'sys',
        tools: const [],
        buildHistory: (s) => ChatHistoryBuilder.build(
          messages: list,
          pendingUserText: '',
          messageStarts: s,
        ),
      );
      expect(out.status, CompactionStatus.notNeeded);
    });

    test('a continue compacts with its answer row as the last row', () async {
      ChatCompactionRunner.debugContextWindow = (_, _) async => 4000;
      ChatCompactionRunner.debugSend =
          ({
            required instruction,
            required history,
            required modelId,
            required providerSlug,
          }) => _reply('short');
      // The continue's rows end with the answer it continues.
      final rows = <Map<String, String>>[
        _user('q1 ${'x' * 8000}'),
        _ai('a1 ${'y' * 8000}'),
        _user('q2'),
        _ai('a2 partial'),
      ];
      const prompt = 'Continue';
      Future<List<Map<String, dynamic>>> build([List<int>? s]) =>
          ChatHistoryBuilder.build(
            messages: rows,
            pendingUserText: prompt,
            messageStarts: s,
          );
      final out = await ChatCompactionRunner.beforeSend(
        messages: rows,
        end: rows.length,
        chatId: 'chat-1',
        modelId: 'm',
        providerSlug: 'p',
        accessToken: 't',
        systemPrompt: 'sys',
        tools: const [],
        history: await build(),
        pendingMessage: prompt,
        buildHistory: build,
      );
      expect(out.compacted, isTrue, reason: out.reason);
      expect(out.tailStart, 2);
    });
  });

  group('anchored estimate (14)', () {
    test('anchors on the last real usage plus the delta', () {
      final messages = [
        _user('q1'),
        _ai(
          'a1',
          usage: jsonEncode({'prompt_tokens': 5000, 'completion_tokens': 200}),
        ),
        _user('q2 ${'w' * 400}'),
        _ai('a2'),
      ];
      final anchor = TokenEstimator.usageAnchorOf(messages)!;
      expect(anchor.tokens, 5200);
      expect(anchor.messageIndex, 1);
      final est = ChatCompaction.estimatePrompt(
        messages: messages,
        history: const [],
        pendingMessage: 'q3',
      );
      expect(est, greaterThan(5200));
      expect(est, lessThan(5400));
    });

    test('an answer from before the latest compaction is no anchor', () {
      final messages = [
        _user('q1'),
        _ai('a1', usage: jsonEncode({'prompt_tokens': 90000})),
        {
          ..._user('q2'),
          ChatCompaction.fieldKey: const CompactionRecord(
            summary: 'S',
            madeAt: 4,
          ).encode(),
        },
        _ai('a2'),
      ];
      final est = ChatCompaction.estimatePrompt(
        messages: messages,
        history: const [
          {'role': 'user', 'content': 'S'},
        ],
        pendingMessage: 'q3',
      );
      expect(est, lessThan(1000));
    });
  });

  group('image tokens (11)', () {
    test('DeepSeek formula', () {
      expect(ImageTokenEstimator.deepSeekImageTokens(544, 544), 184);
      expect(ImageTokenEstimator.deepSeekImageTokens(4096, 4096), 994);
      expect(
        ImageTokenEstimator.deepSeekImageTokens(8000, 300),
        lessThanOrEqualTo(1024),
      );
      expect(ImageTokenEstimator.deepSeekImageTokens(10, 10), 184);
    });

    test('Anthropic and OpenAI formulas', () {
      expect(ImageTokenEstimator.anthropicImageTokens(1000, 1000), 1334);
      expect(ImageTokenEstimator.anthropicImageTokens(3136, 3136), 3279);
      expect(ImageTokenEstimator.openAiImageTokens(1024, 1024), 765);
      expect(ImageTokenEstimator.openAiImageTokens(512, 512), 255);
      expect(
        ImageTokenEstimator.tokensFor('deepseek/deepseek-v4-flash', 544, 544),
        184,
      );
      expect(
        ImageTokenEstimator.tokensFor('anthropic/claude-x', 1000, 1000),
        1334,
      );
      expect(ImageTokenEstimator.tokensFor('x/y', null, 4), 1000);
    });

    test('reads the size from PNG and JPEG headers', () {
      final png = Uint8List(32)
        ..setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..setAll(16, [0, 0, 0x02, 0x20, 0, 0, 0x01, 0x10]);
      expect(ImageTokenEstimator.dimensionsOf(png), (544, 272));
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, //
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, //
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(ImageTokenEstimator.dimensionsOf(jpeg), (512, 256));
      final url = 'data:image/png;base64,${base64Encode(png)}';
      expect(
        TokenEstimator.estimateImageBlockTokens({
          'type': 'image_url',
          'image_url': {'url': url},
        }, modelId: 'deepseek/x'),
        ImageTokenEstimator.deepSeekImageTokens(544, 272),
      );
      expect(
        TokenEstimator.estimateImageBlockTokens({
          'type': 'image_url',
          'image_url': {'url': 'https://x/y.png'},
        }),
        kUnknownImageTokens,
      );
    });
  });

  group('stats row after reload (1c)', () {
    test('the stored usage of the last answer shows, never stamps', () {
      final stats = ChatTurnStats.instance..debugReset();
      final saved = ChatTurnStats.storedUsageReader;
      addTearDown(() => ChatTurnStats.storedUsageReader = saved);
      ChatTurnStats.storedUsageReader = (_) =>
          ChatTurnStats.lastStoredUsage(<(String, String?)>[
            ('user', null),
            ('assistant', '{"prompt_tokens":10,"cached_tokens":5}'),
          ]);
      expect(stats.displayOf('c')!.usage!.cacheHitRatio, 0.5);
      expect(stats.usageOf('c'), isNull);
      expect(
        ChatTurnStats.lastStoredUsage(<(String, String?)>[
          ('assistant', '{"prompt_tokens":10}'),
          ('assistant', null),
        ]),
        isNull,
      );
    });
  });

  testWidgets('divider shows its label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CompactionDivider()),
      ),
    );
    expect(find.text('Earlier messages summarized'), findsOneWidget);
  });
}
