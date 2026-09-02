// lib/services/title_generation_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';

/// Service for automatically generating chat titles using AI.
/// Uses openai/gpt-oss-20b on Groq for title generation over WebSocket.
class TitleGenerationService {
  // Model for title generation. The provider is resolved at call time from
  // the cached model list (see [_resolveTitleProvider]) — hardcoding an empty
  // provider made the server reject every title request with a generic
  // "An error occurred" because `provider_slug` is always sent on the wire.
  //
  // Was `qwen/qwen3.5-9b`, which is not in the server's curated catalog: the
  // server rejected every title request with 400 "not available" and titles
  // silently never generated.
  //
  // Picked by measuring every ZDR-approved model/provider pair in the small
  // model class — 12 runs each (6 conversations DE/EN/FR incl. one very long
  // message), with exactly the parameters below:
  //
  //   gpt-oss-20b    @ groq            136ms  12/12   $0.018 / 1000 titles
  //   gpt-oss-120b   @ groq            188ms  12/12   $0.033
  //   qwen3.6-35b-a3b@ coreweave/fp8   279ms  12/12   $0.025
  //   gemma-4-31b-it @ cerebras/fp16   301ms  12/12   $0.072
  //   qwen3.5-9b     @ together        333ms  10/10   $0.013
  //   qwen3-32b      @ groq            — 404 on every call (dead upstream)
  //
  // Cost is noise at any of these: 10k titles on the fastest is ~$0.18, so
  // the choice is purely about latency and reliability.
  static const String _titleModel = 'openai/gpt-oss-20b';

  // Preferred provider for [_titleModel] — the fastest measured. Not a hard
  // requirement: [_resolveTitleProvider] falls back to whatever the catalog
  // offers, and the server re-pins to an equal-or-cheaper provider on a
  // 429/404. Groq is the dearest provider for this model, so every fallback
  // is cheaper — a Groq outage means slower titles, never no titles.
  static const String _preferredTitleProvider = 'groq';

  // Cached provider slug for [_titleModel], resolved once per session.
  static String? _resolvedTitleProvider;

  // Settings keys, namespaced by user id.
  //
  // The prompt is cached here as **plaintext** (it is only encrypted on the way
  // to Supabase), so unlike `cached_system_prompt` there was never even an
  // accidental encryption-key mismatch standing between one user's prompt and
  // the next user's read. Namespacing is the only thing separating them.
  static String _settingsKey(String userId) => 'auto_generate_titles_$userId';
  static String _systemPromptKey(String userId) =>
      'title_gen_system_prompt_$userId';

  /// Pre-namespacing keys. Dropped rather than migrated — their values cannot
  /// be attributed to a user, and both re-populate from Supabase on the next
  /// [syncSettingsFromSupabase].
  static const String _legacySettingsKey = 'auto_generate_titles';
  static const String _legacySystemPromptKey = 'title_gen_system_prompt';

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

  /// The user the cached settings above belong to.
  ///
  /// Keyed by user id and re-checked on every access rather than cleared from a
  /// sign-out hook: the repo's one such hook
  /// (`AppInitializationService.resetServices()`) was dead code, and
  /// `chat_ui_mobile` signs out via `SupabaseService.signOut()` without going
  /// through `AuthService` at all. Mirrors `_resetIdentityCacheForUser` in
  /// `notes_tools.dart`.
  static String? _cacheOwnerUserId;

  static void _syncCacheToCurrentUser(String? userId) {
    if (_cacheOwnerUserId == userId) return;
    _cacheOwnerUserId = userId;
    _autoGenerateTitlesEnabled = null;
    _customSystemPrompt = null;
    _lastRemoteSyncAt = null;
    _remoteSyncInFlight = null;
  }

  /// The active user id, or null when signed out or before Supabase is up.
  static String? _currentUserId() {
    // Gated on kDebugMode so the override is tree-shaken out of release
    // builds: it is a mutable static that decides ownership, and
    // @visibleForTesting is a lint, not a runtime guard. Tests run in debug.
    if (kDebugMode) {
      final override = debugCurrentUserIdOverride;
      if (override != null) return override();
    }
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// True while [userId] is *still the live signed-in user*.
  ///
  /// Consults live auth, not just [_cacheOwnerUserId]: the latter only advances
  /// when a public entry point runs [_syncCacheToCurrentUser], so between a
  /// sign-out and the next entry point it still names the previous user.
  /// Gating the remote upserts below on this is what stops one user's setting
  /// from being written into the next user's Supabase row.
  static bool _stillOwns(String? userId) =>
      userId != null &&
      _cacheOwnerUserId == userId &&
      _currentUserId() == userId;

  static Future<void> _dropLegacyKeys(SharedPreferences prefs) async {
    if (prefs.containsKey(_legacySettingsKey)) {
      await prefs.remove(_legacySettingsKey);
    }
    if (prefs.containsKey(_legacySystemPromptKey)) {
      await prefs.remove(_legacySystemPromptKey);
    }
  }

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
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _dropLegacyKeys(prefs);
      if (!_stillOwns(userId)) return false;
      _autoGenerateTitlesEnabled ??=
          prefs.getBool(_settingsKey(userId)) ?? false;

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
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _dropLegacyKeys(prefs);
    await prefs.setBool(_settingsKey(userId), enabled);
    if (_stillOwns(userId)) _autoGenerateTitlesEnabled = enabled;

    try {
      // Gate on the user who started this call, and address the row by their
      // id. Reading the live session's user id here instead would upsert this
      // user's setting into whoever is signed in by the time the local write
      // above finished — a write into another account, not just a stale read.
      if (!_stillOwns(userId)) return;
      final session = SupabaseService.auth.currentSession;
      if (session != null) {
        await SupabaseService.client.from('customization_preferences').upsert({
          'user_id': userId,
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
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return defaultSystemPrompt;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _dropLegacyKeys(prefs);
      if (!_stillOwns(userId)) return defaultSystemPrompt;
      _customSystemPrompt ??= prefs.getString(_systemPromptKey(userId));

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
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _dropLegacyKeys(prefs);
    final useDefault =
        prompt.trim().isEmpty || prompt.trim() == defaultSystemPrompt.trim();

    if (useDefault) {
      await prefs.remove(_systemPromptKey(userId));
      if (_stillOwns(userId)) _customSystemPrompt = null;
    } else {
      await prefs.setString(_systemPromptKey(userId), prompt);
      if (_stillOwns(userId)) _customSystemPrompt = prompt;
    }

    try {
      // See setEnabled: gate on the originating user, address their row.
      if (!_stillOwns(userId)) return;
      final session = SupabaseService.auth.currentSession;
      if (session != null) {
        String? encryptedPrompt;
        if (!useDefault) {
          encryptedPrompt = await EncryptionService.encrypt(prompt);
        }
        // Re-check: `encrypt` uses the live user's key, so a switch during it
        // would seal this prompt with the next user's key.
        if (!_stillOwns(userId)) return;
        await SupabaseService.client.from('customization_preferences').upsert({
          'user_id': userId,
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
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _dropLegacyKeys(prefs);
    await prefs.remove(_systemPromptKey(userId));
    if (_stillOwns(userId)) _customSystemPrompt = null;

    try {
      // See setEnabled: gate on the originating user, address their row.
      if (!_stillOwns(userId)) return;
      final session = SupabaseService.auth.currentSession;
      if (session != null) {
        await SupabaseService.client.from('customization_preferences').upsert({
          'user_id': userId,
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
    _syncCacheToCurrentUser(_currentUserId());
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
        // Safe lookup: this runs unawaited from isEnabled()/getSystemPrompt().
        final userId = _currentUserId();
        if (userId == null) return;

        final row = await SupabaseService.client
            .from('customization_preferences')
            .select('$_remoteEnabledColumn,$_remotePromptColumn')
            .eq('user_id', userId)
            .maybeSingle();

        if (row == null) {
          if (_stillOwns(userId)) _lastRemoteSyncAt = DateTime.now();
          return;
        }

        final prefs = await SharedPreferences.getInstance();
        await _dropLegacyKeys(prefs);

        // The user may have signed out (or swapped) during the request; a late
        // response must not land in the next user's cache or prefs namespace.
        if (!_stillOwns(userId)) return;

        final remoteEnabled = row[_remoteEnabledColumn] as bool?;
        if (remoteEnabled != null) {
          _autoGenerateTitlesEnabled = remoteEnabled;
          await prefs.setBool(_settingsKey(userId), remoteEnabled);
        }

        if (row.containsKey(_remotePromptColumn)) {
          final remotePromptRaw = row[_remotePromptColumn];
          if (remotePromptRaw == null ||
              remotePromptRaw.toString().trim().isEmpty) {
            _customSystemPrompt = null;
            await prefs.remove(_systemPromptKey(userId));
          } else {
            final remotePrompt = await _decryptRemotePrompt(
              remotePromptRaw.toString(),
            );
            if (!_stillOwns(userId)) return;
            if (remotePrompt == _decryptFailedSentinel) {
              // Keep local prompt when remote decryption fails.
            } else if (remotePrompt != null && remotePrompt.isNotEmpty) {
              _customSystemPrompt = remotePrompt;
              await prefs.setString(_systemPromptKey(userId), remotePrompt);
            }
          }
        }

        // Guarded like every other post-await write: A's late sync must not
        // refresh the throttle timestamp for B, which would suppress B's own
        // first sync.
        if (_stillOwns(userId)) _lastRemoteSyncAt = DateTime.now();
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

    final inFlight = run();
    _remoteSyncInFlight = inFlight;
    return inFlight.whenComplete(() {
      // Only clear the slot if it still holds THIS future: a user switch
      // nulls it and B may already have started its own, which A's
      // completion would otherwise wipe — duplicating or dropping a sync.
      if (identical(_remoteSyncInFlight, inFlight)) _remoteSyncInFlight = null;
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

  /// Resolve the provider slug to use for the title model.
  ///
  /// The backend always sends `provider_slug` on the wire and rejects an
  /// empty value, so we look up [_titleModel] in the cached model list and
  /// use its first available provider. Result is cached for the session.
  /// Returns an empty string only when the model isn't in the cache yet
  /// (best-effort — the request will then fail the same way it did before
  /// this fix, which is no worse than the old hardcoded behaviour).
  static Future<String> _resolveTitleProvider() async {
    if (_resolvedTitleProvider != null) {
      return _resolvedTitleProvider!;
    }
    try {
      final models = await ModelCacheService.loadAvailableModels();
      for (final model in models) {
        if (model['id'] != _titleModel) continue;
        final providers = model['providers'];
        if (providers is List) {
          final slugs = <String>[
            for (final provider in providers)
              if (provider is Map<String, dynamic>)
                if (provider['slug'] case final String slug when slug.isNotEmpty)
                  slug,
          ];
          // Prefer the fastest measured provider; otherwise take whatever the
          // catalog lists first. The catalog is ZDR-filtered server-side, so
          // any entry here is a legitimate choice.
          final chosen = slugs.contains(_preferredTitleProvider)
              ? _preferredTitleProvider
              : (slugs.isNotEmpty ? slugs.first : null);
          if (chosen != null) {
            _resolvedTitleProvider = chosen;
            return chosen;
          }
        }
        break;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('📝 [TitleGen] Failed to resolve title provider: $e');
      }
    }
    return '';
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
      final titleProvider = await _resolveTitleProvider();

      await for (final event in WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: userMessage,
        modelId: _titleModel,
        providerSlug: titleProvider,
        systemPrompt: systemPrompt,
        // NOTE: the backend currently parses `max_tokens` and `temperature`
        // and then forwards neither upstream (routers/multiplex.py), so both
        // of these are advisory today. They are still sent, and set to what
        // this request actually wants, so the moment the backend honours them
        // nothing here has to change.
        //
        // 200 rather than 32 because reasoning is *mandatory* on the gpt-oss
        // endpoints — OpenRouter 400s on `reasoning: {enabled: false}` — and
        // reasoning tokens count against the budget. Measured at 32: 1/12
        // titles came back empty, clustered on long first messages, i.e. the
        // chats most worth titling. At 200: 12/12. Uncapped (what the wire
        // carries today): 16/16, longest response 90 tokens, so the model
        // stops on its own and there is no runaway to cap.
        maxTokens: 200,
        temperature: 0.3, // Lower temperature for more focused output
        // 'low', not 'none': this endpoint cannot disable reasoning at all
        // (measured: 14/14 rejected with 400). 'low' is also the fastest —
        // 139ms, against 185ms for 'minimal' and 242ms for the model default.
        // The reasoning deltas arrive as ReasoningEvent and are dropped in the
        // switch below, so they never reach the title; they cost tokens, not
        // correctness, and 38 tokens is $0.018 per 1000 titles.
        reasoningEffort: 'low',
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
          case ToolCallsEvent():
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

  // ─── Test seams ──────────────────────────────────────────────────────────
  // The real entry points read the user id from `SupabaseService.auth`, which
  // needs a live backend; these drive the user-change path directly.

  /// Replaces the live auth lookup used by [_currentUserId] and [_stillOwns],
  /// so a test can flip the signed-in user while an async call is suspended.
  @visibleForTesting
  static String? Function()? debugCurrentUserIdOverride;

  @visibleForTesting
  static bool debugStillOwns(String? userId) => _stillOwns(userId);

  @visibleForTesting
  static void debugPrimeCachesForUser(
    String? userId, {
    bool? autoGenerateTitles,
    String? customSystemPrompt,
  }) {
    _cacheOwnerUserId = userId;
    _autoGenerateTitlesEnabled = autoGenerateTitles;
    _customSystemPrompt = customSystemPrompt;
    _lastRemoteSyncAt = userId == null ? null : DateTime.now();
  }

  @visibleForTesting
  static void debugSyncCacheToUser(String? userId) =>
      _syncCacheToCurrentUser(userId);

  @visibleForTesting
  static String? get debugCustomSystemPrompt => _customSystemPrompt;

  @visibleForTesting
  static bool? get debugAutoGenerateTitlesEnabled => _autoGenerateTitlesEnabled;

  @visibleForTesting
  static String settingsKeyForUser(String userId) => _settingsKey(userId);

  @visibleForTesting
  static String systemPromptKeyForUser(String userId) =>
      _systemPromptKey(userId);

  @visibleForTesting
  static const String legacySettingsKey = _legacySettingsKey;

  @visibleForTesting
  static const String legacySystemPromptKey = _legacySystemPromptKey;

  @visibleForTesting
  static Future<void> debugDropLegacyKeys(SharedPreferences prefs) =>
      _dropLegacyKeys(prefs);
}
