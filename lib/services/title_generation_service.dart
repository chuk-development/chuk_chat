// lib/services/title_generation_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';

/// Service for automatically generating chat titles using AI.
/// Uses qwen/qwen3.5-9b model for title generation over WebSocket.
class TitleGenerationService {
  // Model and provider for title generation
  static const String _titleModel = 'qwen/qwen3.5-9b';
  static const String _titleProvider = '';

  // Settings keys
  static const String _settingsKey = 'auto_generate_titles';
  static const String _systemPromptKey = 'title_gen_system_prompt';
  static const String _decryptFailedSentinel = '__decrypt_failed__';
  static const String _remoteEnabledColumn = 'auto_generate_titles';
  static const String _remotePromptColumn = 'title_gen_system_prompt';

  // Default system prompt - ChatGPT-style concise title generation
  static const String defaultSystemPrompt =
      '''Generate a brief title for this conversation based on the user's first message.

Rules:
- 2-6 words maximum
- Capture the main topic or intent
- No quotes or punctuation
- No explanations, just the title''';

  // In-memory cache of settings
  static bool? _autoGenerateTitlesEnabled;
  static String? _customSystemPrompt;
  static DateTime? _lastRemoteSyncAt;
  static Future<void>? _remoteSyncInFlight;
  static Duration get _remoteSyncTtl {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return const Duration(minutes: 2);
    }
    return const Duration(seconds: 30);
  }

  static const Duration _chatLookupRetryDelay = Duration(milliseconds: 450);
  static const int _maxChatLookupAttempts = 8;
  static const int _maxRenameAttempts = 6;
  static final Set<String> _inFlightTitleChats = <String>{};

  /// Check if auto title generation is enabled
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _autoGenerateTitlesEnabled ??= prefs.getBool(_settingsKey) ?? false;

      // Keep local settings synced from Supabase in the background.
      unawaited(syncSettingsFromSupabase());

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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_settingsKey, enabled);
    _autoGenerateTitlesEnabled = enabled;

    try {
      final session = SupabaseService.auth.currentSession;
      if (session != null) {
        await SupabaseService.client.from('customization_preferences').upsert({
          'user_id': session.user.id,
          _remoteEnabledColumn: enabled,
        }, onConflict: 'user_id');
      }
      if (kDebugMode) {
        debugPrint('Auto title generation ${enabled ? 'enabled' : 'disabled'}');
      }
    } on PostgrestException catch (e) {
      if (kDebugMode && !_isMissingTitleColumnsError(e)) {
        debugPrint('Error syncing auto title setting: $e');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error syncing auto title setting: $e');
      }
    }
  }

  /// Get the current system prompt (custom or default)
  static Future<String> getSystemPrompt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customSystemPrompt ??= prefs.getString(_systemPromptKey);

      // Keep local settings synced from Supabase in the background.
      unawaited(syncSettingsFromSupabase());

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
    final prefs = await SharedPreferences.getInstance();
    final useDefault =
        prompt.trim().isEmpty || prompt.trim() == defaultSystemPrompt.trim();

    if (useDefault) {
      await prefs.remove(_systemPromptKey);
      _customSystemPrompt = null;
    } else {
      await prefs.setString(_systemPromptKey, prompt);
      _customSystemPrompt = prompt;
    }

    try {
      final session = SupabaseService.auth.currentSession;
      if (session != null) {
        String? encryptedPrompt;
        if (!useDefault) {
          encryptedPrompt = await EncryptionService.encrypt(prompt);
        }
        await SupabaseService.client.from('customization_preferences').upsert({
          'user_id': session.user.id,
          _remotePromptColumn: encryptedPrompt,
        }, onConflict: 'user_id');
      }

      if (kDebugMode) {
        if (useDefault) {
          debugPrint('System prompt reset to default');
        } else {
          debugPrint('Custom system prompt saved');
        }
      }
    } on PostgrestException catch (e) {
      if (kDebugMode && !_isMissingTitleColumnsError(e)) {
        debugPrint('Error syncing system prompt: $e');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error syncing system prompt: $e');
      }
    }
  }

  /// Reset system prompt to default
  static Future<void> resetSystemPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_systemPromptKey);
    _customSystemPrompt = null;

    try {
      final session = SupabaseService.auth.currentSession;
      if (session != null) {
        await SupabaseService.client.from('customization_preferences').upsert({
          'user_id': session.user.id,
          _remotePromptColumn: null,
        }, onConflict: 'user_id');
      }

      if (kDebugMode) {
        debugPrint('System prompt reset to default');
      }
    } on PostgrestException catch (e) {
      if (kDebugMode && !_isMissingTitleColumnsError(e)) {
        debugPrint('Error resetting system prompt sync: $e');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error resetting system prompt sync: $e');
      }
    }
  }

  /// Refresh title settings from Supabase and cache them locally.
  static Future<void> syncSettingsFromSupabase({bool forceRefresh = false}) {
    if (!forceRefresh &&
        _lastRemoteSyncAt != null &&
        DateTime.now().difference(_lastRemoteSyncAt!) < _remoteSyncTtl) {
      return Future<void>.value();
    }

    if (_remoteSyncInFlight != null) {
      return _remoteSyncInFlight!;
    }

    Future<void> run() async {
      try {
        final user = SupabaseService.auth.currentUser;
        if (user == null) return;

        final row = await SupabaseService.client
            .from('customization_preferences')
            .select('$_remoteEnabledColumn,$_remotePromptColumn')
            .eq('user_id', user.id)
            .maybeSingle();

        if (row == null) {
          _lastRemoteSyncAt = DateTime.now();
          return;
        }

        final prefs = await SharedPreferences.getInstance();

        final remoteEnabled = row[_remoteEnabledColumn] as bool?;
        if (remoteEnabled != null) {
          _autoGenerateTitlesEnabled = remoteEnabled;
          await prefs.setBool(_settingsKey, remoteEnabled);
        }

        if (row.containsKey(_remotePromptColumn)) {
          final remotePromptRaw = row[_remotePromptColumn];
          if (remotePromptRaw == null ||
              remotePromptRaw.toString().trim().isEmpty) {
            _customSystemPrompt = null;
            await prefs.remove(_systemPromptKey);
          } else {
            final remotePrompt = await _decryptRemotePrompt(
              remotePromptRaw.toString(),
            );
            if (remotePrompt == _decryptFailedSentinel) {
              // Keep local prompt when remote decryption fails.
            } else if (remotePrompt != null && remotePrompt.isNotEmpty) {
              _customSystemPrompt = remotePrompt;
              await prefs.setString(_systemPromptKey, remotePrompt);
            }
          }
        }

        _lastRemoteSyncAt = DateTime.now();
      } on PostgrestException catch (e) {
        if (kDebugMode && !_isMissingTitleColumnsError(e)) {
          debugPrint('Failed to sync title settings from Supabase: $e');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to sync title settings from Supabase: $e');
        }
      }
    }

    _remoteSyncInFlight = run();
    return _remoteSyncInFlight!.whenComplete(() {
      _remoteSyncInFlight = null;
    });
  }

  static bool _isMissingTitleColumnsError(PostgrestException error) {
    final code = error.code?.toLowerCase() ?? '';
    final message = error.message.toLowerCase();
    if (code != '42703' && !message.contains('does not exist')) {
      return false;
    }
    return message.contains(_remoteEnabledColumn) ||
        message.contains(_remotePromptColumn);
  }

  static bool _looksLikeEncryptedPayload(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      return decoded['v'] != null &&
          decoded['nonce'] != null &&
          decoded['ciphertext'] != null &&
          decoded['mac'] != null;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _decryptRemotePrompt(String raw) async {
    if (!_looksLikeEncryptedPayload(raw)) {
      return raw;
    }

    try {
      return await EncryptionService.decrypt(raw);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to decrypt remote title prompt: $e');
      }
      return _decryptFailedSentinel;
    }
  }

  /// Check if using custom system prompt
  static Future<bool> hasCustomSystemPrompt() async {
    final prompt = await getSystemPrompt();
    return prompt != defaultSystemPrompt;
  }

  /// Generate a title for a chat based on the first user message.
  /// Returns null if generation fails or feature is disabled.
  ///
  /// [chatId] is used purely to wait until the main chat response has
  /// finished streaming. The actual title chat call goes through the
  /// multiplex with a null chat id — that way it can never claim the
  /// per-chatId in-flight slot guarded by
  /// [MultiplexSession.chatForChat] and cannot accidentally cancel
  /// (or be cancelled by) the main response. Even if the main
  /// response somehow restarts mid-title-gen, the two would be
  /// distinct multiplex requests with distinct req_ids and distinct
  /// in-memory buffers — never interleaving into the same UI
  /// message.
  static Future<String?> generateTitle(
    String firstMessage, {
    String? chatId,
  }) async {
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
        debugPrint(
          '📝 [TitleGen] Generating title for message (${firstMessage.length} chars)',
        );
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
        reasoningEffort: 'none', // No reasoning for title generation
        // Explicitly do NOT pin a chat id — title generation must
        // never share the per-chatId in-flight slot with the main
        // response. The serialization happens in
        // [generateAndApplyTitle] via
        // [MultiplexSession.waitForChatStreamIdle].
        chatId: null,
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
      title = title
          .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
          .trim();
      title = title
          .replaceAll(RegExp(r'<thinking>.*?</thinking>', dotAll: true), '')
          .trim();

      // Remove quotes if present
      if ((title.startsWith('"') && title.endsWith('"')) ||
          (title.startsWith("'") && title.endsWith("'"))) {
        title = title.substring(1, title.length - 1);
      }
      // Remove any trailing punctuation that looks weird
      title = title.replaceAll(RegExp(r'[.!?]+$'), '').trim();
      title = _normalizeGeneratedTitle(title);
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
  static Future<void> generateAndApplyTitle(
    String chatId,
    String firstMessage,
  ) async {
    // Privacy: Only log non-sensitive metadata
    if (kDebugMode) {
      debugPrint(
        '📝 [TitleGen] generateAndApplyTitle called (${firstMessage.length} chars)',
      );
    }

    if (!_inFlightTitleChats.add(chatId)) {
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Title generation already in progress');
      }
      return;
    }

    try {
      final chatReady = await _waitUntilChatAvailable(chatId);
      if (!chatReady) {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Chat not ready yet, skipping');
        }
        return;
      }

      final existingChat = ChatStorageService.getChatById(chatId);
      if (_hasCustomName(existingChat?.customName)) {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Chat already has a custom title, skipping');
        }
        return;
      }

      // Wait for the main response stream for this chat id to finish
      // BEFORE issuing the title chat call. Without this the title
      // chat would have raced the main response on the same /v2/ws
      // connection — both with distinct req_ids and distinct
      // multiplex controllers, but the v1.0.96 export evidence
      // showed character-by-character interleaving into the
      // assistant message buffer. Serializing closes that race for
      // good and keeps the per-chatId in-flight slot single-tenant.
      final idle = await MultiplexSession.waitForChatStreamIdle(chatId);
      if (!idle && kDebugMode) {
        debugPrint(
          '📝 [TitleGen] timed out waiting for main response to '
          'finish — proceeding anyway with a separate (un-tracked) '
          'title request',
        );
      }

      // Re-check the chat name after waiting — the user might have
      // renamed it manually during the main response, in which case
      // we should not stomp on their title.
      final readyChat = ChatStorageService.getChatById(chatId);
      if (_hasCustomName(readyChat?.customName)) {
        if (kDebugMode) {
          debugPrint(
            '📝 [TitleGen] Chat got a custom title while waiting, '
            'skipping',
          );
        }
        return;
      }

      final title = await generateTitle(firstMessage, chatId: chatId);
      if (title == null || title.isEmpty) {
        if (kDebugMode) {
          debugPrint('📝 [TitleGen] Title was null or empty, not applying');
        }
        return;
      }

      final latestChat = ChatStorageService.getChatById(chatId);
      if (_hasCustomName(latestChat?.customName)) {
        if (kDebugMode) {
          debugPrint(
            '📝 [TitleGen] Title changed meanwhile, keeping existing one',
          );
        }
        return;
      }

      final applied = await _applyTitleWithRetry(chatId, title);
      if (kDebugMode && applied) {
        debugPrint('📝 [TitleGen] Successfully applied generated title');
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Error applying title: $e');
      }
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Stack trace: $stackTrace');
      }
    } finally {
      _inFlightTitleChats.remove(chatId);
    }
  }

  static bool _hasCustomName(String? name) {
    return name != null && name.trim().isNotEmpty;
  }

  static String _stripWrappingMarkdown(String value) {
    var current = value.trim();
    final wrappers = <RegExp>[
      RegExp(r'^\*\*(.+)\*\*$', dotAll: true),
      RegExp(r'^__(.+)__$', dotAll: true),
      RegExp(r'^\*(.+)\*$', dotAll: true),
      RegExp(r'^_(.+)_$', dotAll: true),
      RegExp(r'^`(.+)`$', dotAll: true),
    ];

    var changed = true;
    while (changed) {
      changed = false;
      for (final pattern in wrappers) {
        final match = pattern.firstMatch(current);
        if (match == null) continue;
        final inner = match.group(1)?.trim() ?? '';
        if (inner.isEmpty) continue;
        current = inner;
        changed = true;
      }
    }
    return current;
  }

  static String _normalizeGeneratedTitle(String raw) {
    var title = raw.trim();
    title = title.replaceAll(RegExp(r'<\/?[^>]+>'), ' ').trim();
    title = title.replaceFirst(
      RegExp(r'^\s*title\s*:\s*', caseSensitive: false),
      '',
    );
    title = title.replaceFirst(RegExp(r'^\s*#+\s*'), '');
    title = _stripWrappingMarkdown(title);
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title;
  }

  static Future<bool> _waitUntilChatAvailable(String chatId) async {
    for (int attempt = 0; attempt < _maxChatLookupAttempts; attempt++) {
      final chat = ChatStorageService.getChatById(chatId);
      if (chat != null) {
        return true;
      }

      try {
        await ChatStorageService.loadFullChat(chatId);
      } catch (_) {
        // Chat may not exist yet; retry below.
      }

      if (ChatStorageService.getChatById(chatId) != null) {
        return true;
      }

      await Future<void>.delayed(_chatLookupRetryDelay);
    }

    return false;
  }

  static Future<bool> _applyTitleWithRetry(String chatId, String title) async {
    for (int attempt = 0; attempt < _maxRenameAttempts; attempt++) {
      final chat = ChatStorageService.getChatById(chatId);
      if (_hasCustomName(chat?.customName)) {
        return true;
      }

      try {
        await ChatStorageService.renameChat(chatId, title);
        return true;
      } on StateError {
        if (attempt == _maxRenameAttempts - 1) {
          return false;
        }
      }

      await Future<void>.delayed(_chatLookupRetryDelay);
    }

    return false;
  }
}
