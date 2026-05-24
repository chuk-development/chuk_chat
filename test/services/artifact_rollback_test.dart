import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/artifact_storage_service.dart';

void main() {
  group('ArtifactStorageService.latestRemainingVersion', () {
    test('returns null when every version is discarded', () {
      final result = ArtifactStorageService.latestRemainingVersion(
        snapshotVersions: const [1, 2, 3],
        discardedVersions: const {1, 2, 3},
      );
      expect(result, isNull);
    });

    test('returns null when snapshot list is empty', () {
      final result = ArtifactStorageService.latestRemainingVersion(
        snapshotVersions: const [],
        discardedVersions: const {1, 2},
      );
      expect(result, isNull);
    });

    test('returns the highest version when nothing is discarded', () {
      final result = ArtifactStorageService.latestRemainingVersion(
        snapshotVersions: const [1, 2, 3, 4, 5],
        discardedVersions: const {},
      );
      expect(result, 5);
    });

    test('skips the discarded versions and picks the highest remainder', () {
      final result = ArtifactStorageService.latestRemainingVersion(
        snapshotVersions: const [1, 2, 3, 4, 5],
        discardedVersions: const {4, 5},
      );
      expect(
        result,
        3,
        reason: 'after discarding the top two, v3 is the new latest',
      );
    });

    test('handles unordered snapshot input (picks max non-discarded)', () {
      final result = ArtifactStorageService.latestRemainingVersion(
        snapshotVersions: const [3, 1, 5, 2, 4],
        discardedVersions: const {5},
      );
      expect(result, 4);
    });

    test('discarded versions that are not in the snapshot list are ignored',
        () {
      final result = ArtifactStorageService.latestRemainingVersion(
        snapshotVersions: const [1, 2],
        discardedVersions: const {7, 8, 9},
      );
      expect(result, 2);
    });

    test('only the discarded versions in the middle are stripped', () {
      // Snapshots 1..10 exist; the user is regenerating two AI turns in
      // the middle that each bumped the artifact. After rollback, the
      // top version must be the latest surviving snapshot.
      final result = ArtifactStorageService.latestRemainingVersion(
        snapshotVersions: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        discardedVersions: const {5, 6},
      );
      expect(result, 10);
    });
  });

  group('ArtifactStorageService.rollbackArtifactsForMessages (no-op paths)', () {
    setUp(() {
      // Tests share global state — reset before each.
      ArtifactStorageService.currentMessageId = null;
    });

    tearDown(() {
      ArtifactStorageService.currentMessageId = null;
    });

    test('empty iterable returns without touching Supabase', () async {
      // Should complete synchronously without throwing even though no
      // Supabase client is initialised in the test environment.
      await ArtifactStorageService.rollbackArtifactsForMessages(const <String>[]);
    });

    test('whitespace-only message ids are filtered to empty and return',
        () async {
      await ArtifactStorageService.rollbackArtifactsForMessages(const [
        '',
        '   ',
        '\t',
      ]);
    });

    // Non-empty inputs reach SupabaseService.auth and require a live
    // Supabase client, which is not available under `flutter test`.
    // Cover the de-dup / id-shape logic only via the no-op paths above
    // and the pure `latestRemainingVersion` helper exercised in the
    // first group.
  });

  group('ArtifactStorageService.currentMessageId stamping', () {
    setUp(() {
      ArtifactStorageService.currentMessageId = null;
    });

    tearDown(() {
      ArtifactStorageService.currentMessageId = null;
    });

    test('defaults to null between turns', () {
      expect(ArtifactStorageService.currentMessageId, isNull);
    });

    test('round-trips the stamp set by the send pipeline', () {
      ArtifactStorageService.currentMessageId = 'turn-123';
      expect(ArtifactStorageService.currentMessageId, 'turn-123');
    });

    test('callers may clear the stamp by assigning null', () {
      ArtifactStorageService.currentMessageId = 'turn-xyz';
      ArtifactStorageService.currentMessageId = null;
      expect(ArtifactStorageService.currentMessageId, isNull);
    });
  });
}
