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

  group('ArtifactStorageService.computeOrphanBrackets', () {
    test('returns empty when no discarded stamps', () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: const [],
        nextStampedEvents: const [],
      );
      expect(brackets, isEmpty);
    });

    test(
        'open-ended bracket when no next stamped event in the same chat',
        () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: [
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:00:00Z',
          },
        ],
        nextStampedEvents: const [],
      );
      expect(brackets, hasLength(1));
      expect(brackets.first.chatId, 'chat-A');
      expect(brackets.first.start, DateTime.utc(2026, 5, 20, 10));
      expect(
        brackets.first.end,
        isNull,
        reason: 'open-ended bracket runs up to "now"',
      );
    });

    test('closes the bracket at the next stamped event in the same chat',
        () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: [
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:00:00Z',
          },
        ],
        nextStampedEvents: [
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T11:30:00Z',
            'message_id': 'm-next',
          },
        ],
      );
      expect(brackets, hasLength(1));
      expect(brackets.first.end, DateTime.utc(2026, 5, 20, 11, 30));
    });

    test('ignores stamped events from other chats', () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: [
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:00:00Z',
          },
        ],
        nextStampedEvents: [
          {
            'chat_id': 'chat-OTHER',
            'created_at': '2026-05-20T10:30:00Z',
            'message_id': 'm-other',
          },
        ],
      );
      expect(brackets.first.end, isNull,
          reason: 'cross-chat events must not close our bracket');
    });

    test('picks the earliest stamped event strictly after the start', () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: [
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:00:00Z',
          },
        ],
        nextStampedEvents: [
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T09:00:00Z', // BEFORE start — skip
            'message_id': 'm-before',
          },
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T12:00:00Z', // candidate
            'message_id': 'm-mid',
          },
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T14:00:00Z', // later candidate — skip
            'message_id': 'm-late',
          },
        ],
      );
      expect(brackets.first.end, DateTime.utc(2026, 5, 20, 12));
    });

    test('deduplicates identical (chatId, start) pairs', () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: [
          {'chat_id': 'chat-A', 'created_at': '2026-05-20T10:00:00Z'},
          {'chat_id': 'chat-A', 'created_at': '2026-05-20T10:00:00Z'},
        ],
        nextStampedEvents: const [],
      );
      expect(brackets, hasLength(1));
    });

    test('skips rows with missing or malformed fields', () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: [
          {'chat_id': '', 'created_at': '2026-05-20T10:00:00Z'},
          {'chat_id': 'chat-A', 'created_at': null},
          {'chat_id': 'chat-A', 'created_at': 'not-a-date'},
          {'chat_id': 'chat-A', 'created_at': '2026-05-20T10:00:00Z'},
        ],
        nextStampedEvents: const [],
      );
      expect(brackets, hasLength(1));
      expect(brackets.first.chatId, 'chat-A');
    });

    test('produces one bracket per distinct discarded message in same chat',
        () {
      final brackets = ArtifactStorageService.computeOrphanBrackets(
        discardedStamps: [
          {'chat_id': 'chat-A', 'created_at': '2026-05-20T10:00:00Z'},
          {'chat_id': 'chat-A', 'created_at': '2026-05-20T12:00:00Z'},
        ],
        nextStampedEvents: [
          {
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T15:00:00Z',
            'message_id': 'm-after-all',
          },
        ],
      );
      expect(brackets, hasLength(2));
      // Both brackets close on the same later event (the only stamped
      // event strictly after both starts).
      expect(brackets[0].end, DateTime.utc(2026, 5, 20, 15));
      expect(brackets[1].end, DateTime.utc(2026, 5, 20, 15));
    });
  });

  group('ArtifactStorageService.filterOrphanSnapshotsInBrackets', () {
    test('returns empty when no candidates or no brackets', () {
      expect(
        ArtifactStorageService.filterOrphanSnapshotsInBrackets(
          candidateSnapshots: const [],
          brackets: const [],
        ),
        isEmpty,
      );
      expect(
        ArtifactStorageService.filterOrphanSnapshotsInBrackets(
          candidateSnapshots: const [
            {
              'message_id': null,
              'chat_id': 'chat-A',
              'created_at': '2026-05-20T10:30:00Z',
            },
          ],
          brackets: const [],
        ),
        isEmpty,
      );
    });

    test('snapshot inside the bracket window is matched', () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'id': 99,
            'artifact_id': 'art-1',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:30:00Z',
            'version': 3,
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
        ],
      );
      expect(result, hasLength(1));
      expect(result.first['artifact_id'], 'art-1');
    });

    test('snapshot BEFORE the bracket start is NOT matched', () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T09:00:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
        ],
      );
      expect(result, isEmpty);
    });

    test('snapshot AT OR AFTER the bracket end is NOT matched', () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': null,
            'chat_id': 'chat-A',
            // exactly at end — half-open `< end` should exclude.
            'created_at': '2026-05-20T11:00:00Z',
          },
          {
            'artifact_id': 'art-2',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T12:00:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
        ],
      );
      expect(result, isEmpty);
    });

    test('open-ended bracket (end == null) catches everything from start to now',
        () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:00:00Z',
          },
          {
            'artifact_id': 'art-2',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2099-01-01T00:00:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: null,
          ),
        ],
      );
      expect(result, hasLength(2));
    });

    test('safety guard: STAMPED rows are NEVER matched even inside window',
        () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': 'live-msg-id',
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:30:00Z',
          },
          {
            'artifact_id': 'art-2',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:31:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
        ],
      );
      // Only the un-stamped row is rolled back. The live-msg row is left
      // alone even though it's in-window.
      expect(result, hasLength(1));
      expect(result.first['artifact_id'], 'art-2');
    });

    test('cross-chat snapshots in the window are NOT matched', () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': null,
            'chat_id': 'chat-OTHER',
            'created_at': '2026-05-20T10:30:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
        ],
      );
      expect(result, isEmpty);
    });

    test('multiple discarded brackets → multiple windows are honored', () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:30:00Z',
          },
          {
            'artifact_id': 'art-2',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T13:00:00Z',
          },
          {
            'artifact_id': 'art-3',
            'message_id': null,
            'chat_id': 'chat-A',
            // Between the two brackets — must NOT match.
            'created_at': '2026-05-20T11:30:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 12, 30),
            end: DateTime.utc(2026, 5, 20, 13, 30),
          ),
        ],
      );
      final matchedIds =
          result.map((r) => r['artifact_id'] as String).toSet();
      expect(matchedIds, {'art-1', 'art-2'});
    });

    test('skips rows with missing chat_id or unparseable created_at', () {
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': null,
            'chat_id': null,
            'created_at': '2026-05-20T10:30:00Z',
          },
          {
            'artifact_id': 'art-2',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': 'not-a-date',
          },
          {
            'artifact_id': 'art-3',
            'message_id': null,
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:30:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
        ],
      );
      expect(result, hasLength(1));
      expect(result.first['artifact_id'], 'art-3');
    });

    test(
        'whitespace-only message_id is treated as orphan (consistent with _insertVersion normalization)',
        () {
      // PostgREST returns JSON null for NULL columns, and _insertVersion
      // normalizes empty/whitespace stamps to null on write. If a
      // whitespace-only value somehow sneaks in, treat it as an orphan
      // so rollback stays consistent with how the data is written.
      final result = ArtifactStorageService.filterOrphanSnapshotsInBrackets(
        candidateSnapshots: const [
          {
            'artifact_id': 'art-1',
            'message_id': '   ',
            'chat_id': 'chat-A',
            'created_at': '2026-05-20T10:30:00Z',
          },
        ],
        brackets: [
          (
            chatId: 'chat-A',
            start: DateTime.utc(2026, 5, 20, 10),
            end: DateTime.utc(2026, 5, 20, 11),
          ),
        ],
      );
      // Whitespace-only `message_id` is treated as orphan (consistent
      // with `_insertVersion` which trims and collapses empty to null).
      expect(result, hasLength(1));
    });
  });
}
