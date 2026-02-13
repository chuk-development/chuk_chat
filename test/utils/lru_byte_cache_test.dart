import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/lru_byte_cache.dart';

/// Helper: create a Uint8List of [size] bytes.
Uint8List _bytes(int size) => Uint8List(size);

void main() {
  group('LruByteCache', () {
    test('stores and retrieves entries', () {
      final cache = LruByteCache(maxSizeBytes: 1024);
      final data = _bytes(100);

      cache.put('a', data);
      expect(cache.get('a'), equals(data));
      expect(cache.length, 1);
      expect(cache.currentSizeBytes, 100);
    });

    test('returns null for missing keys', () {
      final cache = LruByteCache(maxSizeBytes: 1024);
      expect(cache.get('missing'), isNull);
    });

    test('evicts oldest entry when over limit', () {
      final cache = LruByteCache(maxSizeBytes: 200);

      cache.put('a', _bytes(100));
      cache.put('b', _bytes(100));
      // Cache is exactly at 200 bytes — no eviction yet
      expect(cache.length, 2);

      // Adding 'c' pushes over limit — 'a' (oldest) should be evicted
      cache.put('c', _bytes(100));
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNotNull);
      expect(cache.get('c'), isNotNull);
      expect(cache.currentSizeBytes, 200);
    });

    test('evicts multiple entries if needed', () {
      final cache = LruByteCache(maxSizeBytes: 300);

      cache.put('a', _bytes(100));
      cache.put('b', _bytes(100));
      cache.put('c', _bytes(100));
      expect(cache.length, 3);

      // Adding a 250-byte entry needs to evict a, b, c first (300 - 250 = 50 room needed)
      cache.put('big', _bytes(250));
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNull);
      expect(cache.get('c'), isNull);
      expect(cache.get('big'), isNotNull);
      expect(cache.length, 1);
      expect(cache.currentSizeBytes, 250);
    });

    test('allows single entry larger than maxSizeBytes', () {
      final cache = LruByteCache(maxSizeBytes: 100);

      // Entry larger than max — should still be stored (at least one entry)
      cache.put('huge', _bytes(200));
      expect(cache.get('huge'), isNotNull);
      expect(cache.length, 1);
      expect(cache.currentSizeBytes, 200);
    });

    test('access via get() promotes to most-recently-used', () {
      final cache = LruByteCache(maxSizeBytes: 200);

      cache.put('a', _bytes(100));
      cache.put('b', _bytes(100));

      // Access 'a' to promote it — now 'b' is the oldest
      cache.get('a');

      // Adding 'c' should evict 'b' (oldest), not 'a'
      cache.put('c', _bytes(100));
      expect(cache.get('b'), isNull);
      expect(cache.get('a'), isNotNull);
      expect(cache.get('c'), isNotNull);
    });

    test('updating existing key replaces value and size', () {
      final cache = LruByteCache(maxSizeBytes: 500);

      cache.put('a', _bytes(100));
      expect(cache.currentSizeBytes, 100);

      // Replace with larger value
      cache.put('a', _bytes(300));
      expect(cache.currentSizeBytes, 300);
      expect(cache.length, 1);
    });

    test('remove() frees memory', () {
      final cache = LruByteCache(maxSizeBytes: 500);

      cache.put('a', _bytes(100));
      cache.put('b', _bytes(200));
      expect(cache.currentSizeBytes, 300);

      cache.remove('a');
      expect(cache.get('a'), isNull);
      expect(cache.currentSizeBytes, 200);
      expect(cache.length, 1);
    });

    test('remove() on missing key is a no-op', () {
      final cache = LruByteCache(maxSizeBytes: 500);
      cache.remove('nonexistent'); // should not throw
      expect(cache.length, 0);
      expect(cache.currentSizeBytes, 0);
    });

    test('clear() empties everything', () {
      final cache = LruByteCache(maxSizeBytes: 500);

      cache.put('a', _bytes(100));
      cache.put('b', _bytes(200));
      cache.clear();

      expect(cache.length, 0);
      expect(cache.currentSizeBytes, 0);
      expect(cache.get('a'), isNull);
    });

    test('containsKey() does not promote entry', () {
      final cache = LruByteCache(maxSizeBytes: 200);

      cache.put('a', _bytes(100));
      cache.put('b', _bytes(100));

      // containsKey should NOT promote 'a'
      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('c'), isFalse);

      // 'a' is still oldest — should be evicted when adding 'c'
      cache.put('c', _bytes(100));
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNotNull);
      expect(cache.get('c'), isNotNull);
    });

    test('size accounting stays correct after mixed operations', () {
      final cache = LruByteCache(maxSizeBytes: 1000);

      cache.put('a', _bytes(100));
      cache.put('b', _bytes(200));
      cache.put('c', _bytes(300));
      expect(cache.currentSizeBytes, 600);

      cache.remove('b');
      expect(cache.currentSizeBytes, 400);

      cache.put('d', _bytes(150));
      expect(cache.currentSizeBytes, 550);

      cache.put('a', _bytes(50)); // update: 100 -> 50
      expect(cache.currentSizeBytes, 500);

      cache.clear();
      expect(cache.currentSizeBytes, 0);
    });
  });
}
