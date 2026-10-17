// Canned results for the server-side tools. The same functions answer the
// HTTP routes (/v1/tools/...) and the `tool` frames on /v2/ws, as the real
// server reuses one handler for both. The shapes copy api_server's
// routers/ai/brave.py, routers/ai/crawl.py and routers/ai/images.py.

/// Thrown by a canned tool for a bad request. Maps to HTTP 400 or to an
/// `error` frame with code `http_400`.
class ToolInputError implements Exception {
  ToolInputError(this.detail);
  final String detail;
}

String _query(Map<String, Object?> payload) {
  final query = (payload['query'] ?? payload['q'])?.toString().trim() ?? '';
  if (query.isEmpty) throw ToolInputError("Missing 'query' parameter");
  return query;
}

int _count(Map<String, Object?> payload, {int fallback = 5, int max = 20}) {
  final raw = payload['count'];
  final value = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
  return (value ?? fallback).clamp(1, max);
}

String _slug(String query) =>
    query.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');

/// POST /v1/tools/brave/search, mux tool `brave_search`.
Map<String, Object?> braveSearch(Map<String, Object?> payload) {
  final query = _query(payload);
  final count = _count(payload);
  final slug = _slug(query);
  return {
    'query': query,
    'results': [
      for (var i = 1; i <= count; i++)
        {
          'title': 'Result $i for $query',
          'url': 'https://example.com/$slug/$i',
          'description': 'Emulated search result $i for "$query".',
          'extra_snippets': ['Snippet A for result $i.', 'Snippet B.'],
          'age': '2026-01-${i.toString().padLeft(2, '0')}',
        },
    ],
  };
}

/// POST /v1/tools/brave/images, mux tool `brave_images`.
Map<String, Object?> braveImages(
  Map<String, Object?> payload, {
  required String baseUrl,
}) {
  final query = _query(payload);
  final count = _count(payload);
  return {
    'query': query,
    'results': [
      for (var i = 1; i <= count; i++)
        {
          'title': 'Image $i for $query',
          'image_url': '$baseUrl/v1/ai/image/file/search-$i.png',
          'thumbnail_url': '$baseUrl/v1/ai/image/file/search-$i.png',
          'source_url': 'https://example.com/images/$i',
          'source': 'example.com',
          'width': 16,
          'height': 16,
        },
    ],
  };
}

/// POST /v1/tools/brave/news, mux tool `brave_news`.
Map<String, Object?> braveNews(Map<String, Object?> payload) {
  final query = _query(payload);
  final count = _count(payload);
  final slug = _slug(query);
  return {
    'query': query,
    'results': [
      for (var i = 1; i <= count; i++)
        {
          'title': 'News $i about $query',
          'url': 'https://news.example.com/$slug/$i',
          'description': 'Emulated news item $i about "$query".',
          'age': '$i hours ago',
          'page_age': '2026-01-01T${i.toString().padLeft(2, '0')}:00:00',
          'publisher': 'news.example.com',
          'thumbnail_url': '',
          'breaking': i == 1,
        },
    ],
  };
}

/// POST /v1/tools/brave/rich, mux tool `brave_rich`.
Map<String, Object?> braveRich(Map<String, Object?> payload) {
  final query = _query(payload);
  return {
    'vertical': 'weather',
    'query': query,
    'data': {
      'type': 'rich',
      'subtype': 'weather',
      'location': {'name': 'Kiel', 'country': 'DE'},
      'current': {'temp_c': 12.0, 'condition': 'Cloudy', 'humidity': 80},
    },
  };
}

/// POST /v1/tools/brave/places, mux tools `brave_places`, `places_search`,
/// `restaurants_search`.
Map<String, Object?> bravePlaces(Map<String, Object?> payload) {
  final query = _query(payload);
  final count = _count(payload, max: 10);
  return {
    'query': query,
    'places': [
      for (var i = 1; i <= count; i++)
        {
          'id': 'place-$i',
          'name': 'Place $i ($query)',
          'lat': 54.32 + i / 1000,
          'lon': 10.13 + i / 1000,
          'address': 'Example Street $i, 24103 Kiel, DE',
          'phone': '+49 431 000000$i',
          'website': 'https://example.com/place/$i',
          'opening_hours': '09:00-18:00',
          'opening_hours_week': 'Mo-Fr 09:00-18:00',
          'cuisine': '',
          'rating': 4.5,
          'review_count': 10 * i,
          'price_range': '',
          'description': 'Emulated place $i.',
        },
    ],
  };
}

/// POST /v1/tools/crawl, mux tool `crawl`. Single `url` or batch `urls`.
Map<String, Object?> crawl(Map<String, Object?> payload) {
  final maxRaw = payload['max_chars'];
  final maxChars = ((maxRaw is num ? maxRaw.toInt() : null) ?? 8000).clamp(
    500,
    30000,
  );
  Map<String, Object?> one(String url) {
    final full =
        '# Emulated page\n\nThis is the canned content of $url. '
        'The chuk API emulator does not fetch the network.';
    final truncated = full.length > maxChars;
    final content = truncated ? full.substring(0, maxChars) : full;
    return {
      'url': url,
      'content': content,
      'chars': content.length,
      'truncated': truncated,
      'via': 'emulator',
    };
  }

  final urls = payload['urls'];
  if (urls is List && urls.isNotEmpty) {
    final cleaned = urls
        .map((u) => u.toString().trim())
        .where((u) => u.isNotEmpty)
        .toList();
    if (cleaned.isEmpty) throw ToolInputError("Missing 'urls' parameter");
    return {'results': cleaned.map(one).toList()};
  }
  final url = payload['url']?.toString().trim() ?? '';
  if (url.isEmpty) throw ToolInputError("Missing 'url' parameter");
  return one(url);
}

/// POST /v1/ai/image/generate, mux tool `image_generate`.
Map<String, Object?> imageGenerate(
  Map<String, Object?> fields, {
  required String baseUrl,
  required int sequence,
}) {
  final prompt = fields['prompt']?.toString().trim() ?? '';
  if (prompt.isEmpty) throw ToolInputError("Missing 'prompt' parameter");
  return {
    'image_url': '$baseUrl/v1/ai/image/file/emulated-$sequence.png',
    'width': 16,
    'height': 16,
    'seed': 42,
    'prompt': prompt,
    'model': fields['model']?.toString() ?? 'turbo',
    'billing': {'cost_eur': 0.0, 'megapixels': 0.0},
  };
}
