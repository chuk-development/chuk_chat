import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Google OAuth Service - Backend-assisted flow for Gmail & Calendar APIs
class GoogleOAuth {
  static const int callbackPort = 43824;
  static String get redirectUri => 'http://127.0.0.1:$callbackPort/callback';
  static const String _backendUrl = 'https://function.chuk.dev';

  static const String _gmailApiBase = 'https://gmail.googleapis.com/gmail/v1';
  static const String _calendarApiBase =
      'https://www.googleapis.com/calendar/v3';
  static const String _userinfoUrl =
      'https://www.googleapis.com/oauth2/v2/userinfo';

  static const List<String> scopes = [
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/gmail.send',
    'https://www.googleapis.com/auth/gmail.modify',
    'https://www.googleapis.com/auth/calendar',
    'https://www.googleapis.com/auth/calendar.events',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
  ];

  io.HttpServer? _callbackServer;
  Completer<String>? _authCodeCompleter;

  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;
  String? _userEmail;
  String? _state;

  bool get isAuthenticated => _accessToken != null;
  String? get userEmail => _userEmail;

  // ---------------------------------------------------------------------------
  // Auth flow
  // ---------------------------------------------------------------------------

  /// Start OAuth flow - gets auth URL from backend, opens browser, starts
  /// local callback server.
  Future<void> startAuth() async {
    _state = _generateState();

    _authCodeCompleter = Completer<String>();
    await _startCallbackServer();

    final response = await http.get(
      Uri.parse('$_backendUrl/google/auth-url').replace(
        queryParameters: {
          'redirect_uri': redirectUri,
          'state': _state!,
          'scopes': scopes.join(' '),
        },
      ),
    );

    if (response.statusCode != 200) {
      await _stopCallbackServer();
      throw Exception('Failed to get auth URL: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final authUrl = data['auth_url'] as String?;
    if (authUrl == null) {
      await _stopCallbackServer();
      throw Exception('Backend did not return auth_url');
    }

    final uri = Uri.parse(authUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      await _stopCallbackServer();
      throw Exception('Could not launch Google authorization URL');
    }
  }

  /// Wait for the OAuth callback, exchange code for tokens via backend, and
  /// fetch user info.
  Future<bool> completeAuth() async {
    try {
      final code = await _authCodeCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Authorization timed out'),
      );

      await _stopCallbackServer();

      // Exchange code for tokens via backend
      final response = await http.post(
        Uri.parse('$_backendUrl/google/token'),
        headers: {'Content-Type': 'application/json'},
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

      // Fetch user email
      await _fetchUserInfo();
      await _saveTokens();
      return true;
    } catch (_) {
      await _stopCallbackServer();
      return false;
    }
  }

  /// Refresh the access token via the backend.
  Future<bool> refreshAccessToken() async {
    if (_refreshToken == null) return false;

    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/google/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': _refreshToken}),
      );

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body);
      _accessToken = data['access_token'] as String?;

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

  /// Logout and clear all stored tokens.
  Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    _userEmail = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('google_access_token');
    await prefs.remove('google_refresh_token');
    await prefs.remove('google_token_expiry');
    await prefs.remove('google_user_email');
  }

  // ---------------------------------------------------------------------------
  // Gmail API
  // ---------------------------------------------------------------------------

  /// List messages matching a query.
  Future<Map<String, dynamic>> listMessages({
    String? query,
    List<String>? labelIds,
    int maxResults = 20,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final params = <String, String>{
        'maxResults': maxResults.toString(),
        if (query != null) 'q': query,
        if (labelIds != null) 'labelIds': labelIds.join(','),
      };

      final uri = Uri.parse(
        '$_gmailApiBase/users/me/messages',
      ).replace(queryParameters: params);

      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error': 'Failed to list messages: ${response.statusCode}',
        };
      }

      final data = jsonDecode(response.body);
      final List<dynamic> messageRefs = data['messages'] ?? [];

      // Fetch details for each message
      final messages = <Map<String, dynamic>>[];
      for (final ref in messageRefs) {
        final detail = await _getMessageDetail(ref['id'] as String);
        if (detail != null) {
          messages.add(detail);
        }
      }

      return {
        'success': true,
        'messages': messages,
        'resultSizeEstimate': data['resultSizeEstimate'] ?? 0,
      };
    } catch (e) {
      return {'success': false, 'error': 'Error listing messages: $e'};
    }
  }

  /// Get message headers (subject, from, date) for a single message.
  Future<Map<String, dynamic>?> _getMessageDetail(String messageId) async {
    try {
      final uri = Uri.parse(
        '$_gmailApiBase/users/me/messages/$messageId',
      ).replace(queryParameters: {'format': 'metadata'});

      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final headers = data['payload']?['headers'] as List<dynamic>? ?? [];

      String? subject;
      String? from;
      String? date;
      for (final h in headers) {
        final name = (h['name'] as String).toLowerCase();
        if (name == 'subject') subject = h['value'] as String?;
        if (name == 'from') from = h['value'] as String?;
        if (name == 'date') date = h['value'] as String?;
      }

      return {
        'id': data['id'],
        'threadId': data['threadId'],
        'snippet': data['snippet'],
        'subject': subject,
        'from': from,
        'date': date,
        'labelIds': data['labelIds'],
      };
    } catch (_) {
      return null;
    }
  }

  /// Read a full message including body text.
  Future<Map<String, dynamic>> readMessage(String messageId) async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final uri = Uri.parse(
        '$_gmailApiBase/users/me/messages/$messageId',
      ).replace(queryParameters: {'format': 'full'});

      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error': 'Failed to read message: ${response.statusCode}',
        };
      }

      final data = jsonDecode(response.body);
      final headers = data['payload']?['headers'] as List<dynamic>? ?? [];

      String? subject;
      String? from;
      String? to;
      String? date;
      for (final h in headers) {
        final name = (h['name'] as String).toLowerCase();
        if (name == 'subject') subject = h['value'] as String?;
        if (name == 'from') from = h['value'] as String?;
        if (name == 'to') to = h['value'] as String?;
        if (name == 'date') date = h['value'] as String?;
      }

      final body = _extractBody(data['payload']);

      return {
        'success': true,
        'message': {
          'id': data['id'],
          'threadId': data['threadId'],
          'snippet': data['snippet'],
          'subject': subject,
          'from': from,
          'to': to,
          'date': date,
          'body': body,
          'labelIds': data['labelIds'],
        },
      };
    } catch (e) {
      return {'success': false, 'error': 'Error reading message: $e'};
    }
  }

  /// Send an email via Gmail API.
  Future<Map<String, dynamic>> sendEmail({
    required String to,
    required String subject,
    required String body,
    String? cc,
    String? bcc,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final from = _userEmail ?? 'me';
      final buffer = StringBuffer()
        ..writeln('From: $from')
        ..writeln('To: $to');
      if (cc != null) buffer.writeln('Cc: $cc');
      if (bcc != null) buffer.writeln('Bcc: $bcc');
      buffer
        ..writeln('Subject: $subject')
        ..writeln('Content-Type: text/plain; charset=utf-8')
        ..writeln()
        ..writeln(body);

      final raw = base64Url.encode(utf8.encode(buffer.toString()));

      final response = await http.post(
        Uri.parse('$_gmailApiBase/users/me/messages/send'),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({'raw': raw}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'messageId': data['id'],
          'threadId': data['threadId'],
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to send email: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error sending email: $e'};
    }
  }

  /// List Gmail labels.
  Future<Map<String, dynamic>> getLabels() async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final response = await http.get(
        Uri.parse('$_gmailApiBase/users/me/labels'),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final labels =
            (data['labels'] as List<dynamic>?)
                ?.map(
                  (l) => {'id': l['id'], 'name': l['name'], 'type': l['type']},
                )
                .toList() ??
            [];
        return {'success': true, 'labels': labels};
      } else {
        return {
          'success': false,
          'error': 'Failed to get labels: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error getting labels: $e'};
    }
  }

  // ---------------------------------------------------------------------------
  // Calendar API
  // ---------------------------------------------------------------------------

  /// List calendars for the authenticated user.
  Future<Map<String, dynamic>> listCalendars() async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final response = await http.get(
        Uri.parse('$_calendarApiBase/users/me/calendarList'),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final calendars =
            (data['items'] as List<dynamic>?)
                ?.map(
                  (c) => {
                    'id': c['id'],
                    'summary': c['summary'],
                    'description': c['description'],
                    'primary': c['primary'] ?? false,
                    'backgroundColor': c['backgroundColor'],
                  },
                )
                .toList() ??
            [];
        return {'success': true, 'calendars': calendars};
      } else {
        return {
          'success': false,
          'error': 'Failed to list calendars: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error listing calendars: $e'};
    }
  }

  /// List events from a calendar.
  Future<Map<String, dynamic>> listEvents({
    String calendarId = 'primary',
    DateTime? timeMin,
    DateTime? timeMax,
    int maxResults = 50,
    String? query,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final params = <String, String>{
        'maxResults': maxResults.toString(),
        'singleEvents': 'true',
        'orderBy': 'startTime',
        if (timeMin != null) 'timeMin': timeMin.toUtc().toIso8601String(),
        if (timeMax != null) 'timeMax': timeMax.toUtc().toIso8601String(),
        if (query != null) 'q': query,
      };

      final uri = Uri.parse(
        '$_calendarApiBase/calendars/${Uri.encodeComponent(calendarId)}/events',
      ).replace(queryParameters: params);

      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final events =
            (data['items'] as List<dynamic>?)
                ?.map(
                  (e) => {
                    'id': e['id'],
                    'summary': e['summary'],
                    'description': e['description'],
                    'location': e['location'],
                    'start': e['start'],
                    'end': e['end'],
                    'status': e['status'],
                    'htmlLink': e['htmlLink'],
                    'attendees': e['attendees'],
                  },
                )
                .toList() ??
            [];
        return {'success': true, 'events': events};
      } else {
        return {
          'success': false,
          'error': 'Failed to list events: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error listing events: $e'};
    }
  }

  /// Create a new calendar event.
  Future<Map<String, dynamic>> createEvent({
    String calendarId = 'primary',
    required String summary,
    String? description,
    String? location,
    required DateTime start,
    required DateTime end,
    List<String>? attendees,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final eventBody = <String, dynamic>{
        'summary': summary,
        if (description != null) 'description': description,
        if (location != null) 'location': location,
        'start': {'dateTime': start.toUtc().toIso8601String()},
        'end': {'dateTime': end.toUtc().toIso8601String()},
        if (attendees != null)
          'attendees': attendees.map((e) => {'email': e}).toList(),
      };

      final response = await http.post(
        Uri.parse(
          '$_calendarApiBase/calendars/${Uri.encodeComponent(calendarId)}/events',
        ),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode(eventBody),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'event': {
            'id': data['id'],
            'summary': data['summary'],
            'htmlLink': data['htmlLink'],
            'start': data['start'],
            'end': data['end'],
          },
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to create event: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error creating event: $e'};
    }
  }

  /// Update an existing calendar event.
  Future<Map<String, dynamic>> updateEvent({
    String calendarId = 'primary',
    required String eventId,
    String? summary,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final eventBody = <String, dynamic>{
        if (summary != null) 'summary': summary,
        if (description != null) 'description': description,
        if (location != null) 'location': location,
        if (start != null)
          'start': {'dateTime': start.toUtc().toIso8601String()},
        if (end != null) 'end': {'dateTime': end.toUtc().toIso8601String()},
      };

      final response = await http.patch(
        Uri.parse(
          '$_calendarApiBase/calendars/${Uri.encodeComponent(calendarId)}'
          '/events/${Uri.encodeComponent(eventId)}',
        ),
        headers: {..._authHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode(eventBody),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'event': {
            'id': data['id'],
            'summary': data['summary'],
            'htmlLink': data['htmlLink'],
            'start': data['start'],
            'end': data['end'],
          },
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to update event: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error updating event: $e'};
    }
  }

  /// Delete a calendar event.
  Future<Map<String, dynamic>> deleteEvent({
    String calendarId = 'primary',
    required String eventId,
  }) async {
    final token = await getAccessToken();
    if (token == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    try {
      final response = await http.delete(
        Uri.parse(
          '$_calendarApiBase/calendars/${Uri.encodeComponent(calendarId)}'
          '/events/${Uri.encodeComponent(eventId)}',
        ),
        headers: _authHeaders,
      );

      if (response.statusCode == 204 || response.statusCode == 200) {
        return {'success': true};
      } else {
        return {
          'success': false,
          'error': 'Failed to delete event: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error deleting event: $e'};
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $_accessToken',
    'Accept': 'application/json',
  };

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
            ..write(_buildHtml('Google Connected!', true));
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
    final color = success ? '#34A853' : '#EA4335';
    return '<!DOCTYPE html><html><head><title>$title</title>'
        '<style>body{font-family:sans-serif;display:flex;'
        'justify-content:center;align-items:center;'
        'height:100vh;margin:0;background:#202124;color:#e8eaed;}'
        '.c{text-align:center;padding:40px;background:#292a2d;'
        'border-radius:12px;border:1px solid #3c4043;}'
        'h1{color:$color;}</style></head><body>'
        '<div class="c"><h1>$title</h1>'
        '<p>You can close this window.</p></div></body></html>';
  }

  Future<void> _fetchUserInfo() async {
    try {
      final response = await http.get(
        Uri.parse(_userinfoUrl),
        headers: _authHeaders,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _userEmail = data['email'] as String?;
      }
    } catch (_) {
      // Non-critical: email is used for display only
    }
  }

  /// Recursively extract plain text body from a Gmail message payload.
  String _extractBody(Map<String, dynamic>? payload) {
    if (payload == null) return '';

    // Check for body data directly on this part
    final body = payload['body'] as Map<String, dynamic>?;
    if (body != null) {
      final data = body['data'] as String?;
      if (data != null && data.isNotEmpty) {
        final mimeType = payload['mimeType'] as String? ?? '';
        if (mimeType == 'text/plain') {
          return _decodeBase64Url(data);
        }
      }
    }

    // Recurse into parts
    final parts = payload['parts'] as List<dynamic>?;
    if (parts != null) {
      // Prefer text/plain over text/html
      for (final part in parts) {
        final partMap = part as Map<String, dynamic>;
        final mimeType = partMap['mimeType'] as String? ?? '';
        if (mimeType == 'text/plain') {
          final partBody = partMap['body'] as Map<String, dynamic>?;
          final data = partBody?['data'] as String?;
          if (data != null && data.isNotEmpty) {
            return _decodeBase64Url(data);
          }
        }
      }

      // Recurse into multipart sections
      for (final part in parts) {
        final result = _extractBody(part as Map<String, dynamic>);
        if (result.isNotEmpty) return result;
      }
    }

    return '';
  }

  /// Decode Gmail's URL-safe base64 encoding.
  String _decodeBase64Url(String data) {
    try {
      // Gmail uses URL-safe base64 without padding
      String normalized = data.replaceAll('-', '+').replaceAll('_', '/');
      final remainder = normalized.length % 4;
      if (remainder != 0) {
        normalized += '=' * (4 - remainder);
      }
      return utf8.decode(base64.decode(normalized));
    } catch (_) {
      return '';
    }
  }

  Future<void> _saveTokens() async {
    final prefs = await SharedPreferences.getInstance();
    if (_accessToken != null) {
      await prefs.setString('google_access_token', _accessToken!);
    }
    if (_refreshToken != null) {
      await prefs.setString('google_refresh_token', _refreshToken!);
    }
    if (_tokenExpiry != null) {
      await prefs.setString(
        'google_token_expiry',
        _tokenExpiry!.toIso8601String(),
      );
    }
    if (_userEmail != null) {
      await prefs.setString('google_user_email', _userEmail!);
    }
  }

  Future<void> _loadTokens() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('google_access_token');
    _refreshToken = prefs.getString('google_refresh_token');
    _userEmail = prefs.getString('google_user_email');
    final expiryStr = prefs.getString('google_token_expiry');
    if (expiryStr != null) {
      _tokenExpiry = DateTime.parse(expiryStr);
    }
  }
}
