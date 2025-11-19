// lib/pages/model_selector/models/model_info.dart

/// Pricing details for a model provider
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

  /// Helper to format price per million tokens
  String formatTokenPrice(double pricePerToken) {
    if (pricePerToken == 0.0) return 'Free';
    final pricePerMillion = pricePerToken * 1000000;
    String priceStr = pricePerMillion.toStringAsFixed(6);
    priceStr = priceStr.replaceAll(RegExp(r'\.?0+$'), '');
    return '\$$priceStr/M';
  }

  /// Helper to format request price (not per million)
  String formatRequestPrice(double price) {
    if (price == 0.0) return 'Free';
    return '\$${price.toStringAsFixed(3)}/req';
  }
}

/// Model provider information
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

/// Custom model information
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

/// Exception for authentication requirements
class AuthRequiredException implements Exception {
  const AuthRequiredException();
}
