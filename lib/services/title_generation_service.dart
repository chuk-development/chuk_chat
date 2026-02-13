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

  // Settings keys
  static const String _settingsKey = 'auto_generate_titles';
  static const String _systemPromptKey = 'title_gen_system_prompt';

  // Default system prompt - ChatGPT-style concise title generation
  static const String defaultSystemPrompt = '''Generate a brief title for this conversation based on the user's first message.

Rules:
- 2-6 words maximum
- Capture the main topic or intent
- No quotes or punctuation
- No explanations, just the title''';

  // In-memory cache of settings
  static bool? _autoGenerateTitlesEnabled;
  static String? _customSystemPrompt;

  /// Check if auto title generation is enabled
  static Future<bool> isEnabled() async {
    if (_autoGenerateTitlesEnabled != null) {
      return _autoGenerateTitlesEnabled!;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoGenerateTitlesEnabled = prefs.getBool(_settingsKey) ?? false;
      return _autoGenerateTitlesEnabled!;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading auto title setting: $e');
      }
      return false;
    }
  }

  /// Enable or disable auto title generation
  static Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_settingsKey, enabled);
      _autoGenerateTitlesEnabled = enabled;
      if (kDebugMode) {
        debugPrint('Auto title generation ${enabled ? 'enabled' : 'disabled'}');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error saving auto title setting: $e');
      }
    }
  }

  /// Get the current system prompt (custom or default)
  static Future<String> getSystemPrompt() async {
    if (_customSystemPrompt != null) {
      return _customSystemPrompt!;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _customSystemPrompt = prefs.getString(_systemPromptKey);
      return _customSystemPrompt ?? defaultSystemPrompt;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading system prompt: $e');
      }
      return defaultSystemPrompt;
    }
  }

  /// Set a custom system prompt
  static Future<void> setSystemPrompt(String prompt) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prompt.trim().isEmpty || prompt.trim() == defaultSystemPrompt.trim()) {
        // Clear custom prompt if empty or same as default
        await prefs.remove(_systemPromptKey);
        _customSystemPrompt = null;
        if (kDebugMode) {
          debugPrint('System prompt reset to default');
        }
      } else {
        await prefs.setString(_systemPromptKey, prompt);
        _customSystemPrompt = prompt;
        if (kDebugMode) {
          debugPrint('Custom system prompt saved');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error saving system prompt: $e');
      }
    }
  }

  /// Reset system prompt to default
  static Future<void> resetSystemPrompt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_systemPromptKey);
      _customSystemPrompt = null;
      if (kDebugMode) {
        debugPrint('System prompt reset to default');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error resetting system prompt: $e');
      }
    }
  }

  /// Check if using custom system prompt
  static Future<bool> hasCustomSystemPrompt() async {
    final prompt = await getSystemPrompt();
    return prompt != defaultSystemPrompt;
  }

  /// Generate a title for a chat based on the first user message.
  /// Returns null if generation fails or feature is disabled.
  static Future<String?> generateTitle(String firstMessage) async {
    // Check if feature is enabled
    if (!await isEnabled()) {
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Auto title generation is disabled');
      }
      return null;
    }

    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] No session for title generation');
        }
        return null;
      }

      final accessToken = session.accessToken;

      // Get system prompt (custom or default)
      final systemPrompt = await getSystemPrompt();

      // User message - just the content, system prompt handles the instruction
      final userMessage = firstMessage;

      // Privacy: Don't log user message content in release builds
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Generating title for message (${firstMessage.length} chars)');
      }

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
            if (kDebugMode) {
              debugPrint('📝 [TitleGen] Error: $message');
            }
            return null;
          case DoneEvent():
            break;
          case ReasoningEvent():
          case UsageEvent():
          case MetaEvent():
          case TpsEvent():
            // Ignore these for title generation
            break;
        }
      }

      String title = titleBuffer.toString().trim();
      // Privacy: Don't log generated titles in release builds
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Generated title (${title.length} chars)');
      }

      if (title.isEmpty) {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Empty response');
        }
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

      // Privacy: Don't log titles in release builds
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Final title ready (${title.length} chars)');
      }
      return title;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Error: $e');
      }
    }

    return null;
  }

  /// Generate and apply a title to a chat.
  /// Should be called after the first message is sent.
  static Future<void> generateAndApplyTitle(String chatId, String firstMessage) async {
    // Privacy: Only log non-sensitive metadata
    if (kDebugMode) {
      debugPrint('📝 [TitleGen] generateAndApplyTitle called (${firstMessage.length} chars)');
    }

    try {
      // Check if chat already has a custom name
      final chat = ChatStorageService.getChatById(chatId);
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Chat lookup: ${chat != null ? "found" : "NOT FOUND"}, hasTitle: ${chat?.customName != null}');
      }

      if (chat?.customName != null) {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Chat already has a title, skipping');
        }
        return;
      }

      final title = await generateTitle(firstMessage);
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Generated title result: $title');
      }

      if (title != null && title.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Calling renameChat($chatId, $title)');
        }
        await ChatStorageService.renameChat(chatId, title);
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Successfully applied title to chat $chatId: $title');
        }
      } else {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Title was null or empty, not applying');
        }
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Error applying title: $e');
      }
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Stack trace: $stackTrace');
      }
    }
  }
}
