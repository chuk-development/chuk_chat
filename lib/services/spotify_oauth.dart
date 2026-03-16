import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/service_credentials_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Spotify OAuth Service — backend-assisted flow.
///
/// The client ID and secret live on the API server. This service only handles
/// the browser redirect, local callback server, and token storage.  Tokens are
/// exchanged and refreshed via the API server endpoints:
///
///   GET  /v1/auth/spotify/auth-url
///   POST /v1/auth/spotify/token
///   POST /v1/auth/spotify/refresh
class SpotifyOAuth {
  static const int callbackPort = 43823;
  static String get redirectUri => 'http://127.0.0.1:$callbackPort/callback';

  io.HttpServer? _callbackServer;
  Completer<String>? _authCodeCompleter;

  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;
  String? _state;

  bool get isAuthenticated => _accessToken != null;
  bool get hasToken => _accessToken != null;

  /// The API server base URL (e.g. https://api.chuk.chat).
  String get _backendUrl => ApiConfigService.apiBaseUrl;

  /// Authorization header for API server requests (Supabase JWT).
  Map<String, String> get _apiHeaders {
    final token = SupabaseService.auth.currentSession?.accessToken;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ---------------------------------------------------------------------------
  // Auth flow
  // ---------------------------------------------------------------------------

  /// Start OAuth flow — gets auth URL from API server, opens browser, starts
  /// local callback server.
  Future<void> startAuth() async {
    _state = _generateState();

    _authCodeCompleter = Completer<String>();
    await _startCallbackServer();

    final response = await http.get(
      Uri.parse('$_backendUrl/v1/auth/spotify/auth-url').replace(
        queryParameters: {'redirect_uri': redirectUri, 'state': _state!},
      ),
      headers: _apiHeaders,
    );

    if (response.statusCode != 200) {
      await _stopCallbackServer();
      throw Exception('Failed to get Spotify auth URL: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final authUrl = data['auth_url'] as String?;
    if (authUrl == null) {
      await _stopCallbackServer();
      throw Exception('API server did not return auth_url');
    }

    final uri = Uri.parse(authUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      await _stopCallbackServer();
      throw Exception('Could not launch Spotify authorization URL');
    }
  }

  /// Wait for OAuth callback and exchange code for tokens via API server.
  Future<bool> completeAuth() async {
    try {
      final code = await _authCodeCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Authorization timed out'),
      );

      await _stopCallbackServer();

      // Exchange code for tokens via API server
      final response = await http.post(
        Uri.parse('$_backendUrl/v1/auth/spotify/token'),
        headers: _apiHeaders,
        body: jsonEncode({'code': code, 'redirect_uri': redirectUri}),
      );

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body);
      _accessToken = data['access_token'] as String?;
      _refreshToken = data['refresh_token'] as String?;

      final expiresIn = data['expires_in'];
      if (expiresIn != null) {
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn as int));
      }

      if (_accessToken == null) return false;

      await _saveTokens();
      return true;
    } catch (_) {
      await _stopCallbackServer();
      return false;
    }
  }

  /// Refresh the access token via the API server.
  Future<bool> refreshAccessToken() async {
    if (_refreshToken == null) return false;

    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/v1/auth/spotify/refresh'),
        headers: _apiHeaders,
        body: jsonEncode({'refresh_token': _refreshToken}),
      );

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body);
      _accessToken = data['access_token'] as String?;
      // Spotify may rotate refresh tokens on refresh
      final newRefreshToken = data['refresh_token'] as String?;
      if (newRefreshToken != null) {
        _refreshToken = newRefreshToken;
      }

      final expiresIn = data['expires_in'];
      if (expiresIn != null) {
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn as int));
      }

      if (_accessToken == null) return false;
      await _saveTokens();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get a valid access token, refreshing if expired.
  Future<String?> getAccessToken() async {
    if (_accessToken == null) {
      await _loadTokens();
    }

    if (_tokenExpiry != null &&
        DateTime.now().isAfter(
          _tokenExpiry!.subtract(const Duration(seconds: 60)),
        )) {
      final refreshed = await refreshAccessToken();
      if (!refreshed) {
        _accessToken = null;
        return null;
      }
    }

    return _accessToken;
  }

  /// Check if authenticated (async — loads tokens first).
  Future<bool> checkAuthenticated() async {
    await _loadTokens();
    return _accessToken != null;
  }

  /// Logout and clear all stored tokens (local + Supabase).
  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('spotify_access_token');
    await prefs.remove('spotify_refresh_token');
    await prefs.remove('spotify_token_expiry');
    unawaited(ServiceCredentialsService.delete('spotify'));
  }

  // ---------------------------------------------------------------------------
  // Token persistence (local + encrypted Supabase sync)
  // ---------------------------------------------------------------------------

  Future<void> _saveTokens() async {
    // 1. Local cache (fast)
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) {
      await prefs.setString('spotify_access_token', _accessToken!);
    }
    if (_refreshToken != null) {
      await prefs.setString('spotify_refresh_token', _refreshToken!);
    }
    if (_tokenExpiry != null) {
      await prefs.setString(
        'spotify_token_expiry',
        _tokenExpiry!.toIso8601String(),
      );
    }

    // 2. Encrypted Supabase sync (fire-and-forget for cross-device)
    unawaited(
      ServiceCredentialsService.save('spotify', {
        if (_accessToken != null) 'access_token': _accessToken,
        if (_refreshToken != null) 'refresh_token': _refreshToken,
        if (_tokenExpiry != null)
          'token_expiry': _tokenExpiry!.toIso8601String(),
      }),
    );
  }

  Future<void> _loadTokens() async {
    // 1. Try local cache first (fast)
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('spotify_access_token');
    _refreshToken = prefs.getString('spotify_refresh_token');
    final expiryStr = prefs.getString('spotify_token_expiry');
    if (expiryStr != null) {
      _tokenExpiry = DateTime.tryParse(expiryStr);
    }

    // 2. If no local tokens, try Supabase (cross-device sync)
    if (_accessToken == null) {
      final remote = await ServiceCredentialsService.load('spotify');
      if (remote != null) {
        _accessToken = remote['access_token'] as String?;
        _refreshToken = remote['refresh_token'] as String?;
        final remoteExpiry = remote['token_expiry'] as String?;
        if (remoteExpiry != null) {
          _tokenExpiry = DateTime.tryParse(remoteExpiry);
        }

        // Populate local cache so next load is fast
        if (_accessToken != null) {
          await prefs.setString('spotify_access_token', _accessToken!);
        }
        if (_refreshToken != null) {
          await prefs.setString('spotify_refresh_token', _refreshToken!);
        }
        if (_tokenExpiry != null) {
          await prefs.setString(
            'spotify_token_expiry',
            _tokenExpiry!.toIso8601String(),
          );
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Local callback server
  // ---------------------------------------------------------------------------

  String _generateState() {
    final random = Random.secure();
    final values = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(values);
  }

  Future<void> _startCallbackServer() async {
    _callbackServer = await io.HttpServer.bind('127.0.0.1', callbackPort);

    _callbackServer!.listen((io.HttpRequest request) async {
      if (request.uri.path == '/callback') {
        final code = request.uri.queryParameters['code'];
        final state = request.uri.queryParameters['state'];
        final error = request.uri.queryParameters['error'];

        if (error != null) {
          _authCodeCompleter?.completeError(Exception('OAuth error: $error'));
          request.response
            ..statusCode = 200
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(_buildHtml('Authorization Failed', false));
          await request.response.close();
          return;
        }

        if (state != _state) {
          _authCodeCompleter?.completeError(Exception('CSRF state mismatch'));
          request.response
            ..statusCode = 200
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(_buildHtml('Security Error', false));
          await request.response.close();
          return;
        }

        if (code != null) {
          if (!_authCodeCompleter!.isCompleted) {
            _authCodeCompleter!.complete(code);
          }
          request.response
            ..statusCode = 200
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(_buildHtml('Spotify Connected!', true));
          await request.response.close();
        } else {
          request.response
            ..statusCode = 400
            ..write('Missing authorization code');
          await request.response.close();
        }
      }
    });
  }

  Future<void> _stopCallbackServer() async {
    await _callbackServer?.close();
    _callbackServer = null;
  }

  String _buildHtml(String title, bool success) {
    final color = success ? '#1DB954' : '#EA4335';
    return '<!DOCTYPE html><html><head><title>$title</title>'
        '<style>body{font-family:sans-serif;display:flex;'
        'justify-content:center;align-items:center;'
        'height:100vh;margin:0;background:#191414;color:#e8eaed;}'
        '.c{text-align:center;padding:40px;background:#282828;'
        'border-radius:12px;border:1px solid #3c4043;}'
        'h1{color:$color;}</style></head><body>'
        '<div class="c"><h1>$title</h1>'
        '<p>You can close this window.</p></div></body></html>';
  }
}
