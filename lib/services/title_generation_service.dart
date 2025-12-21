// lib/services/title_generation_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';

/// Service for automatically generating chat titles using AI.
/// Uses qwen/qwen3-8b model via Fireworks provider over WebSocket.
class TitleGenerationService {

  // Model and provider for title generation
  // Using qwen3-8b via fireworks (fast and cheap for title generation)
  static const String _titleModel = 'qwen/qwen3-8b';
  static const String _titleProvider = 'fireworks';

  // Settings key
  static const String _settingsKey = 'auto_generate_titles';

  // In-memory cache of setting
  static bool? _autoGenerateTitlesEnabled;

  /// Check if auto title generation is enabled
  static Future<bool> isEnabled() async {
    if (_autoGenerateTitlesEnabled != null) {
      return _autoGenerateTitlesEnabled!;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoGenerateTitlesEnabled = prefs.getBool(_settingsKey) ?? true;
      return _autoGenerateTitlesEnabled!;
    } catch (e) {
      debugPrint('Error loading auto title setting: $e');
      return false;
    }
  }

  /// Enable or disable auto title generation
  static Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_settingsKey, enabled);
      _autoGenerateTitlesEnabled = enabled;
      debugPrint('Auto title generation ${enabled ? 'enabled' : 'disabled'}');
    } catch (e) {
      debugPrint('Error saving auto title setting: $e');
    }
  }

  /// Generate a title for a chat based on the first user message.
  /// Returns null if generation fails or feature is disabled.
  static Future<String?> generateTitle(String firstMessage) async {
    // Check if feature is enabled
    if (!await isEnabled()) {
      debugPrint('📝 [TitleGen] Auto title generation is disabled');
      return null;
    }

    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('📝 [TitleGen] No session for title generation');
        return null;
      }

      final accessToken = session.accessToken;

      // System prompt for title generation
      const systemPrompt = '''You are a title generator. Your ONLY job is to create short, concise titles (3-6 words) for chat conversations.
Rules:
- Output ONLY the title, nothing else
- No quotes, no explanation, no punctuation at the end
- No thinking or reasoning - just the title
- Keep it under 6 words''';

      // User message - the actual content to create a title for
      final userMessage = 'Create a title for this message: $firstMessage';

      debugPrint('📝 [TitleGen] Generating title for: ${firstMessage.substring(0, firstMessage.length.clamp(0, 50))}...');

      // Use WebSocket streaming (same as main chat)
      final StringBuffer titleBuffer = StringBuffer();

      await for (final event in WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: userMessage,
        modelId: _titleModel,
        providerSlug: _titleProvider,
        systemPrompt: systemPrompt,
        maxTokens: 32, // Very short for titles
        temperature: 0.3, // Lower temperature for more focused output
      )) {
        switch (event) {
          case ContentEvent(:final text):
            titleBuffer.write(text);
          case ErrorEvent(:final message):
            debugPrint('📝 [TitleGen] Error: $message');
            return null;
          case DoneEvent():
            break;
          case ReasoningEvent():
          case UsageEvent():
          case MetaEvent():
            // Ignore these for title generation
            break;
        }
      }

      String title = titleBuffer.toString().trim();
      debugPrint('📝 [TitleGen] Raw buffer content: $title');

      if (title.isEmpty) {
        debugPrint('📝 [TitleGen] Empty response');
        return null;
      }

      // Clean up the title
      // Remove any thinking tags that might be present (qwen models sometimes include these)
      title = title.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '').trim();
      title = title.replaceAll(RegExp(r'<thinking>.*?</thinking>', dotAll: true), '').trim();

      // Remove quotes if present
      if ((title.startsWith('"') && title.endsWith('"')) ||
          (title.startsWith("'") && title.endsWith("'"))) {
        title = title.substring(1, title.length - 1);
      }
      // Remove any trailing punctuation that looks weird
      title = title.replaceAll(RegExp(r'[.!?]+$'), '').trim();
      // Limit length
      if (title.length > 50) {
        title = '${title.substring(0, 47)}...';
      }

      debugPrint('📝 [TitleGen] Final cleaned title: $title');
      return title;
    } catch (e) {
      debugPrint('📝 [TitleGen] Error: $e');
    }

    return null;
  }

  /// Generate and apply a title to a chat.
  /// Should be called after the first message is sent.
  static Future<void> generateAndApplyTitle(String chatId, String firstMessage) async {
    debugPrint('📝 [TitleGen] generateAndApplyTitle called for chat: $chatId');
    debugPrint('📝 [TitleGen] First message: ${firstMessage.substring(0, firstMessage.length.clamp(0, 50))}...');

    try {
      // Check if chat already has a custom name
      final chat = ChatStorageService.getChatById(chatId);
      debugPrint('📝 [TitleGen] Chat lookup result: ${chat != null ? "found" : "NOT FOUND"}');
      if (chat != null) {
        debugPrint('📝 [TitleGen] Chat customName: ${chat.customName}');
      }

      if (chat?.customName != null) {
        debugPrint('📝 [TitleGen] Chat already has a title, skipping');
        return;
      }

      final title = await generateTitle(firstMessage);
      debugPrint('📝 [TitleGen] Generated title result: $title');

      if (title != null && title.isNotEmpty) {
        debugPrint('📝 [TitleGen] Calling renameChat($chatId, $title)');
        await ChatStorageService.renameChat(chatId, title);
        debugPrint('📝 [TitleGen] Successfully applied title to chat $chatId: $title');
      } else {
        debugPrint('📝 [TitleGen] Title was null or empty, not applying');
      }
    } catch (e, stackTrace) {
      debugPrint('📝 [TitleGen] Error applying title: $e');
      debugPrint('📝 [TitleGen] Stack trace: $stackTrace');
    }
  }
}
