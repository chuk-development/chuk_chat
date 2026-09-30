// Sealed project / project file metadata (`encrypted_meta`): the read rule,
// the re-seal decision, the sealed write payloads and the startup sweep
// filters. EncryptionService needs a signed-in user, so the cipher is a
// fake reversible one set through EncryptedMeta.seal / EncryptedMeta.open.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/encrypted_meta.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';

const _prefix = 'FAKEKEY:';

// Raw `updated_at` strings as PostgREST sends them (microseconds, offset).
const _projectStamp = '2026-09-30T10:15:42.123456+00:00';
const _fileStamp = '2026-09-30T11:00:00.000001+00:00';

/// Reversible and opaque: base64 hides the plaintext, like a real envelope.
Future<String> _fakeSeal(String plaintext) async =>
    '$_prefix${base64Encode(utf8.encode(plaintext))}';

/// Opens only envelopes of [_fakeSeal]; anything else acts like a wrong key.
Future<String> _fakeOpen(String envelope) async {
  if (!envelope.startsWith(_prefix)) {
    throw StateError('SecretBoxAuthenticationError');
  }
  return utf8.decode(base64Decode(envelope.substring(_prefix.length)));
}

/// An envelope sealed with another key (cannot be opened).
String _foreignEnvelope(Map<String, Object?> fields) =>
    'OTHERKEY:${base64Encode(utf8.encode(jsonEncode({'v': 1, ...fields})))}';

/// Envelope bound to project row 'proj-1' (the default [_projectRow]).
Future<String> _envelope(
  Map<String, Object?> fields, {
  String table = 'projects',
  String row = 'proj-1',
}) => EncryptedMeta.encode(fields, table: table, rowId: row);

/// Envelope bound to file row 'file-1' (the default [_fileRow]).
Future<String> _fileEnvelope(Map<String, Object?> fields) =>
    _envelope(fields, table: 'project_files', row: 'file-1');

Map<String, dynamic> _projectRow({
  String id = 'proj-1',
  Object? name = kEncryptedPlaceholder,
  Object? description,
  Object? prompt,
  String? envelope,
}) => {
  'id': id,
  'user_id': 'user-1',
  'name': name,
  'description': description,
  'custom_system_prompt': prompt,
  'encrypted_meta': envelope,
  'created_at': '2026-09-01T10:00:00.000Z',
  'updated_at': _projectStamp,
  'is_archived': false,
};

Map<String, dynamic> _fileRow({
  String id = 'file-1',
  Object? fileName = kEncryptedPlaceholder,
  Object? markdown,
  String? envelope,
}) => {
  'id': id,
  'project_id': 'proj-1',
  'file_name': fileName,
  'storage_path': 'user-1/abc.enc',
  'file_type': 'md',
  'file_size': 42,
  'uploaded_at': '2026-09-01T10:00:00.000Z',
  'updated_at': _fileStamp,
  'markdown_summary': markdown,
  'encrypted_meta': envelope,
};

Future<SealedRowRead> _readProject(Map<String, dynamic> raw) =>
    WorkspaceStorageService.resolveSealedRow(
      raw,
      WorkspaceStorageService.projectSealedFields,
      requiredField: 'name',
      table: 'projects',
    );

Future<SealedRowRead> _readFile(Map<String, dynamic> raw) =>
    WorkspaceStorageService.resolveSealedRow(
      raw,
      WorkspaceStorageService.fileSealedFields,
      requiredField: 'file_name',
      table: 'project_files',
    );

/// Evaluates a PostgREST `or` filter of the sweep against one row with SQL
/// semantics (NULL <> x is not true), so the query and [rowNeedsReseal]
/// can be checked against each other.
bool _matchesOrFilter(String filter, Map<String, dynamic> row) {
  for (final clause in filter.split(',')) {
    final dot = clause.indexOf('.');
    final column = clause.substring(0, dot);
    final op = clause.substring(dot + 1);
    final value = row[column];
    if (op == 'is.null') {
      if (value == null) return true;
    } else if (op == 'not.is.null') {
      if (value != null) return true;
    } else if (op.startsWith('neq.')) {
      var operand = op.substring(4);
      if (operand.startsWith('"') && operand.endsWith('"')) {
        operand = operand.substring(1, operand.length - 1);
      }
      if (value != null && value != operand) return true;
    } else {
      fail('Unknown operator in sweep filter: $clause');
    }
  }
  return false;
}

void main() {
  setUp(() {
    EncryptedMeta.seal = _fakeSeal;
    EncryptedMeta.open = _fakeOpen;
  });

  tearDown(EncryptedMeta.resetCipher);

  group('EncryptedMeta', () {
    test('encode drops nulls, adds the version and names its row',
        () async {
      final envelope = await _envelope({'name': 'Alpha', 'description': null});
      final body = jsonDecode(await _fakeOpen(envelope)) as Map;
      expect(body, {
        'v': kEncryptedMetaVersion,
        'tbl': 'projects',
        'row': 'proj-1',
        'name': 'Alpha',
      });
      expect(body.containsKey('description'), isFalse);
    });

    test('decode of null or blank is a legacy row (null)', () async {
      for (final empty in [null, '', '   ']) {
        expect(
          await EncryptedMeta.decode(empty, table: 'projects', rowId: 'p'),
          isNull,
        );
      }
    });

    test('decode round-trips encode for the same row', () async {
      final envelope = await _envelope({'name': 'Alpha'});
      expect(
        await EncryptedMeta.decode(
          envelope,
          table: 'projects',
          rowId: 'proj-1',
        ),
        {
          'v': kEncryptedMetaVersion,
          'tbl': 'projects',
          'row': 'proj-1',
          'name': 'Alpha',
        },
      );
    });

    test('decode throws for another key and for a non-object', () async {
      await expectLater(
        EncryptedMeta.decode(
          _foreignEnvelope({'name': 'x'}),
          table: 'projects',
          rowId: 'proj-1',
        ),
        throwsA(anything),
      );
      await expectLater(
        EncryptedMeta.decode(
          await _fakeSeal('[1, 2]'),
          table: 'projects',
          rowId: 'proj-1',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode throws for an envelope of another row or table', () async {
      final envelope = await _envelope({'name': 'Alpha'});
      await expectLater(
        EncryptedMeta.decode(envelope, table: 'projects', rowId: 'proj-2'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        EncryptedMeta.decode(
          envelope,
          table: 'project_files',
          rowId: 'proj-1',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('isRealPlaintext rejects gaps and the placeholder', () {
      expect(EncryptedMeta.isRealPlaintext('Alpha'), isTrue);
      expect(EncryptedMeta.isRealPlaintext(null), isFalse);
      expect(EncryptedMeta.isRealPlaintext(''), isFalse);
      expect(EncryptedMeta.isRealPlaintext('  '), isFalse);
      expect(EncryptedMeta.isRealPlaintext(kEncryptedPlaceholder), isFalse);
      expect(EncryptedMeta.isRealPlaintext(' $kEncryptedPlaceholder '), isFalse);
      expect(EncryptedMeta.isRealPlaintext(42), isFalse);
    });

    test('pick: real plaintext wins, otherwise the sealed value', () {
      final meta = {'name': 'Sealed'};
      expect(EncryptedMeta.pick('Plain', meta, 'name'), 'Plain');
      expect(EncryptedMeta.pick(kEncryptedPlaceholder, meta, 'name'), 'Sealed');
      expect(EncryptedMeta.pick('', meta, 'name'), 'Sealed');
      expect(EncryptedMeta.pick(null, meta, 'name'), 'Sealed');
      expect(EncryptedMeta.pick(kEncryptedPlaceholder, null, 'name'), isNull);
      expect(EncryptedMeta.pick(null, {'name': 7}, 'name'), isNull);
    });

    test('placeholder satisfies the length(trim(x)) > 0 CHECK', () {
      expect(kEncryptedPlaceholder.trim(), isNotEmpty);
      expect(kEncryptedPlaceholder.runes.length, 1);
    });
  });

  group('resolveSealedRow: projects', () {
    test('legacy row keeps its plaintext and needs a re-seal', () async {
      final read = await _readProject(
        _projectRow(name: 'Alpha', description: 'About', prompt: 'Be brief'),
      );
      expect(read.legacy, isTrue);
      expect(read.undecryptable, isFalse);
      expect(read.needsReseal, isTrue);
      expect(read.row['name'], 'Alpha');
      expect(read.row['description'], 'About');
      expect(read.row['custom_system_prompt'], 'Be brief');
      expect(read.row.containsKey('encrypted_meta'), isFalse);
    });

    test('clean sealed row reads the sealed values', () async {
      final read = await _readProject(
        _projectRow(
          envelope: await _envelope({
            'name': 'Alpha',
            'description': 'About',
            'custom_system_prompt': 'Be brief',
          }),
        ),
      );
      expect(read.legacy, isFalse);
      expect(read.undecryptable, isFalse);
      expect(read.needsReseal, isFalse);
      expect(read.row['name'], 'Alpha');
      expect(read.row['description'], 'About');
      expect(read.row['custom_system_prompt'], 'Be brief');

      final workspace = Workspace.fromJson(read.row);
      expect(workspace.name, 'Alpha');
      expect(workspace.customSystemPrompt, 'Be brief');
    });

    test('old-build plaintext written after the seal wins', () async {
      final read = await _readProject(
        _projectRow(
          name: 'Renamed',
          envelope: await _envelope({
            'name': 'Alpha',
            'description': 'About',
            'custom_system_prompt': 'Be brief',
          }),
        ),
      );
      expect(read.row['name'], 'Renamed');
      expect(read.row['description'], 'About');
      expect(read.row['custom_system_prompt'], 'Be brief');
      expect(read.needsReseal, isTrue);
    });

    test('placeholder and blanks written back by an old build do not '
        'override the sealed values', () async {
      final read = await _readProject(
        _projectRow(
          name: kEncryptedPlaceholder,
          description: '',
          prompt: '',
          envelope: await _envelope({
            'name': 'Alpha',
            'description': 'About',
            'custom_system_prompt': 'Be brief',
          }),
        ),
      );
      expect(read.row['name'], 'Alpha');
      expect(read.row['description'], 'About');
      expect(read.row['custom_system_prompt'], 'Be brief');
      // The '' leftovers are cleaned up by a re-seal (with sealed values).
      expect(read.needsReseal, isTrue);
    });

    test('undecryptable envelope: placeholder name, never re-sealed', () async {
      final read = await _readProject(
        _projectRow(envelope: _foreignEnvelope({'name': 'Alpha'})),
      );
      expect(read.undecryptable, isTrue);
      expect(read.legacy, isFalse);
      expect(read.needsReseal, isFalse);
      expect(read.row['name'], kEncryptedPlaceholder);
      expect(read.row['description'], isNull);
      expect(read.row['custom_system_prompt'], isNull);
      expect(Workspace.fromJson(read.row).name, kEncryptedPlaceholder);
    });

    test('undecryptable envelope with old-build plaintext: shown, still '
        'never re-sealed', () async {
      final read = await _readProject(
        _projectRow(
          name: 'Renamed',
          envelope: _foreignEnvelope({'name': 'Alpha'}),
        ),
      );
      expect(read.undecryptable, isTrue);
      expect(read.needsReseal, isFalse);
      expect(read.row['name'], 'Renamed');
    });
  });

  group('resolveSealedRow: project files', () {
    test('legacy file row keeps its plaintext', () async {
      final read = await _readFile(
        _fileRow(fileName: 'notes.md', markdown: '# Secret notes'),
      );
      expect(read.legacy, isTrue);
      expect(read.needsReseal, isTrue);
      final file = WorkspaceFile.fromJson(read.row);
      expect(file.fileName, 'notes.md');
      expect(file.markdownSummary, '# Secret notes');
    });

    test('sealed file row reads the sealed name and text', () async {
      final read = await _readFile(
        _fileRow(
          envelope: await _fileEnvelope({
            'file_name': 'notes.md',
            'markdown_summary': '# Secret notes',
          }),
        ),
      );
      expect(read.needsReseal, isFalse);
      final file = WorkspaceFile.fromJson(read.row);
      expect(file.fileName, 'notes.md');
      expect(file.markdownSummary, '# Secret notes');
      expect(file.fileType, 'md');
      expect(file.fileSize, 42);
    });

    test('old-build markdown edit wins; placeholder name does not', () async {
      final read = await _readFile(
        _fileRow(
          markdown: '# Edited in an old build',
          envelope: await _fileEnvelope({
            'file_name': 'notes.md',
            'markdown_summary': '# Secret notes',
          }),
        ),
      );
      expect(read.row['file_name'], 'notes.md');
      expect(read.row['markdown_summary'], '# Edited in an old build');
      expect(read.needsReseal, isTrue);
    });

    test('undecryptable file row still builds a model', () async {
      final read = await _readFile(
        _fileRow(envelope: _foreignEnvelope({'file_name': 'notes.md'})),
      );
      expect(read.undecryptable, isTrue);
      expect(read.needsReseal, isFalse);
      final file = WorkspaceFile.fromJson(read.row);
      expect(file.fileName, kEncryptedPlaceholder);
      expect(file.markdownSummary, isNull);
    });
  });

  group('rowNeedsReseal', () {
    bool projectNeeds(Map<String, dynamic> row) =>
        WorkspaceStorageService.rowNeedsReseal(
          row,
          WorkspaceStorageService.projectSealedFields,
          requiredField: 'name',
        );
    bool fileNeeds(Map<String, dynamic> row) =>
        WorkspaceStorageService.rowNeedsReseal(
          row,
          WorkspaceStorageService.fileSealedFields,
          requiredField: 'file_name',
        );

    test('clean sealed rows need nothing', () {
      expect(projectNeeds(_projectRow(envelope: 'E')), isFalse);
      expect(fileNeeds(_fileRow(envelope: 'E')), isFalse);
    });

    test('rows without an envelope need a re-seal', () {
      expect(projectNeeds(_projectRow(name: 'Alpha')), isTrue);
      expect(projectNeeds(_projectRow(name: 'Alpha', envelope: '')), isTrue);
      expect(fileNeeds(_fileRow(fileName: 'a.md')), isTrue);
    });

    test('any non-clean sealed column needs a re-seal', () {
      expect(projectNeeds(_projectRow(name: 'Alpha', envelope: 'E')), isTrue);
      expect(projectNeeds(_projectRow(description: 'x', envelope: 'E')), isTrue);
      expect(projectNeeds(_projectRow(prompt: '', envelope: 'E')), isTrue);
      expect(fileNeeds(_fileRow(fileName: 'a.md', envelope: 'E')), isTrue);
      expect(fileNeeds(_fileRow(markdown: '# x', envelope: 'E')), isTrue);
    });
  });

  group('sweep filters', () {
    final projectRows = <Map<String, dynamic>>[
      _projectRow(envelope: 'E'),
      _projectRow(name: 'Alpha'),
      _projectRow(name: 'Alpha', envelope: 'E'),
      _projectRow(description: 'About', envelope: 'E'),
      _projectRow(description: '', envelope: 'E'),
      _projectRow(prompt: 'Be brief', envelope: 'E'),
      _projectRow(name: kEncryptedPlaceholder),
    ];
    final fileRows = <Map<String, dynamic>>[
      _fileRow(envelope: 'E'),
      _fileRow(fileName: 'a.md'),
      _fileRow(fileName: 'a.md', envelope: 'E'),
      _fileRow(markdown: '# x', envelope: 'E'),
      _fileRow(markdown: '', envelope: 'E'),
    ];

    test('filters have the expected shape', () {
      expect(
        WorkspaceStorageService.projectSweepFilter,
        'encrypted_meta.is.null,name.neq."$kEncryptedPlaceholder",'
        'description.not.is.null,custom_system_prompt.not.is.null',
      );
      expect(
        WorkspaceStorageService.fileSweepFilter,
        'encrypted_meta.is.null,file_name.neq."$kEncryptedPlaceholder",'
        'markdown_summary.not.is.null',
      );
    });

    test('project filter selects exactly the rows rowNeedsReseal flags', () {
      for (final row in projectRows) {
        expect(
          _matchesOrFilter(WorkspaceStorageService.projectSweepFilter, row),
          WorkspaceStorageService.rowNeedsReseal(
            row,
            WorkspaceStorageService.projectSealedFields,
            requiredField: 'name',
          ),
          reason: '$row',
        );
      }
    });

    test('file filter selects exactly the rows rowNeedsReseal flags', () {
      for (final row in fileRows) {
        expect(
          _matchesOrFilter(WorkspaceStorageService.fileSweepFilter, row),
          WorkspaceStorageService.rowNeedsReseal(
            row,
            WorkspaceStorageService.fileSealedFields,
            requiredField: 'file_name',
          ),
          reason: '$row',
        );
      }
    });
  });

  group('sealed write payloads', () {
    const name = 'Tax return helper';
    const description = 'Knows my finances';
    const prompt = 'You are my accountant';
    const fileName = 'salary-2026.md';
    const fileText = '# Salary\n\nGross: 123456';

    test('project payload keeps no plaintext in any column', () async {
      final payload = await WorkspaceStorageService.sealedProjectColumns(
        rowId: 'proj-1',
        name: name,
        description: description,
        customSystemPrompt: prompt,
      );
      expect(payload['name'], kEncryptedPlaceholder);
      expect((payload['name'] as String).trim(), isNotEmpty);
      // Explicit NULLs: an update clears old plaintext columns.
      expect(payload.containsKey('description'), isTrue);
      expect(payload['description'], isNull);
      expect(payload.containsKey('custom_system_prompt'), isTrue);
      expect(payload['custom_system_prompt'], isNull);

      final wire = jsonEncode(payload);
      for (final secret in [name, description, prompt]) {
        expect(wire.contains(secret), isFalse, reason: secret);
      }

      final meta = await EncryptedMeta.decode(
        payload['encrypted_meta'] as String,
        table: 'projects',
        rowId: 'proj-1',
      );
      expect(meta, {
        'v': kEncryptedMetaVersion,
        'tbl': 'projects',
        'row': 'proj-1',
        'name': name,
        'description': description,
        'custom_system_prompt': prompt,
      });
    });

    test('project payload drops cleared fields from the envelope', () async {
      final payload = await WorkspaceStorageService.sealedProjectColumns(
        rowId: 'proj-1',
        name: name,
      );
      final meta = await EncryptedMeta.decode(
        payload['encrypted_meta'] as String,
        table: 'projects',
        rowId: 'proj-1',
      );
      expect(meta, {
        'v': kEncryptedMetaVersion,
        'tbl': 'projects',
        'row': 'proj-1',
        'name': name,
      });
    });

    test('file payload keeps neither the name nor the text in plaintext',
        () async {
      final payload = await WorkspaceStorageService.sealedFileColumns(
        rowId: 'file-1',
        fileName: fileName,
        markdownSummary: fileText,
      );
      expect(payload['file_name'], kEncryptedPlaceholder);
      expect((payload['file_name'] as String).trim(), isNotEmpty);
      expect(payload.containsKey('markdown_summary'), isTrue);
      expect(payload['markdown_summary'], isNull);

      final wire = jsonEncode(payload);
      expect(wire.contains(fileName), isFalse);
      expect(wire.contains('Gross'), isFalse);
      // Plaintext metadata the design leaves outside the envelope.
      expect(payload.containsKey('file_type'), isFalse);
      expect(payload.containsKey('file_size'), isFalse);
      expect(payload.containsKey('storage_path'), isFalse);
    });

    test('a written project row reads back to the same values', () async {
      final row = {
        ..._projectRow(),
        ...await WorkspaceStorageService.sealedProjectColumns(
          rowId: 'proj-1',
          name: name,
          customSystemPrompt: prompt,
        ),
      };
      final read = await _readProject(row);
      expect(read.needsReseal, isFalse);
      expect(read.row['name'], name);
      expect(read.row['description'], isNull);
      expect(read.row['custom_system_prompt'], prompt);
    });

    test('a written file row reads back to the same values', () async {
      final row = {
        ..._fileRow(),
        ...await WorkspaceStorageService.sealedFileColumns(
          rowId: 'file-1',
          fileName: fileName,
          markdownSummary: fileText,
        ),
      };
      final read = await _readFile(row);
      expect(read.needsReseal, isFalse);
      expect(read.row['file_name'], fileName);
      expect(read.row['markdown_summary'], fileText);
    });

    test('withResolvedFields drops the envelope and sets the values', () {
      final row = WorkspaceStorageService.withResolvedFields(
        _projectRow(envelope: 'E'),
        {'name': name, 'description': null},
      );
      expect(row.containsKey('encrypted_meta'), isFalse);
      expect(row['name'], name);
      expect(row['description'], isNull);
      expect(Workspace.fromJson(row).name, name);
    });
  });

  group('mergeProjectFields', () {
    test('keeps the fields an update does not touch', () {
      final merged = WorkspaceStorageService.mergeProjectFields(
        currentName: 'Alpha',
        currentDescription: 'About',
        currentCustomSystemPrompt: 'Old prompt',
        customSystemPrompt: '  New prompt  ',
      );
      expect(merged.name, 'Alpha');
      expect(merged.description, 'About');
      expect(merged.customSystemPrompt, 'New prompt');
    });

    test('an empty string clears description and prompt', () {
      final merged = WorkspaceStorageService.mergeProjectFields(
        currentName: 'Alpha',
        currentDescription: 'About',
        currentCustomSystemPrompt: 'Prompt',
        name: '  Beta ',
        description: '',
        customSystemPrompt: '   ',
      );
      expect(merged.name, 'Beta');
      expect(merged.description, isNull);
      expect(merged.customSystemPrompt, isNull);
    });

    test('an empty new name is rejected', () {
      expect(
        () => WorkspaceStorageService.mergeProjectFields(
          currentName: 'Alpha',
          name: '  ',
        ),
        throwsArgumentError,
      );
    });

    test('the placeholder is never sealed as the name', () {
      expect(
        () => WorkspaceStorageService.mergeProjectFields(
          currentName: kEncryptedPlaceholder,
          customSystemPrompt: 'Prompt',
        ),
        throwsStateError,
      );
      final renamed = WorkspaceStorageService.mergeProjectFields(
        currentName: kEncryptedPlaceholder,
        name: 'Recovered',
      );
      expect(renamed.name, 'Recovered');
    });
  });

  group('re-seal snapshot job', () {
    test('project job carries the raw stamp and values of the same row',
        () async {
      final read = await _readProject(
        _projectRow(name: ' Alpha ', description: '', prompt: 'Be brief'),
      );
      final job = WorkspaceStorageService.resealJobFromRead(
        read,
        isFile: false,
      )!;
      expect(job.id, 'proj-1');
      expect(job.isFile, isFalse);
      expect(job.table, 'projects');
      expect(job.legacy, isTrue);
      expect(job.updatedAt, same(read.row['updated_at']));
      expect(job.updatedAt, _projectStamp);
      expect(job.values, {
        'name': 'Alpha',
        'description': null,
        'custom_system_prompt': 'Be brief',
      });
    });

    test('file job carries workspace, stamp and text', () async {
      final read = await _readFile(
        _fileRow(
          markdown: '# Edited in an old build',
          envelope: await _fileEnvelope({'file_name': 'notes.md'}),
        ),
      );
      final job = WorkspaceStorageService.resealJobFromRead(
        read,
        isFile: true,
      )!;
      expect(job.isFile, isTrue);
      expect(job.table, 'project_files');
      expect(job.workspaceId, 'proj-1');
      expect(job.legacy, isFalse);
      expect(job.updatedAt, _fileStamp);
      expect(job.values, {
        'file_name': 'notes.md',
        'markdown_summary': '# Edited in an old build',
      });
    });

    test('no job for clean, unreadable, unstamped or nameless rows',
        () async {
      Future<ResealJob?> jobFor(Map<String, dynamic> row) async =>
          WorkspaceStorageService.resealJobFromRead(
            await _readProject(row),
            isFile: false,
          );

      // Clean sealed row.
      expect(
        await jobFor(_projectRow(envelope: await _envelope({'name': 'A'}))),
        isNull,
      );
      // Sealed with another key.
      expect(
        await jobFor(
          _projectRow(name: 'A', envelope: _foreignEnvelope({'name': 'A'})),
        ),
        isNull,
      );
      // No stamp to guard the write.
      expect(
        await jobFor({..._projectRow(name: 'A'), 'updated_at': null}),
        isNull,
      );
      expect(
        await jobFor(
          Map.of(_projectRow(name: 'A'))..remove('updated_at'),
        ),
        isNull,
      );
      // Needs a clean-up but has no real name: never seal the placeholder.
      expect(
        await jobFor(
          _projectRow(
            description: '',
            envelope: await _envelope({'description': 'x'}),
          ),
        ),
        isNull,
      );
    });
  });

  group('guarded re-seal write', () {
    late List<http.Request> requests;
    late String responseBody;

    PostgrestQueryBuilder Function(String) fakeFrom() {
      final client = PostgrestClient(
        'http://localhost/rest/v1',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            responseBody,
            200,
            request: request,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      return client.from;
    }

    setUp(() {
      requests = [];
      responseBody = '[{"id":"proj-1"}]';
    });

    Future<ResealJob> projectJob({bool legacy = true}) async =>
        WorkspaceStorageService.resealJobFromRead(
          await _readProject(
            _projectRow(
              name: 'Tax return helper',
              prompt: 'You are my accountant',
              envelope: legacy
                  ? null
                  : await _envelope({'name': 'Old name'}),
            ),
          ),
          isFile: false,
        )!;

    test('legacy project write: id, owner, stamp and no-envelope guards',
        () async {
      final wrote = await WorkspaceStorageService.writeResealJob(
        await projectJob(),
        'user-1',
        from: fakeFrom(),
      );
      expect(wrote, isTrue);
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/rest/v1/projects');
      final query = request.url.queryParameters;
      expect(query['id'], 'eq.proj-1');
      expect(query['user_id'], 'eq.user-1');
      expect(query['updated_at'], 'eq.$_projectStamp');
      expect(query['encrypted_meta'], 'is.null');
      expect(query['select'], 'id');
      expect(query.keys.toSet(), {
        'id',
        'user_id',
        'updated_at',
        'encrypted_meta',
        'select',
      });

      // No value and no envelope in the URL; no plaintext in the body.
      final url = request.url.toString();
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(url.contains('Tax'), isFalse);
      expect(url.contains(_prefix), isFalse);
      expect(request.body.contains('Tax return helper'), isFalse);
      expect(request.body.contains('accountant'), isFalse);
      expect(body['name'], kEncryptedPlaceholder);
      expect(body['custom_system_prompt'], isNull);
      final meta = await EncryptedMeta.decode(
        body['encrypted_meta'] as String,
        table: 'projects',
        rowId: 'proj-1',
      );
      expect(meta!['name'], 'Tax return helper');
      expect(meta['custom_system_prompt'], 'You are my accountant');
    });

    test('non-legacy write is guarded by the stamp, not the envelope',
        () async {
      await WorkspaceStorageService.writeResealJob(
        await projectJob(legacy: false),
        'user-1',
        from: fakeFrom(),
      );
      final query = requests.single.url.queryParameters;
      expect(query['updated_at'], 'eq.$_projectStamp');
      expect(query.containsKey('encrypted_meta'), isFalse);
    });

    test('a write that matches no row is a skipped re-seal', () async {
      responseBody = '[]';
      final wrote = await WorkspaceStorageService.writeResealJob(
        await projectJob(),
        'user-1',
        from: fakeFrom(),
      );
      expect(wrote, isFalse);
    });

    test('file write: id, stamp and no-envelope guards, no owner column',
        () async {
      final job = WorkspaceStorageService.resealJobFromRead(
        await _readFile(
          _fileRow(fileName: 'salary-2026.md', markdown: 'Gross: 123456'),
        ),
        isFile: true,
      )!;
      final wrote = await WorkspaceStorageService.writeResealJob(
        job,
        'user-1',
        from: fakeFrom(),
      );
      expect(wrote, isTrue);
      final request = requests.single;
      expect(request.url.path, '/rest/v1/project_files');
      expect(request.url.queryParameters, {
        'id': 'eq.file-1',
        'updated_at': 'eq.$_fileStamp',
        'encrypted_meta': 'is.null',
        'select': 'id',
      });
      expect(request.url.toString().contains('salary'), isFalse);
      expect(request.body.contains('salary'), isFalse);
      expect(request.body.contains('Gross'), isFalse);
    });
  });

  group('row binding', () {
    test('an envelope sealed for row A on row B is unreadable', () async {
      final envelope = await _envelope({
        'name': 'Alpha',
        'custom_system_prompt': 'Prompt of project A',
      }, row: 'proj-A');
      final read = await _readProject(
        _projectRow(id: 'proj-B', envelope: envelope),
      );
      expect(read.undecryptable, isTrue);
      expect(read.needsReseal, isFalse);
      expect(read.row['name'], kEncryptedPlaceholder);
      expect(read.row['custom_system_prompt'], isNull);
      expect(
        WorkspaceStorageService.resealJobFromRead(read, isFile: false),
        isNull,
      );
      // Edits refuse the row instead of sealing over it.
      await expectLater(
        WorkspaceStorageService.mergeProjectUpdate(
          _projectRow(id: 'proj-B', envelope: envelope),
          customSystemPrompt: 'x',
        ),
        throwsStateError,
      );
    });

    test('a file envelope moved to another file is unreadable', () async {
      final envelope = await _envelope({
        'file_name': 'salary.md',
      }, table: 'project_files', row: 'file-A');
      final read = await _readFile(_fileRow(id: 'file-B', envelope: envelope));
      expect(read.undecryptable, isTrue);
      expect(read.row['file_name'], kEncryptedPlaceholder);
      await expectLater(
        WorkspaceStorageService.currentFileNameForUpdate({
          'id': 'file-B',
          'file_name': kEncryptedPlaceholder,
          'encrypted_meta': envelope,
        }),
        throwsStateError,
      );
    });

    test('a projects envelope on a project_files row with the same id is '
        'unreadable', () async {
      final envelope = await _envelope({
        'name': 'Alpha',
        'file_name': 'Alpha',
      }, row: 'same-id');
      final read = await _readFile(
        _fileRow(id: 'same-id', envelope: envelope),
      );
      expect(read.undecryptable, isTrue);
      expect(read.row['file_name'], kEncryptedPlaceholder);
    });

    test('a row without an id cannot prove its envelope', () async {
      final raw = Map.of(
        _projectRow(envelope: await _envelope({'name': 'Alpha'})),
      )..remove('id');
      final read = await _readProject(raw);
      expect(read.undecryptable, isTrue);
    });
  });

  group('re-seal claims', () {
    Future<ResealJob> legacyJob(String id) async =>
        WorkspaceStorageService.resealJobFromRead(
          await _readProject(_projectRow(id: id, name: 'Alpha')),
          isFile: false,
        )!;

    test('no key: nothing is claimed, the sweep takes the rows', () async {
      final attempted = <String>{};
      final claimed = WorkspaceStorageService.claimResealJobs(
        [await legacyJob('p1'), await legacyJob('p2')],
        attempted,
        hasKey: false,
      );
      expect(claimed, isEmpty);
      expect(attempted, isEmpty);
    });

    test('with a key: each row is claimed once per session', () async {
      final attempted = <String>{};
      final jobs = [await legacyJob('p1'), await legacyJob('p2')];
      final first = WorkspaceStorageService.claimResealJobs(
        jobs,
        attempted,
        hasKey: true,
      );
      expect(first.map((j) => j.id), ['p1', 'p2']);
      expect(attempted, {'project:p1', 'project:p2'});
      expect(
        WorkspaceStorageService.claimResealJobs(
          jobs,
          attempted,
          hasKey: true,
        ),
        isEmpty,
      );
    });

    test('a failure without a server verdict releases the claim', () async {
      final job = await legacyJob('p1');
      final attempted = {job.key};
      WorkspaceStorageService.releaseResealClaim(
        attempted,
        job,
        StateError('Encryption key is not available for the current user.'),
      );
      expect(attempted, isEmpty);
    });

    test('a server verdict keeps the claim', () async {
      final job = await legacyJob('p1');
      final attempted = {job.key};
      WorkspaceStorageService.releaseResealClaim(
        attempted,
        job,
        const PostgrestException(message: 'denied', code: '42501'),
      );
      expect(attempted, {job.key});
    });
  });

  group('merge over the fetched server row', () {
    // What `select('id, name, description, custom_system_prompt,
    // encrypted_meta')` returns for a clean sealed row.
    Future<Map<String, dynamic>> fetchedProject(
      Map<String, Object?> sealed, {
      Object? name = kEncryptedPlaceholder,
    }) async => {
      'id': 'proj-1',
      'name': name,
      'description': null,
      'custom_system_prompt': null,
      'encrypted_meta': await _envelope(sealed),
    };

    test('a rename keeps the prompt another device changed', () async {
      // This device loaded prompt 'A'; device B has since sealed 'B'.
      final merged = await WorkspaceStorageService.mergeProjectUpdate(
        await fetchedProject({
          'name': 'Alpha',
          'description': 'About',
          'custom_system_prompt': 'Prompt from device B',
        }),
        name: 'Renamed',
      );
      expect(merged.name, 'Renamed');
      expect(merged.description, 'About');
      expect(merged.customSystemPrompt, 'Prompt from device B');
    });

    test('old-build plaintext on the server is merged in', () async {
      final merged = await WorkspaceStorageService.mergeProjectUpdate(
        await fetchedProject({
          'name': 'Alpha',
          'custom_system_prompt': 'Prompt',
        }, name: 'Renamed in old build'),
        customSystemPrompt: 'New prompt',
      );
      expect(merged.name, 'Renamed in old build');
      expect(merged.customSystemPrompt, 'New prompt');
    });

    test('a legacy server row is merged from its plaintext', () async {
      final merged = await WorkspaceStorageService.mergeProjectUpdate(
        {
          'id': 'proj-1',
          'name': 'Alpha',
          'description': 'About',
          'custom_system_prompt': 'Prompt',
          'encrypted_meta': null,
        },
        description: '',
      );
      expect(merged.name, 'Alpha');
      expect(merged.description, isNull);
      expect(merged.customSystemPrompt, 'Prompt');
    });

    test('an unreadable server row is never merged', () async {
      await expectLater(
        WorkspaceStorageService.mergeProjectUpdate(
          {
            'id': 'proj-1',
            'name': kEncryptedPlaceholder,
            'encrypted_meta': _foreignEnvelope({'name': 'Alpha'}),
          },
          name: 'Renamed',
        ),
        throwsStateError,
      );
    });

    test('file name comes from the server row', () async {
      expect(
        await WorkspaceStorageService.currentFileNameForUpdate({
          'id': 'file-1',
          'file_name': kEncryptedPlaceholder,
          'encrypted_meta': await _fileEnvelope({'file_name': 'renamed.md'}),
        }),
        'renamed.md',
      );
      expect(
        await WorkspaceStorageService.currentFileNameForUpdate({
          'id': 'file-1',
          'file_name': 'legacy.md',
          'encrypted_meta': null,
        }),
        'legacy.md',
      );
    });

    test('an unreadable or nameless file row is never re-sealed', () async {
      await expectLater(
        WorkspaceStorageService.currentFileNameForUpdate({
          'id': 'file-1',
          'file_name': kEncryptedPlaceholder,
          'encrypted_meta': _foreignEnvelope({'file_name': 'a.md'}),
        }),
        throwsStateError,
      );
      await expectLater(
        WorkspaceStorageService.currentFileNameForUpdate({
          'id': 'file-1',
          'file_name': kEncryptedPlaceholder,
          'encrypted_meta': await _fileEnvelope({'markdown_summary': '# x'}),
        }),
        throwsStateError,
      );
    });
  });

  group('isMissingEncryptedMetaColumn', () {
    test('PostgREST schema cache miss', () {
      expect(
        WorkspaceStorageService.isMissingEncryptedMetaColumn(
          const PostgrestException(
            message:
                "Could not find the 'encrypted_meta' column of 'projects' "
                'in the schema cache',
            code: 'PGRST204',
          ),
        ),
        isTrue,
      );
    });

    test('Postgres undefined column in a filter', () {
      expect(
        WorkspaceStorageService.isMissingEncryptedMetaColumn(
          const PostgrestException(
            message: 'column projects.encrypted_meta does not exist',
            code: '42703',
          ),
        ),
        isTrue,
      );
    });

    test('other errors are not a missing column', () {
      expect(
        WorkspaceStorageService.isMissingEncryptedMetaColumn(
          const PostgrestException(
            message: "Could not find the 'avatar' column of 'projects'",
            code: 'PGRST204',
          ),
        ),
        isFalse,
      );
      expect(
        WorkspaceStorageService.isMissingEncryptedMetaColumn(
          const PostgrestException(
            message: 'new row violates row-level security policy',
            code: '42501',
          ),
        ),
        isFalse,
      );
    });
  });
}
