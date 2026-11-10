import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/turn_usage.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

Future<void> _pump(WidgetTester tester, {TurnUsage? usage, bool info = true}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: InkRipple.splashFactory),
      home: Scaffold(
        body: MessageBubble(
          message: 'Answer.',
          isUser: false,
          showModelInfo: info,
          modelLabel: 'GLM 5.3 Flash',
          workedFor: const Duration(seconds: 3),
          usage: usage,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('compactTokenCount', () {
    expect(compactTokenCount(950), '950');
    expect(compactTokenCount(1234), '1.2k');
    expect(compactTokenCount(1500000), '1.5M');
  });

  testWidgets('the meta line shows the reply token usage', (tester) async {
    await _pump(
      tester,
      usage: TurnUsage.fromServer(<String, dynamic>{
        'prompt_tokens': 1234,
        'completion_tokens': 340,
        'prompt_tokens_details': <String, dynamic>{'cached_tokens': 1000},
      }),
    );
    expect(
      find.textContaining('1.2k in · 340 out · 1.0k cached'),
      findsOneWidget,
    );
  });

  testWidgets('an unknown cache count is left out, never 0', (tester) async {
    await _pump(
      tester,
      usage: const TurnUsage(promptTokens: 10, completionTokens: 5),
    );
    expect(find.textContaining('10 in · 5 out'), findsOneWidget);
    expect(find.textContaining('cached'), findsNothing);
  });

  testWidgets('no usage without the model-info switch', (tester) async {
    await _pump(
      tester,
      info: false,
      usage: const TurnUsage(promptTokens: 10, completionTokens: 5),
    );
    expect(find.textContaining('10 in'), findsNothing);
  });
}
