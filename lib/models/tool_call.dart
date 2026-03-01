import 'package:uuid/uuid.dart';

/// Represents a single tool call made by the AI during a conversation.
///
/// Tool calls go through a lifecycle: pending → running → completed/error.
/// Each call gets a globally-unique ID for unambiguous result matching.
class ToolCall {
  ToolCall({
    String? id,
    required this.name,
    this.arguments = const {},
    this.result,
    this.status = ToolCallStatus.pending,
    this.roundThinking,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  String? result;
  ToolCallStatus status;

  /// Thinking text for this round (set on the first tool call of each round).
  String? roundThinking;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
    if (result != null) 'result': result,
    'status': status.name,
    if (roundThinking != null) 'roundThinking': roundThinking,
  };

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    return ToolCall(
      id: json['id'] as String?,
      name: json['name'] as String? ?? '',
      arguments: (json['arguments'] as Map<String, dynamic>?) ?? const {},
      result: json['result'] as String?,
      status: ToolCallStatus.values.firstWhere(
        (e) => e.name == (json['status'] as String? ?? 'pending'),
        orElse: () => ToolCallStatus.pending,
      ),
      roundThinking: json['roundThinking'] as String?,
    );
  }
}

/// Status of a tool call in its lifecycle.
enum ToolCallStatus { pending, running, completed, error }
