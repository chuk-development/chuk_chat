// lib/widgets/message_bubble/models.dart
//
// Part of message_bubble.dart — the plain data / render-helper types the
// bubble builds on: the public attachment + action models exported with the
// widget, and the private render segments the content-blocks layout groups a
// streaming turn into.

part of '../message_bubble.dart';

/// Per-image metadata describing how an image arrived in the chat and
/// an optional caption the AI attached to it.
class ImageMeta {
  const ImageMeta({required this.source, this.caption, this.model});

  /// "generated" (AI image tool) or "fetched" (fetch_image from URL).
  final String source;

  /// Optional short subtitle supplied by the AI, shown under the image.
  final String? caption;

  /// Human-readable image-generation model label (e.g. "FLUX 2 Klein 9B").
  /// Only set for generated images. Shown under the caption and as a corner
  /// badge on the image so it is always clear which generator produced it.
  final String? model;

  bool get isGenerated => source == 'generated';

  static List<ImageMeta>? decode(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return null;
      return decoded.whereType<Map>().map((raw) {
        final source = raw['source']?.toString() ?? 'generated';
        final captionRaw = raw['caption']?.toString().trim() ?? '';
        final modelRaw = raw['model']?.toString().trim() ?? '';
        return ImageMeta(
          source: source,
          caption: captionRaw.isEmpty ? null : captionRaw,
          model: modelRaw.isEmpty ? null : modelRaw,
        );
      }).toList();
    } catch (_) {
      return null;
    }
  }
}

/// Document attachment data
class DocumentAttachment {
  const DocumentAttachment({
    required this.fileName,
    required this.markdownContent,
  });

  final String fileName;
  final String markdownContent;

  Map<String, String> toJson() {
    return {'fileName': fileName, 'markdownContent': markdownContent};
  }

  factory DocumentAttachment.fromJson(Map<String, dynamic> json) {
    return DocumentAttachment(
      fileName: json['fileName'] as String? ?? 'document',
      markdownContent: json['markdownContent'] as String? ?? '',
    );
  }
}

class MessageBubbleAction {
  const MessageBubbleAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isEnabled = true,
    this.label,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isEnabled;
  final String? label;
}

class _RenderSegment {
  _RenderSegment._({this.text, this.sandboxArtifact})
      : toolCalls = <ToolCall>[],
        timeline = <_ToolTimelineEntry>[];

  _RenderSegment.text(String t) : this._(text: t);
  _RenderSegment.round() : this._();
  _RenderSegment.sandboxArtifact(SandboxArtifactPayload p)
      : this._(sandboxArtifact: p);

  final String? text;

  /// Set for sandbox-artifact segments — the inline downloadable file the
  /// AI handed to the user via send_file_to_user. Rendered as its own
  /// widget (image / pdf / text preview / file chip) between text blocks.
  final SandboxArtifactPayload? sandboxArtifact;

  final List<ToolCall> toolCalls;

  /// Interleaved reasoning/tool entries in true source order — the single
  /// source of truth for a round's contents. A run of
  /// `reasoning → tool → reasoning → tool → reasoning` (multiple streaming
  /// passes with no real text between them, including the final pass's
  /// reasoning *about* the results) accumulates here so the whole round
  /// renders as ONE collapsible bar with cards in the order they happened —
  /// instead of one bar per pass plus a peeled-out trailing reasoning card.
  final List<_ToolTimelineEntry> timeline;

  /// Reasoning strings in source order, derived from [timeline]. Used by the
  /// reasoning-only and `showToolCalls == false` render paths, which collapse
  /// a round's thinking into a single merged reasoning card.
  List<String> get reasoningTexts =>
      timeline.where((e) => e.isReasoning).map((e) => e.reasoning!).toList();

  bool get isText => text != null;
  bool get isSandboxArtifact => sandboxArtifact != null;
  bool get hasContent => timeline.isNotEmpty;
}

class _ToolTimelineEntry {
  const _ToolTimelineEntry.reasoning(this.reasoning) : toolCall = null;
  const _ToolTimelineEntry.tool(this.toolCall) : reasoning = null;

  final String? reasoning;
  final ToolCall? toolCall;

  bool get isReasoning => reasoning != null;
}
