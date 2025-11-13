// lib/model_selector_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_svg/flutter_svg.dart'; // Import for SVG support

// Import your app constants for colors and theme
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the new extension
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/api_status_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

// --- Data Models (Mirroring your FastAPI Pydantic Models) ---

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

  // Helper to format price per million tokens
  String formatTokenPrice(double pricePerToken) {
    if (pricePerToken == 0.0) return 'Free';
    final pricePerMillion = pricePerToken * 1000000;
    String priceStr = pricePerMillion.toStringAsFixed(6);
    priceStr = priceStr.replaceAll(RegExp(r'\.?0+$'), '');
    return '\$$priceStr/M';
  }

  // Helper to format request price (not per million)
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

// --- Flutter Page Widget ---

class ModelSelectorPage extends StatefulWidget {
  const ModelSelectorPage({super.key});

  @override
  State<ModelSelectorPage> createState() => _ModelSelectorPageState();
}

class _ModelSelectorPageState extends State<ModelSelectorPage> {
  final String _baseUrl =
      'https://api.chuk.chat'; // <--- IMPORTANT: SET YOUR FASTAPI SERVER URL HERE
  List<CustomModelInfo> _models = [];
  Map<String, ModelProviderInfo?> _selectedProviders = {};
  bool _isLoading = true;
  String? _error;
  final Map<String, bool> _expandedDescriptions = {};
  Map<String, String> _lastSavedPreferences = {};
  Timer? _apiAvailabilityTimer;

  static const Duration _apiPollInterval = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _initializeModelSelections();
  }

  // Initialize model selections by loading saved preferences and fetching models
  Future<void> _initializeModelSelections() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _selectedProviders.clear();
      _expandedDescriptions.clear();
    });

    try {
      await _fetchModels();
    } on TimeoutException catch (error, stackTrace) {
      debugPrint('Model selector initialization timeout: $error');
      debugPrint('Stack trace: $stackTrace');
      await _handleApiUnavailable('Request timed out: $error');
    } on SocketException catch (error, stackTrace) {
      debugPrint('Model selector initialization network error: $error');
      debugPrint('Stack trace: $stackTrace');
      await _handleApiUnavailable('Network error: $error');
    } on HttpException catch (error, stackTrace) {
      debugPrint('Model selector initialization HTTP error: $error');
      debugPrint('Stack trace: $stackTrace');
      await _handleApiUnavailable('HTTP error: $error');
    } on FormatException catch (error, stackTrace) {
      debugPrint('Model selector initialization format error: $error');
      debugPrint('Stack trace: $stackTrace');
      await _handleApiUnavailable('Data format error: $error');
    } catch (error, stackTrace) {
      // Rethrow non-Exception/unknown errors so programming errors are not swallowed
      debugPrint('Model selector initialization unexpected error: $error');
      debugPrint('Stack trace: $stackTrace');
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
        Uri.parse('$_baseUrl/models_info'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode == 200) {
        _stopApiAvailabilityPolling();
        final List<dynamic> modelsJson = json.decode(response.body);
        final List<CustomModelInfo> fetchedModels = modelsJson
            .map((json) => CustomModelInfo.fromJson(json))
            .toList();

        final Map<String, ModelProviderInfo?> initialSelections = {};
        final List<Future<void>> cleanupFutures = [];
        for (final model in fetchedModels) {
          final String? savedProviderSlug = _lastSavedPreferences[model.id];
          ModelProviderInfo? selectedProvider;

          if (savedProviderSlug != null) {
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
          _expandedDescriptions[model.id] = false;
        }

        if (cleanupFutures.isNotEmpty) {
          await Future.wait(cleanupFutures);
          _lastSavedPreferences =
              await UserPreferencesService.loadAllProviderPreferences();
        }

        if (!mounted) return;
        setState(() {
          _models = fetchedModels;
          _selectedProviders = initialSelections;
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
      await SupabaseService.signOut();
      _showSnackBar('Session expired. Please sign in again.');
    } catch (error) {
      rethrow;
    }
  }

  Future<void> _handleApiUnavailable(String debugDetails) async {
    debugPrint('Model selector API unavailable: $debugDetails');
    final bool hasConnectivity =
        await NetworkStatusService.hasInternetConnection();
    final String message = hasConnectivity
        ? 'We are currently doing maintenance and will be right back.'
        : 'You appear to be offline. Please check your internet connection.';
    if (!mounted) return;
    setState(() {
      _error = message;
      _isLoading = false;
    });
    _showSnackBar(message);
    _startApiAvailabilityPolling();
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
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

  void _onProviderSelect(String modelId, ModelProviderInfo? provider) {
    setState(() {
      _selectedProviders[modelId] = provider;
    });

    if (provider != null) {
      _lastSavedPreferences[modelId] = provider.slug;
      UserPreferencesService.saveSelectedProvider(modelId, provider.slug);
    } else {
      _lastSavedPreferences.remove(modelId);
      UserPreferencesService.clearSelectedProvider(modelId);
    }

    UserPreferencesService.refreshModelSelections();
  }

  void _toggleDescription(String modelId) {
    setState(() {
      _expandedDescriptions[modelId] =
          !(_expandedDescriptions[modelId] ?? false);
    });
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

  // Widget to display an image from a URL (SVG or raster) or a fallback icon
  Widget _buildIconWidget(
    String? imageUrl,
    IconData fallbackIcon, {
    double size = 24,
  }) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
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
                color: iconFg.lighten(0.3),
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
          errorBuilder: (context, error, stackTrace) {
            debugPrint('Error loading image from $imageUrl: $error');
            return Icon(
              fallbackIcon,
              color: iconFg.lighten(0.3),
              size: size,
            ); // Fallback icon is tinted
          },
        );
      }
    } else {
      // Fallback to Icon if URL is null or empty
      return Icon(
        fallbackIcon,
        color: iconFg.lighten(0.3),
        size: size,
      ); // Fallback icon is tinted
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access theme colors dynamically
    final Color scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final TextStyle? titleTextStyle = Theme.of(
      context,
    ).appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text(
          'Models',
          style: titleTextStyle,
        ), // Use theme's title text style
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg), // Set back button color
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: iconFg))
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 50,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Error: $_error',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: iconFg, fontSize: 18),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _initializeModelSelections,
                      icon: Icon(
                        Icons.refresh,
                        color: scaffoldBg,
                      ), // Text color on button
                      label: Text('Retry', style: TextStyle(color: scaffoldBg)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: iconFg, // Button background color
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        textStyle: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._models.map((model) {
                    ModelProviderInfo? selectedProviderForModel =
                        _selectedProviders[model.id];
                    bool isDescriptionExpanded =
                        _expandedDescriptions[model.id] ?? false;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ModelSelectionRow(
                          key: ValueKey(model.id),
                          model: model,
                          selectedProvider: selectedProviderForModel,
                          onProviderChanged: (provider) =>
                              _onProviderSelect(model.id, provider),
                          formatContextLength: _formatContextLength,
                          buildIconWidget: _buildIconWidget,
                          accentColor: accent, // Pass accent to row
                          iconFgColor: iconFg, // Pass iconFg to row
                          bgColor: scaffoldBg, // Pass bg to row
                        ),
                        if (model.description != null &&
                            model.description!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(
                              left: 8.0,
                              right: 8.0,
                              top: 4.0,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                GestureDetector(
                                  onTap: () => _toggleDescription(model.id),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8.0,
                                      horizontal: 12.0,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scaffoldBg.darken(0.05),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: iconFg.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          'Description',
                                          style: TextStyle(
                                            color: iconFg.lighten(0.3),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const Spacer(),
                                        Icon(
                                          isDescriptionExpanded
                                              ? Icons.keyboard_arrow_up
                                              : Icons.keyboard_arrow_down,
                                          color: iconFg.lighten(0.3),
                                          size: 20,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (isDescriptionExpanded)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12.0),
                                    margin: const EdgeInsets.only(top: 4.0),
                                    decoration: BoxDecoration(
                                      color: scaffoldBg.darken(0.05),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: iconFg.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Text(
                                      model.description!,
                                      style: TextStyle(
                                        color: iconFg.lighten(0.3),
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 16),
                      ],
                    );
                  }),
                  const SizedBox(height: 16),
                  Center(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        String summary = 'Current Selections:\n';
                        _selectedProviders.forEach((modelId, provider) {
                          CustomModelInfo? model = _models.firstWhere(
                            (m) => m.id == modelId,
                            orElse: () => CustomModelInfo(
                              id: '',
                              name: 'Unknown',
                              providers: [],
                            ),
                          );

                          if (model.id.isNotEmpty && provider != null) {
                            summary +=
                                '- ${model.name} -> ${provider.name} (Slug: ${provider.slug})\n';
                          } else if (model.id.isNotEmpty) {
                            summary +=
                                '- ${model.name} -> No provider selected\n';
                          }
                        });

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              summary,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                            backgroundColor: accent,
                            behavior: SnackBarBehavior.floating,
                            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            duration: const Duration(seconds: 5),
                            dismissDirection: DismissDirection.horizontal,
                          ),
                        );
                      },
                      icon: Icon(
                        Icons.check_circle_outline,
                        color: scaffoldBg,
                      ), // Text color on button
                      label: Text(
                        'Confirm Selections',
                        style: TextStyle(color: scaffoldBg),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: iconFg, // Button background color
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  @override
  void dispose() {
    _stopApiAvailabilityPolling();
    super.dispose();
  }
}

// Widget to represent a single row for model, provider, and data
class ModelSelectionRow extends StatelessWidget {
  final CustomModelInfo model;
  final ModelProviderInfo? selectedProvider;
  final Function(ModelProviderInfo?) onProviderChanged;
  final String Function(int?) formatContextLength;
  final Widget Function(String?, IconData, {double size}) buildIconWidget;
  final Color accentColor; // New
  final Color iconFgColor; // New
  final Color bgColor; // New

  const ModelSelectionRow({
    super.key,
    required this.model,
    required this.selectedProvider,
    required this.onProviderChanged,
    required this.formatContextLength,
    required this.buildIconWidget,
    required this.accentColor,
    required this.iconFgColor,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    final Color inputFieldBg = bgColor.lighten(0.05);
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isCompact = constraints.maxWidth < 600;
        if (isCompact) {
          return _buildMobileLayout(inputFieldBg);
        }
        return _buildDesktopLayout(inputFieldBg);
      },
    );
  }

  Widget _buildDesktopLayout(Color inputFieldBg) {
    const double containerHeight = 78.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: _buildModelNameCard(
                containerHeight,
                inputFieldBg,
                alignCenter: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: _buildProviderCard(
                containerHeight,
                inputFieldBg,
                alignCenter: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: _buildPriceCard(containerHeight, inputFieldBg),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: _buildContextCard(containerHeight, inputFieldBg),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout(Color inputFieldBg) {
    const double cardHeight = 98.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildModelNameCard(
                  cardHeight,
                  inputFieldBg,
                  alignCenter: false,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildProviderCard(
                  cardHeight,
                  inputFieldBg,
                  alignCenter: false,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _buildPriceCard(cardHeight, inputFieldBg)),
              const SizedBox(width: 8),
              Expanded(child: _buildContextCard(cardHeight, inputFieldBg)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModelNameCard(
    double height,
    Color inputFieldBg, {
    required bool alignCenter,
  }) {
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: inputFieldBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: iconFgColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: alignCenter
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Text(
            'Model',
            style: TextStyle(
              color: iconFgColor.lighten(0.25),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: alignCenter
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              buildIconWidget(model.iconUrl, Icons.psychology_alt, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  model.name,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: iconFgColor,
                    fontSize: 14,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProviderCard(
    double height,
    Color inputFieldBg, {
    required bool alignCenter,
  }) {
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: inputFieldBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: iconFgColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: alignCenter
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Text(
            'Provider',
            style: TextStyle(
              color: iconFgColor.lighten(0.25),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<ModelProviderInfo?>(
                value: selectedProvider,
                dropdownColor: bgColor.darken(0.05).withValues(alpha: 0.9),
                icon: Icon(Icons.arrow_drop_down, color: iconFgColor),
                style: TextStyle(color: iconFgColor, fontSize: 13),
                onChanged: onProviderChanged,
                isExpanded: true,
                hint: _buildDisabledSelectedDisplay(alignCenter),
                items: [
                  DropdownMenuItem<ModelProviderInfo?>(
                    value: null,
                    child: _buildDisabledMenuItem(alignCenter),
                  ),
                  ...model.providers.map(
                    (provider) => DropdownMenuItem<ModelProviderInfo?>(
                      value: provider,
                      child: _buildProviderMenuItem(
                        provider,
                        alignCenter,
                        isSelected: selectedProvider?.slug == provider.slug,
                      ),
                    ),
                  ),
                ],
                selectedItemBuilder: (context) {
                  final items = <Widget>[
                    _wrapSelectedBuilderChild(
                      _buildDisabledSelectedDisplay(alignCenter),
                      alignCenter,
                    ),
                    ...model.providers.map(
                      (provider) => _wrapSelectedBuilderChild(
                        _buildProviderSelectedDisplay(provider, alignCenter),
                        alignCenter,
                      ),
                    ),
                  ];
                  return items;
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wrapSelectedBuilderChild(Widget child, bool alignCenter) {
    return alignCenter
        ? Center(child: child)
        : Align(alignment: Alignment.centerLeft, child: child);
  }

  Widget _buildDisabledMenuItem(bool alignCenter) {
    return Row(
      mainAxisAlignment: alignCenter
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Icon(Icons.block, color: iconFgColor.withValues(alpha: 0.6), size: 16),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Disabled',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: iconFgColor.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
            textAlign: alignCenter ? TextAlign.center : TextAlign.left,
          ),
        ),
      ],
    );
  }

  Widget _buildProviderMenuItem(
    ModelProviderInfo provider,
    bool alignCenter, {
    required bool isSelected,
  }) {
    final Color textColor = isSelected ? accentColor : iconFgColor;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: alignCenter
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        buildIconWidget(provider.iconUrl, Icons.business, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            provider.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
            textAlign: alignCenter ? TextAlign.center : TextAlign.left,
          ),
        ),
      ],
    );
  }

  Widget _buildDisabledSelectedDisplay(bool alignCenter) {
    return Row(
      mainAxisAlignment: alignCenter
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Icon(Icons.block, color: iconFgColor.withValues(alpha: 0.6), size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'Disabled',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignCenter ? TextAlign.center : TextAlign.left,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: iconFgColor.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProviderSelectedDisplay(
    ModelProviderInfo provider,
    bool alignCenter,
  ) {
    return Row(
      mainAxisAlignment: alignCenter
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        buildIconWidget(provider.iconUrl, Icons.business, size: 18),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            provider.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: alignCenter ? TextAlign.center : TextAlign.left,
            style: TextStyle(fontWeight: FontWeight.w500, color: iconFgColor),
          ),
        ),
      ],
    );
  }

  Widget _buildPriceCard(double height, Color inputFieldBg) {
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: inputFieldBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: iconFgColor.withValues(alpha: 0.5)),
      ),
      child: selectedProvider == null
          ? Center(
              child: Text(
                'Pricing',
                style: TextStyle(
                  color: iconFgColor.lighten(0.3).withValues(alpha: 0.7),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pricing',
                  style: TextStyle(
                    color: iconFgColor.lighten(0.25),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'In: ${selectedProvider!.pricing.formatTokenPrice(selectedProvider!.pricing.prompt)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: iconFgColor.lighten(0.3),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                Text(
                  'Out: ${selectedProvider!.pricing.formatTokenPrice(selectedProvider!.pricing.completion)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: iconFgColor.lighten(0.3),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                if (selectedProvider!.pricing.request > 0)
                  Text(
                    'Req: ${selectedProvider!.pricing.formatRequestPrice(selectedProvider!.pricing.request)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: iconFgColor.lighten(0.3),
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
              ],
            ),
    );
  }

  Widget _buildContextCard(double height, Color inputFieldBg) {
    return Container(
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: inputFieldBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: iconFgColor.withValues(alpha: 0.5)),
      ),
      child: selectedProvider == null
          ? Center(
              child: Text(
                'Capabilities',
                style: TextStyle(
                  color: iconFgColor.lighten(0.3).withValues(alpha: 0.7),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Capabilities',
                  style: TextStyle(
                    color: iconFgColor.lighten(0.25),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Ctx: ${formatContextLength(selectedProvider!.contextLength)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: iconFgColor.lighten(0.2),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                Text(
                  'Max Out: ${formatContextLength(selectedProvider!.maxCompletionTokens)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: iconFgColor.lighten(0.2),
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                if (selectedProvider!.isModerated != null)
                  Text(
                    'Moderated: ${selectedProvider!.isModerated! ? 'Yes' : 'No'}',
                    style: TextStyle(
                      fontSize: 10,
                      color: iconFgColor.lighten(0.2),
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
              ],
            ),
    );
  }
}

class _AuthRequiredException implements Exception {
  const _AuthRequiredException();
}
