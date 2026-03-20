import 'dart:convert';

import 'package:http/http.dart' as http;

const String _mcpEndpoint = 'https://api.findadomain.dev/mcp';

/// Longer timeout — FindADomain can be slow to respond.
const Duration _timeout = Duration(seconds: 45);

Future<String> executeFindDomain(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final action =
      (args['action'] as String? ?? 'check').trim().toLowerCase();
  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    switch (action) {
      case 'check':
        return await _executeCheck(effectiveClient, args);
      case 'list_tlds':
        return await _executeListTlds(effectiveClient);
      default:
        return 'Error: Unknown action "$action". Supported: check, list_tlds';
    }
  } catch (error) {
    return 'Domain lookup error: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

Future<String> _executeCheck(
  http.Client client,
  Map<String, dynamic> args,
) async {
  final name = (args['name'] as String? ?? '').trim().toLowerCase();
  if (name.isEmpty) {
    return 'Error: "name" parameter required (domain name without TLD, '
        'e.g. "myapp")';
  }

  final rawTlds = args['tld'] ?? args['tlds'];
  final tlds = _coerceTlds(rawTlds);
  if (tlds.isEmpty) {
    return 'Error: "tld" parameter required (e.g. "com" or '
        '"com,net,org,de")';
  }

  final whois = args['whois'] == true || args['whois'] == 'true';
  final buf = StringBuffer();
  buf.writeln('Domain availability for "$name":');
  buf.writeln();

  for (final tld in tlds) {
    final result = await _callMcpTool(
      client,
      'check_domain',
      {'name': name, 'tld': tld, 'whois': whois},
    );

    if (result == null) {
      buf.writeln('- $name.$tld: lookup failed');
      continue;
    }

    if (result is String) {
      buf.writeln('- $name.$tld: $result');
      continue;
    }

    if (result is Map<String, dynamic>) {
      final available = result['available'];
      final domain = result['domain'] ?? '$name.$tld';
      final status = available == true
          ? 'AVAILABLE'
          : available == false
              ? 'TAKEN'
              : 'unknown';

      buf.write('- $domain: $status');

      if (whois && result.containsKey('whois')) {
        final whoisData = result['whois'];
        if (whoisData is Map<String, dynamic>) {
          final registrar = whoisData['registrar'];
          final expires = whoisData['expiration_date'] ??
              whoisData['expires'];
          if (registrar != null) buf.write(' | Registrar: $registrar');
          if (expires != null) buf.write(' | Expires: $expires');
        }
      }
      buf.writeln();
    } else {
      buf.writeln('- $name.$tld: $result');
    }
  }

  return buf.toString().trimRight();
}

Future<String> _executeListTlds(http.Client client) async {
  final result = await _callMcpTool(client, 'list_tlds', {});

  if (result == null) {
    return 'Error: Could not fetch TLD list';
  }

  if (result is Map<String, dynamic>) {
    final tlds = result['tlds'];
    final count = result['count'] ?? (tlds is List ? tlds.length : '?');
    if (tlds is List) {
      final sample = tlds.take(50).join(', ');
      return 'Available TLDs ($count total): $sample'
          '${tlds.length > 50 ? '...' : ''}';
    }
  }

  return 'TLDs: $result';
}

// ─── MCP transport ──────────────────────────────────────────────────────────

/// Call a tool on the FindADomain MCP server via HTTP POST (JSON-RPC 2.0).
Future<dynamic> _callMcpTool(
  http.Client client,
  String toolName,
  Map<String, dynamic> arguments,
) async {
  final payload = jsonEncode({
    'jsonrpc': '2.0',
    'method': 'tools/call',
    'params': {
      'name': toolName,
      'arguments': arguments,
    },
    'id': 1,
  });

  final response = await client
      .post(
        Uri.parse(_mcpEndpoint),
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'User-Agent': 'chuk-chat/1.0',
        },
        body: payload,
      )
      .timeout(_timeout);

  if (response.statusCode != 200) {
    return null;
  }

  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }

  // JSON-RPC 2.0 result extraction.
  if (decoded.containsKey('error')) {
    final error = decoded['error'];
    if (error is Map<String, dynamic>) {
      return 'Error: ${error['message'] ?? error}';
    }
    return 'Error: $error';
  }

  final result = decoded['result'];
  if (result is Map<String, dynamic>) {
    // MCP tools/call returns {content: [{type: "text", text: "..."}]}
    final content = result['content'];
    if (content is List && content.isNotEmpty) {
      final first = content.first;
      if (first is Map<String, dynamic> && first['text'] is String) {
        final text = first['text'] as String;
        // Try to parse as JSON for structured data.
        try {
          return jsonDecode(text);
        } catch (_) {
          return text;
        }
      }
    }
    return result;
  }

  return result;
}

// ─── Helpers ────────────────────────────────────────────────────────────────

List<String> _coerceTlds(dynamic value) {
  if (value == null) return const [];
  if (value is List) {
    return value
        .map((e) => e.toString().trim().toLowerCase().replaceAll('.', ''))
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return value
      .toString()
      .split(RegExp(r'[,\s]+'))
      .map((e) => e.trim().toLowerCase().replaceAll('.', ''))
      .where((e) => e.isNotEmpty)
      .toList();
}
