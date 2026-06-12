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

  /// Drop everything. Used by tests and as the hard reset.
  void clear() {
    _byContent.clear();
    _refsPausedUntil = null;
  }

  /// React to a server `cache_miss`: drop all entries (so the replay re-sends in
  /// full) and pause ref emission for a cooldown, so a persistently unavailable
  /// server cache doesn't cost a miss on every turn.
  void handleMiss() {
    _byContent.clear();
    _refsPausedUntil = now().add(_missCooldown);
  }

  int get length => _byContent.length;

  void _purgeExpired() {
    final t = now();
    _byContent.removeWhere((_, e) => !e.expiresAt.isAfter(t));
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
