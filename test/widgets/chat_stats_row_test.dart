import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'package:chuk_chat/widgets/chat_stats_row.dart';

Widget _host(Widget child, {double width = 600}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  final ChatTurnStats stats = ChatTurnStats.instance;
  setUp(stats.debugReset);

  testWidgets('shows tok/s, cache hit and context share', (tester) async {
    stats.recordTps('c', 31.24);
    stats.recordUsage('c', <String, dynamic>{
      'prompt_tokens': 9000,
      'completion_tokens': 1000,
      'prompt_tokens_details': <String, dynamic>{'cached_tokens': 4500},
    });
    await tester.pumpWidget(
      _host(
        const ChatStatsRow(
          chatId: 'c',
          modelId: 'm',
          contextLimitOverride: 100000,
        ),
      ),
    );
    expect(find.text('31.2 tok/s'), findsOneWidget);
    expect(find.text('Cache hit 50%'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);
    final Tooltip tip = tester.widget<Tooltip>(
      find.byKey(const ValueKey<String>('chat-stats-context')),
    );
    expect(tip.message, contains('10.0k'));
    expect(tip.message, contains('100k'));
    expect(tip.message, contains('Cached: 4.5k'));
    expect(
      tester.getSize(find.byType(ChatStatsRow)).height,
      kChatStatsRowHeight,
    );
  });

  testWidgets('unknown cache and limit read as a dash', (tester) async {
    stats.recordUsage('c', <String, dynamic>{'prompt_tokens': 10});
    await tester.pumpWidget(
      _host(const ChatStatsRow(chatId: 'c', modelId: '')),
    );
    expect(find.text('— tok/s'), findsOneWidget);
    expect(find.text('Cache hit —'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('keeps its height empty when nothing is known', (tester) async {
    await tester.pumpWidget(
      _host(const ChatStatsRow(chatId: 'none', modelId: 'm')),
    );
    expect(find.byKey(const ValueKey<String>('chat-stats-tps')), findsNothing);
    expect(
      tester.getSize(find.byType(ChatStatsRow)).height,
      kChatStatsRowHeight,
    );
  });

  testWidgets('hidden on narrow screens', (tester) async {
    stats.recordTps('c', 10);
    await tester.pumpWidget(
      _host(const ChatStatsRow(chatId: 'c', modelId: 'm'), width: 320),
    );
    expect(find.byKey(const ValueKey<String>('chat-stats-tps')), findsNothing);
    expect(tester.getSize(find.byType(ChatStatsRow)).height, 0);
  });

  test('formatTokenCount', () {
    expect(formatTokenCount(950), '950');
    expect(formatTokenCount(12345), '12.3k');
    expect(formatTokenCount(128000), '128k');
    expect(formatTokenCount(1000000), '1.0M');
  });
}
