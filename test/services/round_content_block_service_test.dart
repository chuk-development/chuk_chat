import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/round_content_block_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart' show RoundSegment;

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
      'folds pre-tool interim text into first tool call roundThinking',
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

        // Interim text is folded into tool call's roundThinking, not a
        // separate text block.
        expect(
          result.blocks.map((b) => b.type).toList(),
          equals([
            ContentBlockType.reasoning,
            ContentBlockType.toolCalls,
          ]),
        );

        final tcBlock = result.blocks
            .firstWhere((b) => b.type == ContentBlockType.toolCalls);
        expect(
          tcBlock.toolCalls!.first.roundThinking,
          contains('ZWISCHENSTAND 1'),
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

    test('is idempotent: same inputs twice do not double-append', () {
      final toolCalls = [
        ToolCall(
          id: 'tc-1',
          name: 'web_search',
          status: ToolCallStatus.completed,
        ),
      ];

      const providerReasoning = 'Ich suche jetzt die passenden Quellen.';
      const interimText = 'Erste Einordnung.';

      final firstPass = RoundContentBlockService.buildRoundBlocks(
        interimText: interimText,
        providerReasoning: providerReasoning,
        newToolCalls: toolCalls,
        existingBlocks: const [],
      );

      // Caller appends first-pass blocks as it normally would.
      final accumulated = <ContentBlock>[...firstPass.blocks];

      final secondPass = RoundContentBlockService.buildRoundBlocks(
        interimText: interimText,
        providerReasoning: providerReasoning,
        newToolCalls: toolCalls,
        existingBlocks: accumulated,
      );

      expect(firstPass.blocks, isNotEmpty);
      expect(
        secondPass.blocks,
        isEmpty,
        reason:
            'Second call with identical input should not re-append blocks.',
      );
    });

    test('idempotency only matches exact tail, not interior matches', () {
      final toolCalls = [
        ToolCall(
          id: 'tc-1',
          name: 'web_search',
          status: ToolCallStatus.completed,
        ),
      ];

      const providerReasoning = 'Reasoning A';

      final firstPass = RoundContentBlockService.buildRoundBlocks(
        interimText: '',
        providerReasoning: providerReasoning,
        newToolCalls: toolCalls,
      );

      // Append a text block after the first round — the same reasoning+tools
      // at the start of existingBlocks is NOT a tail match, so a repeat
      // should still append.
      final accumulated = <ContentBlock>[
        ...firstPass.blocks,
        const ContentBlock.text('Mid-stream text.'),
      ];

      final secondPass = RoundContentBlockService.buildRoundBlocks(
        interimText: '',
        providerReasoning: providerReasoning,
        newToolCalls: toolCalls,
        existingBlocks: accumulated,
      );

      expect(secondPass.blocks, isNotEmpty);
    });

    test('idempotency distinguishes different tool call ids', () {
      final firstCalls = [
        ToolCall(
          id: 'tc-1',
          name: 'web_search',
          status: ToolCallStatus.completed,
        ),
      ];
      final secondCalls = [
        ToolCall(
          id: 'tc-2',
          name: 'web_search',
          status: ToolCallStatus.completed,
        ),
      ];

      final firstPass = RoundContentBlockService.buildRoundBlocks(
        interimText: '',
        providerReasoning: 'Same reasoning',
        newToolCalls: firstCalls,
      );

      final accumulated = <ContentBlock>[...firstPass.blocks];

      final secondPass = RoundContentBlockService.buildRoundBlocks(
        interimText: '',
        providerReasoning: 'Same reasoning',
        newToolCalls: secondCalls,
        existingBlocks: accumulated,
      );

      expect(
        secondPass.blocks,
        isNotEmpty,
        reason: 'Different tool call ids should NOT dedupe as tail match.',
      );
    });

    test('segmented builder preserves interleaved text → tool → text order', () {
      final hamburgCall = ToolCall(
        id: 'tc-hh',
        name: 'weather',
        arguments: const {'location': 'Hamburg'},
        status: ToolCallStatus.completed,
      );
      final berlinCall = ToolCall(
        id: 'tc-be',
        name: 'weather',
        arguments: const {'location': 'Berlin'},
        status: ToolCallStatus.completed,
      );

      final segments = [
        RoundSegment.text('Ich hole jetzt das Wetter für Hamburg.'),
        RoundSegment.toolCall(hamburgCall),
        RoundSegment.text('In Hamburg sind es 14 °C.'),
        RoundSegment.toolCall(berlinCall),
        RoundSegment.text('In Berlin sind es 16 °C.'),
      ];

      final result = RoundContentBlockService.buildSegmentedRoundBlocks(
        segments: segments,
        providerReasoning: 'Plan: Hamburg, dann Berlin.',
      );

      expect(
        result.blocks.map((b) => b.type).toList(),
        equals([
          ContentBlockType.reasoning,
          ContentBlockType.text,
          ContentBlockType.toolCalls,
          ContentBlockType.text,
          ContentBlockType.toolCalls,
          ContentBlockType.text,
        ]),
      );
      expect(result.blocks[2].toolCalls!.single.id, 'tc-hh');
      expect(result.blocks[4].toolCalls!.single.id, 'tc-be');
    });

    test(
      'skips reasoning block when previous reasoning has identical text '
      '(buildRoundBlocks, provider re-emits same reasoning per round)',
      () {
        const sameReasoning = 'Plan: ich rufe Tools auf.';

        final firstPass = RoundContentBlockService.buildRoundBlocks(
          interimText: '',
          providerReasoning: sameReasoning,
          newToolCalls: [
            ToolCall(
              id: 'tc-1',
              name: 'code_run',
              status: ToolCallStatus.completed,
            ),
          ],
        );

        final accumulated = <ContentBlock>[...firstPass.blocks];

        final secondPass = RoundContentBlockService.buildRoundBlocks(
          interimText: '',
          providerReasoning: sameReasoning,
          newToolCalls: [
            ToolCall(
              id: 'tc-2',
              name: 'code_run',
              status: ToolCallStatus.completed,
            ),
          ],
          existingBlocks: accumulated,
        );

        expect(
          secondPass.blocks.map((b) => b.type).toList(),
          equals([ContentBlockType.toolCalls]),
          reason:
              'Reasoning identical to last reasoning block should be skipped; '
              'only the new tool call block should be appended.',
        );
      },
    );

    test(
      'still emits reasoning block when reasoning text differs from previous '
      '(buildRoundBlocks)',
      () {
        final firstPass = RoundContentBlockService.buildRoundBlocks(
          interimText: '',
          providerReasoning: 'Reasoning A',
          newToolCalls: [
            ToolCall(
              id: 'tc-1',
              name: 'code_run',
              status: ToolCallStatus.completed,
            ),
          ],
        );

        final accumulated = <ContentBlock>[...firstPass.blocks];

        final secondPass = RoundContentBlockService.buildRoundBlocks(
          interimText: '',
          providerReasoning: 'Reasoning B',
          newToolCalls: [
            ToolCall(
              id: 'tc-2',
              name: 'code_run',
              status: ToolCallStatus.completed,
            ),
          ],
          existingBlocks: accumulated,
        );

        expect(
          secondPass.blocks.map((b) => b.type).toList(),
          equals([ContentBlockType.reasoning, ContentBlockType.toolCalls]),
        );
      },
    );

    test(
      'segmented builder skips reasoning when previous reasoning matches',
      () {
        const sameReasoning = 'Plan: weiter testen.';

        final firstPass = RoundContentBlockService.buildSegmentedRoundBlocks(
          segments: [
            RoundSegment.toolCall(
              ToolCall(
                id: 'tc-1',
                name: 'code_run',
                status: ToolCallStatus.completed,
              ),
            ),
          ],
          providerReasoning: sameReasoning,
        );

        final accumulated = <ContentBlock>[...firstPass.blocks];

        final secondPass = RoundContentBlockService.buildSegmentedRoundBlocks(
          segments: [
            RoundSegment.toolCall(
              ToolCall(
                id: 'tc-2',
                name: 'code_run',
                status: ToolCallStatus.completed,
              ),
            ),
          ],
          providerReasoning: sameReasoning,
          existingBlocks: accumulated,
        );

        expect(
          secondPass.blocks.map((b) => b.type).toList(),
          equals([ContentBlockType.toolCalls]),
          reason:
              'Segmented builder should skip duplicate reasoning across rounds.',
        );
      },
    );

    test(
      'drops duplicate text block when it repeats an earlier finalized text '
      '(e.g. answer → notes tool → answer again)',
      () {
        // First round: model writes the answer + a notes tool call.
        final firstPass = RoundContentBlockService.buildRoundBlocks(
          interimText: 'Hamburg ist 16°C. Berlin ist 14°C.',
          providerReasoning: '',
          newToolCalls: [
            ToolCall(
              id: 'tc-notes',
              name: 'notes',
              status: ToolCallStatus.completed,
            ),
          ],
        );

        final accumulated = <ContentBlock>[...firstPass.blocks];

        // Second round: tool returned, model now repeats the same answer.
        final secondPass = RoundContentBlockService.buildRoundBlocks(
          interimText: 'Hamburg ist 16°C. Berlin ist 14°C.',
          providerReasoning: '',
          newToolCalls: const [],
          existingBlocks: accumulated,
        );

        // No new blocks expected because the only new content was a verbatim
        // repeat of the prior text block.
        expect(
          secondPass.blocks,
          isEmpty,
          reason:
              'Duplicate of an earlier finalized text block should be dropped.',
        );
      },
    );
  });
}
