// lib/services/chat_mode_service.dart
//
// The two modes a reader picks between — the way ChatGPT and Grok present
// it. The concrete model sits one level deeper, in the model picker.
//
// Each mode now carries its OWN config: a model, the provider it is pinned
// to, and a reasoning level. Switching mode swaps all three. Fast leans on a
// quick model with reasoning off; Thinking leans on a stronger model that
// reasons before it answers. The reader can retune either mode by hand — the
// config is per-mode memory, so a change to one mode never leaks into the
// other.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ChatMode {
  /// Answers right away. Fast means fast — a light model, reasoning off.
  fast,

  /// Thinks hard before answering — a stronger model, reasoning on.
  thinking,
}

/// One mode's independent settings: which model, on which provider, at which
/// reasoning level. Persisted per mode, so Fast and Thinking never share.
@immutable
class ModeConfig {
  const ModeConfig({
    required this.modelId,
    required this.providerSlug,
    required this.reasoningEffort,
  });

  /// The model id sent to the chat API for this mode.
  final String modelId;

  /// The provider slug the model is pinned to for this mode.
  final String providerSlug;

  /// The reasoning level sent as `reasoning_effort`. One of
  /// [ChatModeService.reasoningLevelsAll]; [ChatModeService.reasoningOff]
  /// means no reasoning pass.
  final String reasoningEffort;

  /// Whether this mode reasons at all. Off is a level, not a missing value.
  bool get reasoningOn => reasoningEffort != ChatModeService.reasoningOff;

  ModeConfig copyWith({
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
  }) {
    return ModeConfig(
      modelId: modelId ?? this.modelId,
      providerSlug: providerSlug ?? this.providerSlug,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'model': modelId,
    'provider': providerSlug,
    'reasoning': reasoningEffort,
  };

  /// Parse stored JSON, taking any missing or non-string field from
  /// [fallback] so a partial or corrupt record can never leave a hole.
  factory ModeConfig.fromJson(
    Map<String, dynamic> json, {
    required ModeConfig fallback,
  }) {
    String field(String key, String orElse) {
      final value = json[key];
      return (value is String && value.isNotEmpty) ? value : orElse;
    }

    return ModeConfig(
      modelId: field('model', fallback.modelId),
      providerSlug: field('provider', fallback.providerSlug),
      reasoningEffort: field('reasoning', fallback.reasoningEffort),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ModeConfig &&
      other.modelId == modelId &&
      other.providerSlug == providerSlug &&
      other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(modelId, providerSlug, reasoningEffort);

  @override
  String toString() =>
      'ModeConfig(model: $modelId, provider: $providerSlug, '
      'reasoning: $reasoningEffort)';
}

class ChatModeService {
  ChatModeService._();

  static const String _prefsKey = 'chat_mode_v1';

  /// The general-purpose fallback model, and the provider it is pinned to.
  /// Matches Fast's config so the broad "make sure a model is selected"
  /// path and a fresh Fast mode land on the same place.
  static const String defaultModelId = 'deepseek/deepseek-v4-flash-0731';
  static const String defaultProviderSlug = 'fireworks/serverless';

  /// The reasoning level that means "no reasoning pass".
  static const String reasoningOff = 'none';

  /// Every reasoning level the chat API accepts, weakest to strongest. The
  /// order doubles as the rank used when clamping a level to what a provider
  /// allows.
  static const List<String> reasoningLevelsAll = <String>[
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
  ];

  /// What Fireworks providers accept — no `minimal`, no `xhigh`.
  static const List<String> reasoningLevelsFireworks = <String>[
    'none',
    'low',
    'medium',
    'high',
  ];

  /// What each mode starts on, and what a failed load falls back to.
  ///
  /// Both modes run the direct Fireworks provider (`fireworks/serverless`).
  /// Fast pairs a quick model with reasoning off; Thinking pairs a stronger
  /// model with a medium reasoning pass. Both are changeable in settings.
  static const Map<ChatMode, ModeConfig> _defaults = <ChatMode, ModeConfig>{
    // Fast's default is the general fallback — derived from the constants
    // so the "these must match" invariant is enforced, not just documented.
    ChatMode.fast: ModeConfig(
      modelId: defaultModelId,
      providerSlug: defaultProviderSlug,
      reasoningEffort: reasoningOff,
    ),
    ChatMode.thinking: ModeConfig(
      modelId: 'deepseek/deepseek-v4-pro-0813',
      providerSlug: defaultProviderSlug,
      reasoningEffort: 'medium',
    ),
  };

  /// What a fresh install starts with. Fast, because most questions are
  /// answered well without a reasoning pass, and waiting for a long one that
  /// adds nothing is the worse first impression.
  static const ChatMode fallbackMode = ChatMode.fast;

  /// Whether [mode] is the deep one.
  static bool isDeepThinking(ChatMode mode) => mode == ChatMode.thinking;

  /// The baked-in config for [mode] — the starting point and the safety net.
  static ModeConfig defaultConfig(ChatMode mode) => _defaults[mode]!;

  // ─── Reasoning levels ─────────────────────────────────────────────────

  /// Whether [slug] is a Fireworks provider (direct or routed).
  static bool isFireworksProvider(String slug) =>
      slug == 'fireworks' || slug.startsWith('fireworks/');

  /// The reasoning levels valid for a model on a given provider, `none`
  /// (off) always first. A model that cannot reason offers only off; a
  /// Fireworks provider offers none/low/medium/high; everything else offers
  /// the full ladder.
  static List<String> reasoningLevelsFor({
    required String providerSlug,
    bool supportsReasoning = true,
  }) {
    if (!supportsReasoning) return const <String>[reasoningOff];
    if (isFireworksProvider(providerSlug)) return reasoningLevelsFireworks;
    return reasoningLevelsAll;
  }

  /// Clamp [level] to what the model+provider allows. An exact match wins;
  /// otherwise the strongest allowed level no stronger than [level] is used,
  /// and only if none qualifies does it drop to the weakest allowed (off).
  /// This keeps a stored `xhigh` from vanishing to off when a model moves to
  /// a Fireworks provider — it lands on `high` instead.
  static String sanitizeReasoning(
    String level, {
    required String providerSlug,
    bool supportsReasoning = true,
  }) {
    final allowed = reasoningLevelsFor(
      providerSlug: providerSlug,
      supportsReasoning: supportsReasoning,
    );
    if (allowed.contains(level)) return level;

    final wantRank = reasoningLevelsAll.indexOf(level);
    if (wantRank < 0) return allowed.first; // unknown token → off

    String best = allowed.first;
    int bestRank = -1;
    for (final candidate in allowed) {
      final rank = reasoningLevelsAll.indexOf(candidate);
      if (rank <= wantRank && rank > bestRank) {
        best = candidate;
        bestRank = rank;
      }
    }
    return best;
  }

  /// A short human label for a reasoning level, for menus.
  static String reasoningLabel(String level) {
    switch (level) {
      case reasoningOff:
        return 'Off';
      case 'minimal':
        return 'Minimal';
      case 'low':
        return 'Low';
      case 'medium':
        return 'Medium';
      case 'high':
        return 'High';
      case 'xhigh':
        return 'Max';
      default:
        return level;
    }
  }

  // ─── Per-mode config store ────────────────────────────────────────────

  static const String _configPrefsKey = 'chat_mode_config_v1';

  static String _configKey(ChatMode mode) => '${_configPrefsKey}_${mode.name}';

  /// Read [mode]'s stored config, falling back to its baked default on a
  /// missing, empty, or corrupt record. The reasoning level is clamped to
  /// what the stored provider allows, so an invalid pairing can never be
  /// sent.
  static Future<ModeConfig> loadConfig(ChatMode mode) async {
    final fallback = defaultConfig(mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_configKey(mode));
      if (raw == null || raw.isEmpty) return fallback;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return fallback;

      final config = ModeConfig.fromJson(
        Map<String, dynamic>.from(decoded),
        fallback: fallback,
      );
      return config.copyWith(
        reasoningEffort: sanitizeReasoning(
          config.reasoningEffort,
          providerSlug: config.providerSlug,
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatMode] Could not read the config for ${mode.name}: $e');
      }
      return fallback;
    }
  }

  /// Persist [config] for [mode]. Failures are swallowed: losing the
  /// preference is a small annoyance, an exception mid-tap is not.
  static Future<void> saveConfig(ChatMode mode, ModeConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configKey(mode), jsonEncode(config.toJson()));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatMode] Could not store the config for ${mode.name}: $e');
      }
    }
  }

  /// Point [mode] at a new model+provider, re-clamping its reasoning level to
  /// the new provider's allowed set. Returns the stored result.
  static Future<ModeConfig> setModelForMode(
    ChatMode mode, {
    required String modelId,
    required String providerSlug,
  }) async {
    final current = await loadConfig(mode);
    // An empty slug means "not resolved yet", not "no provider". Storing it
    // would make the next load fall back to the default provider, pairing
    // the new model with a provider it was never pinned to — so keep the
    // mode's current provider when the caller has none.
    final effectiveProvider =
        providerSlug.isNotEmpty ? providerSlug : current.providerSlug;
    final updated = current.copyWith(
      modelId: modelId,
      providerSlug: effectiveProvider,
      reasoningEffort: sanitizeReasoning(
        current.reasoningEffort,
        providerSlug: effectiveProvider,
      ),
    );
    await saveConfig(mode, updated);
    return updated;
  }

  /// Set [mode]'s reasoning level, clamped to its current provider. Returns
  /// the stored result.
  static Future<ModeConfig> setReasoningForMode(
    ChatMode mode,
    String level,
  ) async {
    final current = await loadConfig(mode);
    final updated = current.copyWith(
      reasoningEffort: sanitizeReasoning(
        level,
        providerSlug: current.providerSlug,
      ),
    );
    await saveConfig(mode, updated);
    return updated;
  }

  // ─── Mode enum persistence ────────────────────────────────────────────

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

  /// Map a stored string back to a mode, tolerating anything unexpected.
  static ChatMode parse(String? raw) {
    for (final mode in ChatMode.values) {
      if (mode.name == raw) return mode;
    }
    return fallbackMode;
  }
}
