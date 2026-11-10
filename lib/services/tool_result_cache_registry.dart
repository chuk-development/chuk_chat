// lib/services/tool_result_cache_registry.dart
//
// Client half of the v2 multiplex tool-result cache (server half lives in
// api_server/tool_result_cache.py).
//
// Why: the agentic tool loop is client-orchestrated. The client uploads a
// formatted tool-result string on the pass that produced it, then — because
// every following pass re-sends the whole conversation — re-uploads that same
// (often large) crawl/search text inside `history` on each subsequent pass. On
// weak mobile uplinks that repeated upload dominates latency.
//
// How: when the client sends a large `message`, it tags the payload with a
// `message_cache_id`. The server caches the exact string it received under that
// id (user-scoped, 10 min TTL). On later passes the same content appears as a
// `history` entry; the client replaces it with a tiny `{role, cache_ref: id}`
// marker so the bytes never go up the wire again.
//
// Safety: a reference can miss (TTL expiry, eviction, a server restart, or a
// reconnect onto a different process). The server reports that as a `cache_miss`
// error and the client clears this registry and re-sends the turn in full — a
// missing ref is never silently dropped. Matching is by exact string equality
// (the content is the Map key), so there is no hash-collision risk of pointing
// a ref at the wrong text.

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class _RegistryEntry {
  _RegistryEntry(this.id, this.expiresAt);
  final String id;
  final DateTime expiresAt;
}

/// Process-wide registry mapping a previously-uploaded message string to the
/// cache id the server stored it under.
class ToolResultCacheRegistry {
  ToolResultCacheRegistry._();
  static final ToolResultCacheRegistry instance = ToolResultCacheRegistry._();

  /// Only bother caching payloads at least this large — small messages cost
  /// more in protocol overhead than they save.
  static const int minContentLength = 2000;

  /// Mirror the server TTL (10 min) so the client stops emitting refs at about
  /// the same time the server stops honoring them, minimising avoidable misses.
  static const Duration _ttl = Duration(minutes: 10);

  /// Cap the number of tracked entries; oldest-registered are dropped first.
  static const int _maxEntries = 64;

  /// After a server miss, stop emitting refs for this long. Stops a broken /
  /// restarted server cache from costing one extra `cache_miss` round-trip on
  /// every single turn — at worst one miss per cooldown window instead.
  static const Duration _missCooldown = Duration(seconds: 60);

  final Map<String, _RegistryEntry> _byContent = <String, _RegistryEntry>{};

  /// Images (data URLs) the server holds: the turn's images (`images` +
  /// `image_cache_ids`) and history images tagged with `cache_id`. Kept
  /// apart from the text entries so a long chat's images do not push the
  /// tool results out (and the other way round).
  final Map<String, _RegistryEntry> _images = <String, _RegistryEntry>{};

  /// Cap of [_images]. A chat may carry up to 100 history images for some
  /// providers; the server keeps them in a shared 96 MiB LRU, so the oldest
  /// go first on both sides.
  static const int _maxImageEntries = 128;

  /// Cap on the characters of all tracked image keys, so the registry never
  /// holds more than a few requests' worth of image data alive.
  static const int _maxImageChars = 48000000;
  int _imageChars = 0;

  DateTime? _refsPausedUntil;

  /// Injectable clock for tests.
  DateTime Function() now = DateTime.now;

  bool get _refsPaused =>
      _refsPausedUntil != null && _refsPausedUntil!.isAfter(now());

  /// True when [content] is worth caching (large enough to matter).
  bool shouldCache(String content) => content.trim().length >= minContentLength;

  /// Register [content] that is about to be uploaded in full, returning the id
  /// to put in `message_cache_id`. Idempotent: re-registering identical, still
  /// fresh content returns the same id.
  ///
  /// Keys are normalised with `trim()`: the tool loop appends the trimmed form
  /// to history (`latestUserMessage.trim()`) and the server stores the stripped
  /// message, so the message we register here and the history entry we later
  /// match against [refFor] line up regardless of surrounding whitespace.
  String register(String content) {
    _purgeExpired();
    final key = content.trim();
    final existing = _byContent[key];
    if (existing != null && existing.expiresAt.isAfter(now())) {
      return existing.id;
    }
    final id = _uuid.v4().replaceAll('-', '');
    _byContent[key] = _RegistryEntry(id, now().add(_ttl));
    _evictIfNeeded();
    return id;
  }

  /// Return the cache id for [content] if it was registered and is still fresh,
  /// else null (meaning: send the content in full). Does NOT extend the TTL.
  /// Returns null while in the post-miss cooldown so the turn sends full text.
  String? refFor(String content) {
    if (_refsPaused) return null;
    final key = content.trim();
    final entry = _byContent[key];
    if (entry == null) return null;
    if (!entry.expiresAt.isAfter(now())) {
      _byContent.remove(key);
      return null;
    }
    return entry.id;
  }

  /// Registers an image ([dataUrl], a `data:image/` URL) that is about to
  /// go up in full with a cache id (`image_cache_ids`, or `cache_id` on a
  /// history block). Returns the id. Re-registering a fresh image returns
  /// the same id and restarts its lifetime, as the server's store does.
  String registerImage(String dataUrl) {
    _purgeExpiredImages();
    final existing = _images.remove(dataUrl);
    final id = existing != null && existing.expiresAt.isAfter(now())
        ? existing.id
        : _uuid.v4().replaceAll('-', '');
    if (existing == null) _imageChars += dataUrl.length;
    _images[dataUrl] = _RegistryEntry(id, now().add(_ttl));
    _evictImagesIfNeeded();
    return id;
  }

  /// The id the server holds [dataUrl] under, or null (send it in full).
  /// A hit restarts the entry's lifetime: the server restarts its TTL each
  /// time a ref resolves (history images are used on every turn). Null
  /// during the post-miss cooldown.
  String? imageRefFor(String dataUrl) {
    if (_refsPaused) return null;
    final entry = _images.remove(dataUrl);
    if (entry == null) return null;
    if (!entry.expiresAt.isAfter(now())) {
      _imageChars -= dataUrl.length;
      return null;
    }
    // Re-insert as the newest, with a fresh lifetime.
    _images[dataUrl] = _RegistryEntry(entry.id, now().add(_ttl));
    return entry.id;
  }

  int get imageCount => _images.length;

  /// Drop everything. Used by tests and as the hard reset.
  void clear() {
    _byContent.clear();
    _images.clear();
    _imageChars = 0;
    _refsPausedUntil = null;
  }

  /// React to a server `cache_miss`: drop all entries (so the replay re-sends in
  /// full) and pause ref emission for a cooldown, so a persistently unavailable
  /// server cache doesn't cost a miss on every turn.
  void handleMiss() {
    _byContent.clear();
    _images.clear();
    _imageChars = 0;
    _refsPausedUntil = now().add(_missCooldown);
  }

  int get length => _byContent.length;

  void _purgeExpired() {
    final t = now();
    _byContent.removeWhere((_, e) => !e.expiresAt.isAfter(t));
  }

  void _purgeExpiredImages() {
    final t = now();
    _images.removeWhere((key, e) {
      if (e.expiresAt.isAfter(t)) return false;
      _imageChars -= key.length;
      return true;
    });
  }

  void _evictImagesIfNeeded() {
    while (_images.length > _maxImageEntries ||
        (_imageChars > _maxImageChars && _images.length > 1)) {
      final oldest = _images.keys.first;
      _images.remove(oldest);
      _imageChars -= oldest.length;
    }
  }

  void _evictIfNeeded() {
    while (_byContent.length > _maxEntries) {
      // Map preserves insertion order — the first key is the oldest.
      _byContent.remove(_byContent.keys.first);
    }
  }
}

/// Stable marker the server attaches (`code`) and the client matches to detect
/// a missed cache reference. Defined once so both the dispatch layer and the
/// retry path agree on it.
const String kCacheMissErrorCode = 'cache_miss';
