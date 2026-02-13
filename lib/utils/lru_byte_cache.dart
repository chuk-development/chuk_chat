// lib/utils/lru_byte_cache.dart
import 'dart:collection' show LinkedHashMap;
import 'dart:typed_data';

/// LRU (Least Recently Used) cache with a maximum total byte size.
///
/// When adding an entry would exceed [maxSizeBytes], the least recently
/// used entries are evicted until there is enough room. Access via [get]
/// promotes the entry to most-recently-used.
class LruByteCache {
  /// Maximum total bytes the cache may hold.
  final int maxSizeBytes;

  /// Insertion-ordered map: oldest entries first, newest last.
  /// Dart's LinkedHashMap iterates in insertion order, so removing
  /// and re-inserting an entry moves it to the end (most recent).
  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();

  int _currentSizeBytes = 0;

  LruByteCache({required this.maxSizeBytes});

  /// Current total bytes stored in the cache.
  int get currentSizeBytes => _currentSizeBytes;

  /// Number of entries in the cache.
  int get length => _entries.length;

  /// Returns the cached bytes for [key], or null if not present.
  /// Promotes the entry to most-recently-used on hit.
  Uint8List? get(String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    // Re-insert at end (most recent)
    _entries[key] = value;
    return value;
  }

  /// Returns true if [key] is in the cache (without promoting it).
  bool containsKey(String key) => _entries.containsKey(key);

  /// Stores [value] under [key]. If the single entry exceeds [maxSizeBytes],
  /// it is still stored (cache holds at least one entry) but all others are
  /// evicted first.
  void put(String key, Uint8List value) {
    // If key already exists, remove it first so size accounting is correct
    final existing = _entries.remove(key);
    if (existing != null) {
      _currentSizeBytes -= existing.lengthInBytes;
    }

    final entrySize = value.lengthInBytes;

    // Evict oldest entries until there is room
    while (_entries.isNotEmpty &&
        _currentSizeBytes + entrySize > maxSizeBytes) {
      _evictOldest();
    }

    _entries[key] = value;
    _currentSizeBytes += entrySize;
  }

  /// Removes [key] from the cache.
  void remove(String key) {
    final removed = _entries.remove(key);
    if (removed != null) {
      _currentSizeBytes -= removed.lengthInBytes;
    }
  }

  /// Removes all entries.
  void clear() {
    _entries.clear();
    _currentSizeBytes = 0;
  }

  void _evictOldest() {
    if (_entries.isEmpty) return;
    final oldestKey = _entries.keys.first;
    final oldestValue = _entries.remove(oldestKey)!;
    _currentSizeBytes -= oldestValue.lengthInBytes;
  }
}
