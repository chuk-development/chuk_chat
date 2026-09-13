// lib/platform_specific/chat/assistant_message_write_mixin.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:cowork/models/tool_call.dart';
import 'package:cowork/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:cowork/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:cowork/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:cowork/platform_specific/chat/regen_variant_seed.dart';
import 'package:cowork/services/chat_runtime_registry.dart';
import 'package:cowork/services/chat_storage_service.dart';

/// How an assistant answer is written down — while it streams, and when it
/// ends.
///
/// Every method here takes the `chatId` the write belongs to, because the
/// reader may have walked away: a write for the chat on screen goes into the
/// live [messages] list, a write for any other chat goes straight to storage
/// through [persistenceHandler]. Getting that fork wrong writes one chat's
/// answer into another chat's transcript, so it is made once, here, and the
/// rest of the screen never repeats it.
///
/// Members are public so the host State and its build method can reach them.
mixin AssistantMessageWriteMixin<T extends StatefulWidget>
    on State<T>, ChatScrollMixin<T>, RegenVariantSeedMixin<T> {
  // --- host-provided -------------------------------------------------------

  /// The transcript of the chat on screen.
  List<Map<String, String>> get messages;

  /// The id of the chat on screen, or null for an unsaved new chat.
  String? get activeChatId;

  ChatPersistenceHandler get persistenceHandler;
  StreamingMessageHandler get streamingHandler;

  /// Write the whole live transcript to storage.
  Future<Object?> persistChat({bool waitForCompletion});

  /// Whether a send of this screen's chat is still in flight.
  bool get isSendingMessage;
  set isSendingMessage(bool value);

  /// Whether the app is in the background — background writes flush at once
  /// instead of waiting for the debounce.
  bool get isAppInBackground;

  /// Whether the device is offline, for the persistence handler's retry path.
  bool get isOffline;

  /// Send the next queued message, now that this run has finished.
  void drainPendingMessages();

  // --- while the answer streams -------------------------------------------

  /// Periodic snapshot persistence — writes the current streamed body of
  /// the assistant message directly to storage every ~500ms (and on
  /// lifecycle pause). Used to defend against the OS suspending the app
  /// mid-stream and losing the tail of a response.
  ///
  /// We pipe through [ChatPersistenceHandler.updateBackgroundChatMessage]
  /// regardless of whether the chat is foregrounded — the handler
  /// debounces writes per (chatId, messageIndex) so per-tick overhead
  /// stays low.
  void persistStreamTick(
    String chatId,
    int index,
    String content,
    String reasoning,
    String? contentBlocksJson,
    bool forceImmediate,
  ) {
    if (index < 0) return;
    unawaited(
      persistenceHandler
          .updateBackgroundChatMessage(
            chatId: chatId,
            messageIndex: index,
            content: content,
            reasoning: reasoning,
            contentBlocksJson: contentBlocksJson,
            // Force-write on app-background OR when the handler explicitly
            // asked for an immediate flush (lifecycle pause / dispose /
            // cancel). Otherwise let the debounce coalesce per-token churn.
            immediate: forceImmediate || isAppInBackground,
          )
          .catchError((error) {
            if (kDebugMode) {
              debugPrint('persistStreamTick failed: $error');
            }
          }),
    );
  }

  /// Tag an assistant message with `interrupted` status when its stream was
  /// torn down before the final-answer event ran (app suspended, widget
  /// disposed mid-stream, user-cancel, etc). The UI uses this flag to show
  /// the "Continue generation" button.
  void markAssistantMessageInterrupted(String chatId, int index) {
    if (index < 0) return;
    if (activeChatId == chatId && mounted && index < messages.length) {
      setState(() {
        final message = Map<String, String>.from(messages[index]);
        message['status'] = 'interrupted';
        messages[index] = message;
      });
    }
    // Always pipe through the debounced background persistence path so the
    // status hits storage even during widget dispose (where setState +
    // persistChat may race the tear-down). The persistence handler also
    // coalesces with any concurrent snapshot tick into a single write.
    unawaited(
      persistenceHandler
          .updateBackgroundChatMessage(
            chatId: chatId,
            messageIndex: index,
            status: 'interrupted',
            immediate: true,
          )
          .catchError((error) {
            if (kDebugMode) {
              debugPrint(
                'updateBackgroundChatMessage (markInterrupted) failed: $error',
              );
            }
          }),
    );
  }

  void updateAiMessage(
    int index,
    String content,
    String reasoning,
    String chatId,
  ) {
    if (!mounted || index < 0 || index >= messages.length) return;
    if (activeChatId != chatId) return;

    // Keep the backing list in sync (for persistence + finalize) but WITHOUT a
    // screen-wide setState. Per-token rebuilds are scoped to the single
    // streaming bubble, which listens to the runtime's `streamingLive`
    // notifier in the list itemBuilder. This replaces a ~30fps full-tree
    // rebuild (every visible bubble + the composer + overlays) with a rebuild
    // of just the streaming bubble's body.
    final Map<String, String> message = Map<String, String>.from(
      messages[index],
    );
    message['text'] = content;
    message['reasoning'] = reasoning;
    messages[index] = message;

    final runtime = ChatRuntimeRegistry.instance.get(chatId);
    // First token of the turn: the placeholder bubble was first built before
    // the stream manager flipped `isChatStreaming` true, so it isn't yet
    // wrapped in its scoped ValueListenableBuilder. Do exactly one setState
    // now (the chat is streaming by the time the first token arrives) to
    // install the wrapper; every subsequent token updates only the notifier.
    final bool firstToken = runtime.streamingLive.value == null;
    runtime.pushStreamingText(
      index: index,
      text: content,
      reasoning: reasoning,
    );
    if (firstToken) {
      setState(() {});
    }

    // Follow the answer as it streams in, but only while pinned to the bottom.
    pinToBottomDuringStream();
  }

  void updateToolCallsForMessage(
    int index,
    List<ToolCall> toolCalls,
    String chatId,
  ) {
    final String toolCallsJson = jsonEncode(
      toolCalls.map((call) => call.toJson()).toList(),
    );

    final bool isActiveChat = activeChatId == chatId;
    if (mounted && isActiveChat && index >= 0 && index < messages.length) {
      setState(() {
        final message = Map<String, String>.from(messages[index]);
        message['toolCalls'] = toolCallsJson;
        messages[index] = message;
      });
      persistChat();
    } else {
      // `else`, not `if (!isActiveChat)`: the live branch above also declines
      // when the widget is gone or the index is out of range, and for an ACTIVE
      // chat that used to fall between the two branches — the update was
      // written nowhere at all, neither to the list nor to storage. That is the
      // teardown during a running answer (bead cowork-8n33). Storage is the
      // right home whenever the list cannot take it.
      final bool hasInFlightCalls = toolCalls.any(
        (call) =>
            call.status == ToolCallStatus.running ||
            call.status == ToolCallStatus.pending,
      );
      unawaited(
        persistenceHandler
            .updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: index,
              toolCallsJson: toolCallsJson,
              immediate: !hasInFlightCalls,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint(
                  'updateBackgroundChatMessage (toolCalls) failed: $error',
                );
              }
            }),
      );
    }
  }

  void handleToolImagesProcessed(
    int index,
    List<String> imagePaths,
    String imageMetasJson,
    String? imageCostEur,
    String? imageGeneratedAt,
    String toolCallsJson,
    String chatId,
  ) {
    if (imagePaths.isEmpty) return;

    final isActiveChat = activeChatId == chatId;
    if (mounted && isActiveChat && index >= 0 && index < messages.length) {
      setState(() {
        final message = Map<String, String>.from(messages[index]);
        message['images'] = jsonEncode(imagePaths);
        message['imageMetas'] = imageMetasJson;
        if (imageCostEur != null) {
          message['imageCostEur'] = imageCostEur;
        }
        if (imageGeneratedAt != null) {
          message['imageGeneratedAt'] = imageGeneratedAt;
        }
        message['toolCalls'] = toolCallsJson;
        messages[index] = message;
      });
      persistChat();
    } else {
      // Plain `else`, not `else if (!isActiveChat)`: see cowork-8n33. An active
      // chat whose widget is gone reached neither branch and lost the images.
      unawaited(
        persistenceHandler
            .updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: index,
              toolCallsJson: toolCallsJson,
              images: jsonEncode(imagePaths),
              imageMetas: imageMetasJson,
              imageCostEur: imageCostEur,
              imageGeneratedAt: imageGeneratedAt,
              immediate: true,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint(
                  'updateBackgroundChatMessage (toolImages) failed: $error',
                );
              }
            }),
      );
    }
  }

  void updateContentBlocksForMessage(
    int index,
    String contentBlocksJson,
    String chatId,
  ) {
    final bool isActiveChat = activeChatId == chatId;
    if (mounted && isActiveChat && index >= 0 && index < messages.length) {
      setState(() {
        final message = Map<String, String>.from(messages[index]);
        message['contentBlocks'] = contentBlocksJson;
        messages[index] = message;
      });
    } else {
      // `else`, not `if (!isActiveChat)`: see cowork-8n33. An active chat whose
      // widget is gone reached neither branch and lost the blocks.
      unawaited(
        persistenceHandler
            .updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: index,
              contentBlocksJson: contentBlocksJson,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint(
                  'updateBackgroundChatMessage (contentBlocks) failed: $error',
                );
              }
            }),
      );
    }
  }

  void updateRequestPayloadForMessage(
    int index,
    String requestPayloadJson,
    String chatId,
  ) {
    final bool isActiveChat = activeChatId == chatId;
    if (!(mounted && isActiveChat && index >= 0 && index < messages.length)) {
      return;
    }

    setState(() {
      final message = Map<String, String>.from(messages[index]);
      final passPayloads = <dynamic>[];

      final existing = message['debugRequests'];
      if (existing != null && existing.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(existing);
          if (decoded is List) {
            passPayloads.addAll(decoded);
          }
        } catch (_) {}
      }

      try {
        passPayloads.add(jsonDecode(requestPayloadJson));
      } catch (_) {
        passPayloads.add({'raw': requestPayloadJson});
      }

      message['debugRequests'] = jsonEncode(passPayloads);
      messages[index] = message;
    });
  }

  // --- when the answer ends ------------------------------------------------

  Future<void> finalizeAiMessage(
    int index,
    String content,
    String reasoning,
    String chatId,
    double? tps,
  ) async {
    if (kDebugMode) {
      debugPrint(
        '✅ [FinalizeMessage] chatId: $chatId, index: $index, activeChatId: $activeChatId',
      );
    }

    // CRITICAL: Clear flags now that streaming is complete
    // This allows realtime updates and didUpdateWidget to proceed
    if (isSendingMessage) {
      isSendingMessage = false;
      if (kDebugMode) {
        debugPrint('✅ [FinalizeMessage] Cleared isSendingMessage flag');
      }
    }
    // RELEASE GLOBAL LOCK when streaming completes
    if (ChatStorageService.isMessageOperationInProgress) {
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint(
          '🔓 [FinalizeMessage] GLOBAL LOCK RELEASED (stream complete)',
        );
      }
    }

    // Streaming ended: drop the per-token live snapshot so the finalized
    // bubble renders from the persisted message text, not a stale live value.
    ChatRuntimeRegistry.instance.lookup(chatId)?.streamingLive.value = null;

    // Check if this is the active chat (for UI updates)
    final bool isActiveChat = activeChatId == chatId;

    // The bounds are part of the condition, not a return inside it (bead
    // cowork-9u1b): an index past the end of the list — a trimmed transcript, a
    // deleted message, a reload racing the answer — used to return from here
    // and write the finished answer nowhere at all. It belongs in the else
    // below, which never reads `messages` and is addressed by chatId.
    if (mounted && isActiveChat && index >= 0 && index < messages.length) {
      // Update UI only for active chat
      setState(() {
        final Map<String, String> message = Map<String, String>.from(
          messages[index],
        );
        message['text'] = content;
        message['reasoning'] = reasoning;
        if (tps != null) message['tps'] = tps.toString();
        // Clear any prior `interrupted` flag — a clean finalize means the
        // assistant body is complete now, so we drop the Continue button.
        if (message['status'] == 'interrupted') {
          message.remove('status');
        }
        // Answer-version pager: on a regenerate, append this fresh answer as a
        // new variant. Content blocks / tool calls / images are written into
        // the message before finalize on mobile, so the snapshot is complete.
        foldRegenVariantOnto(message);
        messages[index] = message;
      });

      scrollChatToBottom();
      persistChat();
      if (isAppInBackground) {
        unawaited(
          persistenceHandler
              .updateBackgroundChatMessage(
                chatId: chatId,
                messageIndex: index,
                content: content,
                reasoning: reasoning,
                tps: tps?.toString(),
                status: 'sent',
                immediate: true,
              )
              .catchError((error) {
                if (kDebugMode) {
                  debugPrint(
                    'updateBackgroundChatMessage (background-final) failed: $error',
                  );
                }
              }),
        );
      }

      // Drain the outbox — one message per finished run, in order.
      drainPendingMessages();
    } else {
      // Plain `else`, not `else if (!isActiveChat)` (bead cowork-8n33): the
      // branch above also declines when the widget is gone, and an ACTIVE chat
      // in that state used to reach neither — the finished answer was dropped.
      //
      // Usually the user switched to a different chat, and then `messages`
      // belongs to the OTHER chat. DO NOT check messages.length here - it is
      // the wrong chat's message list. The snapshot below is keyed by chatId,
      // so it is right either way.
      //
      // Persist the FULL message list from the streaming snapshot (captured at
      // send start, with the live buffer overlaid) and inject the final answer.
      // This reliably inserts/updates the chat even if it was never persisted
      // yet — the previous single-index update silently dropped the answer when
      // the chat (or its placeholder row) wasn't in storage at flush time,
      // which is exactly the race when you start a NEW chat mid-stream.
      final List<Map<String, dynamic>>? bgMessages = streamingHandler
          .getBackgroundMessages(chatId);
      if (bgMessages != null && index >= 0 && index < bgMessages.length) {
        final List<Map<String, String>> fullMessages = bgMessages.map((m) {
          final converted = <String, String>{};
          m.forEach((key, value) {
            if (value == null) return;
            converted[key] = value is String ? value : value.toString();
          });
          return converted;
        }).toList();
        fullMessages[index]['text'] = content;
        fullMessages[index]['reasoning'] = reasoning;
        if (tps != null) fullMessages[index]['tps'] = tps.toString();
        if (fullMessages[index]['status'] == 'interrupted') {
          fullMessages[index].remove('status');
        }
        // Answer-version pager: fold the previous answer into this background
        // turn's row from the seed stashed when the user switched away, so a
        // regenerate that finishes off-screen keeps its pager (writes the
        // variants directly into fullMessages[index]).
        foldBackgroundVariantOnto(chatId, fullMessages[index]);
        unawaited(
          persistenceHandler
              .persistChat(
                messages: fullMessages,
                chatId: chatId,
                isOffline: isOffline,
                silent: true,
              )
              .catchError((error) {
                if (kDebugMode) {
                  debugPrint('persistChat (chat-switched full) failed: $error');
                }
                return null;
              }),
        );
      } else {
        // Fallback: no snapshot available — best-effort single-index update.
        unawaited(
          persistenceHandler
              .updateBackgroundChatMessage(
                chatId: chatId,
                messageIndex: index,
                content: content,
                reasoning: reasoning,
                status: 'sent',
                immediate: true,
              )
              .catchError((error) {
                if (kDebugMode) {
                  debugPrint(
                    'updateBackgroundChatMessage (chat-switched) failed: $error',
                  );
                }
              }),
        );
      }
    }
  }
}
