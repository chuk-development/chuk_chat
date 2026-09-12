// lib/platform_specific/chat/mobile_message_edit_mixin.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/models/chat_model.dart';
import 'package:cowork/models/chat_reply.dart';
import 'package:cowork/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:cowork/platform_specific/chat/chat_ui_helpers.dart';
import 'package:cowork/platform_specific/chat/chat_ui_mobile.dart';
import 'package:cowork/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:cowork/platform_specific/chat/mobile_attach_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_model_selection_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_send_mixin.dart';
import 'package:cowork/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:cowork/platform_specific/chat/regen_variant_seed.dart';
import 'package:cowork/services/artifact_storage_service.dart';
import 'package:cowork/services/chat_storage_service.dart';

/// Going back over what was already said: editing a message, replying to one,
/// sending one again, and picking up an answer that was cut short.
///
/// All four rewrite the transcript below the message they act on, so they sit
/// together: an edit truncates and re-sends, a resend replaces the answer, a
/// continue appends to it. The composer state they share — the reply draft and
/// the attachments an edit restored into the composer — is owned here.
///
/// Members are public so the host State and its build method can reach them.
mixin MobileMessageEditMixin<T extends ChukChatUIMobile>
    on
        State<T>,
        ChatScrollMixin<T>,
        ModelProviderResolutionMixin<T>,
        MobileModelSelectionMixin<T>,
        MobileAttachMixin<T>,
        RegenVariantSeedMixin<T>,
        MobileSendMixin<T> {
  // --- host-provided -------------------------------------------------------

  MessageActionsHandler get messageActionsHandler;

  /// Capture the answer(s) already under the user message at [userIndex], so a
  /// regenerate can fold the old answer into the new one's version pager.
  List<Map<String, dynamic>>? captureRegenSeed(int userIndex);

  // --- state ---------------------------------------------------------------

  /// IDs of attachments restored into the composer when an edit started. These
  /// belong to the saved message, so removing them must NOT delete from storage
  /// (the original survives if the edit is cancelled); attachments uploaded
  /// fresh during the edit are not in this set and ARE deleted on removal.
  final Set<String> restoredAttachmentIds = <String>{};

  Future<void> submitEditedMessage(
    int index,
    String newText, {
    bool removeFollowingAssistant = true,
    bool clearMessagesBelow = false,
    List<AttachedFile>? attachedFilesOverride,
    bool isRegenerate = false,
  }) async {
    if (index < 0 || index >= messages.length) return;
    if (streamingHandler.isStreaming || streamingHandler.isSending) {
      showChatSnackBar('Please wait');
      return;
    }

    setState(() {
      messages[index]['text'] = newText;
      // Reflect the attachment set chosen during editing (the user may have
      // removed images) so the saved bubble and any future edit match it.
      if (attachedFilesOverride != null) {
        ChatUiHelpers.writeAttachmentsToMessage(
          messages[index],
          attachedFilesOverride,
        );
      }
    });

    // Answer-version pager: on a regenerate, archive the answer being
    // discarded so the fresh answer can be appended as a new variant. Must run
    // BEFORE the tail is removed below.
    final List<Map<String, dynamic>>? regenVariantSeed = isRegenerate
        ? captureRegenSeed(index)
        : null;

    // Before removing AI messages, collect:
    //   * artifact ids they created (legacy fallback for chats whose
    //     version snapshots pre-date message_id stamping),
    //   * message ids so we can roll back the artifact versions those
    //     messages produced. The rollback resets `artifacts.content` to
    //     the latest remaining snapshot, or deletes the artifact entirely
    //     if no prior snapshot exists.
    final artifactIdsToDelete = <String>{};
    final discardedMessageIds = <String>{};
    void collectArtifactsFrom(int start, int end) {
      for (int i = start; i < end && i < messages.length; i++) {
        if (messages[i]['sender'] != 'ai') continue;
        artifactIdsToDelete.addAll(
          ChatUiHelpers.extractArtifactIdsFromRawMessage(messages[i]),
        );
        final mid = messages[i]['messageId'];
        if (mid != null && mid.isNotEmpty) {
          discardedMessageIds.add(mid);
        }
      }
    }

    if (clearMessagesBelow && index + 1 < messages.length) {
      collectArtifactsFrom(index + 1, messages.length);
      setState(() {
        messages.removeRange(index + 1, messages.length);
      });
    } else if (removeFollowingAssistant &&
        index + 1 < messages.length &&
        messages[index + 1]['sender'] == 'ai') {
      collectArtifactsFrom(index + 1, index + 2);
      setState(() {
        messages.removeAt(index + 1);
      });
    }

    // Roll back per-message version history first so prior snapshots
    // survive when an AI message only updated an existing artifact.
    if (discardedMessageIds.isNotEmpty) {
      await ArtifactStorageService.rollbackArtifactsForMessages(
        discardedMessageIds,
      );
    }

    if (artifactIdsToDelete.isNotEmpty) {
      // MUST await. deleteArtifactsByIds prunes the in-memory cache
      // only after the Supabase round-trip; firing it unawaited lets
      // the next loadArtifactsForChat return the ghost artifact which
      // ends up in the system prompt as a "still active" item. Idempotent
      // for ids the rollback above already deleted.
      await ArtifactStorageService.deleteArtifactsByIds(artifactIdsToDelete);
    }

    // Resend with new text
    final String originalUserInput = newText;
    late int placeholderIndex;

    // Always use the currently selected model and provider for resend
    // This allows users to switch models and resend with the new selection
    final String modelIdToUse = selectedModelId;
    final String? providerToUse = selectedProviderSlug;

    // Update the user message with the new model/provider
    messages[index]['modelId'] = modelIdToUse;
    messages[index]['provider'] = providerToUse ?? '';

    final List<AttachedFile> attachedFilesForResend =
        attachedFilesOverride ??
        ChatUiHelpers.reconstructAttachedFilesForResend(
          messages[index],
          uuid,
        );
    if (kDebugMode) {
      debugPrint(
        '[ResendDebug] Reconstructed ${attachedFilesForResend.length} attached files for resend',
      );
    }

    // Generate chat ID if needed BEFORE persisting
    activeChatId ??= uuid.v4();
    final String chatId = activeChatId!;

    // Keep builtin tools (artifact_manager, typst_compile) pointing at
    // this chat even if widget.selectedChatId is transiently null
    // during the async resend flow. Without this, the tool handler
    // aborts with "No active chat. Start or select a chat first."
    ChatStorageService.activeMessageChatId = chatId;
    ChatStorageService.selectedChatId ??= chatId;

    // Stamp the new assistant turn with a stable messageId so any
    // artifact versions it produces (create / rewrite / inline tag) are
    // tied to this turn for future regenerate rollbacks. Mirrors the
    // desktop resend path.
    final String assistantMessageId = uuid.v4();
    ArtifactStorageService.currentMessageId = assistantMessageId;
    // Arm the variant fold for this turn (keyed by the new messageId), or
    // clear it when this is not a regenerate.
    armVariantSeed(regenVariantSeed, assistantMessageId);
    setState(() {
      final responseStartedAt = DateTime.now().toIso8601String();
      messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': modelIdToUse,
        'provider': providerToUse ?? '',
        'messageId': assistantMessageId,
        'startedAt': responseStartedAt,
        'sentAt': responseStartedAt,
      });
      placeholderIndex = messages.length - 1;
    });

    // Persist immediately after editing - chat ID is now guaranteed to exist
    persistChat();
    scrollChatToBottom(force: true);

    // Resolve system prompt with workspace context (if any)
    final resolvedSystemPrompt = await resolveSystemPromptForSend();

    // Send using streaming handler with preserved model/provider and attached files
    await streamingHandler.sendMessage(
      userInput: originalUserInput,
      attachedFiles: attachedFilesForResend,
      selectedModelId: modelIdToUse,
      selectedProviderSlug: providerToUse,
      messages: messages,
      systemPrompt: resolvedSystemPrompt,
      activeChatId: chatId,
      placeholderIndex: placeholderIndex,
      getProviderSlug: () async => providerToUse,
      isOffline: isOffline,
      includeRecentImagesInHistory: widget.includeRecentImagesInHistory,
      includeAllImagesInHistory: widget.includeAllImagesInHistory,
      includeReasoningInHistory: widget.includeReasoningInHistory,
      includeToolResultsInHistory: widget.includeToolResultsInHistory,
      toolCallingEnabled: widget.toolCallingEnabled,
      toolDiscoveryMode: widget.toolDiscoveryMode,
      reasoningEffort: clampedReasoningEffort(modelIdToUse, providerToUse),
      // A retry replaces the last answer: the host drops the turn being retried
      // instead of storing a second copy of the same question (bead
      // cowork-bkw).
      regenerate: isRegenerate,
    );
  }

  /// Returns a callback for the ask_user interactive buttons if [index] is
  /// the last AI message, is not streaming, and contains a completed
  /// ask_user tool call. Otherwise returns null.
  void editMessageAt(int index) {
    if (index < 0 || index >= messages.length) return;
    final String text = (messages[index]['text'] ?? '').trim();
    // Restore the message's attachments into the composer so the user can see
    // and remove them while editing. These are already-uploaded files; removal
    // here is list-only (see removeComposerAttachment) so the original message
    // is never corrupted if the edit is cancelled.
    final List<AttachedFile> attached =
        ChatUiHelpers.reconstructAttachedFilesForResend(
          messages[index],
          uuid,
        );
    if (text.isEmpty && attached.isEmpty) return;
    setState(() {
      replyDrafts.remove(replyChatKey);
      messageActionsHandler.startEdit(index);
      composerController.text = text;
      composerController.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
      restoredAttachmentIds
        ..clear()
        ..addAll(attached.map((f) => f.id));
      fileHandler.attachedFiles
        ..clear()
        ..addAll(attached);
    });
    composerFocusNode.requestFocus();
  }

  void replyToMessage(int index) {
    if (index < 0 || index >= messages.length) return;
    final message = messages[index];
    final text = (message['text'] ?? '').trim();
    if (text.isEmpty || text == 'Thinking...') return;
    setState(() {
      messageActionsHandler.cancelEdit();
      replyDrafts[replyChatKey] = ChatReply(
        author: message['sender'] == 'user' ? 'You' : 'AI',
        text: text,
      );
    });
    composerFocusNode.requestFocus();
  }

  void cancelEditMessage() {
    setState(() {
      messageActionsHandler.cancelEdit();
      composerController.clear();
      // List-only clear: the restored attachments still belong to the saved
      // message until an edit is actually submitted, so do NOT delete them
      // from storage here (that would break the original message).
      fileHandler.attachedFiles.clear();
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
        fileHandler.attachedFiles.removeWhere((f) => f.id == fileId);
      });
    } else {
      fileHandler.removeFile(fileId);
    }
  }

  /// Sends the message, or submits an edited message if in edit mode.
  Future<void> sendOrSubmitEdit() async {
    if (messageActionsHandler.isEditing) {
      final editIndex = messageActionsHandler.editingMessageIndex!;
      final newText = composerController.text.trim();
      // Snapshot the (possibly reduced) attachment set BEFORE cancel clears it.
      final attachedSnapshot = List<AttachedFile>.from(
        fileHandler.attachedFiles,
      );
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

  Future<void> resendMessageAt(int index) async {
    if (index < 0 || index >= messages.length) return;

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

    if (sourceIndex < 0 || sourceIndex >= messages.length) {
      showChatSnackBar(AppLocalizations.of(context)!.nothingToResend);
      return;
    }

    final String text = (messages[sourceIndex]['text'] ?? '').trim();
    if (text.isEmpty) {
      showChatSnackBar(AppLocalizations.of(context)!.nothingToResend);
      return;
    }
    // This is a regenerate, so the discarded answer is archived as a variant
    // instead of being lost.
    await submitEditedMessage(
      sourceIndex,
      text,
      removeFollowingAssistant: false,
      clearMessagesBelow: true,
      isRegenerate: true,
    );
  }

  /// Continue an interrupted assistant message — appends new tokens onto the
  /// existing message instead of creating a fresh placeholder.
  ///
  /// Triggered by the "Continue generation" affordance the bubble renders on
  /// any AI message whose persisted status is [ChatMessageStatus.interrupted].
  Future<void> continueGenerationAt(int aiIndex) async {
    if (aiIndex < 0 || aiIndex >= messages.length) return;
    if (streamingHandler.isStreaming || streamingHandler.isSending) {
      showChatSnackBar('Please wait');
      return;
    }
    if (messages[aiIndex]['sender'] != 'ai') return;

    final String priorText = (messages[aiIndex]['text'] ?? '').trim();
    final String? priorContentBlocks = messages[aiIndex]['contentBlocks'];
    if (priorText.isEmpty &&
        (priorContentBlocks == null || priorContentBlocks.isEmpty)) {
      showChatSnackBar('Nothing to continue from');
      return;
    }

    // Persist the active chat id even if widget.selectedChatId is null
    // during this async flow — same protection as resend.
    activeChatId ??= uuid.v4();
    final String chatId = activeChatId!;
    ChatStorageService.activeMessageChatId = chatId;
    ChatStorageService.selectedChatId ??= chatId;

    // Build the API history so the model sees the full prior turn AND its
    // own partial reply. We include messages up to and including the
    // interrupted assistant message — the streaming handler treats this
    // list as "everything that came before the new user turn" and our
    // synthetic [continuePrompt] is appended as the new user message.
    // Anything after [aiIndex] is dropped (sandbox artifacts, etc. would
    // confuse the model and aren't relevant to the continuation).
    final List<Map<String, String>> historyMessages = messages
        .sublist(0, aiIndex + 1)
        .map((m) => Map<String, String>.from(m))
        .toList();

    setState(() {
      // Flip the status off immediately so the Continue button doesn't
      // double-trigger while the new stream is running.
      final m = Map<String, String>.from(messages[aiIndex]);
      m.remove('status');
      messages[aiIndex] = m;
    });

    final String modelIdToUse =
        messages[aiIndex]['modelId']?.trim().isNotEmpty == true
        ? messages[aiIndex]['modelId']!
        : selectedModelId;
    final String? providerToUse =
        messages[aiIndex]['provider']?.trim().isNotEmpty == true
        ? messages[aiIndex]['provider']
        : selectedProviderSlug;

    final resolvedSystemPrompt = await resolveSystemPromptForSend();

    const String continuePrompt =
        'Continue your previous response. Do not repeat what you already '
        'wrote. Pick up exactly where you left off.';

    await streamingHandler.sendMessage(
      userInput: continuePrompt,
      attachedFiles: const <AttachedFile>[],
      selectedModelId: modelIdToUse,
      selectedProviderSlug: providerToUse,
      messages: historyMessages,
      systemPrompt: resolvedSystemPrompt,
      activeChatId: chatId,
      // Stream into the EXISTING assistant message instead of creating a
      // new one — the prior text is seeded into the accumulator below.
      placeholderIndex: aiIndex,
      getProviderSlug: () async => providerToUse,
      isOffline: isOffline,
      includeRecentImagesInHistory: widget.includeRecentImagesInHistory,
      includeAllImagesInHistory: widget.includeAllImagesInHistory,
      includeReasoningInHistory: widget.includeReasoningInHistory,
      includeToolResultsInHistory: widget.includeToolResultsInHistory,
      toolCallingEnabled: widget.toolCallingEnabled,
      toolDiscoveryMode: widget.toolDiscoveryMode,
      reasoningEffort: clampedReasoningEffort(modelIdToUse, providerToUse),
      continuePriorText: priorText,
      continuePriorContentBlocksJson: priorContentBlocks,
    );

    if (kDebugMode) {
      debugPrint(
        '🔁 [Continue] resumed AI message $aiIndex '
        '(priorText chars=${priorText.length})',
      );
    }
  }

  // --- FULLSCREEN EDITOR ---

}
