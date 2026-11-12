// The rail counts what a person wrote, and never more than a readable number.
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/chat_turn_rail.dart';

void main() {
  test('a prompt nobody typed is not a strip', () {
    final List<Map<String, String>> messages = <Map<String, String>>[
      <String, String>{'sender': 'user', 'text': 'check my mail'},
      <String, String>{'sender': 'ai', 'text': 'nothing new'},
      <String, String>{
        'sender': 'user',
        'text': 'hourly check',
        'inputMode': 'agents_source:schedule',
      },
      <String, String>{'sender': 'ai', 'text': 'still nothing'},
      <String, String>{'sender': 'user', 'text': 'thanks'},
    ];
    final List<ChatTurnRailTick> ticks = chatTurnRailTicks(messages);
    expect(ticks.map((ChatTurnRailTick t) => t.index), <int>[0, 4]);
  });

  test('a long chat keeps the newest strips only', () {
    final List<Map<String, String>> messages = <Map<String, String>>[
      for (int i = 0; i < 300; i++) ...<Map<String, String>>[
        <String, String>{'sender': 'user', 'text': 'q$i'},
        <String, String>{'sender': 'ai', 'text': 'a$i'},
      ],
    ];
    final List<ChatTurnRailTick> ticks = chatTurnRailTicks(messages);
    expect(ticks.length, kChatTurnRailMaxTicks);
    expect(ticks.last.index, 598);
    expect(ticks.first.index, 598 - 2 * (kChatTurnRailMaxTicks - 1));
  });
}
