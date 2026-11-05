import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'package:chuk_chat/utils/composer_focus_policy.dart';
import 'package:flutter/foundation.dart';

void main() {
  final ChatTurnStats stats = ChatTurnStats.instance;
  setUp(stats.debugReset);

  test('records tps and usage per chat, last usage wins', () {
    int notified = 0;
    void listener() => notified++;
    stats.addListener(listener);
    stats.recordTps('a', 42.5);
    stats.recordUsage('a', <String, dynamic>{
      'prompt_tokens': 100,
      'completion_tokens': 10,
    });
    stats.recordUsage('a', <String, dynamic>{
      'prompt_tokens': 1000,
      'completion_tokens': 50,
      'prompt_tokens_details': <String, dynamic>{'cached_tokens': 500},
    });
    stats.removeListener(listener);
    final ChatTurnStatsEntry entry = stats.of('a')!;
    expect(entry.tps, 42.5);
    expect(entry.usage!.promptTokens, 1000);
    expect(entry.usage!.cacheHitRatio, 0.5);
    expect(stats.of('b'), isNull);
    expect(notified, 3);
  });

  // H2: a reply that brings no usage must not inherit the last one (the
  // send paths stamp `usageOf` at finalize, and the compaction estimate
  // anchors on it).
  test('beginTurn drops the previous reply usage', () {
    stats.recordUsage('a', <String, dynamic>{
      'prompt_tokens': 90000,
      'completion_tokens': 10,
    });
    stats.recordUsage('b', <String, dynamic>{
      'prompt_tokens': 5,
      'completion_tokens': 1,
    });
    stats.beginTurn('a');
    expect(stats.usageOf('a'), isNull);
    expect(stats.usageOf('b')!.promptTokens, 5);
    stats.recordUsage('a', <String, dynamic>{
      'prompt_tokens': 7,
      'completion_tokens': 2,
    });
    expect(stats.usageOf('a')!.promptTokens, 7);
  });

  test('ignores empty usage and non-positive tps', () {
    stats.recordUsage('a', <String, dynamic>{});
    stats.recordTps('a', 0);
    expect(stats.of('a'), isNull);
  });

  test('unknown cache count stays null', () {
    stats.recordUsage('a', <String, dynamic>{'prompt_tokens': 10});
    expect(stats.usageOf('a')!.cachedTokens, isNull);
    expect(stats.usageOf('a')!.cacheHitRatio, isNull);
  });

  test('rename moves the entry to the new id', () {
    stats.recordTps('tmp', 10);
    stats.rename('tmp', 'real');
    expect(stats.of('tmp'), isNull);
    expect(stats.of('real')!.tps, 10);
  });

  test('context length from the catalogue: pinned provider, else largest', () {
    final List<Map<String, dynamic>> models = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'm',
        'providers': <Map<String, dynamic>>[
          <String, dynamic>{'slug': 'a', 'context_length': 64000},
          <String, dynamic>{'slug': 'b', 'context_length': 128000},
        ],
      },
    ];
    expect(ChatTurnStats.contextLengthFromCatalogue(models, 'm', 'a'), 64000);
    expect(ChatTurnStats.contextLengthFromCatalogue(models, 'm', null), 128000);
    expect(ChatTurnStats.contextLengthFromCatalogue(models, 'x', null), isNull);
  });

  group('composer focus policy', () {
    test('never on phones or the web', () {
      expect(
        mayAutoFocusComposer(isWeb: false, platform: TargetPlatform.android),
        isFalse,
      );
      expect(
        mayAutoFocusComposer(isWeb: false, platform: TargetPlatform.iOS),
        isFalse,
      );
      expect(
        mayAutoFocusComposer(isWeb: true, platform: TargetPlatform.linux),
        isFalse,
      );
      expect(
        mayAutoFocusComposer(isWeb: false, platform: TargetPlatform.linux),
        isTrue,
      );
    });

    test('composer font is 16 on the web', () {
      expect(composerFontSize(isWeb: true), 16);
      expect(composerFontSize(isWeb: false), 15);
    });
  });
}
