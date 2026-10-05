import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/skills/skill_proposal.dart';

import 'agents_relay_client_test.dart' show FakeExecutorHost, FakeRelaySocket;

/// Skill proposals over the real sealed channel (docs/WIRE_CONTRACT.md,
/// "Skill proposals"; bead chuk_chat-al2u): a `skill_proposal` from the run
/// stream or a replay surfaces as [AgentsRelaySkillProposal]; a decision is a
/// request that ends on `skill_proposal_result`.
void main() {
  var ts = 1700000000000;
  int clock() => ts;

  Future<(AgentsRelayClient, FakeExecutorHost, FakeRelaySocket)>
  paired() async {
    final socket = FakeRelaySocket();
    final host = FakeExecutorHost(
      socket: socket,
      deviceId: 'host-laptop-1',
      channelId: 'chan1234',
      digits: '428913',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      nowMs: clock,
    );
    await host.start();
    final client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      connector: (_) async => socket,
      nowMs: clock,
    );
    await client.connect(
      hostUrl: Uri.parse('ws://127.0.0.1:8787'),
      pairingCode: 'chan1234-428913',
    );
    await host.paired.future;
    ts += 1;
    return (client, host, socket);
  }

  tearDown(() {
    AgentsRelayClient.skillProposalDecisionTimeout = const Duration(
      seconds: 30,
    );
  });

  test('a live skill_proposal surfaces pending, keyed to its thread', () async {
    final (client, host, _) = await paired();
    final events = <AgentsRelayInbound>[];
    final sub = client.inbound.listen(events.add);

    await host.emit(<String, dynamic>{
      'type': 'skill_proposal',
      'proposal_id': 'sp_0123456789abcdef',
      'agent_id': 'thread-1',
      'name': 'invoice-export',
      'description': 'Export the month of invoices as one CSV.',
      'body': '# Invoice export\n\n1. Open the portal.\n2. Export.',
    });
    // A frame that names no proposal is dropped, never surfaced.
    await host.emit(<String, dynamic>{'type': 'skill_proposal', 'name': 'x'});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final proposal = events.whereType<AgentsRelaySkillProposal>().single;
    expect(proposal.proposalId, 'sp_0123456789abcdef');
    expect(proposal.name, 'invoice-export');
    expect(proposal.description, startsWith('Export the month'));
    expect(proposal.body, contains('1. Open the portal.'));
    expect(proposal.sessionKey, 'thread-1');
    expect(proposal.replay, isFalse);
    expect(proposal.isDecided, isFalse);

    await sub.cancel();
    await client.dispose();
  });

  test(
    'replayed rows carry replay, mid and the outcome once decided',
    () async {
      final (client, host, _) = await paired();
      final events = <AgentsRelayInbound>[];
      final sub = client.inbound.listen(events.add);

      await host.emit(<String, dynamic>{
        'type': 'skill_proposal',
        'proposal_id': 'sp_saved',
        'agent_id': 'thread-1',
        'name': 'invoice-export',
        'description': 'd',
        'body': 'b',
        'replay': true,
        'mid': 41,
        'status': 'saved',
        'decided_at': 1759700000.5,
        'saved_name': 'monthly-invoices',
      });
      await host.emit(<String, dynamic>{
        'type': 'skill_proposal',
        'proposal_id': 'sp_dismissed',
        'agent_id': 'thread-1',
        'session_key': 'thread-2',
        'name': 'n',
        'description': 'd',
        'body': 'b',
        'replay': true,
        'mid': 42,
        'status': 'dismissed',
        'decided_at': 1759700001,
        'saved_name': null,
      });
      await host.emit(<String, dynamic>{
        'type': 'skill_proposal',
        'proposal_id': 'sp_open',
        'agent_id': 'thread-1',
        'name': 'n',
        'description': 'd',
        'body': 'b',
        'replay': true,
        'mid': 43,
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final rows = events.whereType<AgentsRelaySkillProposal>().toList();
      expect(rows, hasLength(3));

      expect(rows[0].replay, isTrue);
      expect(rows[0].mid, 41);
      expect(rows[0].isSaved, isTrue);
      expect(rows[0].savedName, 'monthly-invoices');
      expect(
        rows[0].decidedAt,
        DateTime.fromMillisecondsSinceEpoch(1759700000500, isUtc: true),
      );

      expect(rows[1].status, AgentsRelaySkillProposal.statusDismissed);
      expect(rows[1].savedName, isNull);
      // `session_key` wins over `agent_id` when the host names both.
      expect(rows[1].sessionKey, 'thread-2');

      expect(rows[2].isDecided, isFalse);
      expect(rows[2].mid, 43);

      await sub.cancel();
      await client.dispose();
    },
  );

  test('a decision seals skill_proposal_decision and completes on the '
      'matching skill_proposal_result', () async {
    final (client, host, _) = await paired();

    final Future<AgentsSkillProposalResult> pending = client
        .sendSkillProposalDecision(
          proposalId: 'sp_1',
          accept: true,
          name: 'monthly-invoices',
        );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final decision = host.received.singleWhere(
      (m) => m['type'] == 'skill_proposal_decision',
    );
    expect(decision['proposal_id'], 'sp_1');
    expect(decision['accept'], true);
    expect(decision['name'], 'monthly-invoices');
    // An absent edit keeps the draft's value: the key is not on the frame.
    expect(decision.containsKey('description'), isFalse);
    expect(decision.containsKey('body'), isFalse);

    // An answer for another proposal does not end this one.
    await host.emit(<String, dynamic>{
      'type': 'skill_proposal_result',
      'proposal_id': 'sp_other',
      'status': 'dismissed',
    });
    await host.emit(<String, dynamic>{
      'type': 'skill_proposal_result',
      'proposal_id': 'sp_1',
      'status': 'saved',
      'name': 'monthly-invoices',
      'errors': <String>[],
      'path': '/ws/skills/monthly-invoices/SKILL.md',
      'scrubbed': true,
    });

    final result = await pending;
    expect(result.isSaved, isTrue);
    expect(result.name, 'monthly-invoices');
    expect(result.path, '/ws/skills/monthly-invoices/SKILL.md');
    expect(result.scrubbed, isTrue);
    expect(result.alreadyDecided, isFalse);

    await client.dispose();
  });

  test('invalid carries the host errors; dismiss sends accept false', () async {
    final (client, host, _) = await paired();

    final pending = client.sendSkillProposalDecision(
      proposalId: 'sp_2',
      accept: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final decision = host.received.singleWhere(
      (m) => m['type'] == 'skill_proposal_decision',
    );
    expect(decision['accept'], false);
    expect(decision.containsKey('name'), isFalse);

    await host.emit(<String, dynamic>{
      'type': 'skill_proposal_result',
      'proposal_id': 'sp_2',
      'status': 'invalid',
      'name': 'x',
      'errors': <Object?>[
        "a skill named 'x' already exists; pick another name",
        7,
      ],
    });
    final result = await pending;
    expect(result.isInvalid, isTrue);
    expect(result.errors, <String>[
      "a skill named 'x' already exists; pick another name",
    ]);
    await client.dispose();
  });

  test('no answer in time completes as failed, not as a hang', () async {
    AgentsRelayClient.skillProposalDecisionTimeout = const Duration(
      milliseconds: 50,
    );
    final (client, _, _) = await paired();
    final result = await client.sendSkillProposalDecision(
      proposalId: 'sp_3',
      accept: true,
    );
    expect(result.status, AgentsSkillProposalResult.statusFailed);
    expect(result.errors, <String>['no_answer']);
    await client.dispose();
  });

  test('a client that is not paired answers failed at once', () async {
    final client = AgentsRelayClient(
      deviceId: 'app-desktop-1',
      signingKeyPair: await AgentsDeviceKeys.generate(),
      connector: (_) async => FakeRelaySocket(),
      nowMs: clock,
    );
    final result = await client.sendSkillProposalDecision(
      proposalId: 'sp_4',
      accept: true,
    );
    expect(result.status, AgentsSkillProposalResult.statusFailed);
    expect(result.errors, <String>['not_sent']);
    await client.dispose();
  });
}
