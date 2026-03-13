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
    if (interimBeforeToolCalls && interimOutputText.isNotEmpty) {
      blocks.add(ContentBlock.text(interimOutputText));
    }
    if (newToolCalls.isNotEmpty) {
      blocks.add(ContentBlock.toolCalls(newToolCalls));
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
