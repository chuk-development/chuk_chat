import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Spotify OAuth PKCE Service
class SpotifyOAuth {
  static const String clientId = 'f5134847822b49b1a7a06a6f85b3c76a';
  static const int callbackPort = 43823;
  static String get redirectUri => 'http://127.0.0.1:$callbackPort/callback';
  static const String authEndpoint = 'https://accounts.spotify.com/authorize';
  static const String tokenEndpoint = 'https://accounts.spotify.com/api/token';

  io.HttpServer? _callbackServer;
  Completer<String>? _authCodeCompleter;

  static const List<String> scopes = [
    'user-read-playback-state',
    'user-modify-playback-state',
    'user-read-currently-playing',
    'playlist-read-private',
    'playlist-read-collaborative',
    'playlist-modify-public',
    'playlist-modify-private',
    'user-library-read',
    'user-library-modify',
    'user-read-email',
    'user-read-private',
  ];

  String? _codeVerifier;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;

  String _generateRandomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
        '0123456789-._~';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Start OAuth flow - opens browser and starts local server
  Future<void> startAuth() async {
    _codeVerifier = _generateRandomString(128);
    final codeChallenge = _generateCodeChallenge(_codeVerifier!);

    _authCodeCompleter = Completer<String>();
    await _startCallbackServer();

    final params = {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': codeChallenge,
      'scope': scopes.join(' '),
    };

    final uri = Uri.parse(authEndpoint).replace(queryParameters: params);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw Exception('Could not launch Spotify auth URL');
    }
  }

  Future<void> _startCallbackServer() async {
    _callbackServer = await io.HttpServer.bind('127.0.0.1', callbackPort);

    _callbackServer!.listen((io.HttpRequest request) async {
      final uri = request.uri;

      if (uri.path == '/callback') {
        final code = uri.queryParameters['code'];

        if (code != null) {
          request.response
            ..statusCode = 200
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(
              '<!DOCTYPE html><html><head><title>Spotify Connected</title>'
              '<style>body{font-family:Arial;text-align:center;'
              'padding:50px;background:#1DB954;color:white;}'
              'h1{font-size:48px;}</style></head><body>'
              '<h1>Success!</h1>'
              '<p>Spotify connected. You can close this window.</p>'
              '</body></html>',
            );
          await request.response.close();

          if (!_authCodeCompleter!.isCompleted) {
            _authCodeCompleter!.complete(code);
          }

          await _callbackServer?.close();
          _callbackServer = null;
        } else {
          request.response
            ..statusCode = 400
            ..write('Error: No authorization code received');
          await request.response.close();
        }
      }
    });
  }

  /// Wait for OAuth callback and exchange code for token
  Future<bool> completeAuth() async {
    try {
      final code = await _authCodeCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw Exception('Authorization timeout'),
      );

      final response = await http.post(
        Uri.parse(tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': _codeVerifier!,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        _tokenExpiry = DateTime.now().add(
          Duration(seconds: data['expires_in'] as int),
        );
        await _saveTokens();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Refresh access token
  Future<bool> refreshAccessToken() async {
    if (_refreshToken == null) return false;

    try {
      final response = await http.post(
        Uri.parse(tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'refresh_token',
          'refresh_token': _refreshToken!,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _accessToken = data['access_token'];
        _tokenExpiry = DateTime.now().add(
          Duration(seconds: data['expires_in'] as int),
        );
        await _saveTokens();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Get valid access token (refreshes if needed)
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

  Future<void> _saveTokens() async {
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
  }

  Future<void> _loadTokens() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('spotify_access_token');
    _refreshToken = prefs.getString('spotify_refresh_token');
    final expiryStr = prefs.getString('spotify_token_expiry');
    if (expiryStr != null) {
      _tokenExpiry = DateTime.parse(expiryStr);
    }
  }

  /// Check if authenticated (async - loads tokens first)
  Future<bool> isAuthenticated() async {
    await _loadTokens();
    return _accessToken != null;
  }

  /// Synchronous check for token presence
  bool get hasToken => _accessToken != null;

  /// Logout
  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('spotify_access_token');
    await prefs.remove('spotify_refresh_token');
    await prefs.remove('spotify_token_expiry');
  }
}
