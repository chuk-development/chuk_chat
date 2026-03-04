import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const int _defaultSearchCount = 5;
const int _maxSearchCount = 8;
const int _defaultAutoCrawlCount = 2;
const int _maxAutoCrawlCount = 3;
const int _defaultAutoCrawlMaxChars = 3000;
const int _maxAutoCrawlMaxChars = 8000;
const int _maxExcerptCharsPerPage = 2200;

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

int _coerceInt(
  dynamic value, {
  required int fallback,
  required int min,
  required int max,
}) {
  int parsed;
  if (value is int) {
    parsed = value;
  } else if (value is num) {
    parsed = value.toInt();
  } else {
    parsed = int.tryParse(value?.toString() ?? '') ?? fallback;
  }
  if (parsed < min) return min;
  if (parsed > max) return max;
  return parsed;
}

bool _coerceBool(dynamic value, {required bool fallback}) {
  if (value == null) return fallback;
  if (value is bool) return value;

  final normalized = value.toString().trim().toLowerCase();
  if (normalized == 'true' ||
      normalized == '1' ||
      normalized == 'yes' ||
      normalized == 'y' ||
      normalized == 'on') {
    return true;
  }
  if (normalized == 'false' ||
      normalized == '0' ||
      normalized == 'no' ||
      normalized == 'n' ||
      normalized == 'off') {
    return false;
  }

  return fallback;
}

String _truncate(String input, int maxChars) {
  if (input.length <= maxChars) return input;
  return '${input.substring(0, maxChars)}...';
}

class _CrawlContext {
  const _CrawlContext({
    required this.url,
    required this.content,
    required this.truncated,
    this.error,
  });

  final String url;
  final String content;
  final bool truncated;
  final String? error;
}

Future<_CrawlContext> _crawlForContext({
  required String baseUrl,
  required Map<String, String> serverHeaders,
  required String url,
  required int maxChars,
}) async {
  try {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/tools/crawl'),
          headers: _buildJsonHeaders(serverHeaders),
          body: jsonEncode({'url': url, 'max_chars': maxChars}),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      final errorData = _tryDecodeJsonObject(response.body);
      final error = errorData?['error']?.toString();
      return _CrawlContext(
        url: url,
        content: '',
        truncated: false,
        error: error ?? 'HTTP ${response.statusCode}',
      );
    }

    final data = _tryDecodeJsonObject(response.body);
    if (data == null) {
      return _CrawlContext(
        url: url,
        content: '',
        truncated: false,
        error: 'Invalid crawl response',
      );
    }

    final error = data['error']?.toString();
    if (error != null && error.isNotEmpty) {
      return _CrawlContext(
        url: url,
        content: '',
        truncated: false,
        error: error,
      );
    }

    final content = data['content']?.toString() ?? '';
    final truncatedRaw = data['truncated'];
    final truncated = truncatedRaw is bool
        ? truncatedRaw
        : truncatedRaw?.toString().toLowerCase() == 'true';

    return _CrawlContext(
      url: url,
      content: content,
      truncated: truncated,
      error: null,
    );
  } on TimeoutException {
    return _CrawlContext(
      url: url,
      content: '',
      truncated: false,
      error: 'Timed out',
    );
  } catch (e) {
    return _CrawlContext(
      url: url,
      content: '',
      truncated: false,
      error: e.toString(),
    );
  }
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

  final searchCount = _coerceInt(
    args['count'],
    fallback: _defaultSearchCount,
    min: 1,
    max: _maxSearchCount,
  );
  final includeContent = _coerceBool(args['include_content'], fallback: true);
  final crawlCount = _coerceInt(
    args['crawl_count'],
    fallback: _defaultAutoCrawlCount,
    min: 0,
    max: _maxAutoCrawlCount,
  );
  final crawlMaxChars = _coerceInt(
    args['crawl_max_chars'],
    fallback: _defaultAutoCrawlMaxChars,
    min: 500,
    max: _maxAutoCrawlMaxChars,
  );

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  try {
    final response = await http
        .post(
          Uri.parse('$baseUrl/v1/tools/brave/search'),
          headers: _buildJsonHeaders(serverHeaders),
          body: jsonEncode({'query': query, 'count': searchCount}),
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
    final topUrlToTitle = <String, String>{};
    for (int i = 0; i < results.length && i < searchCount; i++) {
      final r = results[i];
      if (r is! Map) continue;
      final result = Map<String, dynamic>.from(r);
      final title = result['title']?.toString() ?? '(untitled)';
      final url = result['url']?.toString() ?? '';
      final description = result['description']?.toString() ?? '';

      buffer.writeln('${i + 1}. $title');
      if (url.isNotEmpty) {
        buffer.writeln('   $url');
        if (url.startsWith('http://') || url.startsWith('https://')) {
          topUrlToTitle[url] = title;
        }
      }
      if (description.isNotEmpty) {
        buffer.writeln('   $description');
      }
      buffer.writeln();
    }

    if (includeContent && crawlCount > 0 && topUrlToTitle.isNotEmpty) {
      final urlsToCrawl = topUrlToTitle.keys.take(crawlCount).toList();
      if (urlsToCrawl.isNotEmpty) {
        final crawled = await Future.wait(
          urlsToCrawl.map(
            (url) => _crawlForContext(
              baseUrl: baseUrl,
              serverHeaders: serverHeaders,
              url: url,
              maxChars: crawlMaxChars,
            ),
          ),
        );

        buffer.writeln('Auto-fetched page context:');
        buffer.writeln();

        for (int i = 0; i < crawled.length; i++) {
          final page = crawled[i];
          final title = topUrlToTitle[page.url] ?? '(untitled)';

          buffer.writeln('${i + 1}) $title');
          buffer.writeln('   ${page.url}');

          if (page.error != null && page.error!.isNotEmpty) {
            buffer.writeln('   Fetch error: ${page.error}');
            buffer.writeln();
            continue;
          }

          final excerpt = _truncate(
            page.content.trim(),
            _maxExcerptCharsPerPage,
          );
          if (excerpt.isEmpty) {
            buffer.writeln('   No readable content extracted.');
            buffer.writeln();
            continue;
          }

          buffer.writeln('   Extracted context:');
          buffer.writeln(excerpt);
          if (page.truncated || excerpt.length < page.content.trim().length) {
            buffer.writeln('\n   [Context truncated]');
          }
          buffer.writeln();
        }
      }
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
