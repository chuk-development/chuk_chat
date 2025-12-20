import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class CustomizationPreferences {
  const CustomizationPreferences({
    required this.userId,
    required this.autoSendVoiceTranscription,
    required this.showReasoningTokens,
    required this.showModelInfo,
    required this.imageGenEnabled,
    required this.imageGenDefaultSize,
    required this.imageGenCustomWidth,
    required this.imageGenCustomHeight,
    required this.imageGenUseCustomSize,
  });

  final String userId;
  final bool autoSendVoiceTranscription;
  final bool showReasoningTokens;
  final bool showModelInfo;
  // Image generation settings
  final bool imageGenEnabled;
  final String imageGenDefaultSize;
  final int imageGenCustomWidth;
  final int imageGenCustomHeight;
  final bool imageGenUseCustomSize;

  CustomizationPreferences copyWith({
    bool? autoSendVoiceTranscription,
    bool? showReasoningTokens,
    bool? showModelInfo,
    bool? imageGenEnabled,
    String? imageGenDefaultSize,
    int? imageGenCustomWidth,
    int? imageGenCustomHeight,
    bool? imageGenUseCustomSize,
  }) {
    return CustomizationPreferences(
      userId: userId,
      autoSendVoiceTranscription: autoSendVoiceTranscription ?? this.autoSendVoiceTranscription,
      showReasoningTokens: showReasoningTokens ?? this.showReasoningTokens,
      showModelInfo: showModelInfo ?? this.showModelInfo,
      imageGenEnabled: imageGenEnabled ?? this.imageGenEnabled,
      imageGenDefaultSize: imageGenDefaultSize ?? this.imageGenDefaultSize,
      imageGenCustomWidth: imageGenCustomWidth ?? this.imageGenCustomWidth,
      imageGenCustomHeight: imageGenCustomHeight ?? this.imageGenCustomHeight,
      imageGenUseCustomSize: imageGenUseCustomSize ?? this.imageGenUseCustomSize,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'auto_send_voice_transcription': autoSendVoiceTranscription,
      'show_reasoning_tokens': showReasoningTokens,
      'show_model_info': showModelInfo,
      'image_gen_enabled': imageGenEnabled,
      'image_gen_default_size': imageGenDefaultSize,
      'image_gen_custom_width': imageGenCustomWidth,
      'image_gen_custom_height': imageGenCustomHeight,
      'image_gen_use_custom_size': imageGenUseCustomSize,
    };
  }

  static CustomizationPreferences defaults(String userId) {
    return CustomizationPreferences(
      userId: userId,
      autoSendVoiceTranscription: false, // Default is OFF - user must enable it
      showReasoningTokens: true,
      showModelInfo: true,
      imageGenEnabled: false, // Default is OFF - user must enable it
      imageGenDefaultSize: 'landscape_4_3',
      imageGenCustomWidth: 1024,
      imageGenCustomHeight: 768,
      imageGenUseCustomSize: false,
    );
  }

  static CustomizationPreferences fromMap(String userId, Map<String, dynamic> map) {
    return CustomizationPreferences(
      userId: userId,
      autoSendVoiceTranscription: (map['auto_send_voice_transcription'] as bool?) ?? false,
      showReasoningTokens: (map['show_reasoning_tokens'] as bool?) ?? true,
      showModelInfo: (map['show_model_info'] as bool?) ?? true,
      imageGenEnabled: (map['image_gen_enabled'] as bool?) ?? false,
      imageGenDefaultSize: (map['image_gen_default_size'] as String?) ?? 'landscape_4_3',
      imageGenCustomWidth: (map['image_gen_custom_width'] as int?) ?? 1024,
      imageGenCustomHeight: (map['image_gen_custom_height'] as int?) ?? 768,
      imageGenUseCustomSize: (map['image_gen_use_custom_size'] as bool?) ?? false,
    );
  }
}

class CustomizationPreferencesService {
  const CustomizationPreferencesService();

  SupabaseQueryBuilder get _table =>
      SupabaseService.client.from('customization_preferences');

  Future<CustomizationPreferences> loadOrCreate() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw const CustomizationPreferencesServiceException('User is not signed in.');
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
