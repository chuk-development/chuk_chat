import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class CustomizationPreferences {
  const CustomizationPreferences({
    required this.userId,
    required this.autoSendVoiceTranscription,
    required this.showReasoningTokens,
    required this.showModelInfo,
    required this.showTps,
    required this.imageGenEnabled,
    required this.imageGenDefaultSize,
    required this.imageGenCustomWidth,
    required this.imageGenCustomHeight,
    required this.imageGenUseCustomSize,
    required this.includeRecentImagesInHistory,
    required this.includeAllImagesInHistory,
    required this.includeReasoningInHistory,
    required this.includeToolResultsInHistory,
    required this.toolCallingEnabled,
    required this.toolDiscoveryMode,
    required this.showToolCalls,
    required this.allowMarkdownToolCalls,
    required this.uiLocale,
    required this.chatFontSize,
    required this.chatFontFamily,
  });

  final String userId;
  final bool autoSendVoiceTranscription;
  final bool showReasoningTokens;
  final bool showModelInfo;
  final bool showTps;
  // Image generation settings
  final bool imageGenEnabled;
  final String imageGenDefaultSize;
  final int imageGenCustomWidth;
  final int imageGenCustomHeight;
  final bool imageGenUseCustomSize;
  // AI context settings
  final bool includeRecentImagesInHistory;
  final bool includeAllImagesInHistory;
  final bool includeReasoningInHistory;
  final bool includeToolResultsInHistory;
  // Tool-calling settings
  final bool toolCallingEnabled;
  final bool toolDiscoveryMode;
  final bool showToolCalls;
  final bool allowMarkdownToolCalls;
  // UI locale ('en' or 'de')
  final String uiLocale;
  // Chat body font size (applies to user + AI message text)
  final double chatFontSize;
  // Chat body font family identifier (see constants.dart, e.g. 'arimo')
  final String chatFontFamily;

  CustomizationPreferences copyWith({
    bool? autoSendVoiceTranscription,
    bool? showReasoningTokens,
    bool? showModelInfo,
    bool? showTps,
    bool? imageGenEnabled,
    String? imageGenDefaultSize,
    int? imageGenCustomWidth,
    int? imageGenCustomHeight,
    bool? imageGenUseCustomSize,
    bool? includeRecentImagesInHistory,
    bool? includeAllImagesInHistory,
    bool? includeReasoningInHistory,
    bool? includeToolResultsInHistory,
    bool? toolCallingEnabled,
    bool? toolDiscoveryMode,
    bool? showToolCalls,
    bool? allowMarkdownToolCalls,
    String? uiLocale,
    double? chatFontSize,
    String? chatFontFamily,
  }) {
    return CustomizationPreferences(
      userId: userId,
      autoSendVoiceTranscription:
          autoSendVoiceTranscription ?? this.autoSendVoiceTranscription,
      showReasoningTokens: showReasoningTokens ?? this.showReasoningTokens,
      showModelInfo: showModelInfo ?? this.showModelInfo,
      showTps: showTps ?? this.showTps,
      imageGenEnabled: imageGenEnabled ?? this.imageGenEnabled,
      imageGenDefaultSize: imageGenDefaultSize ?? this.imageGenDefaultSize,
      imageGenCustomWidth: imageGenCustomWidth ?? this.imageGenCustomWidth,
      imageGenCustomHeight: imageGenCustomHeight ?? this.imageGenCustomHeight,
      imageGenUseCustomSize:
          imageGenUseCustomSize ?? this.imageGenUseCustomSize,
      includeRecentImagesInHistory:
          includeRecentImagesInHistory ?? this.includeRecentImagesInHistory,
      includeAllImagesInHistory:
          includeAllImagesInHistory ?? this.includeAllImagesInHistory,
      includeReasoningInHistory:
          includeReasoningInHistory ?? this.includeReasoningInHistory,
      includeToolResultsInHistory:
          includeToolResultsInHistory ?? this.includeToolResultsInHistory,
      toolCallingEnabled: toolCallingEnabled ?? this.toolCallingEnabled,
      toolDiscoveryMode: toolDiscoveryMode ?? this.toolDiscoveryMode,
      showToolCalls: showToolCalls ?? this.showToolCalls,
      allowMarkdownToolCalls:
          allowMarkdownToolCalls ?? this.allowMarkdownToolCalls,
      uiLocale: uiLocale ?? this.uiLocale,
      chatFontSize: chatFontSize ?? this.chatFontSize,
      chatFontFamily: chatFontFamily ?? this.chatFontFamily,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'auto_send_voice_transcription': autoSendVoiceTranscription,
      'show_reasoning_tokens': showReasoningTokens,
      'show_model_info': showModelInfo,
      'show_tps': showTps,
      'image_gen_enabled': imageGenEnabled,
      'image_gen_default_size': imageGenDefaultSize,
      'image_gen_custom_width': imageGenCustomWidth,
      'image_gen_custom_height': imageGenCustomHeight,
      'image_gen_use_custom_size': imageGenUseCustomSize,
      'include_recent_images_in_history': includeRecentImagesInHistory,
      'include_all_images_in_history': includeAllImagesInHistory,
      'include_reasoning_in_history': includeReasoningInHistory,
      'include_tool_results_in_history': includeToolResultsInHistory,
      'tool_calling_enabled': toolCallingEnabled,
      'tool_discovery_mode': toolDiscoveryMode,
      'show_tool_calls': showToolCalls,
      'allow_markdown_tool_calls': allowMarkdownToolCalls,
      'ui_locale': uiLocale,
      'chat_font_size': chatFontSize,
      'chat_font_family': chatFontFamily,
    };
  }

  static CustomizationPreferences defaults(String userId) {
    return CustomizationPreferences(
      userId: userId,
      autoSendVoiceTranscription: false, // Default is OFF - user must enable it
      showReasoningTokens: true,
      showModelInfo: true,
      showTps: false, // Default is OFF - user must enable it
      imageGenEnabled: false, // Default is OFF - user must enable it
      imageGenDefaultSize: 'landscape_4_3',
      imageGenCustomWidth: 1024,
      imageGenCustomHeight: 768,
      imageGenUseCustomSize: false,
      includeRecentImagesInHistory: true, // Default ON
      includeAllImagesInHistory: false,
      includeReasoningInHistory: false,
      includeToolResultsInHistory: kDefaultIncludeToolResultsInHistory,
      toolCallingEnabled: true,
      toolDiscoveryMode: true,
      showToolCalls: true,
      allowMarkdownToolCalls: true,
      uiLocale: 'en',
      chatFontSize: kDefaultChatFontSize,
      chatFontFamily: kDefaultChatFontFamily,
    );
  }

  static CustomizationPreferences fromMap(
    String userId,
    Map<String, dynamic> map,
  ) {
    return CustomizationPreferences(
      userId: userId,
      autoSendVoiceTranscription:
          (map['auto_send_voice_transcription'] as bool?) ?? false,
      showReasoningTokens: (map['show_reasoning_tokens'] as bool?) ?? true,
      showModelInfo: (map['show_model_info'] as bool?) ?? true,
      showTps: (map['show_tps'] as bool?) ?? false,
      imageGenEnabled: (map['image_gen_enabled'] as bool?) ?? false,
      imageGenDefaultSize:
          (map['image_gen_default_size'] as String?) ?? 'landscape_4_3',
      imageGenCustomWidth: (map['image_gen_custom_width'] as int?) ?? 1024,
      imageGenCustomHeight: (map['image_gen_custom_height'] as int?) ?? 768,
      imageGenUseCustomSize:
          (map['image_gen_use_custom_size'] as bool?) ?? false,
      includeRecentImagesInHistory:
          (map['include_recent_images_in_history'] as bool?) ?? true,
      includeAllImagesInHistory:
          (map['include_all_images_in_history'] as bool?) ?? false,
      includeReasoningInHistory:
          (map['include_reasoning_in_history'] as bool?) ?? false,
      includeToolResultsInHistory:
          (map['include_tool_results_in_history'] as bool?) ??
              kDefaultIncludeToolResultsInHistory,
      toolCallingEnabled: (map['tool_calling_enabled'] as bool?) ?? true,
      toolDiscoveryMode: (map['tool_discovery_mode'] as bool?) ?? true,
      showToolCalls: (map['show_tool_calls'] as bool?) ?? true,
      allowMarkdownToolCalls:
          (map['allow_markdown_tool_calls'] as bool?) ?? true,
      uiLocale: (map['ui_locale'] as String?) ?? 'en',
      chatFontSize:
          (map['chat_font_size'] as num?)?.toDouble() ?? kDefaultChatFontSize,
      chatFontFamily: _sanitizeFontFamily(map['chat_font_family'] as String?),
    );
  }
}

String _sanitizeFontFamily(String? id) {
  if (id == null || !kSupportedChatFontFamilies.contains(id)) {
    return kDefaultChatFontFamily;
  }
  return id;
}

class CustomizationPreferencesService {
  const CustomizationPreferencesService();

  SupabaseQueryBuilder get _table =>
      SupabaseService.client.from('customization_preferences');

  Future<CustomizationPreferences> loadOrCreate() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw const CustomizationPreferencesServiceException(
        'User is not signed in.',
      );
    }

    final existing = await _table.select().eq('user_id', user.id).maybeSingle();

    if (existing != null) {
      return CustomizationPreferences.fromMap(user.id, existing);
    }

    final defaults = CustomizationPreferences.defaults(user.id);
    await _table.upsert(defaults.toMap());
    return defaults;
  }

  Future<void> save(CustomizationPreferences preferences) async {
    await _table.upsert(preferences.toMap(), onConflict: 'user_id');
  }
}

class CustomizationPreferencesServiceException implements Exception {
  const CustomizationPreferencesServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
