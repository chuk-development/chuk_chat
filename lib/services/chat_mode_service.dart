// lib/services/chat_mode_service.dart
//
// The two modes a reader picks between — the way ChatGPT and Grok present
// it. The concrete model sits one level deeper, in the model picker.
//
// Both modes run the same model. That is deliberate: a mode switch that
// also swaps the model can land on a provider that is busy or down, and
// "fast" turning into an error is worse than "fast" being a little slower.
// Thinking simply lets the model reason before it answers.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/user_preferences_service.dart';

enum ChatMode {
  /// Thinks briefly, then answers. Fast means fast — not thoughtless.
  fast,

  /// Thinks hard before answering.
  thinking,
}

class ChatModeService {
  ChatModeService._();

  static const String _prefsKey = 'chat_mode_v1';

  /// The model both modes run on, and the provider it is pinned to.
  ///
  /// Pinned rather than routed: the picker's job is availability, and one
  /// known-good provider beats a cheaper one that may be saturated.
  static const String defaultModelId = 'deepseek/deepseek-v4-flash';
  static const String defaultProviderSlug = 'fireworks';

  /// What a fresh install starts with. Fast, because most questions are
  /// answered well with a short think, and waiting for a long one that
  /// adds nothing is the worse first impression.
  static const ChatMode fallbackMode = ChatMode.fast;

  /// Whether [mode] is the deep one. Both modes reason — this only says
  /// which one takes its time.
  static bool isDeepThinking(ChatMode mode) => mode == ChatMode.thinking;

  /// The value the chat API expects for `reasoning_effort`.
  ///
  /// Fast switches reasoning off; thinking asks for the deep pass.
  ///
  /// Reasoning-off must still use tools — a model that skips the search
  /// and then says it searched is a bug in how the tools are offered, not
  /// a reason to force a reasoning pass on every question.
  static String reasoningEffort(ChatMode mode) =>
      mode == ChatMode.fast ? 'none' : 'high';

  /// Read the stored mode, falling back to [fallbackMode].
  static Future<ChatMode> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return parse(prefs.getString(_prefsKey));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatMode] Could not read the stored mode: $e');
      }
      return fallbackMode;
    }
  }

  /// Persist [mode]. Failures are swallowed: losing the preference is a
  /// small annoyance, an exception mid-tap is not.
  static Future<void> save(ChatMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, mode.name);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatMode] Could not store the mode: $e');
      }
    }
  }

  /// Make sure the reader has a model selected, and return it.
  ///
  /// Order: an existing choice wins, then whatever the account carries,
  /// and only if both are empty does this fall back to [defaultModelId]
  /// pinned to [defaultProviderSlug]. Pinning matters more than price
  /// here — a first message that fails because the routed provider is
  /// saturated costs a user, and the picker can still change both.
  static Future<String> ensureModelSelected() async {
    final existing = await UserPreferencesService.loadSelectedModel();
    if (existing != null && existing.isNotEmpty) return existing;

    final fromAccount = await UserPreferencesService.forceLoadSelectedModel();
    if (fromAccount != null && fromAccount.isNotEmpty) return fromAccount;

    await UserPreferencesService.saveSelectedModel(defaultModelId);
    await UserPreferencesService.saveSelectedProvider(
      defaultModelId,
      defaultProviderSlug,
    );
    if (kDebugMode) {
      debugPrint(
        '🎯 [ChatMode] No model chosen yet — defaulting to $defaultModelId '
        'on $defaultProviderSlug',
      );
    }
    return defaultModelId;
  }

  /// Map a stored string back to a mode, tolerating anything unexpected.
  static ChatMode parse(String? raw) {
    for (final mode in ChatMode.values) {
      if (mode.name == raw) return mode;
    }
    return fallbackMode;
  }
}
