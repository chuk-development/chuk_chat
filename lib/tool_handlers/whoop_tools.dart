import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/whoop_oauth.dart';

/// Execute a WHOOP health data action.
///
/// All data fetching is proxied through the API server at
/// `/v1/whoop/<action>`.  The server holds the WHOOP client credentials;
/// we only send the user's access token.
Future<String> executeWhoop(
  Map<String, dynamic> args,
  WhoopOAuth oauth,
) async {
  final isAuth = await oauth.checkAuthenticated();
  if (!isAuth) {
    return 'WHOOP not authenticated. '
        'Please connect your WHOOP account first.';
  }

  final action =
      (args['action'] as String? ?? 'status').trim().toLowerCase();
  final days = args['days'] as int? ?? 7;

  final accessToken = await oauth.getAccessToken();
  if (accessToken == null) {
    return 'WHOOP token expired and could not be refreshed. '
        'Please reconnect your WHOOP account.';
  }

  final supabaseToken = SupabaseService.auth.currentSession?.accessToken;
  final headers = <String, String>{
    'Content-Type': 'application/json',
    if (supabaseToken != null) 'Authorization': 'Bearer $supabaseToken',
  };
  final baseUrl = ApiConfigService.apiBaseUrl;

  try {
    switch (action) {
      case 'status':
        return _fetchData(baseUrl, headers, accessToken, 'status');
      case 'week':
        return _fetchData(baseUrl, headers, accessToken, 'week');
      case 'days':
        return _fetchData(
          baseUrl,
          headers,
          accessToken,
          'days',
          queryParams: {'days': days.toString()},
        );
      case 'sleep':
        return _fetchData(
          baseUrl,
          headers,
          accessToken,
          'sleep',
          queryParams: {'days': days.toString()},
        );
      case 'recovery':
        return _fetchData(
          baseUrl,
          headers,
          accessToken,
          'recovery',
          queryParams: {'days': days.toString()},
        );
      case 'strain':
        return _fetchData(
          baseUrl,
          headers,
          accessToken,
          'strain',
          queryParams: {'days': days.toString()},
        );
      case 'workouts':
        return _fetchData(
          baseUrl,
          headers,
          accessToken,
          'workouts',
          queryParams: {'days': days.toString()},
        );
      default:
        return 'Unknown WHOOP action "$action". '
            'Supported: status, week, days, sleep, recovery, strain, workouts';
    }
  } catch (e) {
    return 'WHOOP error: $e';
  }
}

Future<String> _fetchData(
  String baseUrl,
  Map<String, String> headers,
  String accessToken,
  String endpoint, {
  Map<String, String>? queryParams,
}) async {
  final uri = Uri.parse('$baseUrl/v1/whoop/$endpoint').replace(
    queryParameters: {
      'access_token': accessToken,
      ...?queryParams,
    },
  );

  final response = await http.get(uri, headers: headers).timeout(
    const Duration(seconds: 30),
  );

  if (response.statusCode == 200) {
    // The server returns a formatted text or JSON summary.
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('application/json')) {
      final data = jsonDecode(response.body);
      return _formatResponse(data, endpoint);
    }
    return response.body;
  }

  if (response.statusCode == 401) {
    return 'WHOOP authentication expired. Please reconnect your WHOOP account.';
  }

  return 'WHOOP API error (${response.statusCode}): ${response.body}';
}

String _formatResponse(dynamic data, String endpoint) {
  if (data is String) return data;
  if (data is Map<String, dynamic> && data.containsKey('message')) {
    return data['message'] as String;
  }
  // Return pretty-printed JSON for structured data.
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(data);
}
