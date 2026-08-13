import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/multiplex_tool_proxy.dart';

// Two crawled pages was too thin — portals disagree, and the operator's
// own site fell outside the window. The fetches run together, so reading
// four costs prompt size, not wall-clock.
const int _defaultSearchCount = 8;
const int _maxSearchCount = 10;
const int _defaultAutoCrawlCount = 4;
const int _maxAutoCrawlCount = 6;
const int _defaultAutoCrawlMaxChars = 3500;
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
    Map<String, dynamic>? data;
    final mux = await tryToolViaMultiplex(
      tool: 'crawl',
      payload: {'url': url, 'max_chars': maxChars},
    );
    if (mux.isError) {
      return _CrawlContext(
        url: url,
        content: '',
        truncated: false,
        error: mux.error.toString(),
      );
    }
    if (mux.isOk) {
      data = mux.body;
    } else {
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

      data = _tryDecodeJsonObject(response.body);
    }
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
///
/// Set `type: "images"` to get real photo URLs instead of web pages —
/// pass one of the returned image_url values to `fetch_image` to display
/// the photo inline. Never fall back to generate_image* for real subjects.
Future<String> executeWebSearch({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
}) async {
  final query = args['query'] as String? ?? args['q'] as String? ?? '';
  if (query.isEmpty) {
    return 'Error: No search query provided';
  }

  final typeRaw = (args['type'] as String? ?? 'web').toLowerCase().trim();
  final isImageMode =
      typeRaw == 'images' || typeRaw == 'image' || typeRaw == 'photo';
  if (isImageMode) {
    return executeImageSearch(
      serverHttpUrl: serverHttpUrl,
      serverHeaders: serverHeaders,
      args: args,
    );
  }
  final isNewsMode = typeRaw == 'news';
  if (isNewsMode) {
    return executeNewsSearch(
      serverHttpUrl: serverHttpUrl,
      serverHeaders: serverHeaders,
      args: args,
    );
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

  final body = <String, dynamic>{
    'query': query,
    'count': searchCount,
    // Brave returns up to 5 extra text snippets per hit; cheap wins.
    'extra_snippets': _coerceBool(args['extra_snippets'], fallback: true),
  };
  final freshnessRaw = (args['freshness'] as String? ?? '').trim().toLowerCase();
  if (freshnessRaw.isNotEmpty) body['freshness'] = freshnessRaw;
  final country = (args['country'] as String? ?? '').trim();
  if (country.length == 2) body['country'] = country.toUpperCase();
  final searchLang = (args['search_lang'] as String? ?? '').trim().toLowerCase();
  if (searchLang.isNotEmpty) body['search_lang'] = searchLang;
  final uiLang = (args['ui_lang'] as String? ?? '').trim();
  if (uiLang.isNotEmpty) body['ui_lang'] = uiLang;
  final safesearchRaw =
      (args['safesearch'] as String? ?? '').trim().toLowerCase();
  if ({'off', 'moderate', 'strict'}.contains(safesearchRaw)) {
    body['safesearch'] = safesearchRaw;
  }
  final units = (args['units'] as String? ?? '').trim().toLowerCase();
  if ({'metric', 'imperial'}.contains(units)) body['units'] = units;
  if (args.containsKey('spellcheck')) {
    body['spellcheck'] = _coerceBool(args['spellcheck'], fallback: true);
  }
  final gogglesId = (args['goggles_id'] as String? ?? '').trim();
  if (gogglesId.isNotEmpty) body['goggles_id'] = gogglesId;

  try {
    Map<String, dynamic>? data;
    final mux = await tryToolViaMultiplex(tool: 'brave_search', payload: body);
    if (mux.isError) {
      return 'Web search error: ${mux.error}';
    }
    if (mux.isOk) {
      data = mux.body;
    } else {
      final response = await http
          .post(
            Uri.parse('$baseUrl/v1/tools/brave/search'),
            headers: _buildJsonHeaders(serverHeaders),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorData = _tryDecodeJsonObject(response.body);
        final error = errorData?['error']?.toString();
        return 'Web search error: ${error ?? 'HTTP ${response.statusCode}'}';
      }

      data = _tryDecodeJsonObject(response.body);
    }
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
      final age = result['age']?.toString() ?? '';
      if (age.isNotEmpty) {
        buffer.writeln('   age: $age');
      }
      final extraSnippets = result['extra_snippets'];
      if (extraSnippets is List && extraSnippets.isNotEmpty) {
        for (final snippet in extraSnippets.take(5)) {
          final snippetStr = snippet.toString().trim();
          if (snippetStr.isNotEmpty) {
            buffer.writeln('   • $snippetStr');
          }
        }
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

/// Image search via server-side Brave Image Search proxy.
///
/// Returns real image URLs the model can then pass to `fetch_image` to
/// display the actual photo inline — this is the correct path when the
/// user wants pictures of real people, places, products or events.
/// Do NOT use `generate_image*` for that case; generated images are
/// AI interpretations, not real photos.
Future<String> executeImageSearch({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
}) async {
  final query = args['query'] as String? ?? args['q'] as String? ?? '';
  if (query.isEmpty) {
    return 'Error: No image search query provided';
  }

  final searchCount = _coerceInt(
    args['count'],
    fallback: _defaultSearchCount,
    min: 1,
    max: _maxSearchCount,
  );
  final safesearchRaw =
      (args['safesearch'] as String? ?? 'strict').toLowerCase();
  final safesearch = safesearchRaw == 'off' ? 'off' : 'strict';

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  try {
    final body = <String, dynamic>{
      'query': query,
      'count': searchCount,
      'safesearch': safesearch,
    };

    Map<String, dynamic>? data;
    final mux = await tryToolViaMultiplex(tool: 'brave_images', payload: body);
    if (mux.isError) {
      return 'Image search error: ${mux.error}';
    }
    if (mux.isOk) {
      data = mux.body;
    } else {
      final response = await http
          .post(
            Uri.parse('$baseUrl/v1/tools/brave/images'),
            headers: _buildJsonHeaders(serverHeaders),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorData = _tryDecodeJsonObject(response.body);
        final error = errorData?['error']?.toString();
        return 'Image search error: ${error ?? 'HTTP ${response.statusCode}'}';
      }

      data = _tryDecodeJsonObject(response.body);
    }
    if (data == null) {
      return 'Image search error: Invalid server response';
    }

    final results = data['results'] as List? ?? [];
    if (results.isEmpty) {
      return 'No image results found for: $query';
    }

    final buffer = StringBuffer('Image search results for "$query":\n\n');
    for (int i = 0; i < results.length && i < searchCount; i++) {
      final r = results[i];
      if (r is! Map) continue;
      final result = Map<String, dynamic>.from(r);
      final title = result['title']?.toString() ?? '(untitled)';
      final imageUrl = result['image_url']?.toString() ?? '';
      final thumbnailUrl = result['thumbnail_url']?.toString() ?? '';
      final sourceUrl = result['source_url']?.toString() ?? '';
      final source = result['source']?.toString() ?? '';
      final width = result['width'];
      final height = result['height'];

      buffer.writeln('${i + 1}. $title');
      if (imageUrl.isNotEmpty) {
        buffer.writeln('   image_url: $imageUrl');
      }
      if (thumbnailUrl.isNotEmpty && thumbnailUrl != imageUrl) {
        buffer.writeln('   thumbnail_url: $thumbnailUrl');
      }
      if (sourceUrl.isNotEmpty) {
        buffer.writeln('   source_page: $sourceUrl');
      }
      if (source.isNotEmpty) {
        buffer.writeln('   source: $source');
      }
      if (width != null && height != null) {
        buffer.writeln('   size: ${width}x$height');
      }
      buffer.writeln();
    }

    buffer.writeln(
      'To display a picture to the user, pass one of the image_url values '
      'above to fetch_image. Do NOT call generate_image* for real photos — '
      'use fetch_image on an image_url from this list instead.',
    );

    return buffer.toString();
  } on TimeoutException {
    return 'Image search timed out. Please try again.';
  } catch (e) {
    return 'Image search failed: $e';
  }
}

/// News search via server-side Brave News Search proxy.
///
/// Returns recent articles with publisher, age and thumbnail so the model
/// can answer time-sensitive "latest / just released / breaking" queries
/// without crawling. Use the `freshness` hint when the user scopes a
/// timeframe (pd=24h, pw=week, pm=month, py=year).
Future<String> executeNewsSearch({
  required String? serverHttpUrl,
  required Map<String, String> serverHeaders,
  required Map<String, dynamic> args,
}) async {
  final query = args['query'] as String? ?? args['q'] as String? ?? '';
  if (query.isEmpty) {
    return 'Error: No news search query provided';
  }

  final searchCount = _coerceInt(
    args['count'],
    fallback: _defaultSearchCount,
    min: 1,
    max: _maxSearchCount,
  );

  final freshnessRaw =
      (args['freshness'] as String? ?? '').trim().toLowerCase();
  const freshnessPresets = {'pd', 'pw', 'pm', 'py'};
  String? freshness;
  if (freshnessPresets.contains(freshnessRaw)) {
    freshness = freshnessRaw;
  } else if (RegExp(r'^\d{4}-\d{2}-\d{2}to\d{4}-\d{2}-\d{2}$')
      .hasMatch(freshnessRaw)) {
    freshness = freshnessRaw;
  }

  String? country = (args['country'] as String? ?? '').trim();
  if (country.isEmpty || country.length != 2) country = null;
  country = country?.toUpperCase();

  String? searchLang = (args['search_lang'] as String? ?? '').trim();
  if (searchLang.isEmpty) searchLang = null;
  searchLang = searchLang?.toLowerCase();

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.isEmpty) {
    return 'Error: Not connected to server';
  }

  try {
    final body = <String, dynamic>{'query': query, 'count': searchCount};
    if (freshness != null) body['freshness'] = freshness;
    if (country != null) body['country'] = country;
    if (searchLang != null) body['search_lang'] = searchLang;

    Map<String, dynamic>? data;
    final mux = await tryToolViaMultiplex(tool: 'brave_news', payload: body);
    if (mux.isError) {
      return 'News search error: ${mux.error}';
    }
    if (mux.isOk) {
      data = mux.body;
    } else {
      final response = await http
          .post(
            Uri.parse('$baseUrl/v1/tools/brave/news'),
            headers: _buildJsonHeaders(serverHeaders),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorData = _tryDecodeJsonObject(response.body);
        final error = errorData?['error']?.toString();
        return 'News search error: ${error ?? 'HTTP ${response.statusCode}'}';
      }

      data = _tryDecodeJsonObject(response.body);
    }
    if (data == null) {
      return 'News search error: Invalid server response';
    }

    final results = data['results'] as List? ?? [];
    if (results.isEmpty) {
      return 'No news results found for: $query';
    }

    final buffer = StringBuffer('News results for "$query":\n\n');
    for (int i = 0; i < results.length && i < searchCount; i++) {
      final r = results[i];
      if (r is! Map) continue;
      final result = Map<String, dynamic>.from(r);
      final title = result['title']?.toString() ?? '(untitled)';
      final url = result['url']?.toString() ?? '';
      final description = result['description']?.toString() ?? '';
      final age = result['age']?.toString() ?? '';
      final pageAge = result['page_age']?.toString() ?? '';
      final publisher = result['publisher']?.toString() ?? '';
      final thumbnailUrl = result['thumbnail_url']?.toString() ?? '';
      final breaking = result['breaking'] == true;

      buffer.writeln('${i + 1}. $title${breaking ? '  [BREAKING]' : ''}');
      if (publisher.isNotEmpty || age.isNotEmpty || pageAge.isNotEmpty) {
        final metaBits = <String>[
          if (publisher.isNotEmpty) publisher,
          if (age.isNotEmpty) age,
          if (pageAge.isNotEmpty && pageAge != age) pageAge,
        ];
        buffer.writeln('   ${metaBits.join(' · ')}');
      }
      if (url.isNotEmpty) {
        buffer.writeln('   $url');
      }
      if (description.isNotEmpty) {
        buffer.writeln('   $description');
      }
      if (thumbnailUrl.isNotEmpty) {
        buffer.writeln('   thumbnail_url: $thumbnailUrl');
      }
      buffer.writeln();
    }

    buffer.writeln(
      'Call web_crawl on a url above if you need the full article text.',
    );

    return buffer.toString();
  } on TimeoutException {
    return 'News search timed out. Please try again.';
  } catch (e) {
    return 'News search failed: $e';
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
    final body = {'url': url, 'max_chars': 8000};

    Map<String, dynamic>? data;
    final mux = await tryToolViaMultiplex(tool: 'crawl', payload: body);
    if (mux.isError) {
      return 'Crawl error: ${mux.error}';
    }
    if (mux.isOk) {
      data = mux.body;
    } else {
      final response = await http
          .post(
            Uri.parse('$baseUrl/v1/tools/crawl'),
            headers: _buildJsonHeaders(serverHeaders),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        final errorData = _tryDecodeJsonObject(response.body);
        final error = errorData?['error']?.toString();
        return 'Crawl error: ${error ?? 'HTTP ${response.statusCode}'}';
      }

      data = _tryDecodeJsonObject(response.body);
    }
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
