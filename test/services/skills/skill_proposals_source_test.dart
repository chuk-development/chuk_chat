import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/skills/skill_proposal.dart';
import 'package:chuk_chat/services/skills/skill_proposals_source.dart';

class _FakeControl implements AgentsSkillProposalControl {
  _FakeControl(this.answer);

  AgentsSkillProposalResult Function(String id) answer;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  @override
  Future<AgentsSkillProposalResult> sendSkillProposalDecision({
    required String proposalId,
    required bool accept,
    String? name,
    String? description,
    String? body,
  }) async {
    sent.add(<String, Object?>{
      'proposal_id': proposalId,
      'accept': accept,
      'name': name,
      'description': description,
      'body': body,
    });
    return answer(proposalId);
  }
}

AgentsRelaySkillProposal _proposal(
  String id, {
  String thread = 'thread-1',
  bool replay = false,
  String? status,
  String? savedName,
}) => AgentsRelaySkillProposal(
  proposalId: id,
  name: 'invoice-export',
  description: 'Export invoices.',
  body: '1. Export.',
  agentId: thread,
  sessionKey: thread,
  replay: replay,
  status: status,
  savedName: savedName,
);

void main() {
  final SkillProposalsSource source = SkillProposalsSource.instance;
  late int refreshes;

  setUp(() {
    source.reset();
    refreshes = 0;
    source.refreshSkillsOverride = () async {
      refreshes++;
      return true;
    };
  });

  tearDown(source.reset);

  test('a live proposal is pending in its own thread only', () {
    source.ingest(_proposal('sp_1'));
    expect(source.forThread('thread-1').single.isPending, isTrue);
    expect(source.forThread('thread-2'), isEmpty);
  });

  test('a replayed decided row draws its outcome; a full replay shows only '
      'the newest decided card', () {
    source.ingest(_proposal('sp_old', replay: true, status: 'dismissed'));
    source.ingest(
      _proposal(
        'sp_new',
        replay: true,
        status: 'saved',
        savedName: 'monthly-invoices',
      ),
    );
    final List<SkillProposalEntry> shown = source.forThread('thread-1');
    expect(shown, hasLength(1));
    expect(shown.single.proposalId, 'sp_new');
    expect(shown.single.state, SkillProposalState.saved);
    expect(shown.single.savedName, 'monthly-invoices');
  });

  test('a replay of a decided row closes a card still open; an older pending '
      'row never reopens a decided one', () {
    source.ingest(_proposal('sp_1'));
    source.ingest(_proposal('sp_1', replay: true, status: 'dismissed'));
    expect(source.byId('sp_1')!.state, SkillProposalState.dismissed);
    source.ingest(_proposal('sp_1', replay: true));
    expect(source.byId('sp_1')!.state, SkillProposalState.dismissed);
  });

  test(
    'the next task in the thread hides a decided card, not a pending one',
    () {
      source.ingest(_proposal('sp_done', replay: true, status: 'saved'));
      source.ingest(_proposal('sp_open'));
      // A newer card already pushed the decided one out of view.
      expect(source.forThread('thread-1').map((e) => e.proposalId), <String>[
        'sp_open',
      ]);
      source.ingest(_proposal('sp_open2'));
      source.ingest(
        const AgentsRelayTaskAck(
          taskId: 't1',
          status: 'accepted',
          sessionKey: 'thread-1',
        ),
      );
      expect(source.forThread('thread-1').map((e) => e.proposalId), <String>[
        'sp_open',
        'sp_open2',
      ]);
    },
  );

  test('saved decides the card and refreshes the skills list', () async {
    final control = _FakeControl(
      (id) => AgentsSkillProposalResult(
        proposalId: id,
        status: 'saved',
        name: 'monthly-invoices',
      ),
    );
    source.controlOverride = () => control;
    source.ingest(_proposal('sp_1'));

    final result = await source.decide(
      'sp_1',
      accept: true,
      name: 'monthly-invoices',
    );
    await Future<void>.delayed(Duration.zero);

    expect(result.isSaved, isTrue);
    expect(control.sent.single['name'], 'monthly-invoices');
    final SkillProposalEntry entry = source.forThread('thread-1').single;
    expect(entry.state, SkillProposalState.saved);
    expect(entry.savedName, 'monthly-invoices');
    expect(refreshes, 1);

    // The next task in the thread moves past it.
    source.ingest(
      const AgentsRelayTaskAck(
        taskId: 't2',
        status: 'accepted',
        sessionKey: 'thread-1',
      ),
    );
    expect(source.forThread('thread-1'), isEmpty);
  });

  test('invalid and not_found leave the card pending; no refresh', () async {
    final control = _FakeControl(
      (id) => AgentsSkillProposalResult(
        proposalId: id,
        status: 'invalid',
        errors: const <String>['body is empty'],
      ),
    );
    source.controlOverride = () => control;
    source.ingest(_proposal('sp_1'));

    final result = await source.decide('sp_1', accept: true, body: '');
    expect(result.isInvalid, isTrue);
    expect(source.byId('sp_1')!.isPending, isTrue);
    expect(refreshes, 0);
  });

  test('already decided elsewhere draws that decision', () async {
    source.controlOverride = () => _FakeControl(
      (id) => AgentsSkillProposalResult(
        proposalId: id,
        status: 'dismissed',
        alreadyDecided: true,
      ),
    );
    source.ingest(_proposal('sp_1'));
    await source.decide('sp_1', accept: true);
    expect(source.byId('sp_1')!.state, SkillProposalState.dismissed);
    expect(refreshes, 0);
  });

  test('no transport answers failed, not_connected', () async {
    source.controlOverride = () => null;
    source.ingest(_proposal('sp_1'));
    final result = await source.decide('sp_1', accept: true);
    expect(result.status, AgentsSkillProposalResult.statusFailed);
    expect(result.errors, <String>['not_connected']);
    expect(source.byId('sp_1')!.isPending, isTrue);
  });

  group('form rules (as tool/gen_skills.dart and the host)', () {
    test('name', () {
      expect(SkillDraftRules.validateName('weekly-report'), isNull);
      expect(SkillDraftRules.validateName('a1-b2-c3'), isNull);
      expect(SkillDraftRules.validateName(''), SkillDraftFieldError.nameEmpty);
      for (final String bad in <String>[
        'Weekly',
        'weekly--report',
        '-weekly',
        'weekly-',
        'weekly report',
        'weekly_report',
      ]) {
        expect(
          SkillDraftRules.validateName(bad),
          SkillDraftFieldError.nameInvalid,
          reason: bad,
        );
      }
      expect(
        SkillDraftRules.validateName('a' * 65),
        SkillDraftFieldError.nameTooLong,
      );
      expect(SkillDraftRules.validateName('a' * 64), isNull);
    });

    test('description and body', () {
      expect(SkillDraftRules.validateDescription('x' * 300), isNull);
      expect(
        SkillDraftRules.validateDescription('x' * 301),
        SkillDraftFieldError.descriptionTooLong,
      );
      expect(
        SkillDraftRules.validateDescription('one\ntwo'),
        SkillDraftFieldError.descriptionMultiline,
      );
      expect(
        SkillDraftRules.validateDescription(''),
        SkillDraftFieldError.descriptionEmpty,
      );
      expect(
        SkillDraftRules.validateBody('  \n '),
        SkillDraftFieldError.bodyEmpty,
      );
      expect(
        SkillDraftRules.validateBody(List<String>.filled(501, 'x').join('\n')),
        SkillDraftFieldError.bodyTooLong,
      );
      expect(SkillDraftRules.validateBody('1. Do it.'), isNull);
    });

    test('host errors land under their field', () {
      expect(
        skillDraftFieldForHostError("invalid name 'X': use lower-case"),
        SkillDraftField.name,
      );
      expect(
        skillDraftFieldForHostError(
          "a skill named 'x' already exists; pick another name",
        ),
        SkillDraftField.name,
      );
      expect(
        skillDraftFieldForHostError(
          'description is 301 characters, the limit is 300',
        ),
        SkillDraftField.description,
      );
      expect(
        skillDraftFieldForHostError('body is empty'),
        SkillDraftField.body,
      );
      expect(
        skillDraftFieldForHostError(
          'the workspace already holds 100 skills; delete one first',
        ),
        isNull,
      );
    });
  });
}
