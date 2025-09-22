// lib/model_selector_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_svg/flutter_svg.dart'; // Import for SVG support

// Import your app constants for colors and theme
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the new extension

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
    return '\$${priceStr}/M';
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
    List<ModelProviderInfo> providers =
        providersList.map((i) => ModelProviderInfo.fromJson(i)).toList();

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
  final String _baseUrl = 'https://api.chuk.chat'; // <--- IMPORTANT: SET YOUR FASTAPI SERVER URL HERE
  List<CustomModelInfo> _models = [];
  Map<String, ModelProviderInfo?> _selectedProviders = {};
  bool _isLoading = true;
  String? _error;
  final Map<String, bool> _expandedDescriptions = {};

  @override
  void initState() {
    super.initState();
    _fetchModels();
  }

  Future<void> _fetchModels() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _selectedProviders.clear();
      _expandedDescriptions.clear();
    });

    try {
      final response = await http.get(Uri.parse('$_baseUrl/models_info'));

      if (response.statusCode == 200) {
        List<dynamic> modelsJson = json.decode(response.body);
        List<CustomModelInfo> fetchedModels =
            modelsJson.map((json) => CustomModelInfo.fromJson(json)).toList();

        Map<String, ModelProviderInfo?> initialSelections = {};
        for (var model in fetchedModels) {
          initialSelections[model.id] =
              model.providers.isNotEmpty ? model.providers.first : null;
          _expandedDescriptions[model.id] = false;
        }

        setState(() {
          _models = fetchedModels;
          _selectedProviders = initialSelections;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load models: ${response.statusCode} - ${response.body}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error fetching models: $e';
        _isLoading = false;
      });
    }
  }

  void _onProviderSelect(String modelId, ModelProviderInfo? provider) {
    setState(() {
      _selectedProviders[modelId] = provider;
    });
  }

  void _toggleDescription(String modelId) {
    setState(() {
      _expandedDescriptions[modelId] = !(_expandedDescriptions[modelId] ?? false);
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
  Widget _buildIconWidget(String? imageUrl, IconData fallbackIcon, {double size = 24}) {
    final Color iconFg = Theme.of(context).iconTheme.color!;
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
                child: Icon(Icons.downloading, color: iconFg.lighten(0.3), size: size / 2)),
          ),
        );
      } else {
        return Image.network(
          imageUrl,
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            print('Error loading image from $imageUrl: $error');
            return Icon(fallbackIcon, color: iconFg.lighten(0.3), size: size); // Fallback icon is tinted
          },
        );
      }
    } else {
      // Fallback to Icon if URL is null or empty
      return Icon(fallbackIcon, color: iconFg.lighten(0.3), size: size); // Fallback icon is tinted
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access theme colors dynamically
    final Color scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final TextStyle? titleTextStyle = Theme.of(context).appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Models', style: titleTextStyle), // Use theme's title text style
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
                        const Icon(Icons.error_outline,
                            color: Colors.red, size: 50),
                        const SizedBox(height: 16),
                        Text(
                          'Error: $_error',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: iconFg, fontSize: 18),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _fetchModels,
                          icon: Icon(Icons.refresh, color: scaffoldBg), // Text color on button
                          label: Text('Retry', style: TextStyle(color: scaffoldBg)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: iconFg, // Button background color
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
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
                        bool isDescriptionExpanded = _expandedDescriptions[model.id] ?? false;

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
                              iconFgColor: iconFg,   // Pass iconFg to row
                              bgColor: scaffoldBg, // Pass bg to row
                            ),
                            if (model.description != null && model.description!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 8.0, right: 8.0, top: 4.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    GestureDetector(
                                      onTap: () => _toggleDescription(model.id),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
                                        decoration: BoxDecoration(
                                          color: scaffoldBg.darken(0.05),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: iconFg.withOpacity(0.3)),
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
                                              isDescriptionExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
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
                                          border: Border.all(color: iconFg.withOpacity(0.3)),
                                        ),
                                        child: Text(
                                          model.description!,
                                          style: TextStyle(
                                              color: iconFg.lighten(0.3),
                                              fontSize: 12,
                                              height: 1.4),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 16),
                          ],
                        );
                      }).toList(),
                      const SizedBox(height: 16),
                      Center(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            String summary = 'Current Selections:\n';
                            _selectedProviders.forEach((modelId, provider) {
                              CustomModelInfo? model = _models.firstWhere(
                                  (m) => m.id == modelId,
                                  orElse: () => CustomModelInfo(id: '', name: 'Unknown', providers: []));

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
                                content: Text(summary),
                                backgroundColor: accent,
                                duration: const Duration(seconds: 5),
                              ),
                            );
                          },
                          icon: Icon(Icons.check_circle_outline, color: scaffoldBg), // Text color on button
                          label: Text('Confirm Selections', style: TextStyle(color: scaffoldBg)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: iconFg, // Button background color
                            padding: const EdgeInsets.symmetric(
                                horizontal: 32, vertical: 16),
                            textStyle:
                                const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
}

// Widget to represent a single row for model, provider, and data
class ModelSelectionRow extends StatelessWidget {
  final CustomModelInfo model;
  final ModelProviderInfo? selectedProvider;
  final Function(ModelProviderInfo?) onProviderChanged;
  final String Function(int?) formatContextLength;
  final Widget Function(String?, IconData, {double size}) buildIconWidget;
  final Color accentColor; // New
  final Color iconFgColor;   // New
  final Color bgColor;     // New

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
    const double containerHeight = 60.0; // Consistent height for all main fields

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Column 1: Model Name with Icon (One line)
          Expanded(
            flex: 3,
            child: Container(
              height: containerHeight,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              decoration: BoxDecoration(
                color: inputFieldBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: iconFgColor.withOpacity(0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  buildIconWidget(model.iconUrl, Icons.psychology_alt, size: 24),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      model.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          fontSize: 14),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Column 2: Provider Dropdown with Icon (Less wide)
          Expanded(
            flex: 3,
            child: Container(
              height: containerHeight,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: inputFieldBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: iconFgColor.withOpacity(0.5)),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<ModelProviderInfo>(
                  value: selectedProvider,
                  dropdownColor: bgColor.darken(0.05).withOpacity(0.9),
                  icon: Icon(Icons.arrow_drop_down, color: iconFgColor),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: onProviderChanged,
                  isExpanded: true,
                  items: model.providers.map((provider) {
                    return DropdownMenuItem(
                      value: provider,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          buildIconWidget(provider.iconUrl, Icons.business, size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              provider.name,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: (selectedProvider?.slug == provider.slug)
                                    ? accentColor
                                    : Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  selectedItemBuilder: (context) {
                    return model.providers.map<Widget>((provider) {
                      return Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            buildIconWidget(provider.iconUrl, Icons.business, size: 18),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                provider.name,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Column 3: Price Data
          Expanded(
            flex: 4,
            child: Container(
              height: containerHeight,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10), // Adjusted vertical padding
              decoration: BoxDecoration(
                color: inputFieldBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: iconFgColor.withOpacity(0.5)),
              ),
              child: selectedProvider == null
                  ? Text(
                      'Price Details',
                      style: TextStyle(
                          color: iconFgColor.lighten(0.3).withOpacity(0.7),
                          fontSize: 12),
                      textAlign: TextAlign.center,
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center, // Center content vertically
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'In: ${selectedProvider!.pricing.formatTokenPrice(selectedProvider!.pricing.prompt)}',
                          style: TextStyle(fontSize: 11, color: iconFgColor.lighten(0.3)),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1, // Ensure single line
                        ),
                        Text(
                          'Out: ${selectedProvider!.pricing.formatTokenPrice(selectedProvider!.pricing.completion)}',
                          style: TextStyle(fontSize: 11, color: iconFgColor.lighten(0.3)),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1, // Ensure single line
                        ),
                        if (selectedProvider!.pricing.request > 0)
                          Text(
                            'Req: ${selectedProvider!.pricing.formatRequestPrice(selectedProvider!.pricing.request)}',
                            style: TextStyle(fontSize: 11, color: iconFgColor.lighten(0.3)),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1, // Ensure single line
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(width: 8),

          // Column 4: Context/Tokens Data
          Expanded(
            flex: 4,
            child: Container(
              height: containerHeight,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10), // Adjusted vertical padding
              decoration: BoxDecoration(
                color: inputFieldBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: iconFgColor.withOpacity(0.5)),
              ),
              child: selectedProvider == null
                  ? Text(
                      'Token & Context',
                      style: TextStyle(
                          color: iconFgColor.lighten(0.3).withOpacity(0.7),
                          fontSize: 12),
                      textAlign: TextAlign.center,
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center, // Center content vertically
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ctx: ${formatContextLength(selectedProvider!.contextLength)}',
                          style: TextStyle(fontSize: 11, color: iconFgColor.lighten(0.2)),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1, // Ensure single line
                        ),
                        Text(
                          'Max Out: ${formatContextLength(selectedProvider!.maxCompletionTokens)}',
                          style: TextStyle(fontSize: 11, color: iconFgColor.lighten(0.2)),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1, // Ensure single line
                        ),
                        if (selectedProvider!.isModerated != null)
                          Text(
                            'Moderated: ${selectedProvider!.isModerated! ? 'Yes' : 'No'}',
                            style: TextStyle(fontSize: 10, color: iconFgColor.lighten(0.2)), // Smaller font for moderated status
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1, // Ensure single line
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}