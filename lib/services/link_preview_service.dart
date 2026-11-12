// lib/services/link_preview_service.dart
//
// Link previews (OpenGraph card and site icon) for links in chat messages.
//
// Privacy: the app never contacts the linked site. The card and its images
// come from api_server (`GET /v1/link_preview`, `GET /v1/link_preview/image`),
// which fetches the page server-side with SSRF checks. Only the URL itself
// leaves the device, never the message around it.
//
// Caching, three levels: memory, SQLite `kv_cache` (JSON card) and
// `ImageDiskCache` (image bytes). A miss ("no card for this page") is cached
// too, for a shorter time, so a link without metadata is not fetched again on
// every scroll. A network failure is not cached on disk: it only blocks the
// URL for a few minutes in memory.
//
// Everything fails quietly: no card is the only failure mode.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/image_disk_cache.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/lru_byte_cache.dart';

/// One link preview card as the server returns it.
@immutable
class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.host,
    this.title,
    this.description,
    this.siteName,
    this.imageUrl,
    this.iconUrl,
  });

  final String url;
  final String host;
  final String? title;
  final String? description;
  final String? siteName;
  final String? imageUrl;
  final String? iconUrl;

  /// Parses a server answer. Returns null for `empty: true` and for any
  /// answer without a title (nothing worth drawing).
  static LinkPreview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['empty'] == true) return null;
    final String? url = raw['url'] as String?;
    if (url == null) return null;
    final String? title = _str(raw['title']);
    if (title == null) return null;
    final String host = _str(raw['host']) ?? Uri.tryParse(url)?.host ?? '';
    return LinkPreview(
      url: url,
      host: host,
      title: title,
      description: _str(raw['description']),
      siteName: _str(raw['site_name']),
      imageUrl: _httpUrl(raw['image']),
      iconUrl: _httpUrl(raw['icon']),
    );
  }

  static String? _str(Object? v) {
    if (v is! String) return null;
    final String t = v.trim();
    return t.isEmpty ? null : t;
  }

  static String? _httpUrl(Object? v) {
    final String? s = _str(v);
    if (s == null) return null;
    final Uri? u = Uri.tryParse(s);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
    return s;
  }
}

/// Short label for a URL: host without `www.`, then the path, no scheme,
/// no query. `https://www.example.com/a/b?x=1` -> `example.com/a/b`.
String shortUrlLabel(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  String host = uri.host;
  if (host.startsWith('www.')) host = host.substring(4);
  String path = uri.path;
  if (path.endsWith('/')) path = path.substring(0, path.length - 1);
  return '$host$path';
}

/// Whether the visible text of a link is just its address (an autolink or a
/// pasted URL), so the UI should show a short name instead.
bool linkTextIsUrl(String text, String href) {
  final String t = text.trim();
  if (t.isEmpty) return true;
  String strip(String v) => v
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'^www\.'), '')
      .replaceFirst(RegExp(r'/$'), '');
  return t == href || strip(t) == strip(href);
}

/// Fetches and caches link previews. All members are static, like the other
/// cache services.
class LinkPreviewService {
  const LinkPreviewService._();

  static const String _kvPrefix = 'link_preview:v1:';
  static const Duration cardTtl = Duration(days: 3);
  static const Duration emptyTtl = Duration(hours: 12);
  static const Duration _failureBackoff = Duration(minutes: 5);
  static const Duration _timeout = Duration(seconds: 15);

  static final Map<String, LinkPreview?> _memory = <String, LinkPreview?>{};
  static final Map<String, Future<LinkPreview?>> _inflight =
      <String, Future<LinkPreview?>>{};
  static final Map<String, DateTime> _failedAt = <String, DateTime>{};
  static final LruByteCache _images = LruByteCache(
    maxSizeBytes: 24 * 1024 * 1024,
  );
  static final Map<String, Future<Uint8List?>> _imageInflight =
      <String, Future<Uint8List?>>{};

  /// Test hook: replaces the network call for the card. Returns the decoded
  /// server JSON (or null for a failure).
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(String url)? debugFetchCard;

  /// Test hook: replaces the network call for image bytes.
  @visibleForTesting
  static Future<Uint8List?> Function(String url)? debugFetchImage;

  /// Test hook: skips the SQLite / disk levels.
  @visibleForTesting
  static bool debugSkipPersistentCache = false;

  @visibleForTesting
  static void debugReset() {
    _memory.clear();
    _inflight.clear();
    _failedAt.clear();
    _images.clear();
    _imageInflight.clear();
    debugFetchCard = null;
    debugFetchImage = null;
    debugSkipPersistentCache = false;
  }

  /// Already known card (or known miss) for [url], without any I/O.
  /// Returns `(true, card)` when known.
  static (bool, LinkPreview?) peek(String url) {
    if (_memory.containsKey(url)) return (true, _memory[url]);
    return (false, null);
  }

  /// The card for [url], or null when there is none or the fetch failed.
  static Future<LinkPreview?> get(String url) {
    if (_memory.containsKey(url)) {
      return Future<LinkPreview?>.value(_memory[url]);
    }
    final DateTime? failed = _failedAt[url];
    if (failed != null && DateTime.now().difference(failed) < _failureBackoff) {
      return Future<LinkPreview?>.value(null);
    }
    return _inflight[url] ??= _load(url).whenComplete(() {
      _inflight.remove(url);
    });
  }

  static Future<LinkPreview?> _load(String url) async {
    try {
      if (!debugSkipPersistentCache) {
        final _Stored? stored = await _readKv(url);
        if (stored != null) {
          _memory[url] = stored.preview;
          return stored.preview;
        }
      }
      final Map<String, dynamic>? json = await (debugFetchCard ?? _fetchCard)(
        url,
      );
      if (json == null) {
        _failedAt[url] = DateTime.now();
        return null;
      }
      final LinkPreview? preview = LinkPreview.fromJson(json);
      _memory[url] = preview;
      if (!debugSkipPersistentCache) {
        unawaited(_writeKv(url, json, preview != null));
      }
      return preview;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('LinkPreview: load failed (${error.runtimeType})');
      }
      _failedAt[url] = DateTime.now();
      return null;
    }
  }

  static Future<_Stored?> _readKv(String url) async {
    try {
      final String? raw = await LocalChatCacheService.kvGet('$_kvPrefix$url');
      if (raw == null) return null;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final int at = (decoded['at'] as num?)?.toInt() ?? 0;
      final bool ok = decoded['ok'] == true;
      final Duration age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(at),
      );
      if (age > (ok ? cardTtl : emptyTtl) || age.isNegative) return null;
      return _Stored(ok ? LinkPreview.fromJson(decoded['card']) : null);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeKv(
    String url,
    Map<String, dynamic> json,
    bool ok,
  ) async {
    try {
      await LocalChatCacheService.kvSet(
        '$_kvPrefix$url',
        jsonEncode(<String, dynamic>{
          'at': DateTime.now().millisecondsSinceEpoch,
          'ok': ok,
          if (ok) 'card': json,
        }),
      );
    } catch (_) {
      // A cache that cannot write is only slower.
    }
  }

  static String? _accessToken() {
    try {
      final String? token = SupabaseService.auth.currentSession?.accessToken;
      return (token == null || token.isEmpty) ? null : token;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _fetchCard(String url) async {
    final String? token = _accessToken();
    if (token == null) return null;
    final Uri uri = Uri.parse('${ApiConfigService.apiBaseUrl}/v1/link_preview')
        .replace(queryParameters: <String, String>{'url': url});
    final http.Response resp = await http
        .get(uri, headers: <String, String>{'Authorization': 'Bearer $token'})
        .timeout(_timeout);
    if (resp.statusCode != 200 || resp.body.isEmpty) return null;
    final Object? decoded = jsonDecode(resp.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Bytes of a preview image or site icon, through the server proxy.
  static Future<Uint8List?> image(String url) {
    final Uint8List? hit = _images.get(url);
    if (hit != null) return Future<Uint8List?>.value(hit);
    final DateTime? failed = _failedAt['img:$url'];
    if (failed != null && DateTime.now().difference(failed) < _failureBackoff) {
      return Future<Uint8List?>.value(null);
    }
    return _imageInflight[url] ??= _loadImage(url).whenComplete(() {
      _imageInflight.remove(url);
    });
  }

  /// The site icon of the page behind [url] (from the same cached card).
  static Future<Uint8List?> icon(String url) async {
    final LinkPreview? p = await get(url);
    final String? icon = p?.iconUrl;
    return icon == null ? null : image(icon);
  }

  /// The site icon of [url] if card and bytes are already in memory.
  static Uint8List? peekIcon(String url) {
    final LinkPreview? p = _memory[url];
    final String? icon = p?.iconUrl;
    return icon == null ? null : _images.get(icon);
  }

  /// Bytes already in memory for [url], or null.
  static Uint8List? peekImage(String url) => _images.get(url);

  static Future<Uint8List?> _loadImage(String url) async {
    final String diskKey = 'link_preview/$url';
    try {
      if (!debugSkipPersistentCache) {
        final Uint8List? disk = await ImageDiskCache.read(diskKey);
        if (disk != null && disk.isNotEmpty) {
          _images.put(url, disk);
          return disk;
        }
      }
      final Uint8List? bytes = await (debugFetchImage ?? _fetchImage)(url);
      if (bytes == null || bytes.isEmpty) {
        _failedAt['img:$url'] = DateTime.now();
        return null;
      }
      _images.put(url, bytes);
      if (!debugSkipPersistentCache) {
        unawaited(ImageDiskCache.write(diskKey, bytes));
      }
      return bytes;
    } catch (_) {
      _failedAt['img:$url'] = DateTime.now();
      return null;
    }
  }

  static Future<Uint8List?> _fetchImage(String url) async {
    final String? token = _accessToken();
    if (token == null) return null;
    final Uri uri = Uri.parse(
      '${ApiConfigService.apiBaseUrl}/v1/link_preview/image',
    ).replace(queryParameters: <String, String>{'url': url});
    final http.Response resp = await http
        .get(uri, headers: <String, String>{'Authorization': 'Bearer $token'})
        .timeout(_timeout);
    if (resp.statusCode != 200) return null;
    return resp.bodyBytes;
  }
}

class _Stored {
  const _Stored(this.preview);
  final LinkPreview? preview;
}
