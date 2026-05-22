import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/multiplex_tool_proxy.dart';

class SandboxInfo {
  const SandboxInfo({
    required this.sessionId,
    required this.chatId,
    required this.status,
    required this.createdAt,
    required this.lastActivity,
    required this.snapshotRestored,
  });

  final String sessionId;
  final String? chatId;
  final String status;
  final DateTime createdAt;
  final DateTime lastActivity;
  final bool snapshotRestored;

  factory SandboxInfo.fromJson(Map<String, dynamic> json) {
    return SandboxInfo(
      sessionId: (json['session_id'] ?? '').toString(),
      chatId: json['chat_id'] is String
          ? json['chat_id'] as String
          : json['chat_id']?.toString(),
      status: (json['status'] ?? '').toString(),
      createdAt: _parseDate(json['created_at']),
      lastActivity: _parseDate(json['last_activity']),
      snapshotRestored: json['snapshot_restored'] == true,
    );
  }
}

class SandboxExecResult {
  const SandboxExecResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.executionTimeMs,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
  final int executionTimeMs;

  factory SandboxExecResult.fromJson(Map<String, dynamic> json) {
    return SandboxExecResult(
      stdout: (json['stdout'] ?? '').toString(),
      stderr: (json['stderr'] ?? '').toString(),
      exitCode: _asInt(json['exit_code']) ?? 0,
      executionTimeMs: _asInt(json['execution_time_ms']) ?? 0,
    );
  }
}

class SandboxFileEntry {
  const SandboxFileEntry({
    required this.name,
    this.size,
    this.isDir = false,
    this.permissions = '',
  });

  final String name;
  final int? size;
  final bool isDir;
  final String permissions;

  factory SandboxFileEntry.fromJson(Map<String, dynamic> json) {
    return SandboxFileEntry(
      name: (json['name'] ?? '').toString(),
      size: _asInt(json['size']),
      isDir: json['is_dir'] == true,
      permissions: (json['permissions'] ?? '').toString(),
    );
  }
}

class SandboxUploadResult {
  const SandboxUploadResult({required this.path, required this.size});
  final String path;
  final int size;
}

class SandboxDownloadResult {
  const SandboxDownloadResult({
    required this.bytes,
    required this.filename,
    required this.contentType,
  });

  final Uint8List bytes;
  final String? filename;
  final String contentType;
}

class SandboxServiceException implements Exception {
  SandboxServiceException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'SandboxServiceException($statusCode): $message';
}

class SandboxService {
  static const Duration _controlTimeout = Duration(seconds: 30);
  static const Duration _executeTimeout = Duration(seconds: 320);
  static const Duration _transferTimeout = Duration(seconds: 60);

  static String get _base => ApiConfigService.apiBaseUrl;

  static Map<String, String> _authHeaders(String accessToken, {bool json = false}) {
    return {
      'Authorization': 'Bearer $accessToken',
      if (json) 'Content-Type': 'application/json',
    };
  }

  static Future<SandboxInfo> create({
    required String accessToken,
    String? chatId,
  }) async {
    final payload = <String, dynamic>{
      'chat_id': ?chatId,
    };

    final mux = await tryToolViaMultiplex(
      tool: 'sandbox_create',
      payload: payload,
    );
    if (mux.isError) {
      throw SandboxServiceException(0, mux.error.toString());
    }
    if (mux.isOk) {
      final body = mux.body!;
      return SandboxInfo.fromJson(body);
    }

    final uri = Uri.parse('$_base/v1/ai/sandbox/create');
    final response = await http
        .post(
          uri,
          headers: _authHeaders(accessToken, json: true),
          body: jsonEncode(payload),
        )
        .timeout(_controlTimeout);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _toException(response);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw SandboxServiceException(
        response.statusCode,
        'Malformed sandbox create response.',
      );
    }
    return SandboxInfo.fromJson(decoded);
  }

  static Future<List<SandboxInfo>> list({required String accessToken}) async {
    Map<String, dynamic>? decoded;
    final mux = await tryToolViaMultiplex(
      tool: 'sandbox_list',
      payload: const <String, dynamic>{},
    );
    if (mux.isError) {
      throw SandboxServiceException(0, mux.error.toString());
    }
    if (mux.isOk) {
      decoded = mux.body;
    } else {
      final uri = Uri.parse('$_base/v1/ai/sandbox/list');
      final response = await http
          .get(uri, headers: _authHeaders(accessToken))
          .timeout(_controlTimeout);
      if (response.statusCode != 200) {
        throw _toException(response);
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw SandboxServiceException(
          response.statusCode,
          'Malformed sandbox list response.',
        );
      }
      decoded = body;
    }
    final raw = decoded?['sandboxes'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => SandboxInfo.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static Future<SandboxInfo?> get_({
    required String accessToken,
    required String sessionId,
  }) async {
    final mux = await tryToolViaMultiplex(
      tool: 'sandbox_info',
      payload: {'session_id': sessionId},
    );
    if (mux.isError) {
      final err = mux.error;
      // The server signals a missing sandbox via a `not_found` code.
      if (err.toString().toLowerCase().contains('not_found') ||
          err.toString().contains('404')) {
        return null;
      }
      throw SandboxServiceException(0, err.toString());
    }
    if (mux.isOk) {
      return SandboxInfo.fromJson(mux.body!);
    }

    final uri = Uri.parse('$_base/v1/ai/sandbox/$sessionId');
    final response = await http
        .get(uri, headers: _authHeaders(accessToken))
        .timeout(_controlTimeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw _toException(response);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw SandboxServiceException(
        response.statusCode,
        'Malformed sandbox get response.',
      );
    }
    return SandboxInfo.fromJson(decoded);
  }

  static Future<void> extend({
    required String accessToken,
    required String sessionId,
  }) async {
    final mux = await tryToolViaMultiplex(
      tool: 'sandbox_extend',
      payload: {'session_id': sessionId},
    );
    if (mux.isError) {
      throw SandboxServiceException(0, mux.error.toString());
    }
    if (mux.isOk) return;

    final uri = Uri.parse('$_base/v1/ai/sandbox/$sessionId/extend');
    final response = await http
        .post(uri, headers: _authHeaders(accessToken))
        .timeout(_controlTimeout);
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw _toException(response);
    }
  }

  static Future<void> destroy({
    required String accessToken,
    required String sessionId,
  }) async {
    final mux = await tryToolViaMultiplex(
      tool: 'sandbox_destroy',
      payload: {'session_id': sessionId},
    );
    if (mux.isError) {
      throw SandboxServiceException(0, mux.error.toString());
    }
    if (mux.isOk) return;

    final uri = Uri.parse('$_base/v1/ai/sandbox/$sessionId');
    final response = await http
        .delete(uri, headers: _authHeaders(accessToken))
        .timeout(_controlTimeout);
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw _toException(response);
    }
  }

  static Future<SandboxExecResult> execute({
    required String accessToken,
    required String sessionId,
    required String code,
    String language = 'python',
    int? timeout,
  }) async {
    final payload = <String, dynamic>{
      'session_id': sessionId,
      'code': code,
      'language': language,
      'timeout': ?timeout,
    };

    final mux = await tryToolViaMultiplex(
      tool: 'sandbox_execute',
      payload: payload,
    );
    if (mux.isError) {
      throw SandboxServiceException(0, mux.error.toString());
    }
    if (mux.isOk) {
      return SandboxExecResult.fromJson(mux.body!);
    }

    final uri = Uri.parse('$_base/v1/ai/sandbox/$sessionId/execute');
    final httpPayload = <String, dynamic>{
      'code': code,
      'language': language,
      'timeout': ?timeout,
    };
    final response = await http
        .post(
          uri,
          headers: _authHeaders(accessToken, json: true),
          body: jsonEncode(httpPayload),
        )
        .timeout(_executeTimeout);
    if (response.statusCode != 200) {
      throw _toException(response);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw SandboxServiceException(
        response.statusCode,
        'Malformed execute response.',
      );
    }
    return SandboxExecResult.fromJson(decoded);
  }

  static Future<List<SandboxFileEntry>> listFiles({
    required String accessToken,
    required String sessionId,
    String path = '/home/sandbox',
  }) async {
    Map<String, dynamic>? decoded;
    final mux = await tryToolViaMultiplex(
      tool: 'sandbox_files_list',
      payload: {'session_id': sessionId, 'path': path},
    );
    if (mux.isError) {
      throw SandboxServiceException(0, mux.error.toString());
    }
    if (mux.isOk) {
      decoded = mux.body;
    } else {
      final uri = Uri.parse(
        '$_base/v1/ai/sandbox/$sessionId/files/list',
      ).replace(queryParameters: {'path': path});
      final response = await http
          .get(uri, headers: _authHeaders(accessToken))
          .timeout(_transferTimeout);
      if (response.statusCode != 200) {
        throw _toException(response);
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw SandboxServiceException(
          response.statusCode,
          'Malformed listFiles response.',
        );
      }
      decoded = body;
    }
    final raw = decoded?['files'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => SandboxFileEntry.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static Future<SandboxUploadResult> uploadFile({
    required String accessToken,
    required String sessionId,
    required String filename,
    required List<int> data,
    String contentType = 'application/octet-stream',
    String path = '/home/sandbox',
  }) async {
    final uri = Uri.parse(
      '$_base/v1/ai/sandbox/$sessionId/files/upload',
    ).replace(queryParameters: {'path': path});
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..files.add(
        http.MultipartFile.fromBytes('file', data, filename: filename),
      );
    final streamed = await request.send().timeout(_transferTimeout);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _toException(response);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw SandboxServiceException(
        response.statusCode,
        'Malformed upload response.',
      );
    }
    return SandboxUploadResult(
      path: (decoded['path'] ?? '').toString(),
      size: _asInt(decoded['size']) ?? data.length,
    );
  }

  static Future<SandboxDownloadResult> downloadFile({
    required String accessToken,
    required String sessionId,
    required String path,
  }) async {
    final uri = Uri.parse(
      '$_base/v1/ai/sandbox/$sessionId/files/download',
    ).replace(queryParameters: {'path': path});
    final response = await http
        .get(uri, headers: _authHeaders(accessToken))
        .timeout(_transferTimeout);
    if (response.statusCode != 200) {
      throw _toException(response);
    }
    final disposition = response.headers['content-disposition'];
    return SandboxDownloadResult(
      bytes: response.bodyBytes,
      filename: _filenameFromDisposition(disposition),
      contentType:
          response.headers['content-type'] ?? 'application/octet-stream',
    );
  }

  static SandboxServiceException _toException(http.Response response) {
    String message = 'HTTP ${response.statusCode}';
    if (response.body.isNotEmpty) {
      try {
        final data = jsonDecode(response.body);
        if (data is Map && data['detail'] is String) {
          message = data['detail'] as String;
        } else if (data is Map && data['detail'] != null) {
          message = data['detail'].toString();
        } else {
          message = response.body;
        }
      } catch (_) {
        message = response.body;
      }
    }
    if (message.length > 500) {
      message = '${message.substring(0, 500)}...';
    }
    return SandboxServiceException(response.statusCode, message);
  }

  static String? _filenameFromDisposition(String? header) {
    if (header == null || header.isEmpty) return null;
    final extMatch =
        RegExp(r"""filename\*=([^']*)'[^']*'([^;]+)""", caseSensitive: false)
            .firstMatch(header);
    if (extMatch != null) {
      final encoded = extMatch.group(2)?.trim();
      if (encoded != null && encoded.isNotEmpty) {
        try {
          return Uri.decodeComponent(encoded);
        } catch (_) {
          return encoded;
        }
      }
    }
    final quoted = RegExp(
      r'filename\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(header);
    if (quoted != null) {
      return quoted.group(1);
    }
    final bare = RegExp(
      r'filename\s*=\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(header);
    if (bare != null) {
      return bare.group(1)?.trim();
    }
    return null;
  }
}

DateTime _parseDate(dynamic value) {
  if (value is String && value.isNotEmpty) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Per-chat sandbox session bookkeeping.
///
/// A chat keeps the same upstream session id across tool calls so state
/// (files, installed packages, variables) persists. The cache lives next
/// to the HTTP client it gates so callers — tool handlers, sign-out
/// hooks — depend only on the service layer instead of importing
/// individual tool-handler files.
class SandboxSessionCache {
  SandboxSessionCache._();

  static final Map<String, String> _sessionByChat = {};
  static final Map<String, Future<String>> _inflightEnsure = {};

  /// Hard ceiling on a single ensure attempt. Both SandboxService.get_ and
  /// SandboxService.create have their own 30s control-plane timeouts, so
  /// a well-behaved upstream finishes well under this. The wrapper exists
  /// as belt-and-braces against TLS-handshake stalls or platform-level
  /// socket hangs that bypass the HTTP-layer timeout — without it a hung
  /// ensure would block every subsequent ensure for that chat forever.
  static const Duration _ensureTimeout = Duration(seconds: 75);

  /// Return the session id for `chatId`, creating + caching one if
  /// needed. Concurrent calls for the same chat share one in-flight
  /// future so two parallel tool calls never both call create().
  static Future<String> ensureSession({
    required String accessToken,
    required String chatId,
  }) {
    final inflight = _inflightEnsure[chatId];
    if (inflight != null) return inflight;

    final future = _ensureImpl(accessToken, chatId).timeout(_ensureTimeout);
    _inflightEnsure[chatId] = future;
    future.whenComplete(() => _inflightEnsure.remove(chatId));
    return future;
  }

  static Future<String> _ensureImpl(String accessToken, String chatId) async {
    final cached = _sessionByChat[chatId];
    if (cached != null) {
      try {
        final info = await SandboxService.get_(
          accessToken: accessToken,
          sessionId: cached,
        );
        if (info != null) {
          return cached;
        }
        _sessionByChat.remove(chatId);
      } on SandboxServiceException catch (e) {
        // Only 404 means "session is genuinely gone". Transient 5xx /
        // timeout propagates so the caller can decide whether to retry,
        // and the cached id stays so we don't churn sandboxes on blips.
        if (e.statusCode == 404) {
          _sessionByChat.remove(chatId);
        } else {
          rethrow;
        }
      }
    }

    final info = await SandboxService.create(
      accessToken: accessToken,
      chatId: chatId,
    );
    _sessionByChat[chatId] = info.sessionId;
    return info.sessionId;
  }

  /// Forget the cached session id (and any racing in-flight ensure) for
  /// `chatId`. Returns the previously cached session id when one was
  /// present so the caller can destroy it upstream.
  static String? forgetChat(String chatId) {
    final sessionId = _sessionByChat.remove(chatId);
    _inflightEnsure.remove(chatId);
    return sessionId;
  }

  /// Wipe everything. Called from `AuthService.signOut()` so the next
  /// signed-in user doesn't observe the previous user's session ids
  /// (the server would reject them on the owner-tag check anyway, but
  /// clearing here saves a round-trip).
  static void clearAll() {
    _sessionByChat.clear();
    _inflightEnsure.clear();
  }
}
