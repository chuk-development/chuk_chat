// lib/tool_handlers/artifact_tools.dart
// Server-backed handlers for the `create_artifact` / `update_artifact` tools.
//
// These publish a self-contained HTML page to the artifacts hosting service
// (see ARTIFACTS_BASE_URL / ApiConfigService.artifactsBaseUrl) and return the
// public, unguessable URL. The Bearer token is threaded in via `serverHeaders`,
// exactly like the web/crawl tools — the handler never reaches for a Supabase
// session itself.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';

const Duration _requestTimeout = Duration(seconds: 45);

Map<String, dynamic>? _tryDecodeJsonObject(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    // Ignore decode failures and return null for non-JSON payloads.
  }
  return null;
}

/// Builds the human/model-readable success string from a service response.
String _formatSuccess(Map<String, dynamic> data) {
  final url = data['url']?.toString() ?? '';
  final downloadUrl = data['download_url']?.toString() ?? '';
  final publicId = data['public_id']?.toString() ?? '';

  final buffer = StringBuffer();
  if (url.isNotEmpty) {
    buffer.writeln('Published: $url');
  } else {
    buffer.writeln('Published.');
  }
  buffer.writeln(
    'This page is PUBLIC to anyone with the link (unguessable, not indexed).',
  );
  if (downloadUrl.isNotEmpty) {
    buffer.writeln('Download: $downloadUrl');
  }
  if (publicId.isNotEmpty) {
    buffer.writeln(
      'public_id: $publicId (pass this to update_artifact to change the page).',
    );
  }
  return buffer.toString().trimRight();
}

/// Maps a non-200 status code to a clear, actionable message.
///
/// Every string starts with `Error:` so the executor's failure sniffer
/// (`looksLikeToolFailure`) marks the tool call as failed — otherwise a 401 /
/// 404 / 429 would reach the model as a successful call.
String _formatError(int statusCode, String body) {
  final data = _tryDecodeJsonObject(body);
  final detail = data?['error']?.toString() ?? data?['message']?.toString();
  switch (statusCode) {
    case 401:
      return 'Error: artifact publish failed — not signed in or session '
          'expired. Ask the user to sign in and try again.';
    case 413:
      return 'Error: artifact publish failed — the HTML page is too large. '
          'Make it smaller and try again.';
    case 429:
      return 'Error: artifact publish rate limited. Wait a moment, then try '
          'again.';
    case 404:
      return 'Error: artifact not found — the public_id does not exist or is '
          'not yours. Create a new artifact instead of updating.';
    case 400:
      return 'Error: artifact publish failed — invalid request'
          '${detail != null && detail.isNotEmpty ? ' ($detail)' : ''}.';
    default:
      return 'Error: artifact publish failed — HTTP $statusCode'
          '${detail != null && detail.isNotEmpty ? ' ($detail)' : ''}.';
  }
}

/// Validates the configured base URL before any credential is sent. The Bearer
/// token must never travel over cleartext HTTP; plain http is tolerated only in
/// debug builds for local testing. Returns an `Error:`-prefixed message when
/// the URL is unusable, or null when it is safe to use.
String? _baseUrlError(String baseUrl) {
  if (baseUrl.isEmpty) {
    return 'Error: artifacts service is not configured.';
  }
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || !uri.hasAuthority) {
    return 'Error: artifacts service URL is invalid.';
  }
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http' && kDebugMode) return null;
  return 'Error: artifacts service URL must use https.';
}

Map<String, dynamic> _buildBody(Map<String, dynamic> args, String html) {
  final body = <String, dynamic>{'html': html};
  final title = args['title']?.toString().trim() ?? '';
  if (title.isNotEmpty) {
    body['title'] = title;
  }
  return body;
}

/// Publish a new self-contained HTML page. Returns a public shareable URL.
Future<String> executeCreateArtifact({
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
}) async {
  final html = args['html']?.toString() ?? '';
  if (html.trim().isEmpty) {
    return 'Error: No html provided. Pass a complete standalone HTML document.';
  }

  final baseUrl = ApiConfigService.artifactsBaseUrl;
  final baseUrlError = _baseUrlError(baseUrl);
  if (baseUrlError != null) {
    return baseUrlError;
  }

  if (kDebugMode) {
    debugPrint('create_artifact: html length ${html.length} chars');
  }

  try {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/artifacts'),
          headers: serverHeaders,
          body: jsonEncode(_buildBody(args, html)),
        )
        .timeout(_requestTimeout);

    if (kDebugMode) {
      debugPrint('create_artifact: status ${response.statusCode}');
    }

    if (response.statusCode != 200) {
      return _formatError(response.statusCode, response.body);
    }

    final data = _tryDecodeJsonObject(response.body);
    if (data == null) {
      return 'Error: artifact publish failed — invalid server response.';
    }
    return _formatSuccess(data);
  } on TimeoutException {
    return 'Error: artifact publish timed out. Please try again.';
  } catch (e) {
    return 'Error: artifact publish failed — $e';
  }
}

/// Replace the HTML of a previously created artifact. Returns its public URL.
Future<String> executeUpdateArtifact({
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
}) async {
  final publicId = args['public_id']?.toString().trim() ?? '';
  if (publicId.isEmpty) {
    return 'Error: No public_id provided. Pass the public_id returned by '
        'create_artifact.';
  }
  final html = args['html']?.toString() ?? '';
  if (html.trim().isEmpty) {
    return 'Error: No html provided. Pass the new complete HTML document.';
  }

  final baseUrl = ApiConfigService.artifactsBaseUrl;
  final baseUrlError = _baseUrlError(baseUrl);
  if (baseUrlError != null) {
    return baseUrlError;
  }

  if (kDebugMode) {
    debugPrint('update_artifact: html length ${html.length} chars');
  }

  try {
    final response = await http
        .put(
          Uri.parse('$baseUrl/v1/artifacts/${Uri.encodeComponent(publicId)}'),
          headers: serverHeaders,
          body: jsonEncode(_buildBody(args, html)),
        )
        .timeout(_requestTimeout);

    if (kDebugMode) {
      debugPrint('update_artifact: status ${response.statusCode}');
    }

    if (response.statusCode != 200) {
      return _formatError(response.statusCode, response.body);
    }

    final data = _tryDecodeJsonObject(response.body);
    if (data == null) {
      return 'Error: artifact update failed — invalid server response.';
    }
    return _formatSuccess(data);
  } on TimeoutException {
    return 'Error: artifact update timed out. Please try again.';
  } catch (e) {
    return 'Error: artifact update failed — $e';
  }
}
