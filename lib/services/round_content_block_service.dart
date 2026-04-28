import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/tool_call_handler.dart' show RoundSegment;

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

  /// Build content blocks for a round whose model output interleaved text
  /// and tool calls (e.g. "I'll check Hamburg." → tool → "Got 14°C." → tool).
  ///
  /// Reasoning gets a single block at the top; the segments then translate
  /// directly into alternating text / tool-calls blocks in their original
  /// order. Returns the same idempotency contract as [buildRoundBlocks] —
  /// an empty list when the tail of [existingBlocks] already matches.
  static RoundContentBlockResult buildSegmentedRoundBlocks({
    required List<RoundSegment> segments,
    required String providerReasoning,
    List<ContentBlock> existingBlocks = const [],
  }) {
    final blocks = <ContentBlock>[];
    final reasoning = providerReasoning.trim();
    if (reasoning.isNotEmpty) {
      blocks.add(ContentBlock.reasoning(reasoning));
    }

    var pendingTools = <ToolCall>[];
    void flushPendingTools() {
      if (pendingTools.isEmpty) return;
      blocks.add(ContentBlock.toolCalls(List<ToolCall>.from(pendingTools)));
      pendingTools = <ToolCall>[];
    }

    for (final seg in segments) {
      if (seg.isToolCall) {
        pendingTools.add(seg.toolCall!);
      } else {
        flushPendingTools();
        final text = seg.text!.trim();
        if (text.isEmpty) continue;
        if (_isDuplicateOfEarlierTextBlock(text, existingBlocks)) {
          continue;
        }
        blocks.add(ContentBlock.text(text));
      }
    }
    flushPendingTools();

    final interimOutputText = segments
        .where((s) => s.isText)
        .map((s) => s.text!.trim())
        .where((t) => t.isNotEmpty)
        .join('\n\n');

    if (blocks.isNotEmpty && _tailMatches(existingBlocks, blocks)) {
      return RoundContentBlockResult(
        blocks: const <ContentBlock>[],
        interimOutputText: interimOutputText,
      );
    }

    return RoundContentBlockResult(
      blocks: blocks,
      interimOutputText: interimOutputText,
    );
  }

  /// Build the content blocks for a single streaming round.
  ///
  /// When [existingBlocks] is provided, the result is made idempotent: if the
  /// newly built blocks exactly match the tail of [existingBlocks] (by
  /// content), [RoundContentBlockResult.blocks] will be empty so the caller
  /// does not re-append the same round on a retry/continuation.
  static RoundContentBlockResult buildRoundBlocks({
    required String interimText,
    required String providerReasoning,
    required List<ToolCall> newToolCalls,
    bool interimBeforeToolCalls = false,
    List<ContentBlock> existingBlocks = const [],
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

    // Idempotency: if the newly built blocks already exist as the exact tail
    // of existingBlocks, drop them so the caller does not double-append.
    if (blocks.isNotEmpty && _tailMatches(existingBlocks, blocks)) {
      return RoundContentBlockResult(
        blocks: const <ContentBlock>[],
        interimOutputText: interimOutputText,
      );
    }

    // De-duplicate: when the model writes the same answer text twice in
    // separate rounds (e.g. answer → notes tool → answer again, which Kimi
    // sometimes emits), drop the trailing text block from this round if it
    // already appears verbatim in an earlier finalized text block.
    if (blocks.isNotEmpty &&
        blocks.last.type == ContentBlockType.text &&
        _isDuplicateOfEarlierTextBlock(
          (blocks.last.text ?? '').trim(),
          existingBlocks,
        )) {
      blocks.removeLast();
    }

    return RoundContentBlockResult(
      blocks: blocks,
      interimOutputText: interimOutputText,
    );
  }

  /// Returns true when [tail] is the exact suffix of [existing] (by content
  /// equality of blocks).
  static bool _tailMatches(
    List<ContentBlock> existing,
    List<ContentBlock> tail,
  ) {
    if (tail.isEmpty || existing.length < tail.length) return false;
    final offset = existing.length - tail.length;
    for (var i = 0; i < tail.length; i++) {
      if (!_blocksEqual(existing[offset + i], tail[i])) {
        return false;
      }
    }
    return true;
  }

  static bool _blocksEqual(ContentBlock a, ContentBlock b) {
    if (a.type != b.type) return false;
    switch (a.type) {
      case ContentBlockType.text:
      case ContentBlockType.reasoning:
        return (a.text ?? '').trim() == (b.text ?? '').trim();
      case ContentBlockType.toolCalls:
        final aCalls = a.toolCalls ?? const <ToolCall>[];
        final bCalls = b.toolCalls ?? const <ToolCall>[];
        if (aCalls.length != bCalls.length) return false;
        for (var i = 0; i < aCalls.length; i++) {
          if (!_toolCallEqual(aCalls[i], bCalls[i])) return false;
        }
        return true;
    }
  }

  static bool _toolCallEqual(ToolCall a, ToolCall b) {
    return a.id == b.id && a.name == b.name;
  }

  static bool _isDuplicateOfEarlierTextBlock(
    String newText,
    List<ContentBlock> existing,
  ) {
    if (newText.isEmpty) return false;
    final normalizedNew = _normalizeForCompare(newText);
    if (normalizedNew.isEmpty) return false;
    for (final block in existing) {
      if (block.type != ContentBlockType.text) continue;
      final normalizedExisting = _normalizeForCompare(block.text ?? '');
      if (normalizedExisting.isEmpty) continue;
      if (normalizedExisting == normalizedNew) return true;
      if (normalizedExisting.contains(normalizedNew)) return true;
    }
    return false;
  }

  static String _normalizeForCompare(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
