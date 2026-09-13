// lib/platform_specific/chat/mobile_chat_loading_mixin.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:chuk_chat/platform_specific/chat/mobile_attach_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/mobile_model_selection_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/mobile_send_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/regen_variant_seed.dart';
import 'package:chuk_chat/services/chat_reaction_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/multiplex_session.dart';

/// Opening a chat, and leaving one.
///
/// A chat is loaded twice over: [loadChatById] paints whatever is already in
/// the local store so the thread is on screen at once, and [loadChatByIdAsync]
/// then reconciles it with storage and with any stream that ran while the
/// reader was elsewhere. [applyLoadedChat] is the single place that swaps one
/// transcript for another, so the caches, the edit state and the loading flag
/// can never be left describing the previous chat.
///
/// Members are public so the host State and its build method can reach them.
mixin MobileChatLoadingMixin<T extends ChukChatUIMobile>
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

  // --- state ---------------------------------------------------------------

  /// Loading indicator for chat switching.
  bool isLoadingChat = false;

  /// May the composer take the focus by itself — when this screen mounts, and
  /// when it loads a chat?
  ///
  /// Not on a phone. The shell keeps this screen mounted BEHIND the coworker
  /// list, because it owns the relay socket (`messenger_shell.dart`), so a
  /// focus grab on mount opens the soft keyboard while the list is what the
  /// reader is looking at. And a messenger does not open the keyboard just
  /// because a thread was opened either: the keyboard belongs to the tap on
  /// the composer. With a hardware keyboard (a desktop window that is narrow
  /// enough for this layout) the focus costs nothing and stays.
  bool get mayAutoFocusComposer =>
      !kIsWeb &&
      defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS;

  void loadChatById(String? chatId) {
    if (chatId != null) unawaited(ChatReactionService.instance.load(chatId));
    // The regenerate seed belongs to the chat we are leaving. If its turn is
    // still running it keeps going in the background, so hand the seed over
    // instead of dropping it — otherwise the background completion cannot fold
    // and the previous answer is lost from the pager.
    stashVariantSeedForBackground();
    if (kDebugMode) {
      debugPrint('');
    }
    if (kDebugMode) {
      debugPrint(
        '┌─────────────────────────────────────────────────────────────',
      );
    }
    if (kDebugMode) {
      debugPrint('│ 📂 [LOAD-CHAT-MOBILE] loadChatById called');
    }
    if (kDebugMode) {
      debugPrint('│ 📂 [LOAD-CHAT-MOBILE] chatId param: $chatId');
    }
    if (kDebugMode) {
      debugPrint(
        '│ 📂 [LOAD-CHAT-MOBILE] Current activeChatId: $activeChatId',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '│ 📂 [LOAD-CHAT-MOBILE] Sidebar expanded: ${widget.isSidebarExpanded}',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '└─────────────────────────────────────────────────────────────',
      );
    }

    // Capture sidebar state NOW - before any async operations
    final bool sidebarWasExpanded = widget.isSidebarExpanded;

    // Synchronous fast path: if the requested chat is already in cache and
    // fully loaded, populate inline without entering async / showing the
    // spinner. This avoids a one-frame loading flash when switching between
    // already-loaded chats.
    if (chatId != null) {
      final StoredChat? cached = ChatStorageService.getChatById(chatId);
      if (cached != null && cached.isFullyLoaded) {
        if (kDebugMode) {
          debugPrint(
            '│ ⚡ [LOAD-CHAT-MOBILE] Sync fast path for $chatId (${cached.messages.length} msgs)',
          );
        }
        activeChatId = cached.id;
        // Returning to a chat whose regenerate was still running in the
        // background: re-arm its seed so the now-foreground answer folds.
        restoreVariantSeedForChat(cached.id);
        unawaited(
          MultiplexSession.openForChat(cached.id).catchError((e) {
            if (kDebugMode) {
              debugPrint('⚠️ MultiplexSession.openForChat failed: $e');
            }
          }),
        );
        applyLoadedChat(cached, sidebarWasExpanded);
        return;
      }
    }

    // Slow path: cache miss or stale → show spinner, go async
    setState(() {
      isLoadingChat = true;
    });

    // Use async function to handle lazy loading
    loadChatByIdAsync(chatId, sidebarWasExpanded);
  }

  /// Apply a fully-loaded [StoredChat] to UI state synchronously: rebuild
  /// `messages`, run stale-tool-call recovery, splice in any buffered
  /// streaming content, and clear `isLoadingChat` in a single `setState`.
  ///
  /// Assumes `activeChatId` has already been set to `chat.id` by the caller
  /// and `MultiplexSession.openForChat` has been triggered.
  void applyLoadedChat(StoredChat chat, bool sidebarWasExpanded) {
    if (!mounted) return;

    // Use the shared ChatMessage->raw-map bridge so mobile and desktop stay in
    // lockstep (it carries modelId/provider/images/attachments/toolCalls/
    // contentBlocks AND the local-only messageId/status/queueId needed to keep
    // stable bubble identity + the "Continue generation" affordance on reload).
    final List<Map<String, String>> newMessages = chat.messages
        .map(ChatUiHelpers.messageToRawMap)
        .toList();

    final String? activeChatId = this.activeChatId;

    // Stale-tool-call recovery (skip if a stream is in flight or just
    // completed — the streaming flow handles its own finalization).
    var recoveredStaleCalls = false;
    if (activeChatId != null &&
        !streamingHandler.isChatStreaming(activeChatId) &&
        !streamingHandler.hasCompletedStream(activeChatId)) {
      for (final message in newMessages) {
        if (ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message)) {
          recoveredStaleCalls = true;
        }
      }
    }

    // Splice buffered streaming content (if any) into the freshly-built list
    // before it lands in messages, so the user never sees a stale snapshot.
    final bool chatIsStreaming =
        activeChatId != null && streamingHandler.isChatStreaming(activeChatId);
    final bool chatHasCompletedStream =
        activeChatId != null &&
        streamingHandler.hasCompletedStream(activeChatId);

    if (activeChatId != null && (chatIsStreaming || chatHasCompletedStream)) {
      // Prefer the StreamingManager's background snapshot — captured at
      // stream start (placeholder appended) with the live buffer overlaid by
      // getBackgroundMessages. The cache copy can be stale or even missing
      // the placeholder entirely if the user switched chats within the
      // first snapshot-flush window (the "Thinking..." placeholder is not
      // persisted synchronously). Falling back to in-place splice when no
      // background snapshot exists.
      final bgMessages = streamingHandler.getBackgroundMessages(activeChatId);
      if (bgMessages != null && bgMessages.isNotEmpty) {
        newMessages
          ..clear()
          ..addAll(
            bgMessages.map((m) {
              final converted = <String, String>{};
              m.forEach((key, value) {
                if (value == null) return;
                converted[key] = value is String ? value : value.toString();
              });
              return converted;
            }),
          );
        if (chatHasCompletedStream) {
          streamingHandler.consumeCompletedStream(activeChatId);
        }
      } else {
        final int? streamingMsgIndex = streamingHandler
            .getStreamingMessageIndex(activeChatId);
        if (streamingMsgIndex != null &&
            streamingMsgIndex >= 0 &&
            streamingMsgIndex < newMessages.length) {
          final String? bufferedContent = streamingHandler.getBufferedContent(
            activeChatId,
          );
          final String? bufferedReasoning = streamingHandler
              .getBufferedReasoning(activeChatId);

          if (bufferedContent != null) {
            final Map<String, String> updatedMessage = Map<String, String>.from(
              newMessages[streamingMsgIndex],
            );
            updatedMessage['text'] = bufferedContent;
            updatedMessage['reasoning'] = bufferedReasoning ?? '';
            newMessages[streamingMsgIndex] = updatedMessage;
            if (chatHasCompletedStream) {
              streamingHandler.consumeCompletedStream(activeChatId);
            }
          }
        }
      }
    }

    setState(() {
      messages
        ..clear()
        ..addAll(newMessages);
      isLoadingChat = false;
      showScrollToBottom = false;
    });

    if (recoveredStaleCalls) {
      unawaited(
        persistenceHandler
            .persistChat(
              messages: messages
                  .map((m) => Map<String, String>.from(m))
                  .toList(),
              chatId: activeChatId,
              waitForCompletion: false,
              isOffline: isOffline,
              silent: true,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint('persistChat (recover stale) failed: $error');
              }
              return null;
            }),
      );
    }

    // Opening an existing chat should *start* at the bottom, not animate.
    scrollChatToBottom(force: true, animate: false);
    // Use captured sidebar state to prevent focus when sidebar was open
    if (mayAutoFocusComposer &&
        !sidebarWasExpanded &&
        !widget.isSidebarExpanded) {
      composerFocusNode.requestFocus();
    }
  }

  Future<void> loadChatByIdAsync(
    String? chatId,
    bool sidebarWasExpanded,
  ) async {
    if (!mounted) return;

    if (chatId == null) {
      // New chat - clear everything
      if (kDebugMode) {
        debugPrint(
          '│ 📂 [LOAD-CHAT-MOBILE] chatId is NULL - clearing for new chat',
        );
      }
      setState(() {
        messages.clear();
        clearDecodeCaches();
        fileHandler.clearAll();
        messageActionsHandler.cancelEdit();
        activeChatId = null;
        isLoadingChat = false;
        showScrollToBottom = false;
      });
      scrollChatToBottom(force: true, animate: false);
      if (mayAutoFocusComposer &&
          !sidebarWasExpanded &&
          !widget.isSidebarExpanded) {
        composerFocusNode.requestFocus();
      }
      return;
    }

    // Find chat by ID
    StoredChat? storedChat = ChatStorageService.getChatById(chatId);

    if (storedChat != null) {
      // LAZY LOADING: Check if chat is fully loaded
      if (!storedChat.isFullyLoaded) {
        if (kDebugMode) {
          debugPrint(
            '│ 📂 [LOAD-CHAT-MOBILE] Chat $chatId not fully loaded, fetching...',
          );
        }
        storedChat = await ChatStorageService.loadFullChat(chatId);

        // Check for stale load after async operation
        if (!mounted) return;
      }

      if (storedChat != null && storedChat.isFullyLoaded) {
        if (kDebugMode) {
          debugPrint(
            '│ 📂 [LOAD-CHAT-MOBILE] FOUND chat $chatId with ${storedChat.messages.length} messages',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ 📂 [LOAD-CHAT-MOBILE] Setting activeChatId = ${storedChat.id}',
          );
        }
        activeChatId = storedChat.id;
        // Returning to a chat whose regenerate was still running in the
        // background: re-arm its seed so the now-foreground answer folds.
        restoreVariantSeedForChat(storedChat.id);
        unawaited(
          MultiplexSession.openForChat(storedChat.id).catchError((e) {
            if (kDebugMode) {
              debugPrint('⚠️ MultiplexSession.openForChat failed: $e');
            }
          }),
        );
        applyLoadedChat(storedChat, sidebarWasExpanded);
        return;
      }

      // Chat load failed - treat as new chat
      if (kDebugMode) {
        debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Chat $chatId load failed!');
      }
    } else {
      // Chat not found - treat as new chat
      if (kDebugMode) {
        debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Chat $chatId NOT FOUND!');
      }
      if (kDebugMode) {
        debugPrint(
          '│ ⚠️ [LOAD-CHAT-MOBILE] Available chats: ${ChatStorageService.savedChats.map((c) => c.id).take(5).toList()}...',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ ⚠️ [LOAD-CHAT-MOBILE] Treating as new chat, setting activeChatId = null',
        );
      }
    }

    if (!mounted) return;
    setState(() {
      messages.clear();
      clearDecodeCaches();
      fileHandler.clearAll();
      messageActionsHandler.cancelEdit();
      activeChatId = null;
      isLoadingChat = false;
      showScrollToBottom = false;
    });
    scrollChatToBottom(force: true, animate: false);
    if (mayAutoFocusComposer &&
        !sidebarWasExpanded &&
        !widget.isSidebarExpanded) {
      composerFocusNode.requestFocus();
    }
  }

  /// Returns the current messages list for debug export.
  void newChat() {
    // Preserve the seed for a still-running turn on the chat we are leaving so
    // its background completion can still fold (mirrors loadChatById).
    stashVariantSeedForBackground();
    if (kDebugMode) {
      debugPrint(
        '🆕 [NewChat] Starting newChat(), current activeChatId: $activeChatId',
      );
    }

    // Capture current chat data for background persistence
    final chatIdToSave = activeChatId;
    final messagesToSave = messages.isNotEmpty
        ? messages.map((m) => Map<String, String>.from(m)).toList()
        : null;

    // Clear UI immediately for instant response
    setState(() {
      messages.clear();
      clearDecodeCaches();
      activeChatId = null;
      fileHandler.clearAll();
      composerController.clear();
      messageActionsHandler.cancelEdit();
    });

    // Notify parent that we're now on a new chat (null ID)
    widget.onChatIdChanged(null);
    if (kDebugMode) {
      debugPrint('🆕 [NewChat] After setState, activeChatId: $activeChatId');
    }
    scrollChatToBottom(force: true);
    if (!widget.isSidebarExpanded) {
      composerFocusNode.requestFocus();
    }

    // Persist old chat in background (don't await).
    // CRITICAL: Use silent=true to prevent onChatIdAssigned from changing
    // the selected chat - we're now on a NEW chat!
    // No need to call loadSavedChatsForSidebar() — persistChat() updates
    // local state and fires notifyChanges(), which the sidebar picks up
    // via its changes stream listener.
    //
    // Also: skip persisting if the old chat was just deleted. Without this,
    // `handleChatDeleted` → `newChat()` would schedule a save of the chat
    // we just removed, and any race against the persistence handler's own
    // `wasRecentlyDeleted` guard could resurrect it in Supabase.
    if (messagesToSave != null &&
        chatIdToSave != null &&
        !ChatStorageState.wasRecentlyDeleted(chatIdToSave)) {
      unawaited(
        persistenceHandler
            .persistChat(
              messages: messagesToSave,
              chatId: chatIdToSave,
              waitForCompletion: false,
              isOffline: isOffline,
              silent: true,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint('persistChat (newChat background) failed: $error');
              }
              return null;
            }),
      );
    }
    if (kDebugMode) {
      debugPrint('🆕 [NewChat] Background operations started');
    }
  }

  // --- AUDIO HANDLERS ---

}
