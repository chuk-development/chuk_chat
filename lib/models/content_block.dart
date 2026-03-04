import 'package:chuk_chat/models/tool_call.dart';

/// The type of a content block within an AI response.
enum ContentBlockType { text, toolCalls, reasoning }

/// An ordered block of content within an AI response.
///
/// AI responses can contain interleaved text, tool calls, and reasoning.
/// Each [ContentBlock] represents one segment, and the list order determines
/// the display order in the chat UI.
class ContentBlock {
  const ContentBlock._({required this.type, this.text, this.toolCalls});

  /// A block of visible text shown to the user.
  const ContentBlock.text(String text)
    : this._(type: ContentBlockType.text, text: text);

  /// A block of tool calls (expandable in the UI).
  const ContentBlock.toolCalls(List<ToolCall> calls)
    : this._(type: ContentBlockType.toolCalls, toolCalls: calls);

  /// A reasoning/thinking block (expandable in the UI).
  const ContentBlock.reasoning(String text)
    : this._(type: ContentBlockType.reasoning, text: text);

  final ContentBlockType type;

  /// The text content (for [ContentBlockType.text] and
  /// [ContentBlockType.reasoning] blocks).
  final String? text;

  /// The tool calls (for [ContentBlockType.toolCalls] blocks).
  final List<ToolCall>? toolCalls;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    if (text != null) 'text': text,
    if (toolCalls != null)
      'toolCalls': toolCalls!.map((c) => c.toJson()).toList(),
  };

  factory ContentBlock.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'text';
    final type = ContentBlockType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => ContentBlockType.text,
    );

    List<ToolCall>? toolCalls;
    final rawCalls = json['toolCalls'];
    if (rawCalls is List) {
      toolCalls = rawCalls
          .whereType<Map>()
          .map((item) => ToolCall.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }

    return ContentBlock._(
      type: type,
      text: json['text'] as String?,
      toolCalls: toolCalls,
    );
  }
}
