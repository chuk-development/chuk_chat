// lib/services/chat_profile_service.dart
//
// "Standard": the model and provider chain the server picks for the reader.
//
// The server reads them from `profiles.json` in chuk_chat_model_list and
// lists them at `GET /v1/profiles` (api_server `model_info/profiles.py`).
// The app never pins a provider in Standard: a send carries the marker slug
// [ChatProfileService.standardMarker] through the whole send pipeline, and
// the WebSocket frame turns it into `profile: "standard"`. The server then
// picks model and providers, so a change on the server reaches every app at
// once, with no app update.
//
// This service only keeps what the UI shows (model name, provider names) and
// the model id the send carries as a fallback for a server that does not
// know the profile.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/api_config_service.dart';

/// One provider in a profile's chain, for display.
@immutable
class ChatProfileProvider {
  const ChatProfileProvider({
    required this.slug,
    required this.name,
    this.iconUrl,
  });

  final String slug;
  final String name;
  final String? iconUrl;
}

/// A server-chosen profile: one model and an ordered provider chain.
@immutable
class ChatProfile {
  const ChatProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.modelId,
    required this.modelName,
    this.modelIconUrl,
    this.providers = const <ChatProfileProvider>[],
  });

  final String id;
  final String name;
  final String description;
  final String modelId;
  final String modelName;
  final String? modelIconUrl;
  final List<ChatProfileProvider> providers;

  /// `Wafer → inference.net → Ionstream`, without the `(US)` region tags.
  String get providerChainLabel => providers
      .map((p) => p.name.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), ''))
      .join(' → ');

  static ChatProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? model = raw['model'];
    if (model is! Map) return null;
    final String id = (raw['id'] as String?) ?? '';
    final String modelId = (model['id'] as String?) ?? '';
    if (id.isEmpty || modelId.isEmpty) return null;
    final List<ChatProfileProvider> providers = <ChatProfileProvider>[
      for (final Object? p in (raw['providers'] as List?) ?? const <Object?>[])
        if (p is Map && p['slug'] is String)
          ChatProfileProvider(
            slug: p['slug'] as String,
            name: (p['name'] as String?) ?? p['slug'] as String,
            iconUrl: p['icon_url'] as String?,
          ),
    ];
    return ChatProfile(
      id: id,
      name: (raw['name'] as String?) ?? id,
      description: (raw['description'] as String?) ?? '',
      modelId: modelId,
      modelName: (model['name'] as String?) ?? modelId,
      modelIconUrl: model['icon_url'] as String?,
      providers: providers,
    );
  }
}

class ChatProfileService {
  ChatProfileService._();

  static const String standardId = 'standard';

  /// Provider slug that stands for "the server picks" in the send pipeline.
  /// Never a real provider; the WebSocket frame turns it into a `profile`.
  static const String markerPrefix = 'profile:';
  static const String standardMarker = '$markerPrefix$standardId';

  /// The model Standard runs before the app has heard from the server. Kept
  /// in step with the server's built-in default (`model_info/profiles.py`).
  static const String builtinModelId = 'deepseek/deepseek-v4.1-flash-1017';

  static const String _prefsKey = 'chat_profile_standard_v1';
  static const Duration _httpTimeout = Duration(seconds: 4);

  /// The profile id a provider slug stands for, or null for a real slug.
  static String? profileIdOf(String? slug) {
    if (slug == null || !slug.startsWith(markerPrefix)) return null;
    final String id = slug.substring(markerPrefix.length);
    return id.isEmpty ? null : id;
  }

  static bool isProfileSlug(String? slug) => profileIdOf(slug) != null;

  /// The last known Standard profile, for the UI. Null until loaded.
  static final ValueNotifier<ChatProfile?> standard =
      ValueNotifier<ChatProfile?>(null);

  static bool _loadedFromDisk = false;
  static Future<void>? _inFlight;

  /// The model Standard runs now: the server's choice when known.
  static String get standardModelId =>
      standard.value?.modelId ?? builtinModelId;

  /// Read the stored copy (instant, no network). The network refresh runs
  /// with the model catalogue fetch ([refresh], `ModelPrefetchService`).
  static Future<ChatProfile?> load() async {
    if (!_loadedFromDisk) {
      _loadedFromDisk = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        final String? raw = prefs.getString(_prefsKey);
        if (raw != null && raw.isNotEmpty) {
          standard.value ??= ChatProfile.fromJson(jsonDecode(raw));
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[ChatProfile] stored copy unreadable: $e');
      }
    }
    return standard.value;
  }

  /// Fetch `/v1/profiles` once (deduped). Keeps the old copy on any failure.
  static Future<void> refresh() {
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  static Future<void> _refresh() async {
    try {
      final response = await http
          .get(Uri.parse('${ApiConfigService.apiBaseUrl}/v1/profiles'))
          .timeout(_httpTimeout);
      if (response.statusCode != 200 || response.body.isEmpty) return;
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map) return;
      final String defaultId = (decoded['default'] as String?) ?? standardId;
      ChatProfile? found;
      for (final Object? raw
          in (decoded['profiles'] as List?) ?? const <Object?>[]) {
        final ChatProfile? profile = ChatProfile.fromJson(raw);
        if (profile != null && profile.id == defaultId) found = profile;
      }
      if (found == null) return;
      standard.value = found;
      final prefs = await SharedPreferences.getInstance();
      final Map<String, Object?> raw = (decoded['profiles'] as List)
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .firstWhere((m) => m['id'] == defaultId);
      await prefs.setString(_prefsKey, jsonEncode(raw));
    } catch (e) {
      if (kDebugMode) debugPrint('[ChatProfile] refresh failed: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    standard.value = null;
    _loadedFromDisk = false;
    _inFlight = null;
  }
}
