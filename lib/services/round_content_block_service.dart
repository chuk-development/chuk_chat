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
    if (reasoning.isNotEmpty &&
        !_lastReasoningMatches(existingBlocks, reasoning)) {
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
        if (isDuplicateOfEarlierTextBlock(text, existingBlocks)) {
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
    if (roundReasoning.isNotEmpty &&
        !_lastReasoningMatches(existingBlocks, roundReasoning)) {
      blocks.add(ContentBlock.reasoning(roundReasoning));
    }
    // Preserve true emission order: text emitted BEFORE tool calls renders
    // as its own block above the tool-calls bar; text emitted AFTER tool
    // calls renders below. Never fold pre-tool text into a tool call's
    // roundThinking — that hid the message inside a collapsed card.
    if (interimBeforeToolCalls && interimOutputText.isNotEmpty) {
      blocks.add(ContentBlock.text(interimOutputText));
    }
    if (newToolCalls.isNotEmpty) {
      blocks.add(ContentBlock.toolCalls(newToolCalls));
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
        isDuplicateOfEarlierTextBlock(
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

  /// True when the most recent reasoning block in [existing] has the same
  /// trimmed text as [reasoning]. Used to avoid prepending the same reasoning
  /// block when providers (or the streaming handler) re-emit identical
  /// reasoning text across rounds.
  static bool _lastReasoningMatches(
    List<ContentBlock> existing,
    String reasoning,
  ) {
    final target = reasoning.trim();
    if (target.isEmpty) return false;
    for (var i = existing.length - 1; i >= 0; i--) {
      final block = existing[i];
      if (block.type != ContentBlockType.reasoning) continue;
      return (block.text ?? '').trim() == target;
    }
    return false;
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
      case ContentBlockType.sandboxArtifact:
        // Compare by storage path — same encrypted ciphertext path means
        // the same artifact, regardless of incidental metadata drift.
        return a.sandboxArtifact?.storagePath ==
            b.sandboxArtifact?.storagePath;
    }
  }

  static bool _toolCallEqual(ToolCall a, ToolCall b) {
    return a.id == b.id && a.name == b.name;
  }

  /// Returns true when [newText] is effectively a duplicate of an earlier
  /// finalized text block (exact, contained, or near-contained after
  /// whitespace normalization).
  ///
  /// Public so callers that build text blocks outside this service (e.g. the
  /// final-pass append in `StreamingMessageHandler`) can use the same fuzzy
  /// check rather than re-implementing exact-match comparison.
  static bool isDuplicateOfEarlierTextBlock(
    String newText,
    List<ContentBlock> existing,
  ) {
    if (newText.isEmpty) return false;
    final normalizedNew = normalizeTextForCompare(newText);
    if (normalizedNew.isEmpty) return false;
    for (final block in existing) {
      if (block.type != ContentBlockType.text) continue;
      final normalizedExisting = normalizeTextForCompare(block.text ?? '');
      if (normalizedExisting.isEmpty) continue;
      if (normalizedExisting == normalizedNew) return true;
      if (normalizedExisting.contains(normalizedNew)) return true;
    }
    return false;
  }

  /// Whitespace-normalized form used for duplicate detection.
  static String normalizeTextForCompare(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
