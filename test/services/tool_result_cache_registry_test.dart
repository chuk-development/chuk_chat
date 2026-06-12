import 'package:chuk_chat/services/tool_result_cache_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ToolResultCacheRegistry registry;
  late DateTime clock;

  setUp(() {
    registry = ToolResultCacheRegistry.instance;
    registry.clear();
    clock = DateTime(2026, 1, 1, 12);
    registry.now = () => clock;
  });

  tearDown(() {
    registry.clear();
    registry.now = DateTime.now;
  });

  String big([String seed = 'x']) =>
      seed * (ToolResultCacheRegistry.minContentLength);

  test('shouldCache gates on minimum length', () {
    expect(registry.shouldCache('short'), isFalse);
    expect(
      registry.shouldCache('y' * ToolResultCacheRegistry.minContentLength),
      isTrue,
    );
  });

  test('register then refFor returns the same id', () {
    final content = big();
    final id = registry.register(content);
    expect(id, isNotEmpty);
    expect(registry.refFor(content), id);
  });

  test('register is idempotent for identical fresh content', () {
    final content = big();
    final id1 = registry.register(content);
    final id2 = registry.register(content);
    expect(id1, id2);
    expect(registry.length, 1);
  });

  test('refFor returns null for unregistered content', () {
    expect(registry.refFor(big('z')), isNull);
  });

  test('distinct content gets distinct ids', () {
    final idA = registry.register(big('a'));
    final idB = registry.register(big('b'));
    expect(idA, isNot(idB));
    expect(registry.length, 2);
  });

  test('entries expire after the TTL', () {
    final content = big();
    registry.register(content);
    // Just inside the window → still a hit.
    clock = clock.add(const Duration(minutes: 9, seconds: 59));
    expect(registry.refFor(content), isNotNull);
    // Past the 10-minute TTL → miss, and the stale entry is dropped.
    clock = clock.add(const Duration(seconds: 2));
    expect(registry.refFor(content), isNull);
  });

  test('refFor does not extend the TTL', () {
    final content = big();
    registry.register(content);
    clock = clock.add(const Duration(minutes: 5));
    expect(registry.refFor(content), isNotNull); // read midway
    clock = clock.add(const Duration(minutes: 5, seconds: 1));
    // Still ages out 10 min after register, not after the read.
    expect(registry.refFor(content), isNull);
  });

  test('clear drops all entries (cache_miss recovery path)', () {
    registry.register(big('a'));
    registry.register(big('b'));
    expect(registry.length, 2);
    registry.clear();
    expect(registry.length, 0);
    expect(registry.refFor(big('a')), isNull);
  });

  test('keys are trim-normalised so message and history form match', () {
    // The pass uploads the untrimmed message; the tool loop appends the
    // trimmed form to history. refFor against the trimmed form must still hit.
    final core = big();
    final id = registry.register('\n\n$core\n\n'); // as sent in `message`
    expect(registry.refFor(core), id); // as stored in history (trimmed)
  });

  test('handleMiss pauses ref emission for the cooldown then resumes', () {
    final content = big();
    registry.register(content);
    expect(registry.refFor(content), isNotNull);

    registry.handleMiss();
    // Paused: refs suppressed (turn sends full) even after re-registering.
    registry.register(content);
    expect(registry.refFor(content), isNull);

    // Still paused before the window closes.
    clock = clock.add(const Duration(seconds: 59));
    expect(registry.refFor(content), isNull);

    // After the cooldown, refs resume for freshly registered content.
    clock = clock.add(const Duration(seconds: 2));
    final id = registry.register(content);
    expect(registry.refFor(content), id);
  });

  test('re-registering after expiry mints a fresh id', () {
    final content = big();
    final id1 = registry.register(content);
    clock = clock.add(const Duration(minutes: 11));
    expect(registry.refFor(content), isNull);
    final id2 = registry.register(content);
    expect(id2, isNot(id1));
  });
}
