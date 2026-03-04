// lib/platform_specific/chat/handlers/message_actions_handler.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

/// Handles message-related actions (copy, edit, resend)
class MessageActionsHandler {
  static const String _emptyAssistantResponsePrefix =
      'The model returned an empty response.';

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
    await Clipboard.setData(ClipboardData(text: text));
    onShowSnackBar?.call(label ?? 'Copied');
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

  /// Build message actions for a specific message
  List<MessageBubbleAction> buildActionsForMessage({
    required int index,
    required String messageText,
    required bool isUser,
    required bool isStreaming,
    required Function(int) onEdit,
    required Function(int) onResendMessage,
  }) {
    final bool isAssistantPending = !isUser && isStreaming;
    final List<MessageBubbleAction> actions = [];

    // Copy action
    if (messageText.trim().isNotEmpty) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.copy,
          tooltip: 'Copy message',
          label: 'Copy',
          onPressed: () => copyToClipboard(messageText),
          isEnabled: !isAssistantPending || isUser,
        ),
      );
    }

    // Edit and Resend actions (only for user messages)
    if (isUser) {
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
    } else if (!isAssistantPending &&
        messageText.startsWith(_emptyAssistantResponsePrefix)) {
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
}
