import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/round_content_block_service.dart';

void main() {
  group('RoundContentBlockService', () {
    test('orders reasoning, tool calls, then text', () {
      final toolCalls = [
        ToolCall(name: 'find_tools', status: ToolCallStatus.completed),
      ];

      final result = RoundContentBlockService.buildRoundBlocks(
        interimText: 'Ich habe eine erste Einordnung.',
        providerReasoning: 'Ich suche zuerst passende Quellen.',
        newToolCalls: toolCalls,
      );

      expect(
        result.blocks.map((b) => b.type).toList(),
        equals([
          ContentBlockType.reasoning,
          ContentBlockType.toolCalls,
          ContentBlockType.text,
        ]),
      );
    });

    test(
      'orders reasoning, text, then tool calls for pre-tool interim text',
      () {
        final toolCalls = [
          ToolCall(name: 'web_search', status: ToolCallStatus.completed),
        ];

        final result = RoundContentBlockService.buildRoundBlocks(
          interimText: 'ZWISCHENSTAND 1: Ich habe erste Treffer.',
          providerReasoning: 'Ich suche jetzt die naechsten Details.',
          newToolCalls: toolCalls,
          interimBeforeToolCalls: true,
        );

        expect(
          result.blocks.map((b) => b.type).toList(),
          equals([
            ContentBlockType.reasoning,
            ContentBlockType.text,
            ContentBlockType.toolCalls,
          ]),
        );
      },
    );

    test('keeps multiple tool calls together in one block', () {
      final toolCalls = [
        ToolCall(name: 'find_tools', status: ToolCallStatus.completed),
        ToolCall(name: 'web_search', status: ToolCallStatus.completed),
      ];

      final result = RoundContentBlockService.buildRoundBlocks(
        interimText: '',
        providerReasoning: 'Ich nutze mehrere Tools.',
        newToolCalls: toolCalls,
      );

      final toolBlocks = result.blocks
          .where((b) => b.type == ContentBlockType.toolCalls)
          .toList();

      expect(toolBlocks, hasLength(1));
      expect(toolBlocks.first.toolCalls, hasLength(2));
    });

    test('drops duplicate interim text when it equals fallback reasoning', () {
      final toolCall = ToolCall(
        name: 'find_tools',
        status: ToolCallStatus.completed,
        roundThinking: 'Ich ermittle zuerst die relevanten Quellen.',
      );

      final result = RoundContentBlockService.buildRoundBlocks(
        interimText: 'Ich ermittle zuerst die relevanten Quellen.',
        providerReasoning: '',
        newToolCalls: [toolCall],
      );

      expect(result.interimOutputText, isEmpty);
      expect(
        result.blocks.map((b) => b.type).toList(),
        equals([ContentBlockType.reasoning, ContentBlockType.toolCalls]),
      );
    });

    test('removes reasoning prefix from interim text', () {
      final result = RoundContentBlockService.buildRoundBlocks(
        interimText:
            'Ich habe genug Infos gesammelt.\nZWISCHENSTAND 2: Ich bin fertig.',
        providerReasoning: 'Ich habe genug Infos gesammelt.',
        newToolCalls: const [],
      );

      expect(result.interimOutputText, 'ZWISCHENSTAND 2: Ich bin fertig.');
      expect(
        result.blocks.map((b) => b.type).toList(),
        equals([ContentBlockType.reasoning, ContentBlockType.text]),
      );
    });
  });
}
