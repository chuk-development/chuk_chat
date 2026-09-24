// lib/platform_specific/chat/chat_message_edit_mixin.dart
//
// Shared "act on one message in the list" plumbing for the desktop and mobile
// chat States: start an edit, cancel it, submit it, resend/regenerate a turn,
// branch the chat at a message, and page between answer variants.
//
// Both States carried a byte-identical (or near-identical) copy of every method
// below, and the copies had already drifted — mobile focused the composer after
// starting an edit while desktop focused it after removing an attachment, and
// only mobile localised "nothing to resend". Each of those differences is now a
// named hook instead of a second copy of the whole method.
//
// The host State keeps its own storage; this mixin reaches it through the small
// abstract surface below, because the two States hold it differently (desktop's
// file handler is a `DesktopFileHandler`, mobile's a `FileAttachmentHandler`,
// and desktop's send/submit methods live in a `part` extension, which cannot
// implement an abstract member).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:chuk_chat/services/chat_runtime.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';

mixin ChatMessageEditMixin<W extends StatefulWidget>
    on State<W>, ChatScrollMixin<W> {
  static const Uuid _uuid = Uuid();

  // --- State the host owns ------------------------------------------------

  /// The visible message list.
  List<Map<String, String>> get messages;

  /// The chat owning [messages]. Branching replaces it with the new chat.
  String? get activeChatId;
  set activeChatId(String? value);

  /// Told about a chat switch so the shell can follow along.
  Function(String?) get onChatIdChanged;

  MessageActionsHandler get messageActionsHandler;
  ChatPersistenceHandler get persistenceHandler;

  /// The composer's text field controller and focus node.
  TextEditingController get composerController;
  FocusNode get composerFocusNode;

  /// IDs of attachments restored into the composer when an edit started. These
  /// belong to the saved message, so removing them must NOT delete from
  /// storage (the original survives if the edit is cancelled); attachments
  /// uploaded fresh during the edit are not in this set and ARE deleted.
  Set<String> get restoredAttachmentIds;

  /// The composer's live attachment list, owned by the platform file handler.
  List<AttachedFile> get composerAttachedFiles;

  /// Drop [fileId] from the composer AND from storage. The two file handlers
  /// spell this differently, so the host names the right one.
  void deleteComposerAttachment(String fileId);

  // --- Work the host performs ---------------------------------------------

  Future<void> sendMessage();

  Future<void> submitEditedMessage(
    int index,
    String newText, {
    bool removeFollowingAssistant = true,
    bool clearMessagesBelow = false,
    List<AttachedFile>? attachedFilesOverride,
    bool isRegenerate = false,
  });

  Future<void> persistChat({
    bool waitForCompletion = false,
    bool commit = true,
  });

  // --- Hooks for the real platform differences -----------------------------

  /// Called once an edit has loaded the message into the composer. Mobile
  /// focuses the text field here; desktop leaves focus where it is.
  void onEditStarted() {}

  /// Called after an attachment left the composer. Desktop returns focus to
  /// the text field on the next frame; mobile leaves focus where it is.
  void onComposerAttachmentRemoved() {}

  /// What to say when a resend finds nothing to resend. Mobile localises it.
  String get nothingToResendMessage => 'Nothing to resend.';

  // --- Shared logic ---------------------------------------------------------

  bool isValidMessageIndex(int index) => index >= 0 && index < messages.length;

  void showSnackBar(String message) {
    ChatUiHelpers.showSnackBar(context, message);
  }

  /// Rebuild the attachments of the message at [index] as composer entries.
  List<AttachedFile> reconstructAttachedFilesForResend(int index) {
    if (!isValidMessageIndex(index)) return <AttachedFile>[];
    return ChatUiHelpers.reconstructAttachedFilesForResend(
      messages[index],
      _uuid,
    );
  }

  /// Load the message at [index] into the composer for editing.
  void editMessageAt(int index) {
    if (!isValidMessageIndex(index)) return;
    final String text = (messages[index]['text'] ?? '').trim();
    // Restore the message's attachments into the composer so the user can see
    // and remove them while editing. These are already-uploaded files; removal
    // here is list-only (see [removeComposerAttachment]) so the saved message
    // is never corrupted if the edit is cancelled.
    final List<AttachedFile> attached = reconstructAttachedFilesForResend(
      index,
    );
    if (text.isEmpty && attached.isEmpty) return;
    setState(() {
      messageActionsHandler.startEdit(index);
      composerController.text = text;
      composerController.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
      restoredAttachmentIds
        ..clear()
        ..addAll(attached.map((f) => f.id));
      composerAttachedFiles
        ..clear()
        ..addAll(attached);
    });
    onEditStarted();
  }

  void cancelEditMessage() {
    setState(() {
      messageActionsHandler.cancelEdit();
      composerController.clear();
      // List-only clear: the restored attachments still belong to the saved
      // message until an edit is actually submitted, so do NOT delete them
      // from storage here (that would break the original message).
      composerAttachedFiles.clear();
      restoredAttachmentIds.clear();
    });
  }

  /// Remove an attachment from the composer.
  /// - While editing, attachments restored from the saved message are removed
  ///   list-only (they still belong to that message until submit, and a cancel
  ///   must leave the original intact).
  /// - Attachments uploaded fresh during the edit (not in the restored set),
  ///   and all removals outside editing, also delete the file from storage.
  void removeComposerAttachment(String fileId) {
    if (messageActionsHandler.isEditing &&
        restoredAttachmentIds.contains(fileId)) {
      setState(() {
        composerAttachedFiles.removeWhere((f) => f.id == fileId);
      });
    } else {
      deleteComposerAttachment(fileId);
    }
    onComposerAttachmentRemoved();
  }

  /// Sends the message, or submits an edited message if in edit mode.
  Future<void> sendOrSubmitEdit() async {
    if (messageActionsHandler.isEditing) {
      final editIndex = messageActionsHandler.editingMessageIndex!;
      final newText = composerController.text.trim();
      // Snapshot the (possibly reduced) attachment set BEFORE cancel clears it.
      final attachedSnapshot = List<AttachedFile>.from(composerAttachedFiles);
      cancelEditMessage();
      if (newText.isNotEmpty || attachedSnapshot.isNotEmpty) {
        await submitEditedMessage(
          editIndex,
          newText,
          attachedFilesOverride: attachedSnapshot,
          removeFollowingAssistant: false,
          clearMessagesBelow: true,
        );
      }
    } else {
      await sendMessage();
    }
  }

  /// Re-run the user turn at (or above) [index]. This is a regenerate, so the
  /// discarded answer is archived as a variant instead of being lost.
  Future<void> resendMessageAt(int index) async {
    if (!isValidMessageIndex(index)) return;

    int sourceIndex = index;
    if (messages[sourceIndex]['sender'] != 'user') {
      sourceIndex = -1;
      for (int i = index - 1; i >= 0; i--) {
        if (messages[i]['sender'] == 'user') {
          sourceIndex = i;
          break;
        }
      }
    }

    if (!isValidMessageIndex(sourceIndex)) {
      showSnackBar(nothingToResendMessage);
      return;
    }

    final String text = (messages[sourceIndex]['text'] ?? '').trim();
    if (text.isEmpty) {
      showSnackBar(nothingToResendMessage);
      return;
    }
    await submitEditedMessage(
      sourceIndex,
      text,
      removeFollowingAssistant: false,
      clearMessagesBelow: true,
      isRegenerate: true,
    );
  }

  /// Fork the chat at [index] into a fresh chat holding everything up to and
  /// including that message, then switch to it.
  Future<void> branchFromIndex(int index) async {
    if (!isValidMessageIndex(index)) return;
    final List<Map<String, String>> branchMessages = messages
        .sublist(0, index + 1)
        .map((m) => Map<String, String>.from(m))
        .toList();
    if (branchMessages.isEmpty) return;

    final StoredChat? created = await persistenceHandler.persistChat(
      messages: branchMessages,
      chatId: null,
      waitForCompletion: true,
      silent: true,
    );
    if (created == null) {
      showSnackBar('Could not branch chat');
      return;
    }
    if (!mounted) return;
    setState(() {
      messages
        ..clear()
        ..addAll(branchMessages);
      activeChatId = created.id;
      messageActionsHandler.cancelEdit();
    });
    onChatIdChanged(created.id);
    scrollChatToBottom(force: true);
    showSnackBar('Branched into a new chat');
  }

  // ---------------------------------------------------------------------------
  // Answer-version pager (OpenAI-style ‹ k/n › on regenerated answers).
  // ---------------------------------------------------------------------------

  /// Capture the answer(s) about to be discarded by a regenerate at
  /// [userIndex] (the preceding user message), to seed the fresh answer's
  /// variant archive. Reuses the old answer's own archive when it already has
  /// one (repeated regenerates keep stacking), else a single snapshot. Returns
  /// null when there is no assistant answer to preserve.
  List<Map<String, dynamic>>? captureRegenSeed(int userIndex) {
    final int aiIndex = userIndex + 1;
    if (aiIndex >= messages.length) return null;
    final Map<String, String> old = messages[aiIndex];
    if (old['sender'] != 'ai') return null;
    final existing = ChatUiHelpers.decodeVariants(old['variants']);
    if (existing.isNotEmpty) return existing;
    return <Map<String, dynamic>>[ChatUiHelpers.variantSnapshotOf(old)];
  }

  /// Switch the answer shown by the message at [index] to variant [newIndex]
  /// and persist. Wired to the pager arrows.
  void switchVariantAt(int index, int newIndex) {
    if (!isValidMessageIndex(index)) return;
    if (!ChatUiHelpers.switchVariant(messages[index], newIndex)) return;
    setState(() {});
    unawaited(persistChat());
  }

  // ---------------------------------------------------------------------------
  // Streaming tokens into the visible list.
  // ---------------------------------------------------------------------------

  /// Write the latest streamed [content]/[reasoning] into the message at
  /// [index] of [chatId].
  ///
  /// [chatId] is nullable because desktop drives this from the active chat and
  /// has nothing to write when there is none; a mismatch (mobile's background
  /// chat) is dropped for the same reason.
  void updateAiMessage(
    int index,
    String content,
    String reasoning,
    String? chatId,
  ) {
    if (!mounted || index < 0 || index >= messages.length) return;
    if (chatId == null || activeChatId != chatId) return;

    // Keep the backing list in sync (for persistence + finalize) but WITHOUT a
    // screen-wide setState per token. Per-token rebuilds are scoped to the
    // single streaming bubble, which listens to the runtime's `streamingLive`
    // notifier in the list itemBuilder. This replaces a ~30fps full-tree
    // rebuild (every visible bubble + the composer + overlays) with a rebuild
    // of just the streaming bubble's body.
    final Map<String, String> message = Map<String, String>.from(
      messages[index],
    );
    message['text'] = content;
    message['reasoning'] = reasoning;
    messages[index] = message;

    final ChatRuntime runtime = ChatRuntimeRegistry.instance.get(chatId);
    // First token of the turn: the placeholder bubble was first built before
    // the stream manager flipped streaming on, so it isn't yet wrapped in its
    // scoped ValueListenableBuilder. Do exactly one setState now to install
    // the wrapper; every subsequent token updates only the notifier.
    final bool firstToken = runtime.streamingLive.value == null;
    runtime.pushStreamingText(
      index: index,
      text: content,
      reasoning: reasoning,
    );
    if (firstToken) {
      setState(() {});
    }

    // Follow the answer as it streams in, but only while the user is pinned to
    // the bottom. The layout's streaming slack was removed on the assumption
    // that this runs.
    pinToBottomDuringStream();
  }
}
