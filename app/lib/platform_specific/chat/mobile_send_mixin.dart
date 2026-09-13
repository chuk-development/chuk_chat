// lib/platform_specific/chat/mobile_send_mixin.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/chat_reply.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/composer_queue.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:chuk_chat/platform_specific/chat/mobile_attach_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/mobile_model_selection_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/regen_variant_seed.dart';
import 'package:chuk_chat/services/artifact_context_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/utils/tool_history_formatter.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

/// The outbox and the send.
///
/// Everything between the user tapping send and the request leaving: the
/// queue that holds messages fired while the coworker is still working, the
/// history the request carries, the system prompt it is sent under, and the
/// send itself.
///
/// Members are public so the host State and its build method can reach them.
mixin MobileSendMixin<T extends ChukChatUIMobile>
    on
        State<T>,
        ChatScrollMixin<T>,
        ModelProviderResolutionMixin<T>,
        MobileModelSelectionMixin<T>,
        MobileAttachMixin<T>,
        RegenVariantSeedMixin<T> {
  // --- host-provided -------------------------------------------------------

  /// The composer's text field.
  TextEditingController get composerController;

  /// The composer's focus node.
  FocusNode get composerFocusNode;

  /// The host's snack bar.
  void showChatSnackBar(String message);

  /// Id source for new messages and attachments.
  Uuid get uuid;

  MessageActionsHandler get messageActionsHandler;
  ChatPersistenceHandler get persistenceHandler;
  StreamingMessageHandler get streamingHandler;
  ChatApiService get chatApiService;

  /// The transcript of the chat on screen.
  List<Map<String, String>> get messages;

  /// The id of the chat on screen, or null for an unsaved new chat.
  String? get activeChatId;
  set activeChatId(String? value);

  /// Whether a send of this screen's chat is still in flight.
  bool get isSendingMessage;
  set isSendingMessage(bool value);

  /// Whether this screen's chat has a stream open right now.
  bool get isCurrentChatStreaming;

  /// Whether the device is offline.
  bool get isOffline;

  /// Reply drafts, keyed by [replyChatKey].
  Map<String, ChatReply> get replyDrafts;
  String get replyChatKey;

  /// The bubble that should fly in on the next build, or null.
  set flyInKey(String? value);

  /// Drop the decode caches — the message list has been rewritten.
  void clearDecodeCaches();

  /// Write the whole live transcript to storage.
  Future<Object?> persistChat({bool waitForCompletion});

  /// Replace the message at [index] and send again from there.
  Future<void> submitEditedMessage(
    int index,
    String newText, {
    List<AttachedFile>? attachedFilesOverride,
    bool removeFollowingAssistant,
    bool clearMessagesBelow,
  });

  // --- state ---------------------------------------------------------------

  /// The composer's outbox: what the user fired while the coworker worked.
  final PendingMessageQueue pendingMessages = PendingMessageQueue();

  /// The account's system prompt, as last read.
  String? systemPrompt;

  /// Re-read the account's system prompt into [systemPrompt].
  Future<void> loadSystemPrompt() async {
    try {
      final loaded = await UserPreferencesService.loadSystemPrompt();
      if (!mounted) return;
      setState(() {
        systemPrompt = loaded;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading system prompt: $e');
      }
    }
  }

  /// Park the composer's text in the outbox and clear the field, so the user
  /// can keep firing messages while the coworker works.
  void queuePendingMessage() {
    final String text = composerController.text.trim();
    if (text.isEmpty) return;
    void apply() => pendingMessages.add(text);
    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
    composerController.clear();
    if (kDebugMode) {
      debugPrint(
        '📋 [SendMessage] Queued message '
        '(${text.length} chars, ${pendingMessages.length} waiting)',
      );
    }
  }

  /// Drop everything that waits. When exactly one message waited, its text
  /// goes back into an empty composer so the user can edit it instead of
  /// losing it silently.
  void cancelPendingMessages() {
    if (pendingMessages.isEmpty) return;
    final bool restore =
        pendingMessages.length == 1 && composerController.text.trim().isEmpty;
    void apply() {
      final List<String> dropped = pendingMessages.clear();
      if (restore) {
        final String text = dropped.first;
        composerController.text = text;
        composerController.selection = TextSelection.collapsed(offset: text.length);
      }
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  /// Feed the oldest queued message into the text field and start a new send
  /// cycle. One per finished run: the next finalize drains the one after it,
  /// so a burst goes out in the order it was typed.
  void drainPendingMessages() {
    final String? pending = pendingMessages.takeNext();
    if (pending == null) return;

    if (kDebugMode) {
      debugPrint(
        '📋 [DrainQueue] Sending queued message (${pending.length} chars, '
        '${pendingMessages.length} still waiting)',
      );
    }

    setState(() {
      composerController.text = pending;
      composerController.selection = TextSelection.collapsed(offset: pending.length);
    });
    unawaited(sendMessage());
  }

  Future<void> sendMessage() async {
    // A send is already in flight and its stream has not opened yet. The tap
    // is not dropped: it queues like every other message fired while the
    // coworker works, so a burst survives this window too.
    if (isSendingMessage) {
      queuePendingMessage();
      return;
    }

    // SET GLOBAL LOCK IMMEDIATELY - before any async operations or early returns
    // This prevents didUpdateWidget from loading a different chat during send
    ChatStorageService.isMessageOperationInProgress = true;
    if (kDebugMode) {
      debugPrint('🔒 [SendMessage] GLOBAL LOCK SET');
    }

    if (isCurrentChatStreaming) {
      // The coworker is still working — queue the message instead of
      // interrupting it. Any number may pile up; they go out in order.
      queuePendingMessage();
      // Do NOT release the global lock — the original streaming operation
      // is still in progress and will release it upon completion.
      return;
    }

    // Offline check happens after the user message is added below so we can
    // enqueue + reflect "pending" in the UI.

    if (fileHandler.hasUploading) {
      showChatSnackBar('Upload in progress');
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (uploading)');
      }
      return;
    }

    // Restore a chat-local choice before validating; a cold global dropdown
    // must not reject a perfectly configured chat.
    final chatAtSend = modelSelectionChatId;
    try {
      await hydrateChatModel();
    } catch (_) {
      ChatStorageService.isMessageOperationInProgress = false;
      if (mounted) {
        showChatSnackBar('Could not load this chat model. Please retry.');
      }
      return;
    }
    if (!mounted || chatAtSend != modelSelectionChatId) {
      ChatStorageService.isMessageOperationInProgress = false;
      return;
    }
    // Check if a model is selected
    if (selectedModelId.isEmpty) {
      showChatSnackBar('Please select a model first');
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (no model selected)');
      }
      return;
    }

    // Set flag to block realtime updates during send operation
    isSendingMessage = true;
    if (kDebugMode) {
      debugPrint(
        '📨 [SendMessage] Starting send, activeChatId BEFORE: $activeChatId',
      );
    }

    // CRITICAL FIX: Sync activeChatId with widget.selectedChatId if out of sync
    // This handles cases where activeChatId was cleared but user is still on existing chat
    if (activeChatId == null && widget.selectedChatId != null) {
      activeChatId = widget.selectedChatId;
      // May be a return to a chat with a background regenerate still running.
      restoreVariantSeedForChat(widget.selectedChatId);
      if (kDebugMode) {
        debugPrint(
          '⚠️ [SendMessage] SYNCED activeChatId with widget.selectedChatId: $activeChatId',
        );
      }
    }

    // Credit/free message checks are handled server-side (API returns 402)

    final String typedInput = composerController.text.trim();
    final bool hasAttachments = fileHandler.getUploadedFiles().isNotEmpty;
    final replyForSend = replyDrafts[replyChatKey];
    final String originalUserInput =
        replyForSend != null && (typedInput.isNotEmpty || hasAttachments)
        ? replyForSend.compose(typedInput)
        : typedInput;

    if (originalUserInput.isEmpty && !hasAttachments) {
      isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (empty input)');
      }
      return;
    }

    // Validate message using MessageCompositionService
    final route = await ChatModelSelectionService.instance.resolveForSend(
      chatAtSend ?? '',
      modelId: selectedModelId,
      providerSlug: selectedProviderSlug ?? '',
    );
    final modelIdForThisMessage = route.modelId;
    final rawProviderForThisMessage = route.providerSlug.isNotEmpty
        ? route.providerSlug
        : await ensureProviderSlugForCurrentModel();
    final providerForThisMessage = rawProviderForThisMessage == null
        ? null
        : ModelSelectionDropdown.resolveProviderSlugForSend(
            modelIdForThisMessage,
            rawProviderForThisMessage,
          );
    final reasoningForThisMessage = clampedReasoningEffort(
      modelIdForThisMessage,
      providerForThisMessage,
    );
    if (!mounted || modelSelectionChatId != chatAtSend) {
      isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      return;
    }
    final List<Map<String, dynamic>> apiHistory = buildApiHistory();
    final MessageCompositionResult validationResult =
        await MessageCompositionService.prepareMessage(
          userInput: originalUserInput,
          attachedFiles: fileHandler.attachedFiles,
          selectedModelId: modelIdForThisMessage,
          apiHistory: apiHistory,
          systemPrompt: systemPrompt,
          getProviderSlug: () async => providerForThisMessage,
        );

    if (!validationResult.isValid) {
      isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (invalid message)');
      }
      showChatSnackBar(validationResult.errorMessage ?? 'Invalid message');
      return;
    }

    // Do not append the prepared turn to a different chat after a switch.
    if (!mounted || modelSelectionChatId != chatAtSend) {
      isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint(
          '🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during prepareMessage)',
        );
      }
      return;
    }

    // Generate chat ID if new chat and capture it immediately
    // CRITICAL: Capture the chatId in a local variable to prevent race conditions.
    // activeChatId could be changed by callbacks during async operations below.
    final bool isNewChat = activeChatId == null;
    activeChatId ??= uuid.v4();
    final String chatIdForThisMessage = activeChatId!;
    if (kDebugMode) {
      debugPrint(
        '📨 [SendMessage] activeChatId AFTER: $activeChatId (isNewChat: $isNewChat)',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '📨 [SendMessage] Using chatIdForThisMessage: $chatIdForThisMessage',
      );
    }

    // Extract prepared values from validation result
    final String displayMessageText = validationResult.displayMessageText!;
    final List<String>? imageDataUrls = validationResult.images;

    // CRITICAL: Capture attached files BEFORE clearing them
    // These need to be passed to the streaming handler for the API call
    final List<AttachedFile> attachedFilesForApi = List.from(
      fileHandler.attachedFiles,
    );
    if (kDebugMode) {
      debugPrint(
        '📎 [SendMessage] Captured ${attachedFilesForApi.length} attached files for API call',
      );
    }

    // Add user message
    setState(() {
      final sentAt = DateTime.now().toIso8601String();
      replyDrafts.remove(chatIdForThisMessage);
      // Store message with images and attachments (if any)
      final userMessage = {
        'sender': 'user',
        'text': displayMessageText,
        'reasoning': '',
        'modelId': modelIdForThisMessage,
        'provider': providerForThisMessage ?? '',
        // The wall time the reader sent it, so the bubble can carry a clock.
        'startedAt': sentAt,
        'sentAt': sentAt,
      };

      // Store images as JSON-encoded string if present
      if (imageDataUrls != null && imageDataUrls.isNotEmpty) {
        userMessage['images'] = jsonEncode(imageDataUrls);
      }

      // Store document attachments as JSON-encoded string if present
      final documentAttachments = attachedFilesForApi
          .where((f) => !f.isImage && f.markdownContent != null)
          .map(
            (f) => {
              'fileName': f.fileName,
              'markdownContent': f.markdownContent!,
            },
          )
          .toList();

      if (documentAttachments.isNotEmpty) {
        userMessage['attachments'] = jsonEncode(documentAttachments);
        if (kDebugMode) {
          debugPrint(
            '📄 [AttachmentDebug] Storing ${documentAttachments.length} attachments',
          );
        }
      }

      // Store original AttachedFile objects for resend functionality
      if (attachedFilesForApi.isNotEmpty) {
        userMessage['attachedFilesJson'] = jsonEncode(
          attachedFilesForApi.map((f) => f.toJson()).toList(),
        );
        if (kDebugMode) {
          debugPrint(
            '💾 [AttachmentDebug] Storing ${attachedFilesForApi.length} attached files for resend',
          );
        }
      }

      messages.add(userMessage);
      // Mark this message so its list item flies up on entrance.
      flyInKey = ChatUiHelpers.stableUiKey(userMessage, uuid);
      if (kDebugMode) {
        debugPrint(
          '💾 [MessageDebug] Message added to messages list. Total messages: ${messages.length}',
        );
      }

      composerController.clear();
      // Always clear attachments after sending (not just uploaded ones)
      // Clear directly without relying on callback since we're already in setState
      if (fileHandler.attachedFiles.isNotEmpty) {
        fileHandler.attachedFiles.clear();
      }
      final responseStartedAt = DateTime.now().toIso8601String();
      messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': modelIdForThisMessage,
        'provider': providerForThisMessage ?? '',
        'startedAt': responseStartedAt,
        'sentAt': responseStartedAt,
      });
    });

    final int placeholderIndex = messages.length - 1;
    composerFocusNode.requestFocus();
    scrollChatToBottom(force: true);

    // ── Offline short-circuit ──────────────────────────────────────
    // If offline, enqueue the send, flip the user bubble to pending, drop
    // the AI placeholder, persist and bail.  The retry manager replays the
    // send when the network returns.
    if (!NetworkStatusService.isOnline) {
      // Resolve the system prompt the same way the online path does, so the
      // offline replay later behaves identically (workspace context, etc.).
      final resolvedSystemPrompt = await resolveSystemPromptForSend();
      try {
        final queueId = await OfflineSendCoordinator.enqueue(
          OfflineSendPayload(
            chatId: chatIdForThisMessage,
            messageText: validationResult.aiPromptContent ?? displayMessageText,
            modelId: modelIdForThisMessage,
            providerSlug: providerForThisMessage ?? '',
            systemPrompt: resolvedSystemPrompt,
            imagesJson: imageDataUrls != null && imageDataUrls.isNotEmpty
                ? jsonEncode(imageDataUrls)
                : null,
            maxTokens: validationResult.maxResponseTokens ?? 512,
            reasoningEffort: reasoningForThisMessage,
          ),
        );
        if (mounted) {
          setState(() {
            final userIdx = placeholderIndex - 1;
            if (userIdx >= 0 && userIdx < messages.length) {
              messages[userIdx]['status'] = 'pending';
              messages[userIdx]['queueId'] = queueId;
            }
            if (placeholderIndex >= 0 &&
                placeholderIndex < messages.length &&
                messages[placeholderIndex]['text'] == 'Thinking...') {
              messages.removeAt(placeholderIndex);
            }
          });
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Mobile-Send] enqueue failed: $e');
        }
        if (mounted) {
          setState(() {
            final userIdx = placeholderIndex - 1;
            if (userIdx >= 0 && userIdx < messages.length) {
              messages[userIdx]['status'] = 'failed';
              messages[userIdx]['lastError'] = e.toString();
            }
            if (placeholderIndex >= 0 &&
                placeholderIndex < messages.length &&
                messages[placeholderIndex]['text'] == 'Thinking...') {
              messages.removeAt(placeholderIndex);
            }
          });
        }
      }
      unawaited(
        persistenceHandler.persistChat(
          messages: messages,
          chatId: chatIdForThisMessage,
          isOffline: true,
        ),
      );
      // Propagate the new chat ID to the parent so chat-switch behavior
      // stays consistent. Without this the parent thinks selection is
      // still null while this widget already owns chatIdForThisMessage.
      if (isNewChat) {
        widget.onChatIdChanged(chatIdForThisMessage);
      }
      isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (queued offline)');
      }
      return;
    }

    // Immediately create chat in Supabase for reliable chat ID assignment
    // Use the captured chatIdForThisMessage to ensure consistency
    final storedChat = await persistenceHandler.persistChat(
      messages: messages,
      chatId: chatIdForThisMessage,
      waitForCompletion: true,
      isOffline: isOffline,
    );

    // Check if widget was disposed during persist operation
    if (!mounted) {
      isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint(
          '🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during persistChat)',
        );
      }
      return;
    }

    // Verify the stored chat ID matches what we expected
    if (storedChat != null && storedChat.id != chatIdForThisMessage) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [ChatDebug] Chat ID mismatch! Expected: $chatIdForThisMessage, Got: ${storedChat.id}',
        );
      }
    }

    // Keep activeChatId in sync (should already be correct, but ensure consistency)
    if (storedChat != null) {
      activeChatId = storedChat.id;

      // ID-BASED: Notify parent when a new chat is created
      if (isNewChat) {
        if (kDebugMode) {
          debugPrint('');
        }
        if (kDebugMode) {
          debugPrint(
            '┌─────────────────────────────────────────────────────────────',
          );
        }
        if (kDebugMode) {
          debugPrint('│ 🆕 [SEND-MOBILE] NEW CHAT CREATED!');
        }
        if (kDebugMode) {
          debugPrint('│ 🆕 [SEND-MOBILE] New chat ID: ${storedChat.id}');
        }
        if (kDebugMode) {
          debugPrint(
            '│ 🆕 [SEND-MOBILE] Calling widget.onChatIdChanged(${storedChat.id})',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ 🆕 [SEND-MOBILE] This should update ChatStorageService.selectedChatId',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '└─────────────────────────────────────────────────────────────',
          );
        }
        widget.onChatIdChanged(storedChat.id);

        // Auto-generate title for new chats (fire and forget)
        unawaited(
          TitleGenerationService.generateAndApplyTitle(
            storedChat.id,
            displayMessageText,
          ).catchError((error) {
            if (kDebugMode) {
              debugPrint('Title generation failed: $error');
            }
          }),
        );
      }
    }

    // Resolve system prompt with workspace context (if any)
    final resolvedSystemPrompt = await resolveSystemPromptForSend();

    // Send with streaming handler using the CAPTURED chatId, not activeChatId
    // This prevents race conditions where activeChatId could be changed by callbacks
    if (kDebugMode) {
      debugPrint(
        '📤 [ChatDebug] Sending to streaming handler with chatId: $chatIdForThisMessage',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '📤 [ChatDebug] Sending ${attachedFilesForApi.length} attached files to API',
      );
    }
    if (selectedWorkspaceId != null) {
      if (kDebugMode) {
        debugPrint(
          '📁 [ChatDebug] Workspace context included: $selectedWorkspaceId',
        );
      }
    }
    // NOTE: isSendingMessage is cleared in finalizeAiMessage() when streaming completes,
    // NOT here. This prevents race conditions where didUpdateWidget fires while streaming.
    await streamingHandler.sendMessage(
      modelSelectionCaptured: true,
      userInput: originalUserInput,
      attachedFiles: attachedFilesForApi,
      selectedModelId: modelIdForThisMessage,
      selectedProviderSlug: providerForThisMessage,
      messages: messages,
      systemPrompt: resolvedSystemPrompt,
      activeChatId: chatIdForThisMessage,
      placeholderIndex: placeholderIndex,
      getProviderSlug: () async => providerForThisMessage,
      isOffline: isOffline,
      includeRecentImagesInHistory: widget.includeRecentImagesInHistory,
      includeAllImagesInHistory: widget.includeAllImagesInHistory,
      includeReasoningInHistory: widget.includeReasoningInHistory,
      includeToolResultsInHistory: widget.includeToolResultsInHistory,
      toolCallingEnabled: widget.toolCallingEnabled,
      toolDiscoveryMode: widget.toolDiscoveryMode,
      reasoningEffort: reasoningForThisMessage,
    );
  }

  List<Map<String, dynamic>> buildApiHistory() {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
    for (final Map<String, String> message in messages) {
      final String? sender = message['sender'];
      final String? text = message['text'];

      if (sender == 'user') {
        if (text == null || text.trim().isEmpty || text == 'Thinking...') {
          continue;
        }
        history.add({'role': 'user', 'content': text});
      } else if (sender == 'ai' || sender == 'assistant') {
        // Include prior tool calls + results so the model can reuse data
        // it already fetched on a follow-up question.
        final assistantContent = formatAssistantContent(
          message,
          includeReasoning: widget.includeReasoningInHistory,
          includeToolResults: widget.includeToolResultsInHistory,
        );
        if (assistantContent == null) continue;
        history.add({'role': 'assistant', 'content': assistantContent});
      }
    }
    return history;
  }

  /// Resolve system prompt with workspace context (if any)
  Future<String?> resolveSystemPromptForSend() async {
    // Always reload the system prompt from the database so that changes
    // made in SystemPromptPage take effect without restarting the app.
    String? basePrompt;
    try {
      basePrompt = await UserPreferencesService.loadSystemPrompt();
      if (mounted) {
        setState(() {
          systemPrompt = basePrompt;
        });
      } else {
        systemPrompt = basePrompt;
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Error resolving system prompt for send: $error');
      }
      // Fall back to cached value if reload fails (e.g. offline).
      basePrompt = systemPrompt;
    }

    var resolvedPrompt = basePrompt;

    // If a workspace is active, prepend workspace context
    if (selectedWorkspaceId != null && kFeatureWorkspaces) {
      try {
        final projectContext =
            await WorkspaceMessageService.buildProjectSystemMessage(
              selectedWorkspaceId!,
            );
        // Combine workspace context with user's system prompt
        if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
          resolvedPrompt =
              '$projectContext\n\n---\n\nAdditional User Instructions:\n$resolvedPrompt';
        } else {
          resolvedPrompt = projectContext;
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Error building workspace system message: $error');
        }
        // Fall back to base prompt if workspace context fails
      }
    }

    if (kFeatureArtifacts) {
      final chatId = activeChatId ?? ChatStorageService.selectedChatId;
      if (chatId != null && chatId.isNotEmpty) {
        try {
          final artifactContext =
              await ArtifactContextService.buildArtifactsSystemMessage(chatId);
          if (artifactContext != null && artifactContext.isNotEmpty) {
            if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
              resolvedPrompt = '$artifactContext\n\n---\n\n$resolvedPrompt';
            } else {
              resolvedPrompt = artifactContext;
            }
          }
        } catch (error) {
          if (kDebugMode) {
            debugPrint('Error building artifact system message: $error');
          }
        }
      }
    }

    return resolvedPrompt;
  }

}
