import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

Map<String, String> _buildJsonHeaders(Map<String, String> serverHeaders) {
  return <String, String>{'Content-Type': 'application/json', ...serverHeaders};
}

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

/// Web search via server-side Brave Search proxy.
/// API key stays on the server; server logs usage/costs.
Future<String> executeWebSearch({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
}) async {
  final query = args['query'] as String? ?? args['q'] as String? ?? '';
  if (query.isEmpty) {
    return 'Error: No search query provided';
  }

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  try {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/tools/brave/search'),
          headers: _buildJsonHeaders(serverHeaders),
          body: jsonEncode({'query': query, 'count': 5}),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      final errorData = _tryDecodeJsonObject(response.body);
      final error = errorData?['error']?.toString();
      return 'Web search error: ${error ?? 'HTTP ${response.statusCode}'}';
    }

    final data = _tryDecodeJsonObject(response.body);
    if (data == null) {
      return 'Web search error: Invalid server response';
    }

    final results = data['results'] as List? ?? [];

    if (results.isEmpty) {
      return 'No results found for: $query';
    }

    final buffer = StringBuffer('Search results for "$query":\n\n');
    for (int i = 0; i < results.length && i < 5; i++) {
      final r = results[i];
      if (r is! Map) continue;
      final result = Map<String, dynamic>.from(r);
      final title = result['title']?.toString() ?? '(untitled)';
      final url = result['url']?.toString() ?? '';
      final description = result['description']?.toString() ?? '';

      buffer.writeln('${i + 1}. $title');
      if (url.isNotEmpty) {
        buffer.writeln('   $url');
      }
      if (description.isNotEmpty) {
        buffer.writeln('   $description');
      }
      buffer.writeln();
    }
    return buffer.toString();
  } on TimeoutException {
    return 'Web search timed out. Please try again.';
  } catch (e) {
    return 'Web search failed: $e';
  }
}

/// Crawl a webpage via server-side crawler and return markdown content.
Future<String> executeWebCrawl({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
}) async {
  final url = args['url'] as String? ?? '';
  if (url.isEmpty) {
    return 'Error: No URL provided';
  }

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  try {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/tools/crawl'),
          headers: _buildJsonHeaders(serverHeaders),
          body: jsonEncode({'url': url, 'max_chars': 8000}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      final errorData = _tryDecodeJsonObject(response.body);
      final error = errorData?['error']?.toString();
      return 'Crawl error: ${error ?? 'HTTP ${response.statusCode}'}';
    }

    final data = _tryDecodeJsonObject(response.body);
    if (data == null) {
      return 'Crawl error: Invalid server response';
    }

    final error = data['error']?.toString();
    if (error != null && error.isNotEmpty) {
      return 'Crawl error: $error';
    }

    final content = data['content']?.toString() ?? '';
    final truncatedRaw = data['truncated'];
    final truncated = truncatedRaw is bool
        ? truncatedRaw
        : truncatedRaw?.toString().toLowerCase() == 'true';

    if (content.isEmpty) {
      return 'No content found at: $url';
    }

    final header = 'Content from $url';
    final truncNote = truncated ? '\n\n[Content truncated]' : '';
    return '$header\n\n$content$truncNote';
  } on TimeoutException {
    return 'Web crawl timed out. Please try again.';
  } catch (e) {
    return 'Web crawl failed: $e';
  }
}
