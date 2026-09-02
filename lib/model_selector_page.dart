// lib/model_selector_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/api_status_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart'
    show ChatModeSelector, prettyModelId;
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/per_model_system_prompt_sheet.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart'
    show kAutoCheapestProviderSlug;

// ─── Data models (mirroring FastAPI Pydantic models) ─────────────────────

class PricingDetails {
  final double prompt;
  final double completion;
  final double request;
  final double? image;
  final double? webSearch;
  final double? internalReasoning;

  PricingDetails({
    required this.prompt,
    required this.completion,
    required this.request,
    this.image,
    this.webSearch,
    this.internalReasoning,
  });

  factory PricingDetails.fromJson(Map<String, dynamic> json) {
    return PricingDetails(
      prompt: (json['prompt'] as num?)?.toDouble() ?? 0.0,
      completion: (json['completion'] as num?)?.toDouble() ?? 0.0,
      request: (json['request'] as num?)?.toDouble() ?? 0.0,
      image: (json['image'] as num?)?.toDouble(),
      webSearch: (json['web_search'] as num?)?.toDouble(),
      internalReasoning: (json['internal_reasoning'] as num?)?.toDouble(),
    );
  }

  String formatTokenPrice(double pricePerToken) {
    if (pricePerToken == 0.0) return 'Free';
    final pricePerMillion = pricePerToken * 1000000;
    String priceStr = pricePerMillion.toStringAsFixed(6);
    priceStr = priceStr.replaceAll(RegExp(r'\.?0+$'), '');
    return '\$$priceStr/M';
  }

  String formatRequestPrice(double price) {
    if (price == 0.0) return 'Free';
    return '\$${price.toStringAsFixed(3)}/req';
  }
}

class ModelProviderInfo {
  final String slug;
  final String name;
  final PricingDetails pricing;
  final int? contextLength;
  final int? maxCompletionTokens;
  final bool? isModerated;
  final String? iconUrl;

  ModelProviderInfo({
    required this.slug,
    required this.name,
    required this.pricing,
    this.contextLength,
    this.maxCompletionTokens,
    this.isModerated,
    this.iconUrl,
  });

  factory ModelProviderInfo.fromJson(Map<String, dynamic> json) {
    return ModelProviderInfo(
      slug: json['slug'] as String,
      name: json['name'] as String,
      pricing: PricingDetails.fromJson(json['pricing'] as Map<String, dynamic>),
      contextLength: json['context_length'] as int?,
      maxCompletionTokens: json['max_completion_tokens'] as int?,
      isModerated: json['is_moderated'] as bool?,
      iconUrl: json['icon_url'] as String?,
    );
  }
}

class CustomModelInfo {
  final String id;
  final String name;
  final String? description;
  final List<ModelProviderInfo> providers;
  final String? iconUrl;

  CustomModelInfo({
    required this.id,
    required this.name,
    this.description,
    required this.providers,
    this.iconUrl,
  });

  factory CustomModelInfo.fromJson(Map<String, dynamic> json) {
    var providersList = json['providers'] as List;
    List<ModelProviderInfo> providers = providersList
        .map((i) => ModelProviderInfo.fromJson(i))
        .toList();

    return CustomModelInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      providers: providers,
      iconUrl: json['icon_url'] as String?,
    );
  }
}

// ─── Page widget ────────────────────────────────────────────────────────

/// Which slice of the catalogue the model list shows.
enum _ModelListFilter {
  /// Everything, with the active (provider-pinned) models floated to the top.
  all,

  /// Only the models that have a provider pinned.
  active,

  /// Only the models with no provider pinned yet.
  inactive,
}

class ModelSelectorPage extends StatefulWidget {
  const ModelSelectorPage({super.key});

  @override
  State<ModelSelectorPage> createState() => _ModelSelectorPageState();
}

class _ModelSelectorPageState extends State<ModelSelectorPage> {
  final String _baseUrl = ApiConfigService.apiBaseUrl;
  List<CustomModelInfo> _models = [];
  Map<String, ModelProviderInfo?> _selectedProviders = {};
  // Models for which the user picked "Auto (cheapest)". The map's value is
  // the currently-cheapest provider (for display in the pill).
  final Map<String, ModelProviderInfo> _autoSelected = {};
  Map<String, ModelPromptConfig> _modelPromptConfigs = {};
  bool _isLoading = true;
  String? _error;
  Map<String, String> _lastSavedPreferences = {};
  Timer? _apiAvailabilityTimer;
  StreamSubscription<void>? _refreshSubscription;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Which slice of the catalogue the list below shows. Layered on top of the
  // search filter, never replacing it.
  _ModelListFilter _listFilter = _ModelListFilter.all;

  // Which model each chat mode uses. Editable here so the reader can assign a
  // model to Fast and a model to Thinking without going through the composer.
  ModeConfig? _fastConfig;
  ModeConfig? _thinkingConfig;

  static const Duration _apiPollInterval = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
    _refreshSubscription = ModelSelectionEventBus().refreshStream.listen((_) {
      if (!mounted) return;
      // Realtime change from another device — re-fetch silently so the user
      // sees the new active-model list without pulling to refresh.
      unawaited(_fetchModels());
    });
    _initializeModelSelections();
    _loadModeConfigs();
  }

  Future<void> _loadModeConfigs() async {
    var fast = await ChatModeService.loadConfig(ChatMode.fast);
    final thinking = await ChatModeService.loadConfig(ChatMode.thinking);

    // Fast mode is flash-only now. A stored non-flash pick (e.g. a stale
    // V4 Pro that leaked in) is invalid — heal it to GLM 5.3 Flash, or any
    // flash model the catalogue carries, pinned to its real provider.
    if (!_isFlashModelId(fast.modelId) && _models.isNotEmpty) {
      final healed = await _healFastToFlash();
      if (healed != null) fast = healed;
    }

    if (!mounted) return;
    setState(() {
      _fastConfig = fast;
      _thinkingConfig = thinking;
    });
  }

  bool _isFlashModelId(String id) => id.toLowerCase().contains('flash');

  /// Pick a flash model for Fast — prefer the default GLM 5.3 Flash, else the
  /// first flash model in the catalogue — and store it against Fast with its
  /// pinned or cheapest provider.
  Future<ModeConfig?> _healFastToFlash() async {
    CustomModelInfo? target;
    for (final m in _models) {
      if (m.id == ChatModeService.defaultModelId) {
        target = m;
        break;
      }
    }
    target ??= () {
      for (final m in _models) {
        if (_isFlashModelId(m.id) || m.name.toLowerCase().contains('flash')) {
          return m;
        }
      }
      return null;
    }();
    if (target == null) return null;
    final provider = _selectedProviders[target.id]?.slug ??
        _cheapestProvider(target)?.slug ??
        '';
    return ChatModeService.setModelForMode(
      ChatMode.fast,
      modelId: target.id,
      providerSlug: provider,
    );
  }

  /// Human name for a model id, from the loaded catalogue, falling back to a
  /// prettified slug so the row never shows a raw id.
  String _modelNameFor(String modelId) {
    for (final model in _models) {
      if (model.id == modelId) return model.name;
    }
    return prettyModelId(modelId);
  }

  /// Assign [modelId] to [mode]. The provider is the one the reader already
  /// pinned for that model, or its cheapest, so mode and provider never drift.
  Future<void> _pickModelForMode(ChatMode mode, String modelId) async {
    CustomModelInfo? model;
    for (final m in _models) {
      if (m.id == modelId) {
        model = m;
        break;
      }
    }
    final String providerSlug = _selectedProviders[modelId]?.slug ??
        (model != null ? _cheapestProvider(model)?.slug ?? '' : '');
    final updated = await ChatModeService.setModelForMode(
      mode,
      modelId: modelId,
      providerSlug: providerSlug,
    );
    if (!mounted) return;
    setState(() {
      if (mode == ChatMode.fast) {
        _fastConfig = updated;
      } else {
        _thinkingConfig = updated;
      }
    });
  }

  /// The catalogue entry for [modelId], or null when it is unknown / unset.
  CustomModelInfo? _modelById(String? modelId) {
    if (modelId == null || modelId.isEmpty) return null;
    for (final m in _models) {
      if (m.id == modelId) return m;
    }
    return null;
  }

  /// Pin [mode] to a new provider, keeping its model. The service re-clamps the
  /// mode's reasoning level to the new provider's allowed set.
  Future<void> _setProviderForMode(ChatMode mode, String providerSlug) async {
    final updated = await ChatModeService.setProviderForMode(mode, providerSlug);
    if (!mounted) return;
    setState(() {
      if (mode == ChatMode.fast) {
        _fastConfig = updated;
      } else {
        _thinkingConfig = updated;
      }
    });
  }

  /// Models the reader can assign to a mode: those they have enabled (pinned a
  /// provider for). These are the recommended set. Falls back to the whole
  /// catalogue when nothing is enabled yet.
  List<CustomModelInfo> get _enabledModels {
    final enabled =
        _models.where((m) => _selectedProviders[m.id] != null).toList();
    final list =
        enabled.isNotEmpty ? enabled : List<CustomModelInfo>.from(_models);
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Reasoning levels the mode's current model supports — straight from the
  /// server's `supported_efforts` contract (derived list as a cold-start
  /// fallback), so the picker can never offer a level the model lacks.
  List<String> _reasoningLevelsForMode(ChatMode mode) {
    final config = mode == ChatMode.fast ? _fastConfig : _thinkingConfig;
    if (config == null) return const <String>[ChatModeService.reasoningOff];
    return ChatModeService.reasoningLevelsForModel(
      modelId: config.modelId,
      providerSlug: config.providerSlug,
    );
  }

  Future<void> _setReasoningForMode(ChatMode mode, String level) async {
    final current =
        (mode == ChatMode.fast ? _fastConfig : _thinkingConfig)?.reasoningEffort;
    if (level == current) return;
    final updated = await ChatModeService.setReasoningForMode(mode, level);
    if (!mounted) return;
    setState(() {
      if (mode == ChatMode.fast) {
        _fastConfig = updated;
      } else {
        _thinkingConfig = updated;
      }
    });
  }

  List<CustomModelInfo> get _filteredModels {
    if (_searchQuery.isEmpty) {
      return _models;
    }
    return _models.where((model) {
      final nameMatch = model.name.toLowerCase().contains(_searchQuery);
      final descMatch =
          model.description?.toLowerCase().contains(_searchQuery) ?? false;
      return nameMatch || descMatch;
    }).toList();
  }

  /// The list actually rendered: the search-filtered set, then the Active /
  /// Inactive slice, with the base API order preserved. In the "All" slice the
  /// active (provider-pinned) models float to the top via a STABLE partition,
  /// so each group keeps its original relative order — no alphabetical sort.
  List<CustomModelInfo> get _displayModels {
    final searched = _filteredModels;
    final actives = <CustomModelInfo>[];
    final inactives = <CustomModelInfo>[];
    for (final model in searched) {
      if (_selectedProviders[model.id] != null) {
        actives.add(model);
      } else {
        inactives.add(model);
      }
    }
    switch (_listFilter) {
      case _ModelListFilter.all:
        return <CustomModelInfo>[...actives, ...inactives];
      case _ModelListFilter.active:
        return actives;
      case _ModelListFilter.inactive:
        return inactives;
    }
  }

  Future<void> _initializeModelSelections() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _selectedProviders.clear();
    });

    try {
      await _fetchModels();
    } on TimeoutException catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Model selector initialization timeout: $error');
      }
      if (kDebugMode) {
        debugPrint('Stack trace: $stackTrace');
      }
      await _handleApiUnavailable('Request timed out: $error');
    } on SocketException catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Model selector initialization network error: $error');
      }
      if (kDebugMode) {
        debugPrint('Stack trace: $stackTrace');
      }
      await _handleApiUnavailable('Network error: $error');
    } on HttpException catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Model selector initialization HTTP error: $error');
      }
      if (kDebugMode) {
        debugPrint('Stack trace: $stackTrace');
      }
      await _handleApiUnavailable('HTTP error: $error');
    } on FormatException catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Model selector initialization format error: $error');
      }
      if (kDebugMode) {
        debugPrint('Stack trace: $stackTrace');
      }
      await _handleApiUnavailable('Data format error: $error');
    } catch (error, stackTrace) {
      // Rethrow unknown errors so programming errors are not swallowed.
      if (kDebugMode) {
        debugPrint('Model selector initialization unexpected error: $error');
      }
      if (kDebugMode) {
        debugPrint('Stack trace: $stackTrace');
      }
      rethrow;
    }
  }

  Future<void> _fetchModels() async {
    try {
      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;
      if (session == null || session.accessToken.isEmpty) {
        throw const _AuthRequiredException();
      }
      final String accessToken = session.accessToken;

      _lastSavedPreferences =
          await UserPreferencesService.loadAllProviderPreferences();
      final response = await http.get(
        Uri.parse('$_baseUrl/v1/models_info'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode == 200) {
        _stopApiAvailabilityPolling();
        final List<dynamic> modelsJson = json.decode(response.body);
        final List<CustomModelInfo> fetchedModels = modelsJson
            .map((json) => CustomModelInfo.fromJson(json))
            .toList();

        final Map<String, ModelProviderInfo?> initialSelections = {};
        final Map<String, ModelProviderInfo> autoSelected = {};
        final List<Future<void>> cleanupFutures = [];
        for (final model in fetchedModels) {
          final String? savedProviderSlug = _lastSavedPreferences[model.id];
          ModelProviderInfo? selectedProvider;

          if (savedProviderSlug == kAutoCheapestProviderSlug) {
            final cheapest = _cheapestProvider(model);
            if (cheapest != null) {
              selectedProvider = cheapest;
              autoSelected[model.id] = cheapest;
            }
          } else if (savedProviderSlug != null) {
            try {
              selectedProvider = model.providers.firstWhere(
                (provider) => provider.slug == savedProviderSlug,
              );
            } on StateError {
              selectedProvider = null;
              cleanupFutures.add(
                UserPreferencesService.clearSelectedProvider(model.id),
              );
            }
          }

          initialSelections[model.id] = selectedProvider;
        }

        if (cleanupFutures.isNotEmpty) {
          await Future.wait(cleanupFutures);
          _lastSavedPreferences =
              await UserPreferencesService.loadAllProviderPreferences();
        }

        // Load any saved per-model system prompt configs (decrypted in-memory).
        Map<String, ModelPromptConfig> promptConfigs;
        try {
          promptConfigs = await PerModelSystemPromptService.loadAll();
        } catch (error) {
          if (kDebugMode) {
            debugPrint('Per-model prompt configs load failed: $error');
          }
          promptConfigs = <String, ModelPromptConfig>{};
        }

        if (!mounted) return;
        setState(() {
          _models = fetchedModels;
          _selectedProviders = initialSelections;
          _autoSelected
            ..clear()
            ..addAll(autoSelected);
          _modelPromptConfigs = promptConfigs;
          _isLoading = false;
          _error = null;
        });
        // Models are in now, so a stale non-flash Fast pick can be healed.
        unawaited(_loadModeConfigs());
        return;
      }

      if (response.statusCode == 401) {
        throw const _AuthRequiredException();
      }

      await _handleApiUnavailable(
        'Status ${response.statusCode} - ${response.body}',
      );
    } on TimeoutException catch (error) {
      await _handleApiUnavailable('Request timed out: $error');
    } on SocketException catch (error) {
      await _handleApiUnavailable('Network error: $error');
    } on HttpException catch (error) {
      await _handleApiUnavailable('HTTP error: $error');
    } on FormatException catch (error) {
      await _handleApiUnavailable('Data format error: $error');
    } on _AuthRequiredException {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Session expired. Please sign in again.';
        _models = [];
        _selectedProviders.clear();
      });
      _showSnackBar('Session expired. Please sign in again.');
    } catch (error) {
      rethrow;
    }
  }

  Future<void> _handleApiUnavailable(String debugDetails) async {
    if (kDebugMode) {
      debugPrint('Model selector API unavailable: $debugDetails');
    }
    final bool hasConnectivity =
        await NetworkStatusService.hasInternetConnection();
    final String message = _buildApiUnavailableMessage(
      hasConnectivity: hasConnectivity,
    );
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
    });
    _showSnackBar(message);
    _startApiAvailabilityPolling();
  }

  String _buildApiUnavailableMessage({required bool hasConnectivity}) {
    if (!hasConnectivity) {
      return 'You appear to be offline. Please check your internet connection.';
    }

    final Uri? apiUri = Uri.tryParse(_baseUrl);
    final String host = apiUri?.host.toLowerCase() ?? '';
    final bool isLocalHost =
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '10.0.2.2' ||
        host == '10.0.3.2';

    if (kDebugMode && isLocalHost) {
      return 'Cannot reach local API server at $_baseUrl.';
    }

    return 'We are currently doing maintenance and will be right back.';
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        duration: const Duration(seconds: 2),
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  void _startApiAvailabilityPolling() {
    _apiAvailabilityTimer ??= Timer.periodic(_apiPollInterval, (_) async {
      final bool reachable = await ApiStatusService.isApiReachable(
        baseUrl: _baseUrl,
      );
      if (!reachable) return;
      if (!mounted) return;
      _stopApiAvailabilityPolling();
      setState(() {
        _isLoading = true;
        _error = null;
      });
      await _fetchModels();
    });
  }

  void _stopApiAvailabilityPolling() {
    _apiAvailabilityTimer?.cancel();
    _apiAvailabilityTimer = null;
  }

  Future<void> _onEditModelPrompt(
    CustomModelInfo model,
  ) async {
    final existing = _modelPromptConfigs[model.id];
    final changed = await showPerModelSystemPromptSheet(
      context: context,
      modelId: model.id,
      modelName: model.name,
      initial: existing,
    );
    if (changed != true) return;
    // Refresh configs after edit / delete.
    Map<String, ModelPromptConfig> refreshed;
    try {
      refreshed = await PerModelSystemPromptService.loadAll();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Per-model prompt configs refresh failed: $error');
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _modelPromptConfigs = refreshed;
    });
  }

  Future<void> _onProviderSelect(
    String modelId,
    ModelProviderInfo? provider,
  ) async {
    setState(() {
      _selectedProviders[modelId] = provider;
      _autoSelected.remove(modelId);
    });

    if (provider != null) {
      _lastSavedPreferences[modelId] = provider.slug;
      await UserPreferencesService.saveSelectedProvider(modelId, provider.slug);
    } else {
      _lastSavedPreferences.remove(modelId);
      await UserPreferencesService.clearSelectedProvider(modelId);
    }

    await UserPreferencesService.refreshModelSelections();
  }

  Future<void> _onAutoSelect(CustomModelInfo model) async {
    final cheapest = _cheapestProvider(model);
    if (cheapest == null) return;
    setState(() {
      _selectedProviders[model.id] = cheapest;
      _autoSelected[model.id] = cheapest;
    });
    _lastSavedPreferences[model.id] = kAutoCheapestProviderSlug;
    await UserPreferencesService.saveSelectedProvider(
      model.id,
      kAutoCheapestProviderSlug,
    );
    await UserPreferencesService.refreshModelSelections();
  }

  ModelProviderInfo? _cheapestProvider(CustomModelInfo model) {
    if (model.providers.isEmpty) return null;
    ModelProviderInfo best = model.providers.first;
    for (final p in model.providers.skip(1)) {
      if (p.pricing.completion < best.pricing.completion) best = p;
    }
    return best;
  }

  String _formatContextLength(int? tokens) {
    if (tokens == null) return 'N/A';
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(1)}M';
    } else if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1).replaceAll(RegExp(r'\.0+$'), '')}K';
    }
    return tokens.toString();
  }

  Widget _buildIconWidget(
    String? imageUrl,
    IconData fallbackIcon, {
    double size = 24,
  }) {
    final Color tint = Theme.of(context).colorScheme.onSurfaceVariant;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      final isSvg = imageUrl.toLowerCase().endsWith('.svg');
      if (isSvg) {
        return SvgPicture.network(
          imageUrl,
          width: size,
          height: size,
          fit: BoxFit.contain,
          placeholderBuilder: (context) => SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(
                Icons.downloading,
                color: tint,
                size: size / 2,
              ),
            ),
          ),
        );
      } else {
        return Image.network(
          imageUrl,
          width: size,
          height: size,
          fit: BoxFit.contain,
          cacheWidth: (size * 2).toInt(),
          cacheHeight: (size * 2).toInt(),
          errorBuilder: (context, error, stackTrace) {
            if (kDebugMode) {
              debugPrint('Error loading image from $imageUrl: $error');
            }
            return Icon(fallbackIcon, color: tint, size: size);
          },
        );
      }
    } else {
      return Icon(fallbackIcon, color: tint, size: size);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(l.models),
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: colorScheme.error,
                          size: 48,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l.modelError(_error ?? ''),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _initializeModelSelections,
                          icon: const Icon(Icons.refresh),
                          label: Text(l.retry),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ScrollConfiguration(
                  // Hide the desktop scrollbar; it read as noise over the
                  // rounded model cards.
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  // +3 header slots: search field, mode picker, section header.
                  itemCount: _displayModels.length + 3,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _SearchField(
                          controller: _searchController,
                          hintText: l.searchModels,
                          hasQuery: _searchQuery.isNotEmpty,
                        ),
                      );
                    }
                    if (index == 1) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _ModePickerPanel(
                          buildIconWidget: _buildIconWidget,
                          models: _enabledModels,
                          fast: _ModeRowData(
                            icon: Icons.bolt,
                            title: 'Fast mode',
                            modelId: _fastConfig?.modelId ?? '',
                            modelName: _fastConfig == null
                                ? null
                                : _modelNameFor(_fastConfig!.modelId),
                            reasoningEffort: _fastConfig?.reasoningEffort ??
                                ChatModeService.reasoningOff,
                            reasoningLevels:
                                _reasoningLevelsForMode(ChatMode.fast),
                            providerSlug: _fastConfig?.providerSlug ?? '',
                            providers:
                                _modelById(_fastConfig?.modelId)?.providers ??
                                    const <ModelProviderInfo>[],
                            onPickModel: (id) =>
                                _pickModelForMode(ChatMode.fast, id),
                            onPickReasoning: (lvl) =>
                                _setReasoningForMode(ChatMode.fast, lvl),
                            onPickProvider: (slug) =>
                                _setProviderForMode(ChatMode.fast, slug),
                          ),
                          thinking: _ModeRowData(
                            icon: Icons.psychology_outlined,
                            title: 'Thinking mode',
                            modelId: _thinkingConfig?.modelId ?? '',
                            modelName: _thinkingConfig == null
                                ? null
                                : _modelNameFor(_thinkingConfig!.modelId),
                            reasoningEffort: _thinkingConfig?.reasoningEffort ??
                                ChatModeService.reasoningOff,
                            reasoningLevels:
                                _reasoningLevelsForMode(ChatMode.thinking),
                            providerSlug: _thinkingConfig?.providerSlug ?? '',
                            providers: _modelById(_thinkingConfig?.modelId)
                                    ?.providers ??
                                const <ModelProviderInfo>[],
                            onPickModel: (id) =>
                                _pickModelForMode(ChatMode.thinking, id),
                            onPickReasoning: (lvl) =>
                                _setReasoningForMode(ChatMode.thinking, lvl),
                            onPickProvider: (slug) =>
                                _setProviderForMode(ChatMode.thinking, slug),
                          ),
                        ),
                      );
                    }
                    if (index == 2) {
                      final int count = _displayModels.length;
                      final label = _searchQuery.isEmpty
                          ? 'Available · $count models'
                          : '$count model${count == 1 ? '' : 's'} found';
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ExpressiveSectionHeader(label),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _ListFilterBar(
                              value: _listFilter,
                              onChanged: (f) =>
                                  setState(() => _listFilter = f),
                            ),
                          ),
                        ],
                      );
                    }
                    final model = _displayModels[index - 3];
                    final ModelProviderInfo? selectedProviderForModel =
                        _selectedProviders[model.id];
                    final ModelPromptConfig? promptConfigForModel =
                        _modelPromptConfigs[model.id];

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ModelSelectionRow(
                        key: ValueKey(model.id),
                        model: model,
                        selectedProvider: selectedProviderForModel,
                        promptConfig: promptConfigForModel,
                        isAutoSelected: _autoSelected.containsKey(model.id),
                        isFirstRow: index == 3,
                        onProviderChanged: (provider) =>
                            _onProviderSelect(model.id, provider),
                        onAutoSelected: () => _onAutoSelect(model),
                        onEditPrompt: () => _onEditModelPrompt(model),
                        formatContextLength: _formatContextLength,
                        buildIconWidget: _buildIconWidget,
                      ),
                    );
                  },
                  ),
                ),
    );
  }

  @override
  void dispose() {
    _stopApiAvailabilityPolling();
    _refreshSubscription?.cancel();
    _refreshSubscription = null;
    _searchController.dispose();
    super.dispose();
  }
}

// Card owns its own expansion state so it survives list rebuilds without
// bubbling through the parent.

class ModelSelectionRow extends StatefulWidget {
  final CustomModelInfo model;
  final ModelProviderInfo? selectedProvider;
  final ModelPromptConfig? promptConfig;
  final bool isAutoSelected;
  final bool isFirstRow;
  final Function(ModelProviderInfo?) onProviderChanged;
  final VoidCallback? onAutoSelected;
  final VoidCallback? onEditPrompt;
  final String Function(int?) formatContextLength;
  final Widget Function(String?, IconData, {double size}) buildIconWidget;

  const ModelSelectionRow({
    super.key,
    required this.model,
    required this.selectedProvider,
    this.promptConfig,
    this.isAutoSelected = false,
    this.isFirstRow = false,
    required this.onProviderChanged,
    this.onAutoSelected,
    this.onEditPrompt,
    required this.formatContextLength,
    required this.buildIconWidget,
  });

  @override
  State<ModelSelectionRow> createState() => _ModelSelectionRowState();
}

class _ModelSelectionRowState extends State<ModelSelectionRow> {
  /// Lines shown while the description is collapsed.
  static const int _collapsedMaxLines = 1;
  bool _descriptionExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final bool isActive = widget.selectedProvider != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Base the layout on the row's OWN width, not the window's. Inside the
        // narrow settings pane the window is wide while this pane is not, which
        // is what pushed the provider pill toward the middle.
        final double availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final bool isWide = availableWidth >= kTabletBreakpoint;

        // The provider pill always sits at the right edge of the name row, so
        // provider selection stays where it has always been — far right — in
        // both the settings pane and the full model screen. Its width is
        // capped so the model name keeps at least half the row.
        final Widget pill = _ProviderPill(
          maxWidth: math.max(120.0, math.min(280.0, availableWidth * 0.5)),
          model: widget.model,
          selectedProvider: widget.selectedProvider,
          isAutoSelected: widget.isAutoSelected,
          onProviderChanged: widget.onProviderChanged,
          onAutoSelected: widget.onAutoSelected,
          buildIconWidget: widget.buildIconWidget,
        );
        final Widget keyedPill = widget.isFirstRow
            ? KeyedSubtree(
                key: TourKeyRegistry.instance
                    .keyFor(TourSlots.modelProviderPill),
                child: pill,
              )
            : pill;

        final Widget nameRow = _NameRow(
          model: widget.model,
          buildIconWidget: widget.buildIconWidget,
          promptConfig: widget.promptConfig,
          onEditPrompt: widget.onEditPrompt,
          trailing: keyedPill,
        );

        final Widget? descriptionBlock = _buildDescriptionBlock(theme, m3);
        final Widget? statsBlock = _buildStatsBlock();

        return Container(
          decoration: BoxDecoration(
            color: m3.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            border: isActive
                ? Border.all(color: colorScheme.primary, width: 2)
                : Border.all(color: Colors.transparent, width: 2),
          ),
          padding: EdgeInsets.all(isWide ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              nameRow,
              if (descriptionBlock != null) ...[
                const SizedBox(height: 10),
                descriptionBlock,
              ],
              if (statsBlock != null) ...[
                const SizedBox(height: 14),
                statsBlock,
              ],
            ],
          ),
        );
      },
    );
  }

  Widget? _buildDescriptionBlock(ThemeData theme, dynamic m3) {
    final description = widget.model.description;
    if (description == null || description.isEmpty) return null;
    final Color descColor = m3.onSurfaceVariant as Color;
    final Color primary = theme.colorScheme.primary;
    final TextStyle? descStyle =
        theme.textTheme.bodySmall?.copyWith(color: descColor, height: 1.4);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Measure at the width the text actually gets. The old rule was
        // "longer than 100 characters", which offers a Show more on a wide
        // desktop window where the whole description already fits on one
        // line — a toggle that toggles nothing.
        final TextPainter painter = TextPainter(
          text: TextSpan(text: description, style: descStyle),
          maxLines: _collapsedMaxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final bool needsToggle = painter.didExceedMaxLines;
        painter.dispose();

        if (!needsToggle) {
          return Text(description, style: descStyle);
        }

        return SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(
                  () => _descriptionExpanded = !_descriptionExpanded,
                ),
                child: Text(
                  description,
                  style: descStyle,
                  maxLines: _descriptionExpanded ? null : _collapsedMaxLines,
                  overflow: _descriptionExpanded
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 2),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(
                  () => _descriptionExpanded = !_descriptionExpanded,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _descriptionExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _descriptionExpanded ? 'Show less' : 'Show more',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget? _buildStatsBlock() {
    final provider = widget.selectedProvider;
    if (provider == null) return null;
    final List<_StatChip> chips = [
      _StatChip(
        label: 'Ctx',
        value: widget.formatContextLength(provider.contextLength),
      ),
      // Many providers do not report this — show it only when known, rather
      // than a bare "N/A" chip that says nothing.
      if (provider.maxCompletionTokens != null)
        _StatChip(
          label: 'Max output',
          value: widget.formatContextLength(provider.maxCompletionTokens),
        ),
      _StatChip(
        label: 'In',
        value: provider.pricing.formatTokenPrice(provider.pricing.prompt),
      ),
      _StatChip(
        label: 'Out',
        value: provider.pricing.formatTokenPrice(provider.pricing.completion),
      ),
      if (provider.pricing.request > 0)
        _StatChip(
          label: 'Req',
          value: provider.pricing.formatRequestPrice(provider.pricing.request),
        ),
      if (provider.isModerated != null)
        _StatChip(
          label: 'Moderated',
          value: provider.isModerated! ? 'Yes' : 'No',
        ),
    ];
    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }
}

class _NameRow extends StatelessWidget {
  final CustomModelInfo model;
  final Widget Function(String?, IconData, {double size}) buildIconWidget;
  final ModelPromptConfig? promptConfig;
  final VoidCallback? onEditPrompt;
  final Widget trailing;

  const _NameRow({
    required this.model,
    required this.buildIconWidget,
    required this.trailing,
    this.promptConfig,
    this.onEditPrompt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l = AppLocalizations.of(context);
    final bool hasPromptConfig =
        promptConfig != null && promptConfig!.isActive;
    final Color promptIconColor =
        hasPromptConfig ? colorScheme.primary : theme.m3.onSurfaceVariant;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        buildIconWidget(model.iconUrl, Icons.psychology_alt, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            model.name,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Flexible so the provider pill shrinks (and its label ellipsizes)
        // instead of overflowing the row in a narrow settings pane.
        // Push the provider pill hard against the right edge. Without the
        // Align it sits at the LEFT of its flex box (name Expanded + pill
        // Flexible split the row), leaving a gap to the right.
        Flexible(
          child: Align(alignment: Alignment.centerRight, child: trailing),
        ),
        // The set-system-prompt button is the very last element — to the
        // right of the provider pill, at the far right of the row.
        if (onEditPrompt != null) ...[
          const SizedBox(width: 4),
          IconButton(
            tooltip: hasPromptConfig
                ? (l?.perModelPromptEditConfigured ?? 'Edit system prompt')
                : (l?.perModelPromptEdit ?? 'Set system prompt'),
            visualDensity: VisualDensity.compact,
            icon: Icon(
              hasPromptConfig
                  ? Icons.edit_note
                  : Icons.note_alt_outlined,
              color: promptIconColor,
              size: 20,
            ),
            onPressed: onEditPrompt,
          ),
        ],
      ],
    );
  }
}

class _ProviderPill extends StatelessWidget {
  final CustomModelInfo model;
  final ModelProviderInfo? selectedProvider;
  final bool isAutoSelected;
  final Function(ModelProviderInfo?) onProviderChanged;
  final VoidCallback? onAutoSelected;
  final Widget Function(String?, IconData, {double size}) buildIconWidget;

  /// Overrides the derived cap on the closed face's width.
  final double? maxWidth;

  static const String _kDisabledValue = '__disabled__';

  const _ProviderPill({
    this.maxWidth,
    required this.model,
    required this.selectedProvider,
    this.isAutoSelected = false,
    required this.onProviderChanged,
    this.onAutoSelected,
    required this.buildIconWidget,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final bool hasMultipleProviders = model.providers.length > 1;

    // Closed face is sized to its own content (Container + Row with
    // mainAxisSize.min), capped to pillWidth so a long provider name
    // ellipsizes instead of pushing the model name off narrow phones.
    // The open menu is independently wider (BoxConstraints below) so the
    // full provider names + prices stay readable — a plain DropdownButton
    // can't do that since its closed face and menu share one width.
    final double screenWidth = MediaQuery.of(context).size.width;
    final double pillMaxWidth = maxWidth ??
        (screenWidth < 400 ? math.max(140.0, screenWidth - 200.0) : 280.0);
    final double menuWidth =
        math.min(340.0, screenWidth - 48.0).clamp(220.0, 340.0).toDouble();

    return Theme(
      data: theme.copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: PopupMenuButton<String>(
        color: m3.surfaceContainerHigh,
        constraints: BoxConstraints.tightFor(width: menuWidth),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        onSelected: (value) {
          if (value == _kDisabledValue) {
            onProviderChanged(null);
            return;
          }
          if (value == kAutoCheapestProviderSlug) {
            onAutoSelected?.call();
            return;
          }
          for (final p in model.providers) {
            if (p.slug == value) {
              onProviderChanged(p);
              return;
            }
          }
        },
        itemBuilder: (ctx) => [
          PopupMenuItem<String>(
            value: _kDisabledValue,
            height: 40,
            child: _buildDisabledDisplay(ctx),
          ),
          if (hasMultipleProviders)
            PopupMenuItem<String>(
              value: kAutoCheapestProviderSlug,
              height: 44,
              child: _buildAutoDisplay(
                ctx,
                cheapest: _cheapestProvider(),
                isSelected: isAutoSelected,
                isMenuItem: true,
              ),
            ),
          ...model.providers.map(
            (provider) => PopupMenuItem<String>(
              value: provider.slug,
              height: 44,
              child: _buildProviderDisplay(
                ctx,
                provider,
                isSelected:
                    !isAutoSelected && selectedProvider?.slug == provider.slug,
                showPrice: true,
              ),
            ),
          ),
        ],
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: pillMaxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: m3.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCollapsedFace(context),
                const SizedBox(width: 2),
                Icon(Icons.arrow_drop_down, color: m3.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Compact face shown when the pill is closed — only the current selection
  /// (icon + label), label ellipsized. Width follows content, unlike the
  /// wider open menu.
  Widget _buildCollapsedFace(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: m3.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );

    final Widget iconWidget;
    final String label;
    if (isAutoSelected) {
      iconWidget = Icon(Icons.bolt, color: m3.onSurfaceVariant, size: 16);
      label = 'Auto';
    } else if (selectedProvider != null) {
      iconWidget =
          buildIconWidget(selectedProvider!.iconUrl, Icons.business, size: 16);
      label = selectedProvider!.name;
    } else {
      iconWidget = Icon(Icons.block, color: m3.onSurfaceVariant, size: 16);
      label = 'Disabled';
    }

    return Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }

  ModelProviderInfo? _cheapestProvider() {
    if (model.providers.isEmpty) return null;
    ModelProviderInfo best = model.providers.first;
    for (final p in model.providers.skip(1)) {
      if (p.pricing.completion < best.pricing.completion) best = p;
    }
    return best;
  }

  Widget _buildDisabledDisplay(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.block, color: m3.onSurfaceVariant, size: 16),
        const SizedBox(width: 6),
        Text(
          'Disabled',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: m3.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
        ),
      ],
    );
  }

  Widget _buildAutoDisplay(
    BuildContext context, {
    required ModelProviderInfo? cheapest,
    required bool isSelected,
    required bool isMenuItem,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;
    final Color textColor =
        isSelected ? colorScheme.primary : colorScheme.onSurface;

    // Fix B.2: shorten the selected (collapsed) pill label so the model
    // name in the surrounding row stays visible on narrow phones. The
    // dropdown menu items still show the full "Auto (cheapest) —
    // currently: <provider>" so users see what they're picking; only the
    // pill's collapsed face is abbreviated to "Auto" (the bolt icon next
    // to it carries the "auto" semantic).
    final String label = (cheapest != null && isMenuItem)
        ? l.autoCheapestCurrently(
            cheapest.name,
            cheapest.pricing.formatTokenPrice(cheapest.pricing.completion),
          )
        : (isMenuItem ? l.autoCheapest : 'Auto');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.bolt, color: textColor, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (isMenuItem && cheapest != null)
                Text(
                  _formatInOutPrice(cheapest),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: m3.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProviderDisplay(
    BuildContext context,
    ModelProviderInfo provider, {
    required bool isSelected,
    required bool showPrice,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final Color textColor =
        isSelected ? colorScheme.primary : colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        buildIconWidget(provider.iconUrl, Icons.business, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                provider.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (showPrice)
                Text(
                  _formatInOutPrice(provider),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: m3.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatInOutPrice(ModelProviderInfo provider) {
    final inPrice = provider.pricing.formatTokenPrice(provider.pricing.prompt);
    final outPrice =
        provider.pricing.formatTokenPrice(provider.pricing.completion);
    return '$inPrice in · $outPrice out';
  }
}

class _AuthRequiredException implements Exception {
  const _AuthRequiredException();
}

// ─── Reusable private pieces ─────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final bool hasQuery;

  const _SearchField({
    required this.controller,
    required this.hintText,
    required this.hasQuery,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    return TextField(
      controller: controller,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: m3.onSurfaceVariant,
        ),
        prefixIcon: Icon(
          Icons.search,
          color: m3.onSurfaceVariant,
          size: 20,
        ),
        suffixIcon: hasQuery
            ? IconButton(
                icon: Icon(
                  Icons.clear,
                  color: m3.onSurfaceVariant,
                  size: 20,
                ),
                onPressed: controller.clear,
              )
            : null,
        filled: true,
        fillColor: m3.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }
}

/// One mode's data for the picker panel.
class _ModeRowData {
  final IconData icon;
  final String title;
  final String modelId;
  final String? modelName;
  final String reasoningEffort;
  final List<String> reasoningLevels;

  /// The provider slug the mode's model is currently pinned to.
  final String providerSlug;

  /// The providers the mode's currently-selected model offers.
  final List<ModelProviderInfo> providers;

  final ValueChanged<String> onPickModel;
  final ValueChanged<String> onPickReasoning;
  final ValueChanged<String> onPickProvider;

  const _ModeRowData({
    required this.icon,
    required this.title,
    required this.modelId,
    required this.modelName,
    required this.reasoningEffort,
    required this.reasoningLevels,
    required this.providerSlug,
    required this.providers,
    required this.onPickModel,
    required this.onPickReasoning,
    required this.onPickProvider,
  });
}

/// The panel at the top of the model screen that assigns a model, a provider
/// AND a reasoning level to each chat mode. Fast and Thinking each get their
/// own card, laid out side by side when there is room, using the same anchored
/// dropdown menu as the provider picker on the cards below.
class _ModePickerPanel extends StatelessWidget {
  final List<CustomModelInfo> models;
  final _ModeRowData fast;
  final _ModeRowData thinking;
  final Widget Function(String?, IconData, {double size}) buildIconWidget;

  /// Below this available width the two cards stack instead of sitting side
  /// by side — the narrow settings pane never squeezes them into a strip.
  static const double _sideBySideMinWidth = 460;

  const _ModePickerPanel({
    required this.models,
    required this.fast,
    required this.thinking,
    required this.buildIconWidget,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final bool sideBySide = availableWidth >= _sideBySideMinWidth;
        final Widget fastCard = _modeCard(context, fast);
        final Widget thinkingCard = _modeCard(context, thinking);
        if (sideBySide) {
          // IntrinsicHeight bounds the Row's (otherwise unbounded, inside a
          // ListView) cross-axis extent, so `stretch` matches both card
          // heights instead of forcing an infinite height on their children.
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: fastCard),
                const SizedBox(width: 12),
                Expanded(child: thinkingCard),
              ],
            ),
          );
        }
        return Column(
          children: [
            fastCard,
            const SizedBox(height: 12),
            thinkingCard,
          ],
        );
      },
    );
  }

  Widget _modeCard(BuildContext context, _ModeRowData data) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final bool canReason = data.reasoningLevels.length > 1;
    final bool hasProviderChoice = data.providers.length > 1;
    final bool hasSingleProvider = data.providers.length == 1;

    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(data.icon, size: 20, color: m3.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  data.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          _labelledRow(context, 'Model', _modelMenu(context, data)),
          if (hasProviderChoice)
            _labelledRow(context, 'Provider', _providerMenu(context, data))
          else if (hasSingleProvider)
            _labelledRow(
              context,
              'Provider',
              _staticValue(context, data.providers.first.name),
            ),
          if (canReason)
            _labelledRow(context, 'Reasoning', _reasoningMenu(context, data)),
        ],
      ),
    );
  }

  /// A settings-style row inside a mode card: a quiet label on the left, its
  /// control on the right. The two columns line up across the rows so the two
  /// cards read as clean matched columns.
  Widget _labelledRow(BuildContext context, String label, Widget control) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: control,
            ),
          ),
        ],
      ),
    );
  }

  /// A read-only value on the right of a labelled row, for a model that offers
  /// exactly one provider (nothing to choose).
  Widget _staticValue(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _providerMenu(BuildContext context, _ModeRowData data) {
    String label = data.providerSlug;
    for (final provider in data.providers) {
      if (provider.slug == data.providerSlug) {
        label = provider.name;
        break;
      }
    }
    if (label.isEmpty) label = 'Auto';
    return _menuPill<String>(
      context,
      label: label,
      onSelected: data.onPickProvider,
      itemBuilder: (ctx) => [
        for (final provider in data.providers)
          _menuRow(
            ctx,
            value: provider.slug,
            label: provider.name,
            selected: provider.slug == data.providerSlug,
            leading: buildIconWidget(
              provider.iconUrl,
              Icons.business,
              size: 18,
            ),
          ),
      ],
    );
  }

  Widget _modelMenu(BuildContext context, _ModeRowData data) {
    final label = data.modelName == null
        ? 'Loading…'
        : ChatModeSelector.stripLabPrefix(data.modelName!);
    return _menuPill<String>(
      context,
      label: label,
      onSelected: data.onPickModel,
      itemBuilder: (ctx) => [
        for (final model in models)
          _menuRow(
            ctx,
            value: model.id,
            label: ChatModeSelector.stripLabPrefix(model.name),
            selected: model.id == data.modelId,
            leading: buildIconWidget(
              model.iconUrl,
              Icons.psychology_alt,
              size: 18,
            ),
          ),
      ],
    );
  }

  Widget _reasoningMenu(BuildContext context, _ModeRowData data) {
    return _menuPill<String>(
      context,
      label: ChatModeService.reasoningLabel(data.reasoningEffort),
      subtle: true,
      onSelected: data.onPickReasoning,
      itemBuilder: (ctx) => [
        for (final level in data.reasoningLevels)
          _menuRow(
            ctx,
            value: level,
            label: ChatModeService.reasoningLabel(level),
            selected: level == data.reasoningEffort,
          ),
      ],
    );
  }

  PopupMenuItem<String> _menuRow(
    BuildContext context, {
    required String value,
    required String label,
    required bool selected,
    Widget? leading,
  }) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 10)],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color:
                    selected ? theme.colorScheme.primary : m3.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          if (selected)
            Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
        ],
      ),
    );
  }

  Widget _menuPill<T>(
    BuildContext context, {
    required String label,
    required PopupMenuItemBuilder<T> itemBuilder,
    required ValueChanged<T> onSelected,
    bool subtle = false,
  }) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Theme(
      data: theme.copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: PopupMenuButton<T>(
        color: m3.surfaceContainerHigh,
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        onSelected: onSelected,
        itemBuilder: itemBuilder,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: m3.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: m3.onSurfaceVariant,
                      fontWeight: subtle ? FontWeight.w500 : FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.arrow_drop_down,
                  color: m3.onSurfaceVariant,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A three-way pill toggle above the model list: All / Active / Inactive.
/// Styled to match the page's pills — a filled track with the selected
/// segment lit in the primary colour.
class _ListFilterBar extends StatelessWidget {
  final _ModelListFilter value;
  final ValueChanged<_ModelListFilter> onChanged;

  const _ListFilterBar({required this.value, required this.onChanged});

  static String _labelFor(_ModelListFilter f) {
    switch (f) {
      case _ModelListFilter.all:
        return 'All';
      case _ModelListFilter.active:
        return 'Active';
      case _ModelListFilter.inactive:
        return 'Inactive';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          for (final f in _ModelListFilter.values)
            Expanded(child: _segment(context, f)),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, _ModelListFilter f) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final bool selected = f == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _labelFor(f),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: selected
                ? theme.colorScheme.onPrimary
                : m3.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: m3.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 11.5,
            color: m3.onSurfaceVariant,
            letterSpacing: 0.1,
          ),
          children: [
            TextSpan(text: label),
            const TextSpan(text: '  '),
            TextSpan(
              text: value,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11.5,
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
