// lib/services/mcp/mcp_client.dart
//
// A client for remote MCP servers over the Streamable HTTP transport
// (spec revision 2025-06-18): every message is one HTTP POST to a single
// endpoint, and the reply is either a JSON object or an SSE stream that
// ends with the response. Nothing is installed and nothing is spawned —
// a remote server is a URL and a token.
//
// Only what a chat client needs is implemented: initialize, tools/list and
// tools/call. Server-initiated requests (sampling, elicitation, roots) are
// not offered, so the GET stream is never opened.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The revision this client speaks. Servers negotiate down if they must.
const String kMcpProtocolVersion = '2025-06-18';

/// Thrown when the server wants a token. [wwwAuthenticate] carries the
/// challenge, which is where the OAuth flow starts.
class McpUnauthorized implements Exception {
  const McpUnauthorized(this.wwwAuthenticate);

  final String? wwwAuthenticate;

  @override
  String toString() => 'MCP server requires authorization';
}

/// Any other failure: transport, HTTP status, or a JSON-RPC error.
class McpException implements Exception {
  const McpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a server says about itself in the initialize result.
class McpServerInfo {
  const McpServerInfo({
    required this.name,
    this.title,
    this.version,
    this.iconUrl,
    this.websiteUrl,
    this.instructions,
  });

  final String name;
  final String? title;
  final String? version;
  final String? iconUrl;
  final String? websiteUrl;
  final String? instructions;

  /// The name to show a reader: the title if the server has one.
  String get displayName => (title?.trim().isNotEmpty ?? false) ? title! : name;
}

/// One tool a server offers.
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };

  static McpTool fromJson(Map<String, dynamic> json) => McpTool(
    name: (json['name'] ?? '').toString(),
    description: (json['description'] ?? json['title'] ?? '').toString(),
    inputSchema: json['inputSchema'] is Map
        ? Map<String, dynamic>.from(json['inputSchema'] as Map)
        : const <String, dynamic>{},
  );
}

/// The outcome of a tools/call: the text the model gets, plus whether the
/// server flagged it as an error.
class McpCallResult {
  const McpCallResult({required this.text, required this.isError});

  final String text;
  final bool isError;
}

class McpClient {
  McpClient({
    required this.endpoint,
    this.accessToken,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 60),
  }) : _http = httpClient ?? http.Client();

  final Uri endpoint;
  final String? accessToken;
  final Duration timeout;
  final http.Client _http;

  int _nextId = 1;
  String? _sessionId;
  String _protocolVersion = kMcpProtocolVersion;

  /// Set once the server answered initialize. Sent back on every request.
  String? get sessionId => _sessionId;

  /// Handshake. Returns what the server says about itself.
  Future<McpServerInfo> initialize() async {
    final result = await _request('initialize', {
      'protocolVersion': kMcpProtocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'Chuk Chat', 'version': '1.0'},
    });

    final negotiated = result['protocolVersion'];
    if (negotiated is String && negotiated.isNotEmpty) {
      _protocolVersion = negotiated;
    }

    // The handshake is only complete once the server has been told so. It
    // is a notification, so there is nothing to wait for beyond the 202.
    unawaited(_notify('notifications/initialized'));

    final info = result['serverInfo'];
    final map = info is Map
        ? Map<String, dynamic>.from(info)
        : <String, dynamic>{};
    return McpServerInfo(
      name: (map['name'] ?? endpoint.host).toString(),
      title: map['title']?.toString(),
      version: map['version']?.toString(),
      iconUrl: _firstIcon(map['icons']),
      websiteUrl: map['websiteUrl']?.toString(),
      instructions: result['instructions']?.toString(),
    );
  }

  /// Every tool the server offers, following `nextCursor` pages.
  Future<List<McpTool>> listTools() async {
    final tools = <McpTool>[];
    String? cursor;
    // A server with more pages than this is not a chat connector.
    for (var page = 0; page < 20; page++) {
      final result = await _request('tools/list', {'cursor': ?cursor});
      final list = result['tools'];
      if (list is List) {
        for (final entry in list) {
          if (entry is Map) {
            tools.add(McpTool.fromJson(Map<String, dynamic>.from(entry)));
          }
        }
      }
      final next = result['nextCursor'];
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }
    return tools;
  }

  /// Run a tool and flatten its content blocks to text.
  Future<McpCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    });

    final isError = result['isError'] == true;
    final structured = result['structuredContent'];
    final buffer = StringBuffer();

    final content = result['content'];
    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        switch (block['type']) {
          case 'text':
            buffer.writeln(block['text']?.toString() ?? '');
          case 'image':
          case 'audio':
            buffer.writeln('[${block['type']} returned by the tool]');
          case 'resource_link':
            buffer.writeln('${block['name'] ?? 'resource'}: ${block['uri']}');
          case 'resource':
            final resource = block['resource'];
            if (resource is Map) {
              buffer.writeln(
                resource['text']?.toString() ?? resource['uri']?.toString(),
              );
            }
        }
      }
    }

    if (buffer.isEmpty && structured != null) {
      buffer.writeln(jsonEncode(structured));
    }

    final text = buffer.toString().trim();
    return McpCallResult(
      text: text.isEmpty ? 'The tool returned nothing.' : text,
      isError: isError,
    );
  }

  void close() => _http.close();

  // ─── Transport ─────────────────────────────────────────────────────────

  Map<String, String> _headers({required bool expectsReply}) => {
    'content-type': 'application/json',
    'accept': expectsReply
        ? 'application/json, text/event-stream'
        : 'application/json',
    'mcp-protocol-version': _protocolVersion,
    'mcp-session-id': ?_sessionId,
    if (accessToken != null && accessToken!.isNotEmpty)
      'authorization': 'Bearer $accessToken',
  };

  Future<void> _notify(String method) async {
    try {
      await _http
          .post(
            endpoint,
            headers: _headers(expectsReply: false),
            body: jsonEncode({'jsonrpc': '2.0', 'method': method}),
          )
          .timeout(timeout);
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [MCP] notification $method failed: $e');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = _nextId++;
    final request = http.Request('POST', endpoint)
      ..headers.addAll(_headers(expectsReply: true))
      ..body = jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });

    final http.StreamedResponse response = await _http
        .send(request)
        .timeout(timeout);

    if (response.statusCode == 401) {
      await response.stream.drain<void>();
      throw McpUnauthorized(response.headers['www-authenticate']);
    }
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      throw McpException(
        'The server answered ${response.statusCode}'
        '${body.isEmpty ? '' : ': ${body.substring(0, body.length.clamp(0, 300))}'}',
      );
    }

    // A session id only comes back on initialize, and then belongs on every
    // later request.
    final session = response.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) _sessionId = session;

    final contentType = response.headers['content-type'] ?? '';
    final Map<String, dynamic> message = contentType.contains('text/event-stream')
        ? await _readSseReply(response, id)
        : jsonDecode(await response.stream.bytesToString())
              as Map<String, dynamic>;

    final error = message['error'];
    if (error is Map) {
      throw McpException(
        (error['message'] ?? 'The server reported an error').toString(),
      );
    }
    final result = message['result'];
    return result is Map
        ? Map<String, dynamic>.from(result)
        : <String, dynamic>{};
  }

  /// Read an SSE stream until the reply to [id] arrives. Anything else the
  /// server sends on the way (progress, logs) is not offered to the reader,
  /// so it is dropped.
  Future<Map<String, dynamic>> _readSseReply(
    http.StreamedResponse response,
    int id,
  ) async {
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    final data = StringBuffer();
    await for (final line in lines) {
      if (line.startsWith('data:')) {
        data.writeln(line.substring(5).trimLeft());
        continue;
      }
      if (line.isNotEmpty) continue; // other SSE fields: event, id, retry

      // A blank line ends one event.
      final payload = data.toString().trim();
      data.clear();
      if (payload.isEmpty) continue;

      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['id'] == id) {
        return Map<String, dynamic>.from(decoded);
      }
    }

    final tail = data.toString().trim();
    if (tail.isNotEmpty) {
      final decoded = jsonDecode(tail);
      if (decoded is Map && decoded['id'] == id) {
        return Map<String, dynamic>.from(decoded);
      }
    }
    throw const McpException('The server closed the stream without answering');
  }

  static String? _firstIcon(Object? icons) {
    if (icons is! List) return null;
    for (final icon in icons) {
      if (icon is Map && icon['src'] is String) return icon['src'] as String;
    }
    return null;
  }
}
