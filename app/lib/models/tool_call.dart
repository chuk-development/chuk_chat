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
    DateTime? startedAt,
    this.completedAt,
  }) : id = id ?? const Uuid().v4(),
       startedAt = startedAt ?? DateTime.now();

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  String? result;
  ToolCallStatus status;

  /// Thinking text for this round (set on the first tool call of each round).
  String? roundThinking;

  /// When this tool call was created / started executing.
  final DateTime startedAt;

  /// When execution completed (success or error).
  DateTime? completedAt;

  /// How long the tool call has been running (or ran).
  Duration get elapsed =>
      (completedAt ?? DateTime.now()).difference(startedAt);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
    if (result != null) 'result': result,
    'status': status.name,
    if (roundThinking != null) 'roundThinking': roundThinking,
    'startedAt': startedAt.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
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
      startedAt: json['startedAt'] != null
          ? DateTime.tryParse(json['startedAt'] as String)
          : null,
      completedAt: json['completedAt'] != null
          ? DateTime.tryParse(json['completedAt'] as String)
          : null,
    );
  }
}

/// Status of a tool call in its lifecycle.
enum ToolCallStatus { pending, running, completed, error }

/// Utility to finalize any stale (running/pending) tool calls.
///
/// When a message is finalized but some tool calls are still in
/// running/pending state (e.g. because of a background race condition
/// or stream failure), this marks them as [ToolCallStatus.error] so
/// the UI stops showing spinners.
///
/// Returns `true` if any tool call was modified.
bool finalizeStaleToolCalls(List<ToolCall> toolCalls) {
  var modified = false;
  for (final tc in toolCalls) {
    if (tc.status == ToolCallStatus.running ||
        tc.status == ToolCallStatus.pending) {
      tc.status = ToolCallStatus.error;
      tc.completedAt = DateTime.now();
      tc.result ??= 'Tool call did not complete.';
      modified = true;
    }
  }
  return modified;
}
