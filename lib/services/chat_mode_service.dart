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

import 'package:chuk_chat/services/model_capabilities_service.dart';

enum ChatMode {
  /// Answers right away. Fast means fast — a light model, reasoning off.
  fast,

  /// Thinks hard before answering — a stronger model, reasoning on.
  thinking,

  /// A free slot: any model the reader picks, at any reasoning level. Unlike
  /// Fast and Thinking — whose models are set on the model screen and never
  /// overwritten by a composer pick — Custom's model is whatever the reader
  /// last chose in the composer. Picking a model there switches to this mode.
  custom,
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
  static const String defaultModelId = 'z-ai/glm-5.3-flash';
  static const String defaultProviderSlug = 'fireworks/serverless';

  /// The reasoning level that means "no reasoning pass".
  static const String reasoningOff = 'none';

  /// The reasoning level that means "reason at the model default, no graded
  /// effort". Sent for models that reason but expose only an on/off toggle.
  static const String reasoningOn = 'on';

  /// The graded ladder both OpenRouter and Fireworks accept. `minimal` and
  /// `xhigh` are intentionally NOT offered any more.
  static const List<String> reasoningLevelsGraded = <String>[
    'none',
    'low',
    'medium',
    'high',
  ];

  /// Every graded reasoning token the chat API accepts, weakest to strongest.
  /// The order doubles as the canonical rank used when clamping a level to what
  /// a model allows. Real per-model ladders are irregular subsets of this — the
  /// server decides which tokens a model exposes (see `supported_efforts`); this
  /// list only fixes their ORDER, never invents a model's ladder.
  static const List<String> reasoningLevelsAll = <String>[
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
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
    // Custom starts on the general fallback with reasoning off. It is only a
    // seed: the reader replaces the model the moment they pick one, so the
    // exact starting model matters less than that it is always valid.
    ChatMode.custom: ModeConfig(
      modelId: defaultModelId,
      providerSlug: defaultProviderSlug,
      reasoningEffort: reasoningOff,
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

  /// The reasoning levels valid for a model, `none` (off) always first.
  ///
  /// A model that cannot reason offers only off. A model that reasons but
  /// exposes no graded effort offers a plain on/off toggle. A model with
  /// graded effort offers the low/medium/high ladder — the same set on both
  /// OpenRouter and Fireworks now, so the provider no longer splits the list.
  /// [reasoningMandatory] models forbid disabling reasoning: the server rejects
  /// a "reasoning off" request with a hard 400, so `none` is dropped from the
  /// list entirely. A mandatory graded model offers low/medium/high; a mandatory
  /// toggle model collapses to a single "on" (always on, nothing to turn off).
  static List<String> reasoningLevelsFor({
    required String providerSlug,
    bool supportsReasoning = true,
    bool supportsReasoningEffort = true,
    bool reasoningMandatory = false,
  }) {
    if (!supportsReasoning) return const <String>[reasoningOff];
    if (!supportsReasoningEffort) {
      return reasoningMandatory
          ? const <String>[reasoningOn]
          : const <String>[reasoningOff, reasoningOn];
    }
    return reasoningMandatory
        ? const <String>['low', 'medium', 'high']
        : reasoningLevelsGraded;
  }

  /// THE picker list for [modelId] — the single source of truth. The server
  /// resolves exactly which levels are selectable per model and ships them as
  /// `supported_efforts`; the client renders that list verbatim. Only when the
  /// catalog cache has no entry yet (cold start, or a model the cache does not
  /// know) does this fall back to the derived [reasoningLevelsFor] list, so a
  /// picker never comes up empty. Never hardcodes a per-model ladder.
  static List<String> reasoningLevelsForModel({
    required String modelId,
    required String providerSlug,
  }) {
    final server = ModelCapabilitiesService.supportedEffortsSync(modelId);
    if (server.isNotEmpty) return server;
    return reasoningLevelsFor(
      providerSlug: providerSlug,
      supportsReasoning: ModelCapabilitiesService.supportsReasoningSync(modelId),
      supportsReasoningEffort:
          ModelCapabilitiesService.supportsReasoningEffortSync(modelId),
      reasoningMandatory:
          ModelCapabilitiesService.isReasoningMandatorySync(modelId),
    );
  }

  /// Clamp [level] to what the model allows. An exact match wins; otherwise
  /// the strongest allowed level no stronger than [level] is used, and only if
  /// none qualifies does it drop to the weakest allowed (off).
  ///
  /// The `'on'` token means "reasoning on at some strength". On a binary model
  /// it maps to [reasoningOn]; on a graded model it maps to a graded level
  /// (ranked as `medium`, since `'on'` has no place on the graded ladder).
  static String sanitizeReasoning(
    String level, {
    required String providerSlug,
    bool supportsReasoning = true,
    bool supportsReasoningEffort = true,
    bool reasoningMandatory = false,
  }) {
    final allowed = reasoningLevelsFor(
      providerSlug: providerSlug,
      supportsReasoning: supportsReasoning,
      supportsReasoningEffort: supportsReasoningEffort,
      reasoningMandatory: reasoningMandatory,
    );
    return _clampToAllowed(level, allowed);
  }

  /// Clamp [level] to what [modelId] actually allows, using the server's
  /// `supported_efforts` list as the source of truth (with the derived list as
  /// a cold-start fallback). This is the clamp to run BEFORE display and BEFORE
  /// send, so a stale saved preference can never render or transmit a level the
  /// model does not support. Falls back to the model's advertised default when
  /// nothing weaker qualifies.
  static String sanitizeReasoningForModel(
    String level, {
    required String modelId,
    required String providerSlug,
  }) {
    final allowed = reasoningLevelsForModel(
      modelId: modelId,
      providerSlug: providerSlug,
    );
    return _clampToAllowed(
      level,
      allowed,
      defaultEffort: ModelCapabilitiesService.reasoningDefaultEffortSync(
        modelId,
      ),
    );
  }

  /// Clamp [level] to [allowed]. An exact match wins; otherwise the strongest
  /// allowed level no stronger than [level] is used, and only if none qualifies
  /// does it drop to the weakest allowed (the list's first entry).
  ///
  /// The `'on'` token means "reasoning on at some strength". On a binary model
  /// (its list contains `on`) it maps to [reasoningOn]; on a graded model it
  /// maps to a graded level (ranked as `medium`, since `'on'` has no place on
  /// the graded ladder). [defaultEffort], when given and allowed, is preferred
  /// over a blind guess for a token with no rank.
  static String _clampToAllowed(
    String level,
    List<String> allowed, {
    String? defaultEffort,
  }) {
    if (allowed.isEmpty) return level;
    if (allowed.contains(level)) return level;
    if (level == reasoningOff) return allowed.first;

    // Anything else is an intent to reason at some strength. A binary model
    // collapses that to a plain on/off toggle.
    if (allowed.contains(reasoningOn)) return reasoningOn;

    // Graded model: pick the strongest allowed level no stronger than [level].
    // `'on'` has no rank on the ladder, so treat it as equivalent to `medium`.
    final wantToken = level == reasoningOn ? 'medium' : level;
    final wantRank = reasoningLevelsAll.indexOf(wantToken);
    if (wantRank < 0) {
      // Unknown token — prefer the model's advertised default, else a safe
      // graded level rather than off.
      if (defaultEffort != null && allowed.contains(defaultEffort)) {
        return defaultEffort;
      }
      return allowed.contains('medium') ? 'medium' : allowed.first;
    }

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
      case reasoningOn:
        return 'On';
      case 'minimal':
        return 'Minimal';
      case 'low':
        return 'Low';
      case 'medium':
        return 'Medium';
      case 'high':
        return 'High';
      case 'xhigh':
        return 'X-High';
      case 'max':
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
      // Hydrate capabilities first: the sync lookups below default to "true"
      // when a model is unknown, so sanitizing a stored `on` before the cache
      // loads would misread a binary model as graded and turn `on` into
      // `medium` — a level that model does not accept.
      await ModelCapabilitiesService.initialize();

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
        reasoningEffort: sanitizeReasoningForModel(
          config.reasoningEffort,
          modelId: config.modelId,
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

  /// Whether [mode] has a real stored config record (the reader has set it at
  /// least once), as opposed to only ever running the baked default. Used to
  /// tell "Custom has a remembered model" from "Custom was never picked", so
  /// the composer can label the third point with the model or stay neutral.
  static Future<bool> hasStoredConfig(ChatMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_configKey(mode));
      return raw != null && raw.isNotEmpty;
    } catch (_) {
      return false;
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
      reasoningEffort: sanitizeReasoningForModel(
        current.reasoningEffort,
        modelId: modelId,
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
      reasoningEffort: sanitizeReasoningForModel(
        level,
        modelId: current.modelId,
        providerSlug: current.providerSlug,
      ),
    );
    await saveConfig(mode, updated);
    return updated;
  }

  /// Pin [mode] to a new provider, keeping its model, and re-clamp the mode's
  /// reasoning level to what the new provider allows. Returns the stored
  /// result. An empty slug is ignored — the mode keeps its current provider.
  static Future<ModeConfig> setProviderForMode(
    ChatMode mode,
    String providerSlug,
  ) async {
    final current = await loadConfig(mode);
    if (providerSlug.isEmpty || providerSlug == current.providerSlug) {
      return current;
    }
    final updated = current.copyWith(
      providerSlug: providerSlug,
      reasoningEffort: sanitizeReasoningForModel(
        current.reasoningEffort,
        modelId: current.modelId,
        providerSlug: providerSlug,
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
