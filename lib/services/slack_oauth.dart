import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Slack OAuth Service
///
/// Handles OAuth 2.0 flow for Slack using a local HTTP callback server,
/// token persistence via SharedPreferences, and common Slack API methods.
class SlackOAuth {
  static const int callbackPort = 43826;
  static String get redirectUri => 'http://127.0.0.1:$callbackPort/callback';
  static const String authEndpoint = 'https://slack.com/oauth/v2/authorize';
  static const String tokenEndpoint = 'https://slack.com/api/oauth.v2.access';
  static const String apiBase = 'https://slack.com/api';

  io.HttpServer? _callbackServer;
  Completer<String>? _authCodeCompleter;

  static const List<String> userScopes = [
    'channels:history',
    'channels:read',
    'chat:write',
    'search:read',
    'users:read',
    'groups:history',
    'groups:read',
    'im:history',
    'im:read',
    'mpim:history',
    'mpim:read',
  ];

  String? _accessToken;
  String? _clientId;
  String? _clientSecret;
  String? _teamId;
  String? _teamName;
  String? _userId;
  String? _state;

  /// Set OAuth client credentials.
  void setCredentials({
    required String clientId,
    required String clientSecret,
  }) {
    _clientId = clientId;
    _clientSecret = clientSecret;
  }

  String _generateRandomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
        '0123456789';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  /// Start OAuth flow - opens browser and starts local callback server.
  Future<void> startAuth() async {
    if (_clientId == null || _clientSecret == null) {
      throw StateError(
        'Slack credentials not set. Call setCredentials() first.',
      );
    }

    _state = _generateRandomString(32);
    _authCodeCompleter = Completer<String>();
    await _startCallbackServer();

    final params = {
      'client_id': _clientId!,
      'user_scope': userScopes.join(','),
      'redirect_uri': redirectUri,
      'state': _state!,
    };

    final uri = Uri.parse(authEndpoint).replace(queryParameters: params);

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw Exception('Could not launch Slack auth URL');
    }
  }

  Future<void> _startCallbackServer() async {
    _callbackServer = await io.HttpServer.bind('127.0.0.1', callbackPort);

    _callbackServer!.listen((io.HttpRequest request) async {
      final uri = request.uri;

      if (uri.path == '/callback') {
        final code = uri.queryParameters['code'];
        final returnedState = uri.queryParameters['state'];
        final error = uri.queryParameters['error'];

        if (error != null) {
          request.response
            ..statusCode = 400
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(
              _buildCallbackHtml(
                success: false,
                message: 'Authorization denied: $error',
              ),
            );
          await request.response.close();

          if (!_authCodeCompleter!.isCompleted) {
            _authCodeCompleter!.completeError(
              Exception('Authorization denied: $error'),
            );
          }

          await _callbackServer?.close();
          _callbackServer = null;
          return;
        }

        if (returnedState != _state) {
          request.response
            ..statusCode = 400
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(
              _buildCallbackHtml(
                success: false,
                message: 'Invalid state parameter. Possible CSRF attack.',
              ),
            );
          await request.response.close();

          if (!_authCodeCompleter!.isCompleted) {
            _authCodeCompleter!.completeError(Exception('CSRF state mismatch'));
          }

          await _callbackServer?.close();
          _callbackServer = null;
          return;
        }

        if (code != null) {
          request.response
            ..statusCode = 200
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(
              _buildCallbackHtml(
                success: true,
                message:
                    'Slack connected successfully! You can close this window.',
              ),
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
            ..headers.set('Content-Type', 'text/html; charset=utf-8')
            ..write(
              _buildCallbackHtml(
                success: false,
                message: 'No authorization code received.',
              ),
            );
          await request.response.close();
        }
      }
    });
  }

  String _buildCallbackHtml({required bool success, required String message}) {
    final color = success ? '#36C5F0' : '#E01E5A';
    final title = success ? 'Slack Connected' : 'Connection Failed';
    final heading = success ? 'Success!' : 'Error';

    return '<!DOCTYPE html><html><head><title>$title</title>'
        '<style>'
        'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",'
        'Roboto,sans-serif;text-align:center;padding:60px 20px;'
        'background:$color;color:white;margin:0;}'
        'h1{font-size:48px;margin-bottom:16px;}'
        'p{font-size:18px;opacity:0.9;}'
        '.container{max-width:500px;margin:0 auto;}'
        '</style></head><body>'
        '<div class="container">'
        '<h1>$heading</h1>'
        '<p>$message</p>'
        '</div>'
        '</body></html>';
  }

  /// Wait for OAuth callback and exchange code for token.
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
          'client_id': _clientId!,
          'client_secret': _clientSecret!,
          'code': code,
          'redirect_uri': redirectUri,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        if (data['ok'] != true) {
          return false;
        }

        final authedUser = data['authed_user'] as Map<String, dynamic>?;
        _accessToken = authedUser?['access_token'] as String?;
        _userId = authedUser?['id'] as String?;

        final team = data['team'] as Map<String, dynamic>?;
        _teamId = team?['id'] as String?;
        _teamName = team?['name'] as String?;

        if (_accessToken != null) {
          await _saveTokens();
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Get current access token, loading from storage if needed.
  Future<String?> getAccessToken() async {
    if (_accessToken == null) {
      await _loadTokens();
    }
    return _accessToken;
  }

  Future<void> _saveTokens() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) {
      await prefs.setString('slack_access_token', _accessToken!);
    }
    if (_teamId != null) {
      await prefs.setString('slack_team_id', _teamId!);
    }
    if (_teamName != null) {
      await prefs.setString('slack_team_name', _teamName!);
    }
    if (_userId != null) {
      await prefs.setString('slack_user_id', _userId!);
    }
  }

  Future<void> _loadTokens() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('slack_access_token');
    _teamId = prefs.getString('slack_team_id');
    _teamName = prefs.getString('slack_team_name');
    _userId = prefs.getString('slack_user_id');
  }

  /// Check if authenticated (loads tokens from storage).
  Future<bool> isAuthenticated() async {
    await _loadTokens();
    return _accessToken != null;
  }

  /// Synchronous check for token presence.
  bool get hasToken => _accessToken != null;

  /// Current team name, if available.
  String? get teamName => _teamName;

  /// Current team ID, if available.
  String? get teamId => _teamId;

  /// Current user ID, if available.
  String? get userId => _userId;

  /// Logout and clear stored tokens.
  Future<void> logout() async {
    _accessToken = null;
    _teamId = null;
    _teamName = null;
    _userId = null;
    _state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('slack_access_token');
    await prefs.remove('slack_team_id');
    await prefs.remove('slack_team_name');
    await prefs.remove('slack_user_id');
  }

  // ---------------------------------------------------------------------------
  // Slack API methods
  // ---------------------------------------------------------------------------

  /// Make an authenticated GET request to the Slack API.
  Future<Map<String, dynamic>> _apiGet(
    String method, {
    Map<String, String>? params,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      throw StateError('Not authenticated with Slack');
    }

    final uri = Uri.parse('$apiBase/$method').replace(queryParameters: params);

    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['ok'] != true) {
      throw Exception('Slack API error: ${data['error'] ?? 'unknown'}');
    }
    return data;
  }

  /// Make an authenticated POST request to the Slack API (JSON body).
  Future<Map<String, dynamic>> _apiPost(
    String method, {
    required Map<String, dynamic> body,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      throw StateError('Not authenticated with Slack');
    }

    final response = await http.post(
      Uri.parse('$apiBase/$method'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode(body),
    );

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['ok'] != true) {
      throw Exception('Slack API error: ${data['error'] ?? 'unknown'}');
    }
    return data;
  }

  /// Test authentication and get user info.
  Future<Map<String, dynamic>> testAuth() async {
    return _apiGet('auth.test');
  }

  /// List channels the authenticated user can see.
  ///
  /// [types] defaults to `public_channel,private_channel`.
  /// [limit] controls page size (max 1000).
  Future<Map<String, dynamic>> listChannels({
    String types = 'public_channel,private_channel',
    int limit = 200,
    String? cursor,
  }) async {
    final params = <String, String>{
      'types': types,
      'limit': limit.toString(),
      'exclude_archived': 'true',
    };
    if (cursor != null) params['cursor'] = cursor;
    return _apiGet('conversations.list', params: params);
  }

  /// Get message history for a channel.
  ///
  /// [channel] is the channel ID.
  /// [limit] controls how many messages to return (max 1000).
  Future<Map<String, dynamic>> getChannelHistory({
    required String channel,
    int limit = 100,
    String? cursor,
    String? oldest,
    String? latest,
  }) async {
    final params = <String, String>{
      'channel': channel,
      'limit': limit.toString(),
    };
    if (cursor != null) params['cursor'] = cursor;
    if (oldest != null) params['oldest'] = oldest;
    if (latest != null) params['latest'] = latest;
    return _apiGet('conversations.history', params: params);
  }

  /// Send a message to a channel.
  Future<Map<String, dynamic>> sendMessage({
    required String channel,
    required String text,
    String? threadTs,
  }) async {
    final body = <String, dynamic>{'channel': channel, 'text': text};
    if (threadTs != null) body['thread_ts'] = threadTs;
    return _apiPost('chat.postMessage', body: body);
  }

  /// Search messages across the workspace.
  Future<Map<String, dynamic>> searchMessages({
    required String query,
    int count = 20,
    String? cursor,
    String sortBy = 'timestamp',
    String sortDir = 'desc',
  }) async {
    final params = <String, String>{
      'query': query,
      'count': count.toString(),
      'sort': sortBy,
      'sort_dir': sortDir,
    };
    if (cursor != null) params['cursor'] = cursor;
    return _apiGet('search.messages', params: params);
  }

  /// Get the list of users in the workspace.
  Future<Map<String, dynamic>> getUsers({
    int limit = 200,
    String? cursor,
  }) async {
    final params = <String, String>{'limit': limit.toString()};
    if (cursor != null) params['cursor'] = cursor;
    return _apiGet('users.list', params: params);
  }

  /// Find a channel by name.
  ///
  /// Returns the channel map if found, or `null` if not found.
  Future<Map<String, dynamic>?> findChannel(String name) async {
    try {
      String? cursor;
      do {
        final result = await listChannels(cursor: cursor);
        final channels = result['channels'] as List<dynamic>? ?? [];
        for (final ch in channels) {
          final channel = ch as Map<String, dynamic>;
          if (channel['name'] == name) {
            return channel;
          }
        }
        final metadata = result['response_metadata'] as Map<String, dynamic>?;
        cursor = metadata?['next_cursor'] as String?;
        if (cursor != null && cursor.isEmpty) cursor = null;
      } while (cursor != null);
      return null;
    } catch (_) {
      return null;
    }
  }
}
