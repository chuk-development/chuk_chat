import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';

class RoundContentBlockResult {
  const RoundContentBlockResult({
    required this.blocks,
    required this.interimOutputText,
  });

  final List<ContentBlock> blocks;
  final String interimOutputText;
}

class RoundContentBlockService {
  const RoundContentBlockService._();

  static RoundContentBlockResult buildRoundBlocks({
    required String interimText,
    required String providerReasoning,
    required List<ToolCall> newToolCalls,
    bool interimBeforeToolCalls = false,
  }) {
    final normalizedInterim = interimText.trim();
    final normalizedProviderReasoning = providerReasoning.trim();

    final hasProviderReasoning = normalizedProviderReasoning.isNotEmpty;
    final roundReasoning = hasProviderReasoning
        ? normalizedProviderReasoning
        : (newToolCalls.isNotEmpty
              ? (newToolCalls.first.roundThinking?.trim() ?? '')
              : '');

    var interimOutputText = normalizedInterim;
    if (roundReasoning.isNotEmpty && interimOutputText.isNotEmpty) {
      if (interimOutputText == roundReasoning) {
        interimOutputText = '';
      } else if (interimOutputText.startsWith('$roundReasoning\n')) {
        interimOutputText = interimOutputText
            .substring(roundReasoning.length)
            .trim();
      }
    }

    final blocks = <ContentBlock>[];
    if (roundReasoning.isNotEmpty) {
      blocks.add(ContentBlock.reasoning(roundReasoning));
    }
    // Work on a local copy to avoid mutating the caller's list.
    var effectiveToolCalls = newToolCalls;
    if (interimBeforeToolCalls &&
        interimOutputText.isNotEmpty &&
        newToolCalls.isNotEmpty) {
      // Fold the interim text into the first tool call's thinking so it
      // appears inside the collapsible tool-call section rather than as a
      // standalone text block that looks like a truncated final answer.
      final first = newToolCalls.first;
      final existingThinking = first.roundThinking?.trim() ?? '';
      final merged = existingThinking.isEmpty
          ? interimOutputText
          : '$existingThinking\n\n$interimOutputText';
      final updated = ToolCall(
        id: first.id,
        name: first.name,
        arguments: first.arguments,
        status: first.status,
        result: first.result,
        roundThinking: merged,
        startedAt: first.startedAt,
      )..completedAt = first.completedAt;
      effectiveToolCalls = [updated, ...newToolCalls.skip(1)];
    } else if (interimBeforeToolCalls && interimOutputText.isNotEmpty) {
      blocks.add(ContentBlock.text(interimOutputText));
    }
    if (effectiveToolCalls.isNotEmpty) {
      blocks.add(ContentBlock.toolCalls(effectiveToolCalls));
    }
    if (!interimBeforeToolCalls && interimOutputText.isNotEmpty) {
      blocks.add(ContentBlock.text(interimOutputText));
    }

    return RoundContentBlockResult(
      blocks: blocks,
      interimOutputText: interimOutputText,
    );
  }
}
