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

/// WHOOP OAuth Service — backend-assisted flow.
///
/// The client ID and secret live on the API server. This service only handles
/// the browser redirect, local callback server, and token storage.  Tokens are
/// exchanged and refreshed via the API server endpoints:
///
///   GET  /v1/auth/whoop/auth-url
///   POST /v1/auth/whoop/token
///   POST /v1/auth/whoop/refresh
class WhoopOAuth {
  static const int callbackPort = 43827;
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
    try {
      await _startCallbackServer();
    } catch (e) {
      _authCodeCompleter?.completeError(e);
      rethrow;
    }

    final response = await http.get(
      Uri.parse('$_backendUrl/v1/auth/whoop/auth-url').replace(
        queryParameters: {'redirect_uri': redirectUri, 'state': _state!},
      ),
      headers: _apiHeaders,
    );

    if (response.statusCode != 200) {
      await _stopCallbackServer();
      throw Exception('Failed to get WHOOP auth URL: ${response.statusCode}');
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
      throw Exception('Could not launch WHOOP authorization URL');
    }
  }

  /// Wait for OAuth callback and exchange code for tokens via API server.
  Future<bool> completeAuth() async {
    if (_authCodeCompleter == null) return false;

    try {
      final code = await _authCodeCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Authorization timed out'),
      );

      await _stopCallbackServer();

      // Exchange code for tokens via API server
      final response = await http.post(
        Uri.parse('$_backendUrl/v1/auth/whoop/token'),
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
        Uri.parse('$_backendUrl/v1/auth/whoop/refresh'),
        headers: _apiHeaders,
        body: jsonEncode({'refresh_token': _refreshToken}),
      );

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body);
      _accessToken = data['access_token'] as String?;
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
    await prefs.remove('whoop_access_token');
    await prefs.remove('whoop_refresh_token');
    await prefs.remove('whoop_token_expiry');
    unawaited(ServiceCredentialsService.delete('whoop'));
  }

  // ---------------------------------------------------------------------------
  // Token persistence (local + encrypted Supabase sync)
  // ---------------------------------------------------------------------------

  Future<void> _saveTokens() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) {
      await prefs.setString('whoop_access_token', _accessToken!);
    }
    if (_refreshToken != null) {
      await prefs.setString('whoop_refresh_token', _refreshToken!);
    }
    if (_tokenExpiry != null) {
      await prefs.setString(
        'whoop_token_expiry',
        _tokenExpiry!.toIso8601String(),
      );
    }

    unawaited(
      ServiceCredentialsService.save('whoop', {
        if (_accessToken != null) 'access_token': _accessToken,
        if (_refreshToken != null) 'refresh_token': _refreshToken,
        if (_tokenExpiry != null)
          'token_expiry': _tokenExpiry!.toIso8601String(),
      }),
    );
  }

  Future<void> _loadTokens() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('whoop_access_token');
    _refreshToken = prefs.getString('whoop_refresh_token');
    final expiryStr = prefs.getString('whoop_token_expiry');
    if (expiryStr != null) {
      _tokenExpiry = DateTime.tryParse(expiryStr);
    }

    if (_accessToken == null) {
      final remote = await ServiceCredentialsService.load('whoop');
      if (remote != null) {
        _accessToken = remote['access_token'] as String?;
        _refreshToken = remote['refresh_token'] as String?;
        final remoteExpiry = remote['token_expiry'] as String?;
        if (remoteExpiry != null) {
          _tokenExpiry = DateTime.tryParse(remoteExpiry);
        }

        if (_accessToken != null) {
          await prefs.setString('whoop_access_token', _accessToken!);
        }
        if (_refreshToken != null) {
          await prefs.setString('whoop_refresh_token', _refreshToken!);
        }
        if (_tokenExpiry != null) {
          await prefs.setString(
            'whoop_token_expiry',
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
            ..write(_buildHtml('WHOOP Connected!', true));
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
    final color = success ? '#44D62C' : '#EA4335';
    return '<!DOCTYPE html><html><head><title>$title</title>'
        '<style>body{font-family:sans-serif;display:flex;'
        'justify-content:center;align-items:center;'
        'height:100vh;margin:0;background:#1a1a2e;color:#e8eaed;}'
        '.c{text-align:center;padding:40px;background:#16213e;'
        'border-radius:12px;border:1px solid #0f3460;}'
        'h1{color:$color;}</style></head><body>'
        '<div class="c"><h1>$title</h1>'
        '<p>You can close this window.</p></div></body></html>';
  }
}
