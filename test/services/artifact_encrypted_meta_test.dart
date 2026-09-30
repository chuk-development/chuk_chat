import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/encrypted_meta.dart';

// A reversible stand-in for EncryptionService: base64 behind a prefix, so a
// sealed value never shows its plaintext, and an envelope without the prefix
// behaves like one sealed with another key.
const String _prefix = 'fake:';

Future<String> _fakeSeal(String plaintext) async =>
    '$_prefix${base64Encode(utf8.encode(plaintext))}';

Future<String> _fakeOpen(String envelope) async {
  if (!envelope.startsWith(_prefix)) {
    throw const FormatException('sealed with another key');
  }
  return utf8.decode(base64Decode(envelope.substring(_prefix.length)));
}

const String _rowUuid = '3f2b8c1e-6a4d-4f0e-9b7a-2c5d8e1f0a93';

Map<String, dynamic> _row({
  required String id,
  required Object? title,
  Object? language,
  Object? encryptedMeta,
  String updatedAt = '2026-09-01T10:00:00.000Z',
}) {
  return <String, dynamic>{
    'id': id,
    'chat_id': 'chat-1',
    'user_id': 'user-1',
    'message_id': 'msg-1',
    'title': title,
    'type': 'code',
    'language': language,
    'content': 'ignored',
    'version': 3,
    'attachment_path': '',
    'created_at': '2026-08-01T09:00:00.000Z',
    'updated_at': updatedAt,
    'encrypted_meta': encryptedMeta,
  };
}

ArtifactRowRef _ref({
  required String rowId,
  required String handle,
  required String updatedAt,
  String? title,
  String? stamp,
}) {
  return (
    rowId: rowId,
    handle: handle,
    chatId: 'chat-1',
    title: title ?? handle,
    language: null,
    updatedAt: DateTime.parse(updatedAt),
    stamp: stamp,
  );
}

/// Seals [fields] the way the service does, bound to `artifacts` row
/// [rowId].
Future<String> _seal(String rowId, Map<String, Object?> fields) =>
    EncryptedMeta.encode(fields, table: 'artifacts', rowId: rowId);

Future<ArtifactDocument> _resolve(Map<String, dynamic> row) async {
  final opened = await ArtifactStorageService.decodeRowMeta(
    row['encrypted_meta'],
    rowId: row['id'] as String,
  );
  return ArtifactStorageService.documentFromRow(
    row,
    decryptedContent: 'body',
    meta: opened.meta,
    metaUnreadable: opened.unreadable,
  );
}

Future<bool> _needsReseal(Map<String, dynamic> row) async {
  final opened = await ArtifactStorageService.decodeRowMeta(
    row['encrypted_meta'],
    rowId: row['id'] as String,
  );
  return ArtifactStorageService.needsReseal(
    row,
    meta: opened.meta,
    metaUnreadable: opened.unreadable,
  );
}

/// Opens an envelope as the service does for `artifacts` row [rowId];
/// throws when it was sealed for another row.
Future<Map<String, dynamic>> _open(Object? envelope, String rowId) async {
  final meta = await EncryptedMeta.decode(
    envelope as String?,
    table: 'artifacts',
    rowId: rowId,
  );
  expect(meta, isNotNull);
  return meta!;
}

void main() {
  setUp(() {
    EncryptedMeta.seal = _fakeSeal;
    EncryptedMeta.open = _fakeOpen;
  });

  tearDown(EncryptedMeta.resetCipher);

  group('reading a row', () {
    test('legacy row: the id is the handle, plaintext is used', () async {
      final row = _row(id: 'todo-app', title: 'Todo App', language: 'dart');

      final doc = await _resolve(row);

      expect(doc.id, 'todo-app');
      expect(doc.rowId, 'todo-app');
      expect(doc.title, 'Todo App');
      expect(doc.language, 'dart');
      expect(doc.type, ArtifactType.code);
      expect(doc.version, 3);
      expect(doc.content, 'body');
      expect(doc.attachmentPath, isNull);
      expect(await _needsReseal(row), isTrue);
    });

    test('legacy row without a title falls back to the handle', () async {
      final doc = await _resolve(_row(id: 'todo-app', title: null));
      expect(doc.title, 'todo-app');
    });

    test('sealed row: handle, title and language come from the envelope',
        () async {
      final row = _row(
        id: _rowUuid,
        title: kEncryptedPlaceholder,
        encryptedMeta: await _seal(_rowUuid, {
          'handle': 'todo-app',
          'title': 'Todo App',
          'language': 'dart',
        }),
      );

      final doc = await _resolve(row);

      expect(doc.id, 'todo-app');
      expect(doc.rowId, _rowUuid);
      expect(doc.title, 'Todo App');
      expect(doc.language, 'dart');
      expect(await _needsReseal(row), isFalse);
    });

    test('sealed row with plaintext from an old build: plaintext wins and '
        'the row is queued for a re-seal', () async {
      final row = _row(
        id: _rowUuid,
        title: 'Renamed by old app',
        language: 'python',
        encryptedMeta: await _seal(_rowUuid, {
          'handle': 'todo-app',
          'title': 'Todo App',
          'language': 'dart',
        }),
      );

      final doc = await _resolve(row);

      expect(doc.id, 'todo-app', reason: 'the handle stays the sealed one');
      expect(doc.rowId, _rowUuid);
      expect(doc.title, 'Renamed by old app');
      expect(doc.language, 'python');
      expect(await _needsReseal(row), isTrue);

      // The re-seal keeps the row id (it is not the handle) and seals the
      // values the reader saw.
      final update = await ArtifactStorageService.buildResealUpdate(
        ArtifactStorageService.rowRefFromRow(
          row,
          meta: (await ArtifactStorageService.decodeRowMeta(
            row['encrypted_meta'],
            rowId: _rowUuid,
          )).meta,
        ),
      );
      expect(update.containsKey('id'), isFalse);
      expect(update['title'], kEncryptedPlaceholder);
      expect(update['language'], isNull);
      final sealed = await _open(update['encrypted_meta'], _rowUuid);
      expect(sealed['handle'], 'todo-app');
      expect(sealed['title'], 'Renamed by old app');
      expect(sealed['language'], 'python');
    });

    test('undecryptable envelope: row id as handle, placeholder title, '
        'never re-sealed', () async {
      final row = _row(
        id: _rowUuid,
        title: kEncryptedPlaceholder,
        encryptedMeta: 'sealed-with-an-older-key',
      );

      final opened = await ArtifactStorageService.decodeRowMeta(
        row['encrypted_meta'],
        rowId: _rowUuid,
      );
      expect(opened.unreadable, isTrue);
      expect(opened.meta, isNull);

      final doc = await _resolve(row);
      expect(doc.id, _rowUuid);
      expect(doc.rowId, _rowUuid);
      expect(doc.title, kEncryptedPlaceholder);
      expect(doc.language, isNull);
      expect(await _needsReseal(row), isFalse);
    });

    test('undecryptable envelope is never re-sealed, even with plaintext '
        'from an old build', () async {
      final row = _row(
        id: _rowUuid,
        title: 'Old build title',
        language: 'dart',
        encryptedMeta: 'sealed-with-an-older-key',
      );

      expect(await _needsReseal(row), isFalse);
      final doc = await _resolve(row);
      expect(doc.id, _rowUuid);
      expect(doc.title, 'Old build title');
    });

    test('an envelope that is not a JSON object counts as unreadable',
        () async {
      final envelope = await _fakeSeal('["not", "an", "object"]');
      final opened = await ArtifactStorageService.decodeRowMeta(
        envelope,
        rowId: _rowUuid,
      );
      expect(opened.unreadable, isTrue);
    });

    test('a sealed row whose id still is its handle needs a re-key',
        () async {
      final row = _row(
        id: 'todo-app',
        title: kEncryptedPlaceholder,
        encryptedMeta: await _seal('todo-app', {
          'handle': 'todo-app',
          'title': 'Todo App',
        }),
      );
      expect(await _needsReseal(row), isTrue);
    });
  });

  group('envelope bound to its row', () {
    const otherRow = '9a1c7e52-0b3d-4c8f-a6e2-5d4f3b2a1c0e';

    test('an envelope moved to another row is unreadable there', () async {
      // Two artifacts of one user; the server swaps their envelopes.
      final sealedForA = await _seal(_rowUuid, {
        'handle': 'todo-app',
        'title': 'Todo App',
      });
      final rowB = _row(
        id: otherRow,
        title: kEncryptedPlaceholder,
        encryptedMeta: sealedForA,
      );

      final opened = await ArtifactStorageService.decodeRowMeta(
        sealedForA,
        rowId: otherRow,
      );
      expect(opened.unreadable, isTrue);
      expect(opened.meta, isNull);

      final doc = await _resolve(rowB);
      expect(doc.id, otherRow, reason: 'the stolen handle is not taken');
      expect(doc.title, kEncryptedPlaceholder);
      expect(await _needsReseal(rowB), isFalse,
          reason: 'handled like an unreadable row: never re-sealed');

      // On its own row the same envelope still opens.
      final home = await ArtifactStorageService.decodeRowMeta(
        sealedForA,
        rowId: _rowUuid,
      );
      expect(home.unreadable, isFalse);
      expect(home.meta?['handle'], 'todo-app');
    });

    test('an envelope from another table with the same id is unreadable',
        () async {
      final projectEnvelope = await EncryptedMeta.encode(
        {'name': 'Plan'},
        table: 'projects',
        rowId: _rowUuid,
      );
      final opened = await ArtifactStorageService.decodeRowMeta(
        projectEnvelope,
        rowId: _rowUuid,
      );
      expect(opened.unreadable, isTrue);
    });

    test('a new row seals for its own new id', () async {
      final payload = await ArtifactStorageService.buildInsertPayload(
        rowId: _rowUuid,
        handle: 'todo-app',
        chatId: 'chat-1',
        userId: 'user-1',
        title: 'Todo App',
        type: ArtifactType.code,
        encryptedContent: 'cipher',
        now: DateTime.utc(2026, 9, 30),
      );
      final sealed = await _open(payload['encrypted_meta'], _rowUuid);
      expect(sealed['tbl'], 'artifacts');
      expect(sealed['row'], _rowUuid);
      await expectLater(
        _open(payload['encrypted_meta'], otherRow),
        throwsFormatException,
      );
    });

    test('a re-key seals for the new id; a plain re-seal for the same id',
        () async {
      final legacy = ArtifactStorageService.rowRefFromRow(
        _row(id: 'todo-app', title: 'Todo App'),
        meta: null,
      );
      final rekeyed = await ArtifactStorageService.buildResealUpdate(
        legacy,
        newRowId: () => otherRow,
      );
      expect(rekeyed['id'], otherRow);
      expect((await _open(rekeyed['encrypted_meta'], otherRow))['row'],
          otherRow);

      final sealedRow = _row(
        id: _rowUuid,
        title: 'Renamed by old app',
        encryptedMeta: await _seal(_rowUuid, {
          'handle': 'todo-app',
          'title': 'Todo App',
        }),
      );
      final sealedRef = ArtifactStorageService.rowRefFromRow(
        sealedRow,
        meta: (await ArtifactStorageService.decodeRowMeta(
          sealedRow['encrypted_meta'],
          rowId: _rowUuid,
        )).meta,
      );
      final update = await ArtifactStorageService.buildResealUpdate(sealedRef);
      expect(update.containsKey('id'), isFalse);
      expect((await _open(update['encrypted_meta'], _rowUuid))['row'],
          _rowUuid);
    });

    test('sealedMetaColumns binds to the id it is given', () async {
      final columns = await ArtifactStorageService.sealedMetaColumns(
        rowId: otherRow,
        handle: 'todo-app',
        title: 'Todo App',
      );
      expect((await _open(columns['encrypted_meta'], otherRow))['handle'],
          'todo-app');
      await expectLater(
        _open(columns['encrypted_meta'], _rowUuid),
        throwsFormatException,
      );
    });
  });

  group('re-seal sweep filter', () {
    test('selects by the placeholder only, never by a name', () {
      expect(
        ArtifactStorageService.resealCandidateFilter,
        'encrypted_meta.is.null,'
        'title.neq.$kEncryptedPlaceholder,'
        'language.not.is.null',
      );
    });

    test('every row the filter selects needs a re-seal; a clean sealed row '
        'does not', () async {
      final meta = await _seal(_rowUuid, {
        'handle': 'todo-app',
        'title': 'Todo App',
      });

      // encrypted_meta.is.null
      expect(
        await _needsReseal(
          _row(id: 'todo-app', title: kEncryptedPlaceholder),
        ),
        isTrue,
      );
      // title.neq.placeholder
      expect(
        await _needsReseal(
          _row(id: _rowUuid, title: 'Plain', encryptedMeta: meta),
        ),
        isTrue,
      );
      // language.not.is.null (even an empty string is cleared)
      expect(
        await _needsReseal(
          _row(
            id: _rowUuid,
            title: kEncryptedPlaceholder,
            language: '',
            encryptedMeta: meta,
          ),
        ),
        isTrue,
      );
      // None of the three.
      expect(
        await _needsReseal(
          _row(
            id: _rowUuid,
            title: kEncryptedPlaceholder,
            encryptedMeta: meta,
          ),
        ),
        isFalse,
      );
    });
  });

  group('handle lookup', () {
    test('prefers the newest row when a handle appears twice', () {
      final refs = [
        _ref(
          rowId: 'row-old',
          handle: 'todo-app',
          updatedAt: '2026-09-01T10:00:00Z',
        ),
        _ref(
          rowId: 'row-new',
          handle: 'todo-app',
          updatedAt: '2026-09-02T10:00:00Z',
        ),
        _ref(
          rowId: 'row-other',
          handle: 'notes',
          updatedAt: '2026-09-03T10:00:00Z',
        ),
      ];

      expect(
        ArtifactStorageService.resolveRowRef(refs, 'todo-app')?.rowId,
        'row-new',
      );
      expect(
        ArtifactStorageService.resolveRowRef(refs.reversed, 'todo-app')?.rowId,
        'row-new',
        reason: 'order of the rows must not matter',
      );
    });

    test('accepts a row id', () {
      final refs = [
        _ref(rowId: _rowUuid, handle: 'todo-app', updatedAt: '2026-09-01'),
      ];
      expect(
        ArtifactStorageService.resolveRowRef(refs, _rowUuid)?.handle,
        'todo-app',
      );
    });

    test('a handle match wins over a row id match', () {
      final refs = [
        _ref(rowId: 'shared', handle: 'first', updatedAt: '2026-09-01'),
        _ref(rowId: 'second-row', handle: 'shared', updatedAt: '2026-09-01'),
      ];
      expect(
        ArtifactStorageService.resolveRowRef(refs, 'shared')?.rowId,
        'second-row',
      );
    });

    test('an unknown key resolves to nothing', () {
      final refs = [
        _ref(rowId: _rowUuid, handle: 'todo-app', updatedAt: '2026-09-01'),
      ];
      expect(ArtifactStorageService.resolveRowRef(refs, 'missing'), isNull);
      expect(
        ArtifactStorageService.resolveRowRef(const <ArtifactRowRef>[], 'x'),
        isNull,
      );
    });
  });

  group('write payloads', () {
    test('insert: random row id, handle and title only inside the envelope',
        () async {
      final rowId = const Uuid().v4();
      final payload = await ArtifactStorageService.buildInsertPayload(
        rowId: rowId,
        handle: 'secret-plan',
        chatId: 'chat-1',
        userId: 'user-1',
        title: '  Secret Plan  ',
        type: ArtifactType.markdown,
        language: ' markdown ',
        encryptedContent: 'cipher',
        messageId: 'msg-1',
        now: DateTime.utc(2026, 9, 30, 12),
      );

      expect(payload['id'], rowId);
      expect(payload['id'], isNot('secret-plan'));
      expect(ArtifactStorageService.isValidHandle(payload['id'] as String),
          isTrue);
      expect(payload['title'], kEncryptedPlaceholder);
      expect(payload['language'], isNull);
      expect(payload['is_active'], isTrue);
      expect(payload['version'], 1);
      expect(payload['type'], 'markdown');
      expect(payload['created_at'], '2026-09-30T12:00:00.000Z');

      for (final entry in payload.entries) {
        final value = entry.value?.toString() ?? '';
        expect(value.contains('secret-plan'), isFalse,
            reason: '${entry.key} must not carry the handle');
        expect(value.contains('Secret Plan'), isFalse,
            reason: '${entry.key} must not carry the title');
      }
      expect((payload['encrypted_meta'] as String).contains('markdown'),
          isFalse,
          reason: 'the envelope must not show the language');

      final sealed = await _open(payload['encrypted_meta'], rowId);
      expect(sealed['handle'], 'secret-plan');
      expect(sealed['title'], 'Secret Plan');
      expect(sealed['language'], 'markdown');
      expect(sealed['v'], kEncryptedMetaVersion);
    });

    test('insert: an empty title falls back to the handle, a blank language '
        'is dropped', () async {
      final payload = await ArtifactStorageService.buildInsertPayload(
        rowId: _rowUuid,
        handle: 'todo-app',
        chatId: 'chat-1',
        userId: 'user-1',
        title: '   ',
        type: ArtifactType.code,
        language: '  ',
        encryptedContent: 'cipher',
        now: DateTime.utc(2026, 9, 30),
      );

      final sealed = await _open(payload['encrypted_meta'], _rowUuid);
      expect(sealed['title'], 'todo-app');
      expect(sealed.containsKey('language'), isFalse);
      expect(payload['title'], kEncryptedPlaceholder);
    });

    test('re-seal of a legacy row: new random id, sealed metadata', () async {
      final row = _row(id: 'todo-app', title: 'Todo App', language: 'dart');
      final ref = ArtifactStorageService.rowRefFromRow(row, meta: null);

      final update = await ArtifactStorageService.buildResealUpdate(ref);

      final newId = update['id'] as String?;
      expect(newId, isNotNull);
      expect(newId, isNot('todo-app'));
      expect(ArtifactStorageService.isValidHandle(newId!), isTrue);
      expect(update['title'], kEncryptedPlaceholder);
      expect(update['language'], isNull);
      expect(update.keys.toSet(), {'id', 'title', 'language', 'encrypted_meta'},
          reason: 'a re-seal must not touch content, version or timestamps');
      // Sealed for the new id, in the same update that sets it.
      final sealed = await _open(update['encrypted_meta'], newId);
      expect(sealed['handle'], 'todo-app');
      expect(sealed['title'], 'Todo App');
      expect(sealed['language'], 'dart');
      await expectLater(
        _open(update['encrypted_meta'], 'todo-app'),
        throwsFormatException,
        reason: 'the old id no longer opens it',
      );
    });

    test('re-seal takes the row id from the given generator', () async {
      final ref = ArtifactStorageService.rowRefFromRow(
        _row(id: 'todo-app', title: 'Todo App'),
        meta: null,
      );
      final update = await ArtifactStorageService.buildResealUpdate(
        ref,
        newRowId: () => _rowUuid,
      );
      expect(update['id'], _rowUuid);
    });

    test('random row ids pass the artifact id pattern', () {
      for (var i = 0; i < 50; i++) {
        expect(ArtifactStorageService.isValidHandle(const Uuid().v4()), isTrue);
      }
    });
  });

  group('re-seal stamp (optimistic concurrency)', () {
    const rawStamp = '2026-09-01T10:00:00.123456+00:00';

    test('rows carry their updated_at exactly as the server sent it',
        () async {
      final row = _row(
        id: 'todo-app',
        title: 'Todo App',
        updatedAt: rawStamp,
      );
      final ref = ArtifactStorageService.rowRefFromRow(row, meta: null);
      expect(ref.stamp, rawStamp, reason: 'not rebuilt from a DateTime');
      expect((await _resolve(row)).updatedAtStamp, rawStamp);
    });

    test('a row without updated_at has no stamp', () {
      final row = _row(id: 'todo-app', title: 'Todo App')
        ..remove('updated_at');
      expect(ArtifactStorageService.rowRefFromRow(row, meta: null).stamp,
          isNull);
    });

    test('filters: row, owner and the raw stamp, nothing else', () async {
      final meta = await _seal(_rowUuid, {
        'handle': 'secret-plan',
        'title': 'Secret Plan',
      });
      final row = _row(
        id: _rowUuid,
        title: 'Secret Plan',
        encryptedMeta: meta,
        updatedAt: rawStamp,
      );
      final ref = ArtifactStorageService.rowRefFromRow(
        row,
        meta: (await ArtifactStorageService.decodeRowMeta(
          meta,
          rowId: _rowUuid,
        )).meta,
      );

      final filters = ArtifactStorageService.resealFilters(
        ref,
        userId: 'user-1',
      );

      expect(filters, {
        'id': _rowUuid,
        'user_id': 'user-1',
        'updated_at': rawStamp,
      });
      for (final value in filters!.values) {
        expect(value.contains('secret-plan'), isFalse);
        expect(value.contains('Secret Plan'), isFalse);
        expect(value, isNot(meta));
      }
    });

    test('a legacy row is filtered by its old id and its stamp', () {
      final ref = ArtifactStorageService.rowRefFromRow(
        _row(id: 'todo-app', title: 'Todo App', updatedAt: rawStamp),
        meta: null,
      );
      expect(ArtifactStorageService.resealFilters(ref, userId: 'user-1'), {
        'id': 'todo-app',
        'user_id': 'user-1',
        'updated_at': rawStamp,
      });
    });

    test('no stamp, no re-seal', () {
      final ref = _ref(
        rowId: _rowUuid,
        handle: 'todo-app',
        updatedAt: '2026-09-01',
      );
      expect(
        ArtifactStorageService.resealFilters(ref, userId: 'user-1'),
        isNull,
      );
      expect(
        ArtifactStorageService.resealFilters(
          _ref(
            rowId: _rowUuid,
            handle: 'todo-app',
            updatedAt: '2026-09-01',
            stamp: '',
          ),
          userId: 'user-1',
        ),
        isNull,
      );
    });

    test('the freshest copy wins, and its values travel with its stamp', () {
      final cached = _ref(
        rowId: _rowUuid,
        handle: 'todo-app',
        title: 'Old title',
        updatedAt: '2026-09-01T10:00:00Z',
        stamp: '2026-09-01T10:00:00.000001+00:00',
      );
      final indexed = _ref(
        rowId: _rowUuid,
        handle: 'todo-app',
        title: 'New title',
        // Client clock after a local write; the stamp is what counts.
        updatedAt: '2020-01-01T00:00:00Z',
        stamp: '2026-09-02T10:00:00.000001+00:00',
      );

      final picked = ArtifactStorageService.freshestRef([cached, indexed]);

      expect(picked?.title, 'New title');
      expect(picked?.stamp, '2026-09-02T10:00:00.000001+00:00');
    });

    test('copies without a stamp are never picked; a tie keeps the first',
        () {
      final unstamped = _ref(
        rowId: _rowUuid,
        handle: 'todo-app',
        title: 'Unstamped',
        updatedAt: '2026-09-09T10:00:00Z',
      );
      final first = _ref(
        rowId: _rowUuid,
        handle: 'todo-app',
        title: 'First',
        updatedAt: '2026-09-01T10:00:00Z',
        stamp: rawStamp,
      );
      final second = _ref(
        rowId: _rowUuid,
        handle: 'todo-app',
        title: 'Second',
        updatedAt: '2026-09-01T10:00:00Z',
        stamp: rawStamp,
      );

      expect(
        ArtifactStorageService.freshestRef([unstamped, first, second])?.title,
        'First',
      );
      expect(ArtifactStorageService.freshestRef([unstamped]), isNull);
      expect(
        ArtifactStorageService.freshestRef(const <ArtifactRowRef>[]),
        isNull,
      );
    });
  });

  group('model', () {
    test('rowId defaults to the handle', () {
      final doc = ArtifactDocument(
        id: 'sandbox_file',
        chatId: 'chat-1',
        userId: 'user-1',
        title: 'file.md',
        type: ArtifactType.markdown,
        content: '',
        version: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      expect(doc.rowId, 'sandbox_file');
    });

    test('copyWith moves the row id and keeps the handle', () {
      final doc = ArtifactDocument(
        id: 'todo-app',
        chatId: 'chat-1',
        userId: 'user-1',
        title: 'Todo',
        type: ArtifactType.code,
        content: '',
        version: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      final moved = doc
          .copyWith(updatedAtStamp: '2026-09-01T10:00:00+00:00')
          .copyWith(rowId: _rowUuid);
      expect(moved.id, 'todo-app');
      expect(moved.rowId, _rowUuid);
      expect(moved.updatedAtStamp, '2026-09-01T10:00:00+00:00',
          reason: 'a re-key keeps the stamp (the trigger keeps it too)');
      expect(moved.copyWith(title: 'Other').rowId, _rowUuid);
    });

    test('version snapshots carry the handle, not the row id', () {
      final snapshot = ArtifactVersionSnapshot.fromMap(
        {
          'artifact_id': _rowUuid,
          'version': 2,
          'created_at': '2026-09-01T10:00:00Z',
        },
        decryptedContent: 'body',
        artifactId: 'todo-app',
      );
      expect(snapshot.artifactId, 'todo-app');
      expect(snapshot.version, 2);
    });
  });
}
