import 'dart:convert';

import 'package:http/http.dart' as http;

/// Error returned by a Supabase RPC call.
class ChukdooApiException implements Exception {
  final int statusCode;
  final String message;
  final String? code;

  const ChukdooApiException(this.statusCode, this.message, {this.code});

  /// The device token is unknown or was revoked in the app.
  bool get isUnauthorized =>
      statusCode == 401 || code == '28000' || message.contains('invalid device token');

  @override
  String toString() =>
      'ChukdooApiException($statusCode${code == null ? '' : ', $code'}): $message';
}

/// Minimal PostgREST RPC client over plain HTTP (no supabase SDK).
///
/// Every request carries the anon key as `apikey`; identity comes from the
/// device token passed as a function argument, never from a user session.
class SupabaseRpc {
  final Uri _base;
  final String _anonKey;
  final http.Client _http;
  final Duration timeout;

  SupabaseRpc({
    required String supabaseUrl,
    required String anonKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  })  : _base = Uri.parse(supabaseUrl.endsWith('/')
            ? supabaseUrl.substring(0, supabaseUrl.length - 1)
            : supabaseUrl),
        _anonKey = anonKey,
        _http = client ?? http.Client();

  Future<dynamic> call(String function, Map<String, dynamic> params) async {
    final uri = _base.replace(path: '${_base.path}/rest/v1/rpc/$function');
    final response = await _http
        .post(
          uri,
          headers: {
            'apikey': _anonKey,
            'Authorization': 'Bearer $_anonKey',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(params),
        )
        .timeout(timeout);
    final body = response.body;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (body.isEmpty) return null;
      return jsonDecode(body);
    }
    String message = body;
    String? code;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        message = (decoded['message'] ?? decoded['error'] ?? body).toString();
        code = decoded['code']?.toString();
      }
    } catch (_) {}
    throw ChukdooApiException(response.statusCode, message, code: code);
  }

  void close() => _http.close();
}

/// The tables a device may touch (see the migration's whitelist).
enum ChukdooTable {
  todos('todos'),
  projects('projects'),
  calendars('calendars'),
  calendarEvents('calendar_events'),
  habits('habits'),
  notes('notes'),
  noteFolders('note_folders');

  const ChukdooTable(this.sqlName);
  final String sqlName;
}

/// The device data API: raw (still encrypted) rows in and out.
class DeviceApi {
  final SupabaseRpc rpc;
  final String deviceToken;

  DeviceApi({required this.rpc, required this.deviceToken});

  Future<Map<String, dynamic>> whoami() async =>
      Map<String, dynamic>.from(
          await rpc.call('device_whoami', {'p_token': deviceToken}) as Map);

  Future<List<Map<String, dynamic>>> pull(ChukdooTable table,
      {DateTime? since}) async {
    final result = await rpc.call('device_pull', {
      'p_token': deviceToken,
      'p_table': table.sqlName,
      'p_since': since?.toUtc().toIso8601String(),
    });
    return [
      for (final row in (result as List? ?? const []))
        Map<String, dynamic>.from(row as Map),
    ];
  }

  Future<void> upsert(ChukdooTable table, Map<String, dynamic> row) async {
    await rpc.call('device_upsert', {
      'p_token': deviceToken,
      'p_table': table.sqlName,
      'p_row': row,
    });
  }

  /// Revokes this device's token on the server.
  Future<void> unpair() async {
    await rpc.call('device_unpair', {'p_token': deviceToken});
  }

  /// Returns the number of deleted rows (0 if it did not exist).
  Future<int> delete(ChukdooTable table, String id) async {
    final result = await rpc.call('device_delete', {
      'p_token': deviceToken,
      'p_table': table.sqlName,
      'p_id': id,
    });
    return (result as Map?)?['deleted'] as int? ?? 0;
  }
}
