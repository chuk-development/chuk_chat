// lib/model_selector_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/api_status_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
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
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  static const Duration _apiPollInterval = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
    _initializeModelSelections();
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
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  // +2 header slots: search field + section header.
                  itemCount: _filteredModels.length + 2,
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
                      final label = _searchQuery.isEmpty
                          ? 'AVAILABLE · ${_filteredModels.length} MODELS'
                          : '${_filteredModels.length} MODEL${_filteredModels.length == 1 ? '' : 'S'} FOUND';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _SectionHeader(label),
                      );
                    }
                    final model = _filteredModels[index - 2];
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
    );
  }

  @override
  void dispose() {
    _stopApiAvailabilityPolling();
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
  static const int _descriptionToggleThreshold = 100;
  bool _descriptionExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final bool isActive = widget.selectedProvider != null;
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isDesktop = screenWidth >= kTabletBreakpoint;

    final Widget nameRow = _NameRow(
      model: widget.model,
      buildIconWidget: widget.buildIconWidget,
      promptConfig: widget.promptConfig,
      onEditPrompt: widget.onEditPrompt,
      trailing: _ProviderPill(
        model: widget.model,
        selectedProvider: widget.selectedProvider,
        isAutoSelected: widget.isAutoSelected,
        onProviderChanged: widget.onProviderChanged,
        onAutoSelected: widget.onAutoSelected,
        buildIconWidget: widget.buildIconWidget,
      ),
    );

    final Widget? descriptionBlock = _buildDescriptionBlock(theme, m3);
    final Widget? statsBlock = _buildStatsBlock();

    final List<Widget> mobileChildren = <Widget>[
      nameRow,
      if (descriptionBlock != null) ...[
        const SizedBox(height: 10),
        descriptionBlock,
      ],
      if (statsBlock != null) ...[
        const SizedBox(height: 12),
        statsBlock,
      ],
    ];

    // Desktop reuses the same pieces but gives the stats a tighter right
    // column so the header doesn't feel crammed.
    final List<Widget> desktopChildren = <Widget>[
      nameRow,
      if (descriptionBlock != null) ...[
        const SizedBox(height: 10),
        descriptionBlock,
      ],
      if (statsBlock != null) ...[
        const SizedBox(height: 14),
        statsBlock,
      ],
    ];

    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: isActive
            ? Border.all(color: colorScheme.primary, width: 2)
            : Border.all(color: Colors.transparent, width: 2),
      ),
      padding: EdgeInsets.all(isDesktop ? 20 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: isDesktop ? desktopChildren : mobileChildren,
      ),
    );
  }

  Widget? _buildDescriptionBlock(ThemeData theme, dynamic m3) {
    final description = widget.model.description;
    if (description == null || description.isEmpty) return null;
    final bool needsToggle = description.length > _descriptionToggleThreshold;
    final Color descColor = m3.onSurfaceVariant as Color;
    final Color primary = theme.colorScheme.primary;

    if (!needsToggle) {
      return Text(
        description,
        style:
            theme.textTheme.bodySmall?.copyWith(color: descColor, height: 1.4),
      );
    }

    final TextStyle? descStyle =
        theme.textTheme.bodySmall?.copyWith(color: descColor, height: 1.4);

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                setState(() => _descriptionExpanded = !_descriptionExpanded),
            child: Text(
              description,
              style: descStyle,
              maxLines: _descriptionExpanded ? null : 1,
              overflow: _descriptionExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 2),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                setState(() => _descriptionExpanded = !_descriptionExpanded),
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
  }

  Widget? _buildStatsBlock() {
    final provider = widget.selectedProvider;
    if (provider == null) return null;
    final List<_StatChip> chips = [
      _StatChip(
        label: 'Ctx',
        value: widget.formatContextLength(provider.contextLength),
      ),
      _StatChip(
        label: 'Max Out',
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
          const SizedBox(width: 4),
        ],
        trailing,
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

  static const String _kDisabledValue = '__disabled__';

  const _ProviderPill({
    required this.model,
    required this.selectedProvider,
    this.isAutoSelected = false,
    required this.onProviderChanged,
    this.onAutoSelected,
    required this.buildIconWidget,
  });

  String get _selectedValue {
    if (isAutoSelected) return kAutoCheapestProviderSlug;
    final p = selectedProvider;
    return p == null ? _kDisabledValue : p.slug;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final bool hasMultipleProviders = model.providers.length > 1;

    // Fixed column width keeps provider pills visually aligned across all
    // cards. Wide enough to fit "Auto (cheapest) — currently: <Provider>"
    // and the two-line "$X.XX/M in · $Y.YY/M out" price subtitle without
    // truncation.
    return SizedBox(
      width: 280,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: m3.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedValue,
          dropdownColor: m3.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          isExpanded: true,
          icon: Icon(
            Icons.arrow_drop_down,
            color: m3.onSurfaceVariant,
          ),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurface,
          ),
          onChanged: (value) {
            if (value == null || value == _kDisabledValue) {
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
          isDense: true,
          hint: _buildDisabledDisplay(context),
          items: [
            DropdownMenuItem<String>(
              value: _kDisabledValue,
              child: _buildDisabledDisplay(context),
            ),
            if (hasMultipleProviders)
              DropdownMenuItem<String>(
                value: kAutoCheapestProviderSlug,
                child: _buildAutoDisplay(
                  context,
                  cheapest: _cheapestProvider(),
                  isSelected: isAutoSelected,
                  isMenuItem: true,
                ),
              ),
            ...model.providers.map(
              (provider) => DropdownMenuItem<String>(
                value: provider.slug,
                child: _buildProviderDisplay(
                  context,
                  provider,
                  isSelected:
                      !isAutoSelected && selectedProvider?.slug == provider.slug,
                  showPrice: true,
                ),
              ),
            ),
          ],
          selectedItemBuilder: (ctx) {
            return [
              _buildDisabledDisplay(ctx),
              if (hasMultipleProviders)
                _buildAutoDisplay(
                  ctx,
                  cheapest: _cheapestProvider(),
                  isSelected: true,
                  isMenuItem: false,
                ),
              ...model.providers.map(
                (provider) => _buildProviderDisplay(
                  ctx,
                  provider,
                  isSelected: true,
                  showPrice: false,
                ),
              ),
            ];
          },
        ),
      ),
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

    final String label = (cheapest != null && isMenuItem)
        ? l.autoCheapestCurrently(
            cheapest.name,
            cheapest.pricing.formatTokenPrice(cheapest.pricing.completion),
          )
        : l.autoCheapest;

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
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          color: colorScheme.primary,
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
