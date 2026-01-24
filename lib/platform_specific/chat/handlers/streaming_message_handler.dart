// lib/platform_specific/chat/handlers/streaming_message_handler.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
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

  bool _isStreaming = false;
  bool _isSending = false;

  bool get isStreaming => _isStreaming;
  bool get isSending => _isSending;

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
  }) async {
    if (_isSending && !_isStreaming) {
      onShowSnackBar?.call('Please wait');
      return;
    }

    if (_isStreaming) {
      await cancelStream(activeChatId);
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

    // Build API history
    final List<Map<String, String>> apiHistory = _buildApiHistory(
      messages,
      userInput,
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

  /// Build API history from messages
  List<Map<String, String>> _buildApiHistory(
    List<Map<String, String>> messages,
    String pendingUserText,
  ) {
    final List<Map<String, String>> history = <Map<String, String>>[];
    for (final Map<String, String> message in messages) {
      final String? sender = message['sender'];
      final String? text = message['text'];
      if (text == null || text.trim().isEmpty) continue;

      if (sender == 'user') {
        history.add({'role': 'user', 'content': text});
      } else if (sender == 'ai' || sender == 'assistant') {
        history.add({'role': 'assistant', 'content': text});
      }
    }

    if (pendingUserText.trim().isNotEmpty) {
      history.add({'role': 'user', 'content': pendingUserText});
    }

    return history;
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
