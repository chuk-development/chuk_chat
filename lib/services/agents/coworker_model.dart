/// What a coworker runs on, in one answer: its own model when it has one, the
/// app default when it has not.
///
/// ## The one model of "model, provider, reasoning"
///
/// * **A coworker's own model** — model, provider and reasoning level — is
///   stored per coworker thread in [ChatModelSelectionService]. The coworker
///   profile (the model page, [CoworkerModelState]) and the composer of that
///   coworker's thread both read and write this one record. The relay send
///   resolves it again at send time, so what the profile shows is what runs.
/// * **The app default** is the composer's mode — Fast, Thinking or Custom —
///   set in Settings → Model Selection ([ChatModeService]). A coworker with no
///   model of its own runs on it, and so does a plain chat.
///
/// Nothing else picks a coworker's model. The host stores none: every task
/// names the model it runs on, and the host's status frame reports what the
/// last run really used (`AgentModelChoice`).
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart'
    show ChatModeSelector, prettyModelId;
import 'package:chuk_chat/widgets/model_selection_dropdown.dart'
    show kAutoCheapestProviderSlug;

/// One provider of a model, as the account's catalogue lists it.
@immutable
class CoworkerProvider {
  const CoworkerProvider({
    required this.slug,
    required this.name,
    this.promptPrice,
    this.completionPrice,
    this.contextLength,
  });

  final String slug;
  final String name;

  /// USD per token, as the catalogue ships it. Null when it is not listed.
  final double? promptPrice;
  final double? completionPrice;
  final int? contextLength;

  static CoworkerProvider? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final slug = raw['slug'];
    if (slug is! String || slug.isEmpty) return null;
    final name = raw['name'];
    final pricing = raw['pricing'];
    double? price(String key) {
      if (pricing is! Map) return null;
      final value = pricing[key];
      return value is num ? value.toDouble() : null;
    }

    final context = raw['context_length'];
    return CoworkerProvider(
      slug: slug,
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : providerLabelFromSlug(slug),
      promptPrice: price('prompt'),
      completionPrice: price('completion'),
      contextLength: context is num ? context.toInt() : null,
    );
  }

  /// `$0.14 in · $0.42 out per 1M`, or null when the catalogue has no price.
  String? get priceLine {
    final input = promptPrice;
    final output = completionPrice;
    if (input == null && output == null) return null;
    if ((input ?? 0) == 0 && (output ?? 0) == 0) return 'Free';
    return '${formatPerMillion(input ?? 0)} in · '
        '${formatPerMillion(output ?? 0)} out per 1M';
  }
}

/// One model of the catalogue, with the providers that serve it.
@immutable
class CoworkerCatalogueModel {
  const CoworkerCatalogueModel({
    required this.id,
    required this.name,
    required this.providers,
  });

  final String id;
  final String name;
  final List<CoworkerProvider> providers;

  /// The name without the lab prefix (`DeepSeek: V4 Flash` → `V4 Flash`).
  String get shortName => ChatModeSelector.stripLabPrefix(name);

  CoworkerProvider? provider(String slug) {
    for (final candidate in providers) {
      if (candidate.slug == slug) return candidate;
    }
    return null;
  }

  /// The provider with the lowest output price, or null with none listed.
  CoworkerProvider? get cheapest {
    CoworkerProvider? best;
    for (final candidate in providers) {
      final price = candidate.completionPrice;
      if (price == null) continue;
      if (best == null || price < best.completionPrice!) best = candidate;
    }
    return best ?? (providers.isEmpty ? null : providers.first);
  }

  static CoworkerCatalogueModel? fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['name'];
    final providers = <CoworkerProvider>[
      if (raw['providers'] is List)
        for (final entry in raw['providers'] as List)
          ?CoworkerProvider.fromJson(entry),
    ];
    return CoworkerCatalogueModel(
      id: id,
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : prettyModelId(id),
      providers: providers,
    );
  }
}

/// What a coworker runs on right now.
@immutable
class CoworkerModelState {
  const CoworkerModelState({
    required this.own,
    required this.defaultMode,
    required this.defaultConfig,
  });

  /// The coworker's own model, or null when it follows the app default.
  final ChatModelSelection? own;

  /// The composer mode the app default comes from.
  final ChatMode defaultMode;

  /// That mode's model, provider and reasoning level.
  final ModeConfig defaultConfig;

  bool get followsDefault => own == null;

  String get modelId => own?.modelId ?? defaultConfig.modelId;
  String get providerSlug => own?.providerSlug ?? defaultConfig.providerSlug;

  /// The level the next run asks for, clamped to what the model allows.
  String get reasoningEffort => ChatModeService.sanitizeReasoningForModel(
    own?.reasoningEffort ?? defaultConfig.reasoningEffort,
    modelId: modelId,
    providerSlug: providerSlug,
  );

  /// `Fast`, `Thinking` or `Custom`: the name of the default it follows.
  String get defaultLabel => switch (defaultMode) {
    ChatMode.fast => 'Fast',
    ChatMode.thinking => 'Thinking',
    ChatMode.custom => 'Custom',
  };
}

/// Reads and writes a coworker's model. Static, like the services it sits on.
class CoworkerModel {
  CoworkerModel._();

  /// The coworker behind [chatId] (its thread key): own model or default.
  static Future<CoworkerModelState> resolve(String chatId) async {
    final own = chatId.isEmpty
        ? null
        : await ChatModelSelectionService.instance.load(chatId);
    final mode = await ChatModeService.load();
    final config = await ChatModeService.loadConfig(mode);
    return CoworkerModelState(
      own: own,
      defaultMode: mode,
      defaultConfig: config,
    );
  }

  /// How long a page or a row waits for the model data before it shows what
  /// it has ([fallbackState], a Retry row). The waiting widget owns the
  /// timer, so it goes with the widget.
  static const Duration loadTimeout = Duration(seconds: 8);

  /// [resolve] that does not throw: a read that fails falls back on its own
  /// (no own model when the stored choice cannot be read, the built-in
  /// default mode and its model otherwise). A read that hangs is the
  /// caller's watchdog's job ([loadTimeout]).
  static Future<CoworkerModelState> resolveOrFallback(String chatId) async {
    Future<T> safely<T>(Future<T> Function() read, T fallback) async {
      try {
        return await read();
      } catch (e) {
        if (kDebugMode) debugPrint('CoworkerModel: read failed: $e');
        return fallback;
      }
    }

    final ChatModelSelection? own = chatId.isEmpty
        ? null
        : await safely<ChatModelSelection?>(
            () => ChatModelSelectionService.instance.load(chatId),
            null,
          );
    final ChatMode mode = await safely<ChatMode>(
      ChatModeService.load,
      ChatModeService.fallbackMode,
    );
    final ModeConfig config = await safely<ModeConfig>(
      () => ChatModeService.loadConfig(mode),
      ChatModeService.defaultConfig(mode),
    );
    return CoworkerModelState(
      own: own,
      defaultMode: mode,
      defaultConfig: config,
    );
  }

  /// What to show when the coworker's model could not be read in time: the
  /// built-in default mode and its model.
  static CoworkerModelState fallbackState() => CoworkerModelState(
    own: null,
    defaultMode: ChatModeService.fallbackMode,
    defaultConfig: ChatModeService.defaultConfig(ChatModeService.fallbackMode),
  );

  /// The catalogue as this device last cached it. Empty before the first
  /// model fetch of the install.
  static Future<List<CoworkerCatalogueModel>> catalogue() async {
    final override = debugCatalogue;
    if (override != null) return override();
    try {
      final raw = await ModelCacheService.loadAvailableModels();
      return <CoworkerCatalogueModel>[
        for (final entry in raw) ?CoworkerCatalogueModel.fromJson(entry),
      ];
    } catch (_) {
      // An unreadable cache is an empty one: the caller fetches or says so.
      return const <CoworkerCatalogueModel>[];
    }
  }

  /// Test seam: replaces the device cache as the catalogue.
  @visibleForTesting
  static Future<List<CoworkerCatalogueModel>> Function()? debugCatalogue;

  /// The provider a newly picked model starts on: the one pinned for it on
  /// the model screen, else the cheapest the catalogue lists. Null when the
  /// catalogue does not know the model.
  static Future<String?> providerFor(
    String modelId, {
    List<CoworkerCatalogueModel>? models,
  }) async {
    final list = models ?? await catalogue();
    CoworkerCatalogueModel? model;
    for (final candidate in list) {
      if (candidate.id == modelId) {
        model = candidate;
        break;
      }
    }
    final pinned = await _pinnedProvider(modelId);
    if (pinned != null &&
        (model == null ||
            model.providers.isEmpty ||
            model.provider(pinned) != null)) {
      return pinned;
    }
    return model?.cheapest?.slug;
  }

  static Future<String?> _pinnedProvider(String modelId) async {
    String? userId;
    try {
      userId = SupabaseService.auth.currentUser?.id;
    } catch (_) {
      userId = null;
    }
    if (userId == null) return null;
    try {
      final prefs = await ModelCacheService.loadProviderPreferences(userId);
      final slug = prefs[modelId]?.trim();
      if (slug == null || slug.isEmpty || slug == kAutoCheapestProviderSlug) {
        return null;
      }
      return slug;
    } catch (_) {
      return null;
    }
  }

  /// Gives the coworker its own model. [reasoningEffort] is clamped to what
  /// the model allows before it is stored.
  static Future<ChatModelSelection> setOwn(
    String chatId, {
    required String modelId,
    required String providerSlug,
    required String reasoningEffort,
  }) async {
    final selection = ChatModelSelection(
      modelId: modelId,
      providerSlug: providerSlug,
      reasoningEffort: ChatModeService.sanitizeReasoningForModel(
        reasoningEffort,
        modelId: modelId,
        providerSlug: providerSlug,
      ),
    );
    await ChatModelSelectionService.instance.save(chatId, selection);
    return selection;
  }

  /// Drops the coworker's own model: it follows the app default again.
  static Future<void> useDefault(String chatId) =>
      ChatModelSelectionService.instance.clear(chatId);
}

/// `fireworks/serverless` → `Fireworks`; `deepinfra` → `Deepinfra`. Only for a
/// slug the catalogue does not name; the catalogue's own name always wins.
String providerLabelFromSlug(String slug) {
  final head = slug.split('/').first.trim();
  if (head.isEmpty) return slug;
  return head
      .split(RegExp(r'[-_]'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

/// The provider's name for [slug] from [models], else from the slug itself.
String providerLabel(
  String slug, {
  String? modelId,
  List<CoworkerCatalogueModel> models = const <CoworkerCatalogueModel>[],
}) {
  if (slug.isEmpty) return 'Automatic';
  for (final model in models) {
    if (modelId != null && model.id != modelId) continue;
    final provider = model.provider(slug);
    if (provider != null) return provider.name;
  }
  return providerLabelFromSlug(slug);
}

/// The model's short name from [models], else a prettified id.
String modelLabel(
  String modelId, {
  List<CoworkerCatalogueModel> models = const <CoworkerCatalogueModel>[],
}) {
  for (final model in models) {
    if (model.id == modelId) return model.shortName;
  }
  return ChatModeSelector.stripLabPrefix(prettyModelId(modelId));
}

/// `$0.42` per million tokens from a per-token price.
String formatPerMillion(double perToken) {
  final perMillion = perToken * 1000000;
  if (perMillion == 0) return r'$0';
  if (perMillion >= 10) return '\$${perMillion.toStringAsFixed(1)}';
  if (perMillion >= 1) return '\$${perMillion.toStringAsFixed(2)}';
  final text = perMillion
      .toStringAsFixed(3)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
  return '\$$text';
}
