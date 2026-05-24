import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/artifact_storage_service.dart';

void main() {
  group('ArtifactStorageService pending flushers', () {
    tearDown(() async {
      // Make sure we don't leak callbacks between tests.
      await ArtifactStorageService.flushPendingEdits();
    });

    test('flushPendingEdits is a no-op when no flushers are registered',
        () async {
      // Should not throw even with zero registrations.
      await ArtifactStorageService.flushPendingEdits();
    });

    test('registered flusher is invoked exactly once', () async {
      var count = 0;
      Future<void> flush() async {
        count += 1;
      }

      ArtifactStorageService.registerPendingFlusher('a', flush);
      await ArtifactStorageService.flushPendingEdits();
      expect(count, 1);

      // Still registered — flushing again invokes it again.
      await ArtifactStorageService.flushPendingEdits();
      expect(count, 2);

      ArtifactStorageService.unregisterPendingFlusher('a', flush);
      await ArtifactStorageService.flushPendingEdits();
      expect(count, 2, reason: 'unregister should stop further invocations');
    });

    test('registerPendingFlusher overwrites the previous flusher for an id',
        () async {
      var firstCalls = 0;
      var secondCalls = 0;
      Future<void> first() async {
        firstCalls += 1;
      }

      Future<void> second() async {
        secondCalls += 1;
      }

      ArtifactStorageService.registerPendingFlusher('dup', first);
      ArtifactStorageService.registerPendingFlusher('dup', second);
      await ArtifactStorageService.flushPendingEdits();

      expect(firstCalls, 0);
      expect(secondCalls, 1);

      ArtifactStorageService.unregisterPendingFlusher('dup', second);
    });

    test('unregisterPendingFlusher with stale expected does not remove '
        'the active flusher', () async {
      var calls = 0;
      Future<void> active() async {
        calls += 1;
      }

      Future<void> stale() async {}

      ArtifactStorageService.registerPendingFlusher('id', active);
      ArtifactStorageService.unregisterPendingFlusher('id', stale);
      await ArtifactStorageService.flushPendingEdits();
      expect(calls, 1, reason: 'active flusher must still be registered');

      ArtifactStorageService.unregisterPendingFlusher('id', active);
    });

    test('flushPendingEdits swallows errors from individual flushers',
        () async {
      var goodCalls = 0;
      Future<void> bad() async => throw StateError('boom');
      Future<void> good() async {
        goodCalls += 1;
      }

      ArtifactStorageService.registerPendingFlusher('bad', bad);
      ArtifactStorageService.registerPendingFlusher('good', good);

      // Must not throw — a broken editor cannot block the user's send.
      await ArtifactStorageService.flushPendingEdits();
      expect(goodCalls, 1);

      ArtifactStorageService.unregisterPendingFlusher('bad', bad);
      ArtifactStorageService.unregisterPendingFlusher('good', good);
    });

    test('empty artifactId is ignored by register/unregister', () async {
      var calls = 0;
      Future<void> flush() async {
        calls += 1;
      }

      ArtifactStorageService.registerPendingFlusher('', flush);
      ArtifactStorageService.registerPendingFlusher('   ', flush);
      await ArtifactStorageService.flushPendingEdits();
      expect(calls, 0);

      // unregister with empty id is a no-op (must not throw).
      ArtifactStorageService.unregisterPendingFlusher('');
      ArtifactStorageService.unregisterPendingFlusher('  ');
    });
  });
}
