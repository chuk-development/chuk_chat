// lib/platform_specific/chat/handlers/message_actions_handler.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/utils/clipboard_text_sanitizer.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

/// Handles message-related actions (copy, edit, resend)
class MessageActionsHandler {
  // Callbacks
  Function(String)? onShowSnackBar;
  Function(int, String)? onSubmitEdit;
  Function(int)? onResend;

  int? _editingMessageIndex;

  int? get editingMessageIndex => _editingMessageIndex;
  bool get isEditing => _editingMessageIndex != null;

  /// Copy text to clipboard
  Future<void> copyToClipboard(String text, {String? label}) async {
    if (text.trim().isEmpty) {
      onShowSnackBar?.call('Nothing to copy');
      return;
    }

    final hadImageData = ClipboardTextSanitizer.containsImageData(text);
    final sanitizedText = ClipboardTextSanitizer.sanitize(text);

    if (sanitizedText.trim().isEmpty) {
      onShowSnackBar?.call(
        hadImageData ? 'Nothing to copy (images removed)' : 'Nothing to copy',
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: sanitizedText));
    onShowSnackBar?.call(
      label ?? (hadImageData ? 'Copied (images removed)' : 'Copied'),
    );
  }

  /// Start editing a message at the given index
  void startEdit(int index) {
    _editingMessageIndex = index;
  }

  /// Cancel editing
  void cancelEdit() {
    _editingMessageIndex = null;
  }

  /// Submit edited message
  Future<void> submitEdit(int index, String newText) async {
    final String trimmedText = newText.trim();
    if (trimmedText.isEmpty) {
      onShowSnackBar?.call('Message empty');
      return;
    }

    _editingMessageIndex = null;
    onSubmitEdit?.call(index, trimmedText);
  }

  /// Resend message at index
  Future<void> resend(int index, String text) async {
    if (text.trim().isEmpty) {
      onShowSnackBar?.call('Nothing to resend');
      return;
    }
    onResend?.call(index);
  }

  /// Build actions for AI messages (shown below the bubble).
  List<MessageBubbleAction> buildActionsForMessage({
    required int index,
    required String messageText,
    required bool isUser,
    required bool isStreaming,
    required Function(int) onEdit,
    required Function(int) onResendMessage,
    bool hasFailedToolCalls = false,
    List<ToolCall>? toolCalls,
  }) {
    // User message actions are built separately via buildUserMessageActions.
    if (isUser) return const [];

    final bool isAssistantPending = isStreaming;
    final List<MessageBubbleAction> actions = [];

    // Copy action for AI messages — includes tool call debug info
    if (messageText.trim().isNotEmpty || (toolCalls?.isNotEmpty ?? false)) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.copy,
          tooltip: 'Copy message',
          label: 'Copy',
          onPressed: () {
            final debugText = _buildCopyText(messageText, toolCalls);
            copyToClipboard(debugText);
          },
          isEnabled: !isAssistantPending,
        ),
      );
    }

    // Retry action — always available on finalized AI messages
    if (!isAssistantPending) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.replay,
          tooltip: 'Retry response',
          label: 'Retry',
          onPressed: () => onResendMessage(index),
        ),
      );
    }

    return actions;
  }

  /// Build the text to copy, including tool call debug info when present.
  String _buildCopyText(String messageText, List<ToolCall>? toolCalls) {
    if (toolCalls == null || toolCalls.isEmpty) return messageText;

    final buffer = StringBuffer();
    if (messageText.trim().isNotEmpty) {
      buffer.writeln(messageText.trim());
      buffer.writeln();
    }

    buffer.writeln('--- Tool Calls (${toolCalls.length}) ---');
    for (final tc in toolCalls) {
      final elapsed = tc.elapsed;
      final elapsedStr = elapsed.inSeconds >= 60
          ? '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s'
          : '${elapsed.inSeconds}.${(elapsed.inMilliseconds % 1000) ~/ 100}s';

      buffer.writeln();
      buffer.writeln('[${tc.status.name.toUpperCase()}] ${tc.name}');
      buffer.writeln('  Started: ${_formatTime(tc.startedAt)}');
      if (tc.completedAt != null) {
        buffer.writeln('  Completed: ${_formatTime(tc.completedAt!)}');
      }
      buffer.writeln('  Elapsed: $elapsedStr');

      if (tc.arguments.isNotEmpty) {
        final argsStr = tc.arguments.entries
            .map((e) => '${e.key}: ${e.value}')
            .join(', ');
        buffer.writeln('  Args: $argsStr');
      }

      if (tc.status == ToolCallStatus.running ||
          tc.status == ToolCallStatus.pending) {
        buffer.writeln('  ⚠ STUCK — tool never completed');
      }

      if (tc.result != null) {
        final resultPreview = tc.result!.length > 200
            ? '${tc.result!.substring(0, 200)}...'
            : tc.result!;
        buffer.writeln('  Result: $resultPreview');
      }
    }

    return buffer.toString();
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  /// Build actions for user messages (shown in long-press popup).
  List<MessageBubbleAction> buildUserMessageActions({
    required int index,
    required String messageText,
    required Function(int) onEdit,
    required Function(int) onResendMessage,
  }) {
    final List<MessageBubbleAction> actions = [];

    if (messageText.trim().isNotEmpty) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.copy,
          tooltip: 'Copy message',
          label: 'Copy',
          onPressed: () => copyToClipboard(messageText),
        ),
      );
    }

    actions.add(
      MessageBubbleAction(
        icon: Icons.edit,
        tooltip: 'Edit message',
        label: 'Edit',
        onPressed: () => onEdit(index),
      ),
    );

    actions.add(
      MessageBubbleAction(
        icon: Icons.replay,
        tooltip: 'Resend message',
        label: 'Resend',
        onPressed: () => onResendMessage(index),
      ),
    );

    return actions;
  }
}
