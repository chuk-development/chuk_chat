// lib/services/title_generation_service.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';

/// Service for automatically generating chat titles using AI.
/// Uses qwen/qwen3-8b model via Fireworks provider.
class TitleGenerationService {
  static String get _apiBaseUrl => ApiConfigService.apiBaseUrl;

  // Model and provider for title generation
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
      _autoGenerateTitlesEnabled = prefs.getBool(_settingsKey) ?? false;
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
      debugPrint('Auto title generation is disabled');
      return null;
    }

    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No session for title generation');
        return null;
      }

      final accessToken = session.accessToken;

      // Build prompt for title generation
      final prompt = '''Generate a short, concise title (3-6 words) for a chat conversation that starts with this message.
Only respond with the title, nothing else. No quotes, no explanation.

User message: $firstMessage''';

      debugPrint('Generating title for message: ${firstMessage.substring(0, firstMessage.length.clamp(0, 50))}...');

      // Make non-streaming request
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/v1/ai/chat/simple'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model_id': _titleModel,
          'provider_slug': _titleProvider,
          'message': prompt,
          'max_tokens': 20,
          'temperature': 0.7,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String? title = data['content'] as String?;

        if (title != null && title.isNotEmpty) {
          // Clean up the title
          title = title.trim();
          // Remove quotes if present
          if ((title.startsWith('"') && title.endsWith('"')) ||
              (title.startsWith("'") && title.endsWith("'"))) {
            title = title.substring(1, title.length - 1);
          }
          // Limit length
          if (title.length > 50) {
            title = '${title.substring(0, 47)}...';
          }
          debugPrint('Generated title: $title');
          return title;
        }
      } else {
        debugPrint('Title generation failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error generating title: $e');
    }

    return null;
  }

  /// Generate and apply a title to a chat.
  /// Should be called after the first message is sent.
  static Future<void> generateAndApplyTitle(String chatId, String firstMessage) async {
    try {
      // Check if chat already has a custom name
      final chat = ChatStorageService.getChatById(chatId);
      if (chat?.customName != null) {
        debugPrint('Chat already has a title, skipping generation');
        return;
      }

      final title = await generateTitle(firstMessage);
      if (title != null && title.isNotEmpty) {
        await ChatStorageService.renameChat(chatId, title);
        debugPrint('Applied generated title to chat $chatId: $title');
      }
    } catch (e) {
      debugPrint('Error applying generated title: $e');
    }
  }
}
