import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// GitHub OAuth Service - Supports both OAuth App and Personal Access Token
class GitHubOAuth {
  static const int callbackPort = 43825;
  static String get redirectUri => 'http://127.0.0.1:$callbackPort/callback';

  static const String authEndpoint = 'https://github.com/login/oauth/authorize';
  static const String tokenEndpoint =
      'https://github.com/login/oauth/access_token';
  static const String apiBase = 'https://api.github.com';

  static const List<String> scopes = ['repo', 'read:user', 'read:org'];

  String? _accessToken;
  String? _clientId;
  bool _isPersonalToken = false;
  String? _state;

  io.HttpServer? _callbackServer;
  Completer<String>? _authCodeCompleter;

  bool get isAuthenticated => _accessToken != null;
  bool get isPersonalToken => _isPersonalToken;

  Future<void> loadSavedToken() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('github_access_token');
    _isPersonalToken = prefs.getBool('github_is_personal_token') ?? false;
    _clientId = prefs.getString('github_client_id');
  }

  Future<void> setPersonalToken(String token) async {
    final response = await http.get(
      Uri.parse('$apiBase/user'),
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github.v3+json',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Invalid token: ${response.statusCode}');
    }

    _accessToken = token;
    _isPersonalToken = true;
    await _saveToken();
  }

  Future<void> setClientId(String clientId) async {
    _clientId = clientId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('github_client_id', clientId);
  }

  Future<void> startAuth() async {
    if (_clientId == null || _clientId!.isEmpty) {
      throw Exception(
        'GitHub OAuth requires client_id. '
        'Set it via setClientId() first.',
      );
    }

    _state = _generateState();

    final params = {
      'client_id': _clientId!,
      'redirect_uri': redirectUri,
      'scope': scopes.join(' '),
      'state': _state!,
    };

    _authCodeCompleter = Completer<String>();
    await _startCallbackServer();

    final uri = Uri.parse(authEndpoint).replace(queryParameters: params);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      throw Exception('Could not launch GitHub authorization URL');
    }
  }

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
            ..headers.set('Content-Type', 'text/html')
            ..write(_buildHtml('Authorization Failed', false));
          await request.response.close();
          return;
        }

        if (state != _state) {
          _authCodeCompleter?.completeError(Exception('State mismatch'));
          request.response
            ..statusCode = 200
            ..headers.set('Content-Type', 'text/html')
            ..write(_buildHtml('Security Error', false));
          await request.response.close();
          return;
        }

        if (code != null) {
          _authCodeCompleter?.complete(code);
          request.response
            ..statusCode = 200
            ..headers.set('Content-Type', 'text/html')
            ..write(_buildHtml('GitHub Connected!', true));
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

  String _buildHtml(String title, bool success) {
    final color = success ? '#28a745' : '#dc3545';
    return '<!DOCTYPE html><html><head><title>$title</title>'
        '<style>body{font-family:sans-serif;display:flex;'
        'justify-content:center;align-items:center;'
        'height:100vh;margin:0;background:#0d1117;color:#c9d1d9;}'
        '.c{text-align:center;padding:40px;background:#161b22;'
        'border-radius:12px;border:1px solid #30363d;}'
        'h1{color:$color;}</style></head><body>'
        '<div class="c"><h1>$title</h1>'
        '<p>You can close this window.</p></div></body></html>';
  }

  Future<bool> completeAuth({String? clientSecret}) async {
    try {
      final code = await _authCodeCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Authorization timed out'),
      );

      await _stopCallbackServer();

      if (clientSecret != null) {
        final response = await http.post(
          Uri.parse(tokenEndpoint),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {
            'client_id': _clientId,
            'client_secret': clientSecret,
            'code': code,
            'redirect_uri': redirectUri,
          },
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['access_token'] != null) {
            _accessToken = data['access_token'] as String;
            _isPersonalToken = false;
            await _saveToken();
            return true;
          }
        }
        return false;
      } else {
        throw Exception(
          'OAuth requires client_secret on backend. '
          'Use Personal Access Token instead.',
        );
      }
    } catch (e) {
      await _stopCallbackServer();
      rethrow;
    }
  }

  Future<void> _stopCallbackServer() async {
    await _callbackServer?.close();
    _callbackServer = null;
  }

  Future<void> _saveToken() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) {
      await prefs.setString('github_access_token', _accessToken!);
      await prefs.setBool('github_is_personal_token', _isPersonalToken);
    }
  }

  Future<void> logout() async {
    _accessToken = null;
    _isPersonalToken = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('github_access_token');
    await prefs.remove('github_is_personal_token');
  }

  String? getAccessToken() => _accessToken;

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $_accessToken',
    'Accept': 'application/vnd.github.v3+json',
  };

  Future<Map<String, dynamic>> getUser() async {
    if (_accessToken == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final response = await http.get(
        Uri.parse('$apiBase/user'),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'user': {
            'login': data['login'],
            'name': data['name'],
            'email': data['email'],
            'public_repos': data['public_repos'],
            'followers': data['followers'],
          },
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to get user: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error getting user: $e'};
    }
  }

  Future<Map<String, dynamic>> listRepos({
    String? type,
    String? sort,
    int perPage = 30,
  }) async {
    if (_accessToken == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final params = <String, String>{
        'per_page': perPage.toString(),
        if (type != null) 'type': type,
        if (sort != null) 'sort': sort,
      };

      final uri = Uri.parse(
        '$apiBase/user/repos',
      ).replace(queryParameters: params);
      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return {
          'success': true,
          'repos': data
              .map(
                (r) => {
                  'name': r['name'],
                  'full_name': r['full_name'],
                  'description': r['description'],
                  'private': r['private'],
                  'html_url': r['html_url'],
                  'language': r['language'],
                  'stargazers_count': r['stargazers_count'],
                  'forks_count': r['forks_count'],
                  'updated_at': r['updated_at'],
                },
              )
              .toList(),
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to list repos: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error listing repos: $e'};
    }
  }

  Future<Map<String, dynamic>> getRepo(String owner, String repo) async {
    if (_accessToken == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final response = await http.get(
        Uri.parse('$apiBase/repos/$owner/$repo'),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'repo': {
            'name': data['name'],
            'full_name': data['full_name'],
            'description': data['description'],
            'private': data['private'],
            'stargazers_count': data['stargazers_count'],
            'forks_count': data['forks_count'],
            'open_issues_count': data['open_issues_count'],
            'default_branch': data['default_branch'],
          },
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to get repo: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error getting repo: $e'};
    }
  }

  Future<Map<String, dynamic>> listIssues(
    String owner,
    String repo, {
    String state = 'open',
    int perPage = 30,
  }) async {
    if (_accessToken == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final params = {'state': state, 'per_page': perPage.toString()};

      final uri = Uri.parse(
        '$apiBase/repos/$owner/$repo/issues',
      ).replace(queryParameters: params);
      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return {
          'success': true,
          'issues': data
              .map(
                (i) => {
                  'number': i['number'],
                  'title': i['title'],
                  'state': i['state'],
                  'user': i['user']['login'],
                  'labels': (i['labels'] as List)
                      .map((l) => l['name'])
                      .toList(),
                  'comments': i['comments'],
                  'html_url': i['html_url'],
                },
              )
              .toList(),
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to list issues: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error listing issues: $e'};
    }
  }

  Future<Map<String, dynamic>> createIssue(
    String owner,
    String repo, {
    required String title,
    String? body,
    List<String>? labels,
  }) async {
    if (_accessToken == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final response = await http.post(
        Uri.parse('$apiBase/repos/$owner/$repo/issues'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          if (body != null) 'body': body,
          if (labels != null) 'labels': labels,
        }),
      );

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'issue': {
            'number': data['number'],
            'title': data['title'],
            'html_url': data['html_url'],
          },
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to create issue: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error creating issue: $e'};
    }
  }

  Future<Map<String, dynamic>> listPullRequests(
    String owner,
    String repo, {
    String state = 'open',
    int perPage = 30,
  }) async {
    if (_accessToken == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final params = {'state': state, 'per_page': perPage.toString()};

      final uri = Uri.parse(
        '$apiBase/repos/$owner/$repo/pulls',
      ).replace(queryParameters: params);
      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return {
          'success': true,
          'pull_requests': data
              .map(
                (pr) => {
                  'number': pr['number'],
                  'title': pr['title'],
                  'state': pr['state'],
                  'user': pr['user']['login'],
                  'head': pr['head']['ref'],
                  'base': pr['base']['ref'],
                  'html_url': pr['html_url'],
                  'draft': pr['draft'],
                },
              )
              .toList(),
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to list PRs: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error listing PRs: $e'};
    }
  }

  Future<Map<String, dynamic>> addComment(
    String owner,
    String repo,
    int issueNumber, {
    required String body,
  }) async {
    if (_accessToken == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final response = await http.post(
        Uri.parse('$apiBase/repos/$owner/$repo/issues/$issueNumber/comments'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({'body': body}),
      );

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'comment': {'id': data['id'], 'html_url': data['html_url']},
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to add comment: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error adding comment: $e'};
    }
  }
}
