// lib/voice/voice_call_service.dart
//
// Whether a voice call can be offered at all, and the two network facts a
// call needs: the token server URL and who the caller is.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/api_config_base.dart' show getApiBaseUrl;
import 'package:chuk_chat/services/current_user.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/voice/voice_protocol.dart';

abstract final class VoiceCallService {
  /// The token server, from the gitignored `.env`
  /// (`--dart-define-from-file=.env`). The repository is public: this URL is
  /// never written into the code, and never logged.
  static const String tokenUrl = String.fromEnvironment('VOICE_TOKEN_URL');

  /// True when the call button may be shown: the build flag is on, a token
  /// server is configured, and the app is native (the call store and the
  /// microphone foreground service have no web side).
  static bool get isAvailable =>
      kFeatureVoiceCall && tokenUrl.isNotEmpty && !kIsWeb;

  static const Duration _tokenTimeout = Duration(seconds: 12);
  static const String _installIdKey = 'voice_call_install_id';
  static String? _sessionInstallId;

  /// The id the worker keys the caller on: the Supabase user id, or a stable
  /// per-install id when nobody is signed in.
  static Future<String> callerId() async {
    final String? userId = CurrentUser.id;
    if (userId != null && userId.isNotEmpty) return userId;
    return _installId();
  }

  static Future<String> _installId() async {
    final String? cached = _sessionInstallId;
    if (cached != null) return cached;
    final String fresh = const Uuid().v4();
    if (kIsWeb) return _sessionInstallId = fresh;
    try {
      await LocalChatCacheService.kvSetIfAbsent(_installIdKey, fresh);
      final String? stored = await LocalChatCacheService.kvGet(_installIdKey);
      return _sessionInstallId = stored ?? fresh;
    } catch (_) {
      return _sessionInstallId = fresh;
    }
  }

  /// The token server address, checked: https, or plain http in a debug
  /// build only (the request carries the call's context).
  @visibleForTesting
  static Uri tokenUri(String url, {bool allowHttp = kDebugMode}) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      throw const VoiceCallException('VOICE_TOKEN_URL is not a valid URL');
    }
    if (uri.scheme == 'https' || (allowHttp && uri.scheme == 'http')) {
      return uri;
    }
    throw const VoiceCallException('VOICE_TOKEN_URL must use https');
  }

  /// The headers of a token request to [uri]. The Supabase access token goes
  /// along as a bearer ONLY when [uri] is on the app's own API host
  /// ([apiBaseUrl], default the host the app uses for its API): the
  /// JWT-checked `/v1/voice/token`. Any other token server (a test server on
  /// another domain) never sees the account's token.
  @visibleForTesting
  static Map<String, String> tokenHeaders(
    Uri uri, {
    String? accessToken,
    String? apiBaseUrl,
  }) {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (accessToken == null || accessToken.isEmpty) return headers;
    final Uri? api = Uri.tryParse(apiBaseUrl ?? getApiBaseUrl());
    final String apiHost = api?.host.toLowerCase() ?? '';
    if (apiHost.isNotEmpty && uri.host.toLowerCase() == apiHost) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  /// POSTs [body] to the token server and returns where to join.
  ///
  /// The Supabase access token goes along only to the app's own API host
  /// ([tokenHeaders]), so `/v1/voice/token` there is a drop-in URL change.
  static Future<VoiceCredentials> fetchCredentials(
    Map<String, dynamic> body, {
    http.Client? client,
  }) async {
    final Uri uri = tokenUri(tokenUrl);
    final Map<String, String> headers = tokenHeaders(
      uri,
      accessToken: _accessToken(),
    );

    final http.Client c = client ?? http.Client();
    final http.Response response;
    try {
      response = await c
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(_tokenTimeout);
    } on TimeoutException {
      throw const VoiceCallException('Token server timed out');
    } catch (_) {
      // An http ClientException names the URL; never pass it on.
      throw const VoiceCallException('Could not reach the token server');
    } finally {
      if (client == null) c.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VoiceCallException('Token server answered ${response.statusCode}');
    }
    try {
      return VoiceProtocol.parseTokenResponse(response.body);
    } on FormatException {
      throw const VoiceCallException('Token server sent no token');
    }
  }

  static String? _accessToken() {
    try {
      return SupabaseService.auth.currentSession?.accessToken;
    } catch (_) {
      return null;
    }
  }
}

/// A call failure with a message that is safe to show and to log: it never
/// carries the token, the token URL or transcript text.
class VoiceCallException implements Exception {
  const VoiceCallException(this.message);

  final String message;

  @override
  String toString() => message;
}
