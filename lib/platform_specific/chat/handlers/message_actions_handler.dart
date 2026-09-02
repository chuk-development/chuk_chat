// lib/platform_specific/chat/handlers/message_actions_handler.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/utils/clipboard_text_sanitizer.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
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

  /// Strips tool-call protocol from text that is about to leave the app.
  ///
  /// The chat view renders through [stripToolCallBlocksForDisplay], but copy
  /// reads the raw `text` field. Anything the UI hides — `<tool_call>` blocks,
  /// `<artifact>` blocks, provider special tokens — was therefore pasted into
  /// other apps.
  static String _forExport(String text) =>
      stripToolCallBlocksForDisplay(text);

  /// Copy text to clipboard
  Future<void> copyToClipboard(String rawText, {String? label}) async {
    final text = _forExport(rawText);
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
    Future<void> Function(int)? onRetryToolPass,
    bool canRetryToolPass = false,
    void Function(int)? onBranch,
  }) {
    // User message actions are built separately via buildUserMessageActions.
    if (isUser) return const [];

    final bool isAssistantPending = isStreaming;
    final List<MessageBubbleAction> actions = [];

    // Copy action for AI messages — message text only (no tool call metadata)
    if (messageText.trim().isNotEmpty) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.copy,
          tooltip: 'Copy message',
          label: 'Copy',
          onPressed: () => copyToClipboard(messageText),
          isEnabled: !isAssistantPending,
        ),
      );
    }

    // Retry action — always available on finalized AI messages
    if (!isAssistantPending) {
      final shouldUsePassRetry = canRetryToolPass && onRetryToolPass != null;
      actions.add(
        MessageBubbleAction(
          icon: Icons.replay,
          tooltip: shouldUsePassRetry
              ? 'Retry from failed tool step'
              : 'Retry response',
          label: 'Retry',
          onPressed: () {
            if (shouldUsePassRetry) {
              unawaited(onRetryToolPass(index));
              return;
            }
            onResendMessage(index);
          },
        ),
      );
    }

    // Branch — fork the conversation into a new chat, up to and including this
    // message. The current chat is left untouched.
    if (!isAssistantPending && onBranch != null) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.alt_route,
          tooltip: 'Branch into a new chat',
          label: 'Branch',
          onPressed: () => onBranch(index),
        ),
      );
    }

    return actions;
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
