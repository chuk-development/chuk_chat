// lib/services/chat_mode_service.dart
//
// The two modes a reader picks between.
//
// Standard: we pick model and providers on the server (best value: fast first
// token, >= 100 tok/s, low price) and change them when the market moves. The
// reader only chooses the reasoning level. See [ChatProfileService].
//
// Custom: any model the reader picks, on the provider they pin.
//
// Each mode carries its own config (model, provider, reasoning level), so a
// change to one never leaks into the other.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_profile_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/retired_model_fallback.dart';

enum ChatMode {
  /// Model and provider chain chosen by the server ([ChatProfileService]).
  /// The reader picks only the reasoning level.
  standard,

  /// Any model the reader picks, at any reasoning level. Picking a model in
  /// the composer switches to this mode.
  custom,
}

/// One mode's independent settings: which model, on which provider, at which
/// reasoning level. Persisted per mode, so Standard and Custom never share.
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
  /// Custom's seed; also where the broad "make sure a model is selected"
  /// path lands.
  static const String defaultModelId = 'z-ai/glm-5.3-flash';
  static const String defaultProviderSlug = 'fireworks/serverless';

  /// The reasoning level that means "no reasoning pass".
  static const String reasoningOff = 'none';

  /// The reasoning level that means "reason at the model default, no graded
  /// effort". Sent for models that reason but expose only an on/off toggle.
  static const String reasoningOn = 'on';

  /// The graded ladder offered when the catalog has not said otherwise.
  /// `minimal` and `xhigh` are intentionally NOT offered any more, and neither
  /// is `medium`: the models the app ships as defaults (glm-5.3-flash,
  /// deepseek-v4-pro) do not accept it, and a request with an unsupported
  /// effort is answered WITHOUT any reasoning — silently. `low` and `high` are
  /// on every graded ladder the catalog has shown so far, so a cold-cache
  /// clamp can only land on a level the server honours. The server's own
  /// `supported_efforts` list replaces this the moment it is known.
  static const List<String> reasoningLevelsGraded = <String>[
    'none',
    'low',
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

  /// What Fireworks providers accept — no `minimal`, no `xhigh`, and no
  /// `medium` as a cold-cache guess (see [reasoningLevelsGraded]).
  static const List<String> reasoningLevelsFireworks = <String>[
    'none',
    'low',
    'high',
  ];

  /// What each mode starts on, and what a failed load falls back to.
  ///
  /// Standard's model is the server's choice ([ChatProfileService]); its
  /// provider is the profile marker, which the send turns into
  /// `profile: "standard"`. Custom starts on the general fallback with
  /// reasoning off; it is only a seed, replaced by the reader's first pick.
  static ModeConfig defaultConfig(ChatMode mode) => switch (mode) {
    ChatMode.standard => ModeConfig(
      modelId: ChatProfileService.standardModelId,
      providerSlug: ChatProfileService.standardMarker,
      reasoningEffort: 'low',
    ),
    ChatMode.custom => const ModeConfig(
      modelId: defaultModelId,
      providerSlug: defaultProviderSlug,
      reasoningEffort: reasoningOff,
    ),
  };

  /// What a fresh install and a new account start with.
  static const ChatMode fallbackMode = ChatMode.standard;

  // ─── Reasoning levels ─────────────────────────────────────────────────

  /// Whether [slug] is a Fireworks provider (direct or routed).
  static bool isFireworksProvider(String slug) =>
      slug == 'fireworks' || slug.startsWith('fireworks/');

  /// The reasoning levels valid for a model, `none` (off) always first.
  ///
  /// A model that cannot reason offers only off. A model that reasons but
  /// exposes no graded effort offers a plain on/off toggle. A model with
  /// graded effort offers the low/high ladder — the same set on both
  /// OpenRouter and Fireworks now, so the provider no longer splits the list
  /// (no `medium` here: see [reasoningLevelsGraded]).
  /// [reasoningMandatory] models forbid disabling reasoning: the server rejects
  /// a "reasoning off" request with a hard 400, so `none` is dropped from the
  /// list entirely. A mandatory graded model offers low/high; a mandatory
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
        ? const <String>['low', 'high']
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
      supportsReasoning: ModelCapabilitiesService.supportsReasoningSync(
        modelId,
      ),
      supportsReasoningEffort:
          ModelCapabilitiesService.supportsReasoningEffortSync(modelId),
      reasoningMandatory: ModelCapabilitiesService.isReasoningMandatorySync(
        modelId,
      ),
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
      // graded level rather than off (the ladder may have no `medium`).
      if (defaultEffort != null && allowed.contains(defaultEffort)) {
        return defaultEffort;
      }
      for (final safe in const <String>['medium', 'low', 'high']) {
        if (allowed.contains(safe)) return safe;
      }
      return allowed.first;
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
    if (mode == ChatMode.standard) {
      // Model and provider are the server's; only the level is the reader's.
      await ChatProfileService.load();
    }
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

      final ModeConfig stored = ModeConfig.fromJson(
        Map<String, dynamic>.from(decoded),
        fallback: fallback,
      );
      final config = mode == ChatMode.standard
          ? fallback.copyWith(reasoningEffort: stored.reasoningEffort)
          : await _replaceRetiredModel(mode, stored, fallback);
      return config.copyWith(
        reasoningEffort: sanitizeReasoningForModel(
          config.reasoningEffort,
          modelId: config.modelId,
          providerSlug: config.providerSlug,
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [ChatMode] Could not read the config for ${mode.name}: $e',
        );
      }
      return fallback;
    }
  }

  /// [config] with its model moved off a model the server retired.
  ///
  /// The server drops old models from the catalog and names the successor in
  /// the successor's `replaces` list ([replacementForRetiredModel]). A mode
  /// still on a dropped model moves to that successor, or to the mode's
  /// default model when the server names none. The provider pinned for the
  /// old model may not serve the new one, so it is cleared (Auto picks the
  /// cheapest) unless the new model is the default, which keeps the default
  /// provider. The result is stored, so the move happens once.
  static Future<ModeConfig> _replaceRetiredModel(
    ChatMode mode,
    ModeConfig config,
    ModeConfig fallback,
  ) async {
    List<Map<String, dynamic>> catalog;
    try {
      catalog = await ModelCacheService.loadAvailableModels();
    } catch (_) {
      // No readable catalog is no evidence the model is gone: keep it.
      return config;
    }
    final String? replacement = replacementForRetiredModel(
      config.modelId,
      catalog,
      fallbackModelId: fallback.modelId,
    );
    if (replacement == null || replacement == config.modelId) return config;
    final ModeConfig moved = config.copyWith(
      modelId: replacement,
      providerSlug: replacement == fallback.modelId
          ? fallback.providerSlug
          : '',
    );
    if (kDebugMode) {
      debugPrint(
        '[ChatMode] ${mode.name}: retired model ${config.modelId} '
        '-> $replacement',
      );
    }
    await saveConfig(mode, moved);
    return moved;
  }

  /// Persist [config] for [mode]. Failures are swallowed: losing the
  /// preference is a small annoyance, an exception mid-tap is not.
  static Future<void> saveConfig(ChatMode mode, ModeConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configKey(mode), jsonEncode(config.toJson()));
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [ChatMode] Could not store the config for ${mode.name}: $e',
        );
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
    // Standard's model and provider are the server's: nothing to store.
    if (mode == ChatMode.standard) return current;
    // An empty slug means "not resolved yet", not "no provider". Storing it
    // would make the next load fall back to the default provider, pairing
    // the new model with a provider it was never pinned to — so keep the
    // mode's current provider when the caller has none.
    final effectiveProvider = providerSlug.isNotEmpty
        ? providerSlug
        : current.providerSlug;
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
    if (mode == ChatMode.standard ||
        providerSlug.isEmpty ||
        providerSlug == current.providerSlug) {
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
  /// The old `fast` and `thinking` modes (before 2026-11-17) become Standard.
  static ChatMode parse(String? raw) {
    for (final mode in ChatMode.values) {
      if (mode.name == raw) return mode;
    }
    return fallbackMode;
  }
}
