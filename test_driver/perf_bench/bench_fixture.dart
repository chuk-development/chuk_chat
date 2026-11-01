// Synthetic chats for the phone benchmark (docs/PERFORMANCE.md). Same shape
// as real long chats: prose, tables, code, lists, `:::` blocks, tool calls.
// No real data: the benchmark never reads the owner's account.

import 'dart:convert';

const String kBenchLongChatId = '11111111-1111-4111-8111-111111111111';
const String kBenchShortChatId = '22222222-2222-4222-8222-222222222222';
const String kBenchLongTitle = 'Bench long chat';
const String kBenchShortTitle = 'Bench short chat';

/// One answer. [i] picks the kind, so a chat holds all of them in turn.
String benchAnswer(int i) {
  switch (i % 8) {
    case 0:
      return '## Plan $i\n\n'
          '${'The assistant explains a step in plain prose. ' * 14}\n\n'
          '| Option | Cost | Risk | Note |\n|---|---|---|---|\n'
          '| Alpha | $i EUR | low | keeps the old flow |\n'
          '| Beta | ${i * 2} EUR | medium | needs a migration |\n'
          '| Gamma | ${i * 3} EUR | high | full rewrite of the module |\n\n'
          '${'A closing paragraph with **bold** and `code`. ' * 6}';
    case 1:
      return '::: steps Migration\n'
          '1. Back up the data | Copy the database first\n'
          '2. Run the rewrite | Takes about $i minutes\n'
          '3. Check the result | Compare the row counts\n'
          ':::\n\n'
          '${'A paragraph after the block that wraps on a phone. ' * 8}';
    case 2:
      return 'Here is the code.\n\n'
          '```dart\nFuture<void> run() async {\n'
          '  for (var i = 0; i < $i; i++) {\n    await step(i);\n  }\n}\n```\n\n'
          '${'And a short note about the code above it. ' * 6}';
    case 3:
      return '### Findings\n\n'
          '- first point of the list, with `inline` code\n'
          '- second point, a bit longer than the first one\n'
          '  - a nested point\n'
          '1. ordered one\n2. ordered two\n\n'
          '> [!NOTE]\n> A note the reader must not miss.\n\n'
          '${'More text with a [link](https://example.com/$i). ' * 8}';
    case 4:
      return '::: timeline\n'
          '2024 | The first release\n'
          '2025 | The second release\n'
          '2026 | The current release\n'
          ':::\n\n'
          '| Name | Value |\n|---|---|\n| a | $i |\n| b | ${i + 1} |\n\n'
          '${'A paragraph that ends the answer. ' * 8}';
    case 5:
      return '${'A longer block of prose with *emphasis* in it. ' * 30}\n\n'
          '${'A second paragraph about the same subject. ' * 16}';
    case 6:
      return '::: scale 7 von 10\nFair value for the price.\n:::\n\n'
          '${'The explanation that follows the rating. ' * 12}';
    default:
      return 'Short answer $i. ${'The assistant explains one thing. ' * 6}';
  }
}

String _toolCalls(int i) => jsonEncode(<Map<String, dynamic>>[
  for (int c = 0; c < 3; c++)
    <String, dynamic>{
      'id': 'call-$i-$c',
      'name': c.isEven ? 'web_search' : 'web_fetch',
      'arguments': <String, dynamic>{'query': 'search term $i $c'},
      'result': 'result line\n${'one row of the tool result\n' * 8}',
      'status': 'completed',
      'startedAt': '2026-09-20T10:00:0$c.000Z',
      'completedAt': '2026-09-20T10:00:0${c + 1}.000Z',
    },
]);

/// [count] messages, half of them questions.
List<Map<String, dynamic>> benchMessages(int count) =>
    <Map<String, dynamic>>[
      for (int i = 0; i < count; i++)
        if (i.isEven)
          <String, dynamic>{'role': 'user', 'text': 'Question $i, please help.'}
        else
          <String, dynamic>{
            'role': 'assistant',
            'text': benchAnswer(i),
            'modelId': 'deepseek/deepseek-v4-flash-0731',
            'provider': 'fireworks',
            'generationMs': '${1200 + i}',
            if (i % 5 == 0) 'toolCalls': _toolCalls(i),
          },
    ];

/// The long answer the streaming phase writes, about 12 KB.
String benchStreamAnswer() =>
    <String>[for (int i = 0; i < 16; i++) benchAnswer(i)].join('\n\n');
