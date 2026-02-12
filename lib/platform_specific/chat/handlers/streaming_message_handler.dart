// lib/platform_specific/chat/handlers/streaming_message_handler.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/models/chat_model.dart';

/// Handles message streaming and sending
class StreamingMessageHandler {
  final StreamingManager _streamingManager = StreamingManager();

  // Callbacks
  Function(String)? onShowSnackBar;
  Function()? onUpdateUI;
  Function(int index, String content, String reasoning, String chatId)?
  onMessageUpdate;
  Function(int index, String content, String reasoning, String chatId, double? tps)?
  onMessageFinalize;
  Function(String chatId, int index, String content, String reasoning)?
  onBackgroundUpdate;
  Function()? onPaymentRequired;

  bool _isStreaming = false;
  bool _isSending = false;

  bool get isStreaming => _isStreaming;
  bool get isSending => _isSending;

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
  }) async {
    // Check if THIS specific chat is currently streaming (not some other chat)
    final bool thisChatIsStreaming = activeChatId != null &&
        _streamingManager.isStreaming(activeChatId);

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

    // Debug: Log attached files
    if (kDebugMode) {
      debugPrint('📎 [StreamingHandler] Received ${attachedFiles.length} attached files');
      for (final f in attachedFiles) {
        debugPrint('  - ${f.fileName}: isImage=${f.isImage}, encryptedPath=${f.encryptedImagePath}, isUploading=${f.isUploading}');
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
          debugPrint('  - image[$i]: ${images[i].substring(0, 50)}...');
        }
      }
    }

    _isSending = true;
    _isStreaming = true;
    onUpdateUI?.call();

    try {
      final stream = WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: aiPromptContent,
        modelId: selectedModelId,
        providerSlug: providerSlug,
        history: apiHistory.isEmpty ? null : apiHistory,
        systemPrompt: effectiveSystemPrompt,
        maxTokens: maxResponseTokens,
        images: images,
      );

      // Use StreamingManager to handle the stream
      await _streamingManager.startStream(
        chatId: activeChatId!,
        messageIndex: placeholderIndex,
        stream: stream,
        onUpdate: (content, reasoning) {
          // Update UI for active chat
          if (onMessageUpdate != null) {
            onMessageUpdate!(
              placeholderIndex,
              content,
              reasoning,
              activeChatId,
            );
          }
          // Always persist to database in background
          if (onBackgroundUpdate != null) {
            onBackgroundUpdate!(
              activeChatId,
              placeholderIndex,
              content,
              reasoning,
            );
          }
        },
        onComplete: (finalContent, finalReasoning, tps) {
          if (onMessageFinalize != null) {
            final effectiveContent = finalContent.isEmpty
                ? 'The model returned an empty response.'
                : finalContent;
            onMessageFinalize!(
              placeholderIndex,
              effectiveContent,
              finalReasoning,
              activeChatId,
              tps,
            );
          }
          // Always persist final message to database in background
          if (onBackgroundUpdate != null) {
            final effectiveContent = finalContent.isEmpty
                ? 'The model returned an empty response.'
                : finalContent;
            onBackgroundUpdate!(
              activeChatId,
              placeholderIndex,
              effectiveContent,
              finalReasoning,
            );
          }

          _isStreaming = false;
          _isSending = false;
          onUpdateUI?.call();
        },
        onError: (errorMessage) {
          // Handle 402 Payment Required from API server
          if (errorMessage == '__PAYMENT_REQUIRED__') {
            final paymentMessage = 'You have used all free messages. Please subscribe to continue chatting.';
            if (onMessageFinalize != null) {
              onMessageFinalize!(
                placeholderIndex,
                paymentMessage,
                '',
                activeChatId,
                null,
              );
            }
            // Persist to database for consistency
            if (onBackgroundUpdate != null) {
              onBackgroundUpdate!(
                activeChatId,
                placeholderIndex,
                paymentMessage,
                '',
              );
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
              activeChatId,
              null,
            );
          }
          onShowSnackBar?.call(errorMessage);

          _isStreaming = false;
          _isSending = false;
          onUpdateUI?.call();
        },
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to start stream: $error');
      }
      if (onMessageFinalize != null) {
        onMessageFinalize!(
          placeholderIndex,
          'Failed to start streaming: $error',
          '',
          activeChatId!,
          null,
        );
      }
      onShowSnackBar?.call('Failed to start streaming: $error');

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
  void setBackgroundMessages(String chatId, List<Map<String, dynamic>> messages) {
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
        final bool hasImages = message['images'] != null && message['images']!.isNotEmpty;
        final bool shouldAddImages = shouldIncludeImages && hasImages && imageEligibleIndices.contains(i);

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
            assistantContent = '<thinking>\n$reasoning\n</thinking>\n\n$assistantContent';
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
            debugPrint('⚠️ [StreamingHandler] Failed to resolve history image: $e');
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
    // StreamingManager is global, don't dispose it
  }
}
