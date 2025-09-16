import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Import for SystemUiOverlayStyle
import 'package:http/http.dart' as http;

// --- Data Models (Mirroring your FastAPI Pydantic Models) ---

class PricingDetails {
  final double prompt;
  final double completion;
  final double request;

  PricingDetails({
    required this.prompt,
    required this.completion,
    required this.request,
  });

  factory PricingDetails.fromJson(Map<String, dynamic> json) {
    return PricingDetails(
      prompt: (json['prompt'] as num?)?.toDouble() ?? 0.0,
      completion: (json['completion'] as num?)?.toDouble() ?? 0.0,
      request: (json['request'] as num?)?.toDouble() ?? 0.0,
    );
  }

  // Helper to format price per million tokens
  String formatTokenPrice(double pricePerToken) {
    if (pricePerToken == 0.0) return 'Free';
    final pricePerMillion = pricePerToken * 1000000;
    // Format to 3 decimal places, remove trailing zeros, and trailing dot if it becomes integer
    String priceStr = pricePerMillion.toStringAsFixed(6); // Start with enough precision
    priceStr = priceStr.replaceAll(RegExp(r'\.?0+$'), ''); // Remove trailing .000 or .00 etc.
    return '\$${priceStr}/M';
  }

  // Helper to format request price (not per million)
  String formatRequestPrice(double price) {
    if (price == 0.0) return 'Free';
    return '\$${price.toStringAsFixed(3)}/req'; // Formatted to 3 decimal places for request price
  }
}

class ModelProviderInfo {
  final String slug;
  final String name;
  final PricingDetails pricing;
  final int? contextLength;
  final int? maxCompletionTokens;

  ModelProviderInfo({
    required this.slug,
    required this.name,
    required this.pricing,
    this.contextLength,
    this.maxCompletionTokens,
  });

  factory ModelProviderInfo.fromJson(Map<String, dynamic> json) {
    return ModelProviderInfo(
      slug: json['slug'] as String,
      name: json['name'] as String,
      pricing: PricingDetails.fromJson(json['pricing'] as Map<String, dynamic>),
      contextLength: json['context_length'] as int?,
      maxCompletionTokens: json['max_completion_tokens'] as int?,
    );
  }
}

class CustomModelInfo {
  final String id;
  final String name;
  final String? description;
  final List<ModelProviderInfo> providers;

  CustomModelInfo({
    required this.id,
    required this.name,
    this.description,
    required this.providers,
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
  final String _baseUrl = 'http://127.0.0.1:8000'; // <--- IMPORTANT: SET YOUR FASTAPI SERVER URL HERE
  List<CustomModelInfo> _models = [];
  CustomModelInfo? _selectedModel;
  ModelProviderInfo? _selectedProvider;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchModels();
  }

  Future<void> _fetchModels() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http.get(Uri.parse('$_baseUrl/models_info'));

      if (response.statusCode == 200) {
        List<dynamic> modelsJson = json.decode(response.body);
        setState(() {
          _models = modelsJson.map((json) => CustomModelInfo.fromJson(json)).toList();
          if (_models.isNotEmpty) {
            _selectedModel = _models.first; // Auto-select the first model
            if (_selectedModel!.providers.isNotEmpty) {
              _selectedProvider = _selectedModel!.providers.first; // Auto-select first provider
            }
          }
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

  void _onSelectModel(CustomModelInfo? model) {
    setState(() {
      _selectedModel = model;
      _selectedProvider = model?.providers.isNotEmpty == true ? model!.providers.first : null;
    });
  }

  void _onSelectProvider(ModelProviderInfo? provider) {
    setState(() {
      _selectedProvider = provider;
    });
  }

  // Helper to format context length from tokens to 'K' or 'M'
  String _formatContextLength(int? tokens) {
    if (tokens == null) return 'N/A';
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(1)}M';
    } else if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1).replaceAll(RegExp(r'\.0+$'), '')}K';
    }
    return tokens.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Model & Provider Pricing', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.deepPurple,
        elevation: 0,
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
                        const Icon(Icons.error_outline, color: Colors.red, size: 50),
                        const SizedBox(height: 16),
                        Text(
                          'Error: $_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red, fontSize: 18),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _fetchModels,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                          style: ElevatedButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.deepPurple,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
                      _buildSectionTitle('Select a Model'),
                      const SizedBox(height: 10),
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                          child: DropdownButtonFormField<CustomModelInfo>(
                            value: _selectedModel,
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              labelText: 'Model Name',
                              labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple),
                              floatingLabelBehavior: FloatingLabelBehavior.always,
                            ),
                            isExpanded: true,
                            items: _models.map((model) {
                              return DropdownMenuItem(
                                value: model,
                                child: Text(model.name, overflow: TextOverflow.ellipsis),
                              );
                            }).toList(),
                            onChanged: _onSelectModel,
                            icon: const Icon(Icons.arrow_drop_down, color: Colors.deepPurple),
                            selectedItemBuilder: (context) {
                              return _models.map<Widget>((model) {
                                return Text(model.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500));
                              }).toList();
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_selectedModel != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          child: Text(
                            '${_selectedModel!.description ?? 'No description available.'}',
                            style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: Colors.grey[700]),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildSectionTitle('Available Providers'),
                        const SizedBox(height: 10),
                        Card(
                          elevation: 2,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                            child: DropdownButtonFormField<ModelProviderInfo>(
                              value: _selectedProvider,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                labelText: 'Provider Name',
                                labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple),
                                floatingLabelBehavior: FloatingLabelBehavior.always,
                              ),
                              isExpanded: true,
                              items: _selectedModel!.providers.map((provider) {
                                return DropdownMenuItem(
                                  value: provider,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        provider.name,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        'Input: ${provider.pricing.formatTokenPrice(provider.pricing.prompt)} | Output: ${provider.pricing.formatTokenPrice(provider.pricing.completion)}',
                                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text('Context: ${_formatContextLength(provider.contextLength)} | Max Out: ${_formatContextLength(provider.maxCompletionTokens)}',
                                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: _onSelectProvider,
                              icon: const Icon(Icons.arrow_drop_down, color: Colors.deepPurple),
                              selectedItemBuilder: (context) {
                                return _selectedModel!.providers.map<Widget>((provider) {
                                  return Text(provider.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500));
                                }).toList();
                              },
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (_selectedProvider != null)
                        _buildSelectedProviderDetailsCard(_selectedProvider!),
                      const SizedBox(height: 30),
                      Center(
                        child: ElevatedButton.icon(
                          onPressed: _selectedModel != null && _selectedProvider != null
                              ? () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          'Selected: Model "${_selectedModel!.name}"\n'
                                          'Provider: "${_selectedProvider!.name}" (Slug: ${_selectedProvider!.slug})'
                                      ),
                                      backgroundColor: Colors.deepPurple,
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                  // TODO: Integrate the actual API call here
                                  // Use _selectedModel!.id and _selectedProvider!.slug
                                }
                              : null,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('Use This Selection'),
                          style: ElevatedButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.deepPurpleAccent,
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.deepPurple),
    );
  }

  Widget _buildModelDetailsCard(CustomModelInfo model) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Selected Model Overview:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
            ),
            const Divider(color: Colors.deepPurpleAccent),
            _buildInfoRow('Name:', model.name),
            _buildInfoRow('ID:', model.id),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedProviderDetailsCard(ModelProviderInfo provider) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      color: Colors.deepPurple[50],
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Selected Provider Pricing:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
            ),
            const Divider(color: Colors.deepPurpleAccent),
            _buildInfoRow('Provider Name:', provider.name),
            _buildInfoRow('Provider Slug:', provider.slug),
            const SizedBox(height: 8),
            const Text('Pricing:', style: TextStyle(fontWeight: FontWeight.bold)),
            _buildInfoRow('Input Price:', provider.pricing.formatTokenPrice(provider.pricing.prompt)),
            _buildInfoRow('Output Price:', provider.pricing.formatTokenPrice(provider.pricing.completion)),
            if (provider.pricing.request > 0)
              _buildInfoRow('Request Price:', provider.pricing.formatRequestPrice(provider.pricing.request)),
            const SizedBox(height: 8),
            const Text('Context & Output:', style: TextStyle(fontWeight: FontWeight.bold)),
            _buildInfoRow('Context Length:', _formatContextLength(provider.contextLength)),
            _buildInfoRow('Max Output Tokens:', _formatContextLength(provider.maxCompletionTokens)),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.black87)),
          ),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.black))),
        ],
      ),
    );
  }
}

// --- Main function to run the app ---
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenRouter Client',
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        appBarTheme: const AppBarTheme( // Fixed: Removed const from ThemeData and AppBarTheme constructor
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
          // systemOverlayStyle: SystemUiOverlayStyle.light, // This can't be const here
        ),
        cardTheme: const CardThemeData(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))), // Fixed: const here as well
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurpleAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.deepPurpleAccent),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.deepPurple, width: 2),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey[400]!),
          ),
          labelStyle: const TextStyle(color: Colors.deepPurple),
          floatingLabelStyle: const TextStyle(color: Colors.deepPurple, fontWeight: FontWeight.bold),
        ),
      ),
      home: const ModelSelectorPage(),
    );
  }
}