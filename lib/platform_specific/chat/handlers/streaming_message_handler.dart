// lib/platform_specific/chat/handlers/streaming_message_handler.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_image_result_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

/// Handles message streaming and sending
class StreamingMessageHandler {
  final StreamingManager _streamingManager = StreamingManager();
  final ToolCallHandler _toolCallHandler = ToolCallHandler();

  // Callbacks
  Function(String)? onShowSnackBar;
  Function()? onUpdateUI;
  Function(int index, String content, String reasoning, String chatId)?
  onMessageUpdate;
  Function(
    int index,
    String content,
    String reasoning,
    String chatId,
    double? tps,
  )?
  onMessageFinalize;
  Function(int index, List<ToolCall> toolCalls, String chatId)?
  onToolCallsUpdate;
  Function(
    int index,
    List<String> imagePaths,
    String? imageCostEur,
    String? imageGeneratedAt,
    String toolCallsJson,
    String chatId,
  )?
  onToolImagesProcessed;

  /// Called when content blocks are updated during or after the tool loop.
  /// [contentBlocksJson] is a JSON-encoded list of [ContentBlock] objects.
  Function(int index, String contentBlocksJson, String chatId)?
  onContentBlocksUpdate;

  Function(String chatId, int index, String content, String reasoning)?
  onBackgroundUpdate;
  Function()? onPaymentRequired;

  bool _isStreaming = false;
  bool _isSending = false;
  bool _isDisposed = false;
  Future<void>? _activeToolLoopFuture;

  bool get isStreaming => _isStreaming;
  bool get isSending => _isSending;
  Future<void>? get activeToolLoopFuture => _activeToolLoopFuture;

  // In-memory cache for resolved Base64 images (storage path -> data URL)
  static final Map<String, String> _imageBase64Cache = {};
  static const int _maxCacheSize = 10;

  /// Send a message with streaming response
  Future<void> sendMessage({
    required String userInput,
    required List<AttachedFile> attachedFiles,
    required String selectedModelId,
    required String? selectedProviderSlug,
    required List<Map<String, String>> messages,
    required String? systemPrompt,
    required String? activeChatId,
    required int placeholderIndex,
    required Future<String?> Function() getProviderSlug,
    required bool isOffline,
    bool includeRecentImagesInHistory = true,
    bool includeAllImagesInHistory = false,
    bool includeReasoningInHistory = false,
    bool toolCallingEnabled = true,
    bool toolDiscoveryMode = true,
    bool allowMarkdownToolCalls = true,
  }) async {
    if (_isDisposed) return;

    // Check if THIS specific chat is currently streaming (not some other chat)
    final bool thisChatIsStreaming =
        activeChatId != null && _streamingManager.isStreaming(activeChatId);

    if (thisChatIsStreaming) {
      await cancelStream(activeChatId);
      return;
    }

    if (_isSending) {
      onShowSnackBar?.call('Please wait');
      return;
    }

    // Check network status before sending
    if (isOffline) {
      onShowSnackBar?.call('You are offline. Please check your connection.');
      return;
    }

    if (attachedFiles.any((f) => f.isUploading)) {
      onShowSnackBar?.call('Upload in progress');
      return;
    }

    if (activeChatId == null || activeChatId.isEmpty) {
      onShowSnackBar?.call('Cannot send message without an active chat.');
      return;
    }

    // Debug: Log attached files
    if (kDebugMode) {
      debugPrint(
        '📎 [StreamingHandler] Received ${attachedFiles.length} attached files',
      );
      for (final f in attachedFiles) {
        debugPrint(
          '  - ${f.fileName}: isImage=${f.isImage}, encryptedPath=${f.encryptedImagePath}, isUploading=${f.isUploading}',
        );
      }
    }

    // Build API history (with optional images and reasoning)
    final List<Map<String, dynamic>> apiHistory = await _buildApiHistory(
      messages,
      userInput,
      includeRecentImages: includeRecentImagesInHistory,
      includeAllImages: includeAllImagesInHistory,
      includeReasoning: includeReasoningInHistory,
    );

    // Prepare message using MessageCompositionService
    final result = await MessageCompositionService.prepareMessage(
      userInput: userInput,
      attachedFiles: attachedFiles,
      selectedModelId: selectedModelId,
      apiHistory: apiHistory,
      systemPrompt: systemPrompt,
      getProviderSlug: getProviderSlug,
    );

    if (!result.isValid) {
      onShowSnackBar?.call(result.errorMessage ?? 'Invalid message');
      if (result.errorMessage == 'Session expired. Please sign in again.') {
        await SupabaseService.signOut();
      }
      return;
    }

    // Extract prepared values
    final String accessToken = result.accessToken!;
    final String providerSlug = result.providerSlug!;
    final int maxResponseTokens = result.maxResponseTokens!;
    final String? effectiveSystemPrompt = result.effectiveSystemPrompt;
    final String aiPromptContent = result.aiPromptContent!;
    final List<String>? images = result.images;

    // Debug: Log what images we're sending
    if (kDebugMode) {
      debugPrint('🚀 [StreamingHandler] Sending to API:');
      debugPrint('  - images: ${images?.length ?? 0}');
      if (images != null && images.isNotEmpty) {
        for (int i = 0; i < images.length; i++) {
          final preview = images[i].length > 50
              ? images[i].substring(0, 50)
              : images[i];
          debugPrint('  - image[$i]: $preview...');
        }
      }
    }

    _isSending = true;
    _isStreaming = true;
    onUpdateUI?.call();

    final chatId = activeChatId;

    final toolSession = _toolCallHandler.createSession(
      initialUserMessage: aiPromptContent,
      history: apiHistory,
      accessToken: accessToken,
      discoveryContextKey: chatId,
      baseSystemPrompt: effectiveSystemPrompt,
      toolCallingEnabled: toolCallingEnabled,
      discoveryMode: toolDiscoveryMode,
      allowMarkdownToolCalls: allowMarkdownToolCalls,
    );
    final initialSystemPrompt = await _toolCallHandler.buildInitialSystemPrompt(
      toolSession,
    );
    const int kMaxStreamingPasses = 20;

    // Accumulates display text across all streaming passes so that AI text
    // from earlier passes is never lost when a new pass begins.
    final accumulatedText = StringBuffer();

    // Ordered content blocks built across streaming passes.
    // Each completed pass adds its text + tool_calls blocks here.
    final contentBlocks = <ContentBlock>[];
    int previousToolCallCount = 0;

    /// Encode current content blocks to JSON.
    String encodeBlocks() =>
        jsonEncode(contentBlocks.map((b) => b.toJson()).toList());

    Future<void> startStreamingPass({
      required String message,
      required List<Map<String, dynamic>> history,
      required String? systemPrompt,
      List<String>? passImages,
      int currentPass = 0,
    }) async {
      if (currentPass >= kMaxStreamingPasses) {
        const stopMessage =
            'Tool loop stopped after reaching the safety limit.';
        if (onMessageFinalize != null) {
          onMessageFinalize!(placeholderIndex, stopMessage, '', chatId, null);
        }
        if (onBackgroundUpdate != null) {
          onBackgroundUpdate!(chatId, placeholderIndex, stopMessage, '');
        }
        _isStreaming = false;
        _isSending = false;
        onUpdateUI?.call();
        return;
      }

      final stream = WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: message,
        modelId: selectedModelId,
        providerSlug: providerSlug,
        history: history.isEmpty ? null : history,
        systemPrompt: systemPrompt,
        maxTokens: maxResponseTokens,
        images: passImages,
      );

      await _streamingManager.startStream(
        chatId: chatId,
        messageIndex: placeholderIndex,
        stream: stream,
        onUpdate: (content, reasoning) {
          if (_isDisposed) return;
          final displayContent = stripToolCallBlocksForDisplay(content);

          // When content blocks exist (multi-pass), only show current pass
          // text — previous passes are rendered from content blocks.
          // When no blocks yet (first pass / no tools), show full text.
          final fullDisplay = contentBlocks.isEmpty
              ? displayContent
              : displayContent;

          if (onMessageUpdate != null) {
            onMessageUpdate!(placeholderIndex, fullDisplay, reasoning, chatId);
          }
          if (onBackgroundUpdate != null) {
            onBackgroundUpdate!(
              chatId,
              placeholderIndex,
              fullDisplay,
              reasoning,
            );
          }
        },
        onComplete: (finalContent, finalReasoning, tps) {
          if (_isDisposed) return;

          // onComplete is sync in StreamingManager, so tool-loop continuation
          // runs asynchronously and is tracked for lifecycle safety.
          final completionFuture = () async {
            try {
              final loopResult = await _toolCallHandler
                  .processAssistantResponse(
                    session: toolSession,
                    content: finalContent,
                    reasoning: finalReasoning,
                    onToolCallsUpdated: (toolCalls) {
                      onToolCallsUpdate?.call(
                        placeholderIndex,
                        toolCalls,
                        chatId,
                      );
                    },
                  );

              if (_isDisposed) return;

              if (loopResult.shouldContinue && loopResult.nextStep != null) {
                final interimText = loopResult.interimContent?.trim() ?? '';

                // --- Build content blocks for this completed pass ---
                // Determine which tool calls are new in this round.
                final allToolCalls = loopResult.toolCalls;
                final newToolCalls = allToolCalls.length > previousToolCallCount
                    ? allToolCalls.sublist(previousToolCallCount)
                    : <ToolCall>[];
                previousToolCallCount = allToolCalls.length;

                // Add text block for this pass's visible text.
                if (interimText.isNotEmpty) {
                  contentBlocks.add(ContentBlock.text(interimText));
                }
                // Add tool_calls block for this pass's tool calls.
                // If the AI didn't say anything to the user since the last
                // tool_calls block, merge into that block instead of creating
                // a separate collapsible bar.
                if (newToolCalls.isNotEmpty) {
                  if (interimText.isEmpty &&
                      contentBlocks.isNotEmpty &&
                      contentBlocks.last.type == ContentBlockType.toolCalls) {
                    final merged = [
                      ...contentBlocks.last.toolCalls!,
                      ...newToolCalls,
                    ];
                    contentBlocks[contentBlocks.length - 1] =
                        ContentBlock.toolCalls(merged);
                  } else {
                    contentBlocks.add(ContentBlock.toolCalls(newToolCalls));
                  }
                }

                // Fire content blocks update so the UI can render them.
                onContentBlocksUpdate?.call(
                  placeholderIndex,
                  encodeBlocks(),
                  chatId,
                );

                // Accumulate text for backward-compat message field.
                if (interimText.isNotEmpty) {
                  accumulatedText.write(interimText);
                  accumulatedText.write('\n\n');
                }

                // Clear the message text for the next pass — content
                // blocks handle previous passes, onMessageUpdate will
                // show only the new pass's streaming text.
                if (onMessageUpdate != null) {
                  onMessageUpdate!(
                    placeholderIndex,
                    '',
                    finalReasoning,
                    chatId,
                  );
                }

                if (_isDisposed) return;

                final next = loopResult.nextStep!;
                // Yield to event loop so interim UI updates can paint first.
                await Future<void>.delayed(Duration.zero);
                await startStreamingPass(
                  message: next.message,
                  history: next.history,
                  systemPrompt: next.systemPrompt,
                  currentPass: currentPass + 1,
                );
                return;
              }

              if (_isDisposed) return;

              // Persist tool-generated images to encrypted storage
              await _processToolImages(
                loopResult.toolCalls,
                placeholderIndex,
                chatId,
              );

              final rawContent =
                  (loopResult.finalContent ?? finalContent).isEmpty
                  ? 'The model returned an empty response.'
                  : (loopResult.finalContent ?? finalContent);
              final effectiveReasoning =
                  loopResult.finalReasoning ?? finalReasoning;

              // --- Build final content blocks ---
              if (contentBlocks.isNotEmpty) {
                // Multi-pass: add the final answer as a text block.
                final finalText = stripToolCallBlocksForDisplay(
                  rawContent,
                ).trim();
                if (effectiveReasoning.isNotEmpty) {
                  contentBlocks.add(ContentBlock.reasoning(effectiveReasoning));
                }
                if (finalText.isNotEmpty) {
                  contentBlocks.add(ContentBlock.text(finalText));
                }
                onContentBlocksUpdate?.call(
                  placeholderIndex,
                  encodeBlocks(),
                  chatId,
                );
              }

              // Prepend accumulated text from previous passes so nothing
              // is lost in the flat message field (backward compat).
              final effectiveContent = accumulatedText.isEmpty
                  ? rawContent
                  : '$accumulatedText$rawContent';

              if (onMessageFinalize != null) {
                onMessageFinalize!(
                  placeholderIndex,
                  effectiveContent,
                  effectiveReasoning,
                  chatId,
                  tps,
                );
              }
              if (onBackgroundUpdate != null) {
                onBackgroundUpdate!(
                  chatId,
                  placeholderIndex,
                  effectiveContent,
                  effectiveReasoning,
                );
              }

              _isStreaming = false;
              _isSending = false;
              onUpdateUI?.call();
            } catch (error) {
              if (_isDisposed) return;
              if (kDebugMode) {
                debugPrint('Tool loop processing failed: $error');
              }
              const userMessage =
                  'An unexpected error occurred while processing tools.';
              if (onMessageFinalize != null) {
                onMessageFinalize!(
                  placeholderIndex,
                  userMessage,
                  '',
                  chatId,
                  null,
                );
              }
              onShowSnackBar?.call(
                'An unexpected error occurred. Please try again.',
              );
              _isStreaming = false;
              _isSending = false;
              onUpdateUI?.call();
            }
          }();

          _activeToolLoopFuture = completionFuture;
          unawaited(completionFuture);
        },
        onError: (errorMessage) {
          if (_isDisposed) return;

          if (errorMessage == '__PAYMENT_REQUIRED__') {
            final paymentMessage =
                'You have used all free messages. Please subscribe to continue chatting.';
            if (onMessageFinalize != null) {
              onMessageFinalize!(
                placeholderIndex,
                paymentMessage,
                '',
                chatId,
                null,
              );
            }
            if (onBackgroundUpdate != null) {
              onBackgroundUpdate!(chatId, placeholderIndex, paymentMessage, '');
            }
            _isStreaming = false;
            _isSending = false;
            onUpdateUI?.call();
            onPaymentRequired?.call();
            return;
          }

          if (onMessageFinalize != null) {
            onMessageFinalize!(
              placeholderIndex,
              errorMessage,
              '',
              chatId,
              null,
            );
          }
          onShowSnackBar?.call(errorMessage);

          _isStreaming = false;
          _isSending = false;
          onUpdateUI?.call();
        },
      );
    }

    try {
      await startStreamingPass(
        message: aiPromptContent,
        history: apiHistory,
        systemPrompt: initialSystemPrompt,
        passImages: images,
      );
    } catch (error) {
      if (_isDisposed) return;
      if (kDebugMode) {
        debugPrint('Failed to start stream: $error');
      }
      const failureMessage = 'Failed to start streaming. Please try again.';
      if (onMessageFinalize != null) {
        onMessageFinalize!(placeholderIndex, failureMessage, '', chatId, null);
      }
      onShowSnackBar?.call(failureMessage);

      _isStreaming = false;
      _isSending = false;
      onUpdateUI?.call();
    }
  }

  /// Cancel active stream
  Future<void> cancelStream(String? chatId) async {
    if (chatId != null && (_isStreaming || _isSending)) {
      if (kDebugMode) {
        debugPrint('Cancelling stream for chat $chatId...');
      }
      await _streamingManager.cancelStream(chatId);

      _isStreaming = false;
      _isSending = false;
      onShowSnackBar?.call('Response cancelled');
      onUpdateUI?.call();
    }
  }

  /// Download tool-generated images, encrypt, and persist to Supabase storage.
  Future<void> _processToolImages(
    List<ToolCall> toolCalls,
    int index,
    String chatId,
  ) async {
    if (toolCalls.isEmpty || _isDisposed) return;

    final hasImages = toolCalls.any(
      (c) =>
          c.result != null &&
          (c.result!.startsWith('IMAGE:') ||
              c.result!.startsWith('IMAGE_DATA:')),
    );
    if (!hasImages) return;

    try {
      final imageResult = await ToolImageResultService.processToolCalls(
        toolCalls,
      );

      if (imageResult.imagePaths.isEmpty || _isDisposed) return;

      final updatedToolCallsJson = jsonEncode(
        imageResult.toolCalls.map((c) => c.toJson()).toList(),
      );

      onToolImagesProcessed?.call(
        index,
        imageResult.imagePaths,
        imageResult.imageCostEur,
        imageResult.imageGeneratedAt,
        updatedToolCallsJson,
        chatId,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to process tool images: $error');
      }
    }
  }

  /// Reset state (use when stuck in invalid state)
  void resetState() {
    _isStreaming = false;
    _isSending = false;
    onUpdateUI?.call();
  }

  /// Check if a specific chat is streaming
  bool isChatStreaming(String chatId) {
    return _streamingManager.isStreaming(chatId);
  }

  /// Get buffered content for a streaming chat
  String? getBufferedContent(String chatId) {
    return _streamingManager.getBufferedContent(chatId);
  }

  /// Get buffered reasoning for a streaming chat
  String? getBufferedReasoning(String chatId) {
    return _streamingManager.getBufferedReasoning(chatId);
  }

  /// Get the streaming message index for a chat
  int? getStreamingMessageIndex(String chatId) {
    return _streamingManager.getStreamingMessageIndex(chatId);
  }

  /// Check if a chat has a completed stream with buffered content
  bool hasCompletedStream(String chatId) {
    return _streamingManager.hasCompletedStream(chatId);
  }

  /// Remove a completed stream entry after its content has been consumed
  void consumeCompletedStream(String chatId) {
    _streamingManager.consumeCompletedStream(chatId);
  }

  /// Store background messages for a streaming chat when user switches away
  void setBackgroundMessages(
    String chatId,
    List<Map<String, dynamic>> messages,
  ) {
    _streamingManager.setBackgroundMessages(chatId, messages);
  }

  /// Build API history from messages, optionally including images and reasoning
  Future<List<Map<String, dynamic>>> _buildApiHistory(
    List<Map<String, String>> messages,
    String pendingUserText, {
    bool includeRecentImages = true,
    bool includeAllImages = false,
    bool includeReasoning = false,
  }) async {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];

    // Determine image window: count user messages with images from end
    final bool shouldIncludeImages = includeRecentImages || includeAllImages;
    final int imageWindow = includeAllImages ? messages.length : 6;

    // Find which user messages (by index) are within the image window
    final Set<int> imageEligibleIndices = {};
    if (shouldIncludeImages) {
      int userMsgCount = 0;
      for (int i = messages.length - 1; i >= 0; i--) {
        if (messages[i]['sender'] == 'user') {
          userMsgCount++;
          if (userMsgCount <= imageWindow) {
            imageEligibleIndices.add(i);
          }
        }
      }
    }

    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];
      final String? sender = message['sender'];
      final String? text = message['text'];

      if (sender == 'user') {
        final bool hasImages =
            message['images'] != null && message['images']!.isNotEmpty;
        final bool shouldAddImages =
            shouldIncludeImages &&
            hasImages &&
            imageEligibleIndices.contains(i);

        if (shouldAddImages) {
          // Build multimodal content with text + images
          final content = <Map<String, dynamic>>[];
          if (text != null && text.trim().isNotEmpty) {
            content.add({'type': 'text', 'text': text});
          }
          // Resolve image storage paths to Base64
          final imageDataUrls = await _resolveHistoryImages(message['images']!);
          for (final dataUrl in imageDataUrls) {
            content.add({
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            });
          }
          if (content.isNotEmpty) {
            history.add({'role': 'user', 'content': content});
          }
        } else if (text != null && text.trim().isNotEmpty) {
          history.add({'role': 'user', 'content': text});
        }
      } else if (sender == 'ai' || sender == 'assistant') {
        if (text == null || text.trim().isEmpty) continue;
        String assistantContent = text;
        if (includeReasoning) {
          final reasoning = message['reasoning'] ?? '';
          if (reasoning.isNotEmpty) {
            assistantContent =
                '<thinking>\n$reasoning\n</thinking>\n\n$assistantContent';
          }
        }
        history.add({'role': 'assistant', 'content': assistantContent});
      }
    }

    // Don't add pendingUserText here - the server adds the current message
    // from the 'message' parameter. Adding it here causes duplicate user
    // messages which makes AI models think the user sent the message twice.

    return history;
  }

  /// Resolve image storage paths from a JSON-encoded list to Base64 data URLs
  Future<List<String>> _resolveHistoryImages(String imagesJson) async {
    final List<String> dataUrls = [];
    try {
      final decoded = jsonDecode(imagesJson);
      if (decoded is! List) return dataUrls;

      for (final img in decoded) {
        final path = img.toString();
        if (path.isEmpty) continue;

        // Check if already a data URL
        if (path.startsWith('data:image/')) {
          dataUrls.add(path);
          continue;
        }

        // Check cache
        if (_imageBase64Cache.containsKey(path)) {
          dataUrls.add(_imageBase64Cache[path]!);
          continue;
        }

        // Download, decrypt, convert to Base64
        try {
          final bytes = await ImageStorageService.downloadAndDecryptImage(path);
          final base64 = base64Encode(bytes);
          final dataUrl = 'data:image/jpeg;base64,$base64';

          // Cache with eviction
          if (_imageBase64Cache.length >= _maxCacheSize) {
            _imageBase64Cache.remove(_imageBase64Cache.keys.first);
          }
          _imageBase64Cache[path] = dataUrl;
          dataUrls.add(dataUrl);
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [StreamingHandler] Failed to resolve history image: $e',
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [StreamingHandler] Failed to parse images JSON: $e');
      }
    }
    return dataUrls;
  }

  /// Get session safely with network error handling
  Future<dynamic> getSessionSafely() async {
    try {
      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;

      if (session == null) {
        // Check if we're offline before logging out
        final bool isOnline =
            await NetworkStatusService.hasInternetConnection();
        if (!isOnline) {
          onShowSnackBar?.call('Cannot connect. Please check your network.');
          return null;
        }

        // Online but no session = genuinely expired
        onShowSnackBar?.call('Session expired. Please sign in again.');
        await SupabaseService.signOut();
        return null;
      }

      return session;
    } catch (error) {
      // Check if this is a network error
      if (NetworkStatusService.isNetworkError(error)) {
        if (kDebugMode) {
          debugPrint('Network error during session refresh: $error');
        }
        onShowSnackBar?.call('Network error. Please check your connection.');
        return null;
      }

      // Not a network error, likely auth issue
      if (kDebugMode) {
        debugPrint('Auth error during session refresh: $error');
      }
      onShowSnackBar?.call('Authentication error. Please sign in again.');
      await SupabaseService.signOut();
      return null;
    }
  }

  /// Dispose resources
  void dispose() {
    _isDisposed = true;
    _activeToolLoopFuture = null;
    // StreamingManager is global, don't dispose it
  }
}
