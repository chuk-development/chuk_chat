// What did it do: run changes and undo (docs/WIRE_CONTRACT.md, bead
// chuk_chat-4qry). The wire shapes, the copy on the answer's run meta, and
// the service's round trips.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_run_changes.dart';
import 'package:chuk_chat/services/agents/agents_run_changes_service.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';

/// The `run_changes` example of the wire contract.
Map<String, dynamic> runChangesFrame({String runId = 'run-1'}) =>
    <String, dynamic>{
      'type': 'run_changes',
      'run_id': runId,
      'session_key': 'thread-1',
      'files': <Map<String, dynamic>>[
        <String, dynamic>{
          'path': 'notes/plan.md',
          'change': 'added',
          'additions': 12,
          'deletions': 0,
          'undoable': true,
        },
        <String, dynamic>{
          'path': 'report.csv',
          'change': 'modified',
          'additions': 3,
          'deletions': 1,
          'undoable': false,
          'conflict': <String, dynamic>{
            'path': 'report.csv',
            'reason': 'changed_later',
            'runs': <String>['run-2'],
          },
        },
        <String, dynamic>{
          'path': 'old.txt',
          'change': 'deleted',
          'additions': 0,
          'deletions': 9,
          'undoable': false,
          'undone': true,
        },
        <String, dynamic>{
          'path': 'logo.bin',
          'change': 'added',
          'undoable': true,
          'binary': true,
        },
      ],
      'files_total': 6,
      'commits': <Map<String, dynamic>>[
        <String, dynamic>{
          'commit': 'abc123',
          'short': 'abc1',
          'time': '2026-10-05T09:12:00Z',
          'subject': 'write_file: notes/plan.md',
          'seq': 17,
          'files': 1,
        },
      ],
      'commits_total': 4,
      'actions': 23,
      'summary': <String, dynamic>{
        'files': 3,
        'additions': 15,
        'deletions': 10,
        'undone': 1,
      },
      'undoable': true,
      'conflicts': <Map<String, dynamic>>[
        <String, dynamic>{
          'path': 'report.csv',
          'reason': 'changed_later',
          'runs': <String>['run-2'],
        },
      ],
    };

void main() {
  group('the changes block', () {
    test('parses files, counts and undone; caps undone at files', () {
      final s = AgentsRunChangesSummary.fromJson(<String, dynamic>{
        'files': 3,
        'additions': 42,
        'deletions': 7,
        'undone': 9,
      })!;
      expect(s.files, 3);
      expect(s.additions, 42);
      expect(s.deletions, 7);
      expect(s.undone, 3);
      expect(s.allUndone, isTrue);
    });

    test('no block, an empty block or junk draws nothing', () {
      expect(AgentsRunChangesSummary.fromJson(null), isNull);
      expect(AgentsRunChangesSummary.fromJson('3'), isNull);
      expect(
        AgentsRunChangesSummary.fromJson(<String, dynamic>{'files': 0}),
        isNull,
      );
      expect(
        AgentsRunChangesSummary.fromJson(<String, dynamic>{'files': true}),
        isNull,
      );
    });

    test('partly undone is neither none nor all', () {
      const s = AgentsRunChangesSummary(files: 3, undone: 1);
      expect(s.partlyUndone, isTrue);
      expect(s.allUndone, isFalse);
    });
  });

  group('the answer keeps the changes on its run meta', () {
    const changes = AgentsRunChangesSummary(
      files: 3,
      additions: 42,
      deletions: 7,
    );

    test('one call carries cost, run id and changes, and survives the cache '
        'round trip', () {
      final meta = runMetaCall(runId: 'run-1', changes: changes)!;
      final back = ToolCall.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );
      final split = splitRunMeta(<ToolCall>[back], null);
      expect(split.toolCalls, isEmpty);
      expect(split.runId, 'run-1');
      expect(split.changes, changes);
      expect(split.cost, isNull);
    });

    test('changes alone still make a meta call', () {
      expect(runMetaCall(changes: changes), isNotNull);
      expect(runMetaCall(), isNull);
    });

    test(
      'the ledger keeps the changes across a second finish without them',
      () {
        final ledger = AgentsRunLedger.instance;
        ledger.reset();
        addTearDown(ledger.reset);
        ledger.begin('thread-1');
        ledger.finish(
          'thread-1',
          reason: 'finished',
          runId: 'run-1',
          changes: changes,
        );
        ledger.finish('thread-1', reason: 'finished', runId: 'run-1');
        final run = ledger.take('thread-1')!;
        expect(
          run.toolCalls.where((c) => c.name == kAgentsRunMetaTool),
          hasLength(1),
        );
        expect(splitRunMeta(run.toolCalls, null).changes, changes);
      },
    );
  });

  group('run_changes', () {
    test('parses rows, conflicts, commits and the caps', () {
      final r = AgentsRunChangesReport.fromPayload(runChangesFrame())!;
      expect(r.runId, 'run-1');
      expect(r.sessionKey, 'thread-1');
      expect(r.files.map((f) => f.change), <AgentsRunFileChange>[
        AgentsRunFileChange.added,
        AgentsRunFileChange.modified,
        AgentsRunFileChange.deleted,
        AgentsRunFileChange.added,
      ]);
      expect(r.files[0].undoable, isTrue);
      expect(
        r.files[1].conflict!.reason,
        AgentsRunConflictReason.changedLaterByRun,
      );
      expect(r.files[1].conflict!.runs, <String>['run-2']);
      expect(r.files[2].undone, isTrue);
      expect(r.files[3].binary, isTrue);
      expect(r.hiddenFiles, 2);
      expect(r.commits.single.subject, 'write_file: notes/plan.md');
      expect(r.commits.single.time, isNotNull);
      expect(r.commitsTotal, 4);
      expect(r.summary!.undone, 1);
      expect(r.undoable, isTrue);
      expect(r.conflicts.single.path, 'report.csv');
    });

    test('conflict reasons: your edit, unsaved edit, a later run', () {
      AgentsRunConflictReason reason(Map<String, dynamic> raw) =>
          AgentsRunConflict.fromJson(raw, path: 'a')!.reason;
      expect(
        reason(<String, dynamic>{'reason': 'changed_later', 'outside': true}),
        AgentsRunConflictReason.changedOutside,
      );
      expect(
        reason(<String, dynamic>{'reason': 'uncommitted'}),
        AgentsRunConflictReason.uncommitted,
      );
      expect(
        reason(<String, dynamic>{
          'reason': 'changed_later',
          'runs': <String>['r'],
        }),
        AgentsRunConflictReason.changedLaterByRun,
      );
    });

    test('run_active keeps the list', () {
      final r = AgentsRunChangesReport.fromPayload(<String, dynamic>{
        ...runChangesFrame(),
        'undoable': false,
        'reason': 'run_active',
      })!;
      expect(r.runActive, isTrue);
      expect(r.files, hasLength(4));
    });
  });

  group('run_undo_result', () {
    test('ok with the updated block and the note', () {
      final r = AgentsRunUndoResult.fromPayload(<String, dynamic>{
        'type': 'run_undo_result',
        'run_id': 'run-1',
        'session_key': 'thread-1',
        'ok': true,
        'reverted': <String>['notes/plan.md'],
        'conflicts': <Object>[],
        'changes': <String, dynamic>{'files': 3, 'undone': 2},
        'note': 'Files in the workspace are restored.',
      })!;
      expect(r.ok, isTrue);
      expect(r.reverted, <String>['notes/plan.md']);
      expect(r.changes!.undone, 2);
      expect(r.note, startsWith('Files'));
    });

    test('conflicts and run_active refuse', () {
      final c = AgentsRunUndoResult.fromPayload(<String, dynamic>{
        'run_id': 'run-1',
        'ok': false,
        'code': 'conflicts',
        'conflicts': <Map<String, dynamic>>[
          <String, dynamic>{'path': 'report.csv', 'reason': 'uncommitted'},
        ],
      })!;
      expect(c.isConflicts, isTrue);
      expect(c.conflicts.single.reason, AgentsRunConflictReason.uncommitted);
      final a = AgentsRunUndoResult.fromPayload(<String, dynamic>{
        'run_id': 'run-1',
        'ok': false,
        'code': 'run_active',
      })!;
      expect(a.isRunActive, isTrue);
    });
  });

  group('the service', () {
    late List<Map<String, dynamic>> sent;
    late List<String> undoneThreads;
    late AgentsRunChangesService service;

    setUp(() {
      sent = <Map<String, dynamic>>[];
      undoneThreads = <String>[];
      service = AgentsRunChangesService(
        send: (payload) async => sent.add(payload),
        onUndone: undoneThreads.add,
        timeout: const Duration(milliseconds: 200),
      );
    });

    test('fetch sends run_changes_get and settles on the answer', () async {
      final future = service.fetch('run-1');
      // A second ask for the same run shares the first one.
      final again = service.fetch('run-1');
      await Future<void>.delayed(Duration.zero);
      expect(sent.single, <String, dynamic>{
        'type': 'run_changes_get',
        'run_id': 'run-1',
      });
      service.handleFrame(runChangesFrame());
      final report = await future;
      expect(identical(report, await again), isTrue);
      expect(report.files, hasLength(4));
      // The summary is the line's newest block.
      expect(service.summaryOf('run-1')!.undone, 1);
    });

    test('undo sends the paths and force only as true', () async {
      final plain = service.undo('run-1', paths: <String>['a.txt']);
      await Future<void>.delayed(Duration.zero);
      expect(sent.last, <String, dynamic>{
        'type': 'run_undo',
        'run_id': 'run-1',
        'paths': <String>['a.txt'],
      });
      service.handleFrame(<String, dynamic>{
        'type': 'run_undo_result',
        'run_id': 'run-1',
        'session_key': 'thread-1',
        'ok': true,
        'reverted': <String>['a.txt'],
        'changes': <String, dynamic>{'files': 2, 'undone': 1},
      });
      final ok = await plain;
      expect(ok.ok, isTrue);
      expect(service.summaryOf('run-1')!.undone, 1);
      // A full replay will bring the host's updated copy of the answer.
      expect(undoneThreads, <String>['thread-1']);

      final forced = service.undo('run-1', force: true);
      await Future<void>.delayed(Duration.zero);
      expect(sent.last['force'], isTrue);
      expect(sent.last.containsKey('paths'), isFalse);
      service.handleFrame(<String, dynamic>{
        'type': 'run_undo_result',
        'run_id': 'run-1',
        'ok': false,
        'code': 'run_active',
      });
      expect((await forced).isRunActive, isTrue);
      expect(undoneThreads, hasLength(1));
    });

    test('no answer and no connection end the wait', () async {
      final late = await service.fetch('run-9');
      expect(late.failure, 'no_answer');

      final offline = AgentsRunChangesService(
        send: (_) async => throw StateError('offline'),
      );
      expect((await offline.undo('run-1')).code, 'not_sent');
      expect((await offline.fetch('run-1')).failure, 'not_sent');
    });

    test('the undo note shows once', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await service.claimUndoNote(), isTrue);
      expect(await service.claimUndoNote(), isFalse);
      // A new app session reads the stored flag.
      final next = AgentsRunChangesService(send: (_) async {});
      expect(await next.claimUndoNote(), isFalse);
    });
  });
}
