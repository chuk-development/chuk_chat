import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_checkpoints.dart';
import 'package:chuk_chat/services/agents/agents_reply_frames.dart';

/// Plays the host: every frame sent is recorded, and [answer] gives the
/// reply (or null for silence).
class _Host {
  _Host(this.answer);

  final Map<String, dynamic>? Function(Map<String, dynamic> frame) answer;
  final AgentsReplyFrames bus = AgentsReplyFrames();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  Future<void> send(Map<String, dynamic> frame) async {
    sent.add(frame);
    final Map<String, dynamic>? reply = answer(frame);
    if (reply != null) Future<void>.microtask(() => bus.add(reply));
  }

  AgentsCheckpoints service({Duration? timeout}) => AgentsCheckpoints(
    send: send,
    replies: bus,
    timeout: timeout ?? const Duration(seconds: 2),
  );
}

void main() {
  group('list', () {
    test('sends checkpoints_list and reads the items newest first', () async {
      final _Host host = _Host(
        (Map<String, dynamic> f) => <String, dynamic>{
          'type': 'checkpoints',
          'session_key': f['session_key'],
          'ok': true,
          'items': <Object?>[
            <String, dynamic>{
              'id': 'aaaa000000000001',
              'commit': 'c1',
              'created_at': 1762300000.1,
              'run_id': 'r1',
              'user_mid': 800,
              'prompt': 'older',
            },
            <String, dynamic>{
              'id': 'aaaa000000000002',
              'created_at': 1762300500.0,
              'user_mid': 812,
              'prompt': 'newer',
            },
            'junk',
            <String, dynamic>{'id': ''},
          ],
        },
      );
      final AgentsCheckpointList list = await host.service().list('t1');
      expect(host.sent.single, <String, dynamic>{
        'type': 'checkpoints_list',
        'session_key': 't1',
      });
      expect(list.ok, isTrue);
      expect(list.items.map((AgentsCheckpoint c) => c.prompt), <String>[
        'newer',
        'older',
      ]);
      expect(list.items.last.userMid, 800);
      expect(list.items.last.runId, 'r1');
      expect(list.items.last.createdAt?.millisecondsSinceEpoch, 1762300000100);
    });

    test('a reply for another thread is not taken', () async {
      final _Host host = _Host(
        (Map<String, dynamic> f) => <String, dynamic>{
          'type': 'checkpoints',
          'session_key': 'other',
          'ok': true,
          'items': const <Object?>[],
        },
      );
      final AgentsCheckpointList list = await host
          .service(timeout: const Duration(milliseconds: 50))
          .list('t1');
      expect(list.error, AgentsCheckpoints.errTimeout);
    });

    test('no link gives not_connected', () async {
      final AgentsCheckpoints service = AgentsCheckpoints(
        send: (_) async => throw const AgentsNotConnected(),
        replies: AgentsReplyFrames(),
      );
      expect(
        (await service.list('t1')).error,
        AgentsCheckpoints.errNotConnected,
      );
    });
  });

  group('rewind', () {
    test('safe refusal carries the conflicts', () async {
      final _Host host = _Host(
        (Map<String, dynamic> f) => <String, dynamic>{
          'type': 'checkpoint_rewound',
          'session_key': 't1',
          'checkpoint_id': f['checkpoint_id'],
          'mode': 'safe',
          'ok': false,
          'error': 'files changed outside the agent since this checkpoint',
          'conflicts': <String>['notes.md'],
          'restorable': 3,
        },
      );
      final AgentsRewindResult r = await host.service().rewind('t1', 'cp1');
      expect(host.sent.single['mode'], 'safe');
      expect(host.sent.single['checkpoint_id'], 'cp1');
      expect(r.hasConflicts, isTrue);
      expect(r.conflicts, <String>['notes.md']);
      expect(r.restorable, 3);
      expect(r.isBusy, isFalse);
    });

    test('every mode goes out as given and the lists are read', () async {
      for (final String mode in AgentsRewindMode.all) {
        final _Host host = _Host(
          (Map<String, dynamic> f) => <String, dynamic>{
            'type': 'checkpoint_rewound',
            'session_key': 't1',
            'checkpoint_id': 'cp1',
            'mode': f['mode'],
            'ok': true,
            'restored': <String>['a.py'],
            'merged': <String>['b.md'],
            'kept': <String>['c.txt'],
            'refused': <String>['link/d.txt'],
            'commit': 'abc',
            'note': 'Files are restored.',
          },
        );
        final AgentsRewindResult r = await host.service().rewind(
          't1',
          'cp1',
          mode: mode,
        );
        expect(host.sent.single['mode'], mode);
        expect(r.ok, isTrue);
        expect(r.mode, mode);
        expect(r.restored, <String>['a.py']);
        expect(r.merged, <String>['b.md']);
        expect(r.kept, <String>['c.txt']);
        expect(r.refused, <String>['link/d.txt']);
      }
    });

    test('busy is read as busy', () async {
      final _Host host = _Host(
        (_) => <String, dynamic>{
          'type': 'checkpoint_rewound',
          'session_key': 't1',
          'checkpoint_id': 'cp1',
          'ok': false,
          'error': 'busy: a task of this agent is running',
        },
      );
      final AgentsRewindResult r = await host.service().rewind('t1', 'cp1');
      expect(r.isBusy, isTrue);
      expect(r.hasConflicts, isFalse);
    });

    test('an unknown mode is refused before anything is sent', () {
      final _Host host = _Host((_) => null);
      expect(
        () => host.service().rewind('t1', 'cp1', mode: 'yolo'),
        throwsArgumentError,
      );
      expect(host.sent, isEmpty);
    });
  });

  group('fork', () {
    test('sends thread_fork and reads the new thread', () async {
      final _Host host = _Host(
        (Map<String, dynamic> f) => <String, dynamic>{
          'type': 'thread_forked',
          'session_key': 't1',
          'ok': true,
          'new_session_key': 't1:fork:0a1b2c3d',
          'mid': f['mid'],
          'copied': 14,
        },
      );
      final AgentsForkResult r = await host.service().fork('t1', 815);
      expect(host.sent.single, <String, dynamic>{
        'type': 'thread_fork',
        'session_key': 't1',
        'mid': 815,
      });
      expect(r.ok, isTrue);
      expect(r.newSessionKey, 't1:fork:0a1b2c3d');
      expect(r.copied, 14);
      expect(r.checkpointId, isNull);
      expect(r.needsWorkspaceChoice, isFalse);
    });

    test('a workspace conflict asks for a choice', () async {
      final _Host host = _Host(
        (_) => <String, dynamic>{
          'type': 'thread_forked',
          'session_key': 't1',
          'ok': true,
          'new_session_key': 'n1',
          'mid': 815,
          'copied': 3,
          'checkpoint_id': 'cp9',
          'workspace': <String, dynamic>{
            'ok': false,
            'error': 'files changed outside the agent since this checkpoint',
            'conflicts': <String>['x.md'],
          },
        },
      );
      final AgentsForkResult r = await host.service().fork(
        't1',
        815,
        mode: AgentsRewindMode.merge,
      );
      expect(host.sent.single['mode'], 'merge');
      expect(r.needsWorkspaceChoice, isTrue);
      expect(r.workspace?.conflicts, <String>['x.md']);
      expect(r.checkpointId, 'cp9');
    });

    test('an error reply is a failure', () async {
      final _Host host = _Host(
        (_) => <String, dynamic>{
          'type': 'thread_forked',
          'session_key': 't1',
          'ok': false,
          'error': 'the message is not in this thread',
        },
      );
      final AgentsForkResult r = await host.service().fork('t1', 1);
      expect(r.ok, isFalse);
      expect(r.error, 'the message is not in this thread');
    });
  });
}
