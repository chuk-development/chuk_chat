import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/skills/skill_proposal.dart';
import 'package:chuk_chat/services/skills/skill_proposals_source.dart';
import 'package:chuk_chat/widgets/agents_skill_proposal_card.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';

import '../support/fake_relay_controller.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

const AgentsRelaySkillProposal _draft = AgentsRelaySkillProposal(
  proposalId: 'sp_1',
  name: 'invoice-export',
  description: 'Export the month of invoices as one CSV.',
  body: '# Invoice export\n\n1. Open the portal.\n2. Export the month.',
  agentId: 'thread-1',
  sessionKey: 'thread-1',
);

SkillProposalEntry _entry({
  SkillProposalState state = SkillProposalState.pending,
  String? savedName,
}) => SkillProposalEntry(
  proposal: _draft,
  threadKey: 'thread-1',
  state: state,
  savedName: savedName,
);

/// Records every answer and replies with [reply].
class _Decisions {
  _Decisions([this.reply]);

  AgentsSkillProposalResult Function()? reply;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  Future<AgentsSkillProposalResult> decide({
    required bool accept,
    String? name,
    String? description,
    String? body,
  }) async {
    sent.add(<String, Object?>{
      'accept': accept,
      'name': name,
      'description': description,
      'body': body,
    });
    return reply?.call() ??
        AgentsSkillProposalResult(
          proposalId: 'sp_1',
          status: accept ? 'saved' : 'dismissed',
        );
  }
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

/// The card can be taller than the test window: scroll the target in first.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

/// The localizations load on the first frame; settle before looking.
Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  group('the card', () {
    testWidgets('pending: title, name, description; steps behind a toggle, '
        'rendered as Markdown', (tester) async {
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(
            entry: _entry(),
            onDecide: _Decisions().decide,
          ),
        ),
      );
      expect(find.text('Save as skill?'), findsOneWidget);
      expect(find.text('invoice-export'), findsOneWidget);
      expect(
        find.text('Export the month of invoices as one CSV.'),
        findsOneWidget,
      );
      expect(_key('agents-skill-proposal-steps'), findsNothing);
      expect(find.text('Save skill'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);

      await _tap(tester, find.text('Show steps'));
      await tester.pumpAndSettle();
      expect(_key('agents-skill-proposal-steps'), findsOneWidget);
      // Markdown, not the raw text: the heading mark is gone.
      expect(find.textContaining('# Invoice export'), findsNothing);
      expect(find.textContaining('Open the portal.'), findsWidgets);
      expect(find.text('Hide steps'), findsOneWidget);
    });

    testWidgets('Save skill sends accept true with no edits', (tester) async {
      final decisions = _Decisions();
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(entry: _entry(), onDecide: decisions.decide),
        ),
      );
      await _tap(tester, find.text('Save skill'));
      await tester.pumpAndSettle();
      expect(decisions.sent, <Map<String, Object?>>[
        <String, Object?>{
          'accept': true,
          'name': null,
          'description': null,
          'body': null,
        },
      ]);
    });

    testWidgets('Dismiss sends accept false', (tester) async {
      final decisions = _Decisions();
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(entry: _entry(), onDecide: decisions.decide),
        ),
      );
      await _tap(tester, find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(decisions.sent.single['accept'], false);
    });

    testWidgets('saved: one line with the name, no buttons', (tester) async {
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(
            entry: _entry(
              state: SkillProposalState.saved,
              savedName: 'monthly-invoices',
            ),
            onDecide: _Decisions().decide,
          ),
        ),
      );
      expect(_key('agents-skill-proposal-saved'), findsOneWidget);
      expect(
        find.text('Saved as skill monthly-invoices', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Save skill'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Dismiss'), findsNothing);
    });

    testWidgets('dismissed: collapses to "Not saved"', (tester) async {
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(
            entry: _entry(state: SkillProposalState.dismissed),
            onDecide: _Decisions().decide,
          ),
        ),
      );
      expect(find.text('Not saved'), findsOneWidget);
      expect(find.text('invoice-export'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Edit validates before it sends: name rule, n/300, one line, '
        'body not empty', (tester) async {
      final decisions = _Decisions();
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(entry: _entry(), onDecide: decisions.decide),
        ),
      );
      await _tap(tester, find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(3));
      expect(_key('agents-skill-proposal-description-count'), findsOneWidget);
      expect(find.text('40/300'), findsOneWidget);

      await tester.enterText(
        _key('agents-skill-proposal-field-name'),
        'Invoice Export',
      );
      await tester.enterText(
        _key('agents-skill-proposal-field-description'),
        'x' * 301,
      );
      await tester.enterText(_key('agents-skill-proposal-field-body'), '  ');
      await tester.pump();
      expect(find.text('301/300'), findsOneWidget);

      await _tap(tester, find.text('Save skill'));
      await tester.pumpAndSettle();
      expect(decisions.sent, isEmpty);
      expect(_key('agents-skill-proposal-name-error'), findsOneWidget);
      expect(
        find.textContaining('lower-case letters and digits joined'),
        findsOneWidget,
      );
      expect(
        find.text('The description has more than 300 characters.'),
        findsOneWidget,
      );
      expect(find.text('The steps are empty.'), findsOneWidget);

      // A newline typed into the description is refused by the field.
      await tester.enterText(
        _key('agents-skill-proposal-field-description'),
        'one\nline',
      );
      await tester.pump();
      expect(find.text('oneline'), findsOneWidget);
    });

    testWidgets('Edit sends only what changed', (tester) async {
      final decisions = _Decisions(
        () => const AgentsSkillProposalResult(
          proposalId: 'sp_1',
          status: 'saved',
          name: 'monthly-invoices',
        ),
      );
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(entry: _entry(), onDecide: decisions.decide),
        ),
      );
      await _tap(tester, find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        _key('agents-skill-proposal-field-name'),
        'monthly-invoices',
      );
      await _tap(tester, find.text('Save skill'));
      await tester.pumpAndSettle();
      expect(decisions.sent.single, <String, Object?>{
        'accept': true,
        'name': 'monthly-invoices',
        'description': null,
        'body': null,
      });
      // The source decides the card; the form closes on a decided reply.
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('invalid: the host errors show under their fields, and a plain '
        'Save opens the form', (tester) async {
      final decisions = _Decisions(
        () => const AgentsSkillProposalResult(
          proposalId: 'sp_1',
          status: 'invalid',
          errors: <String>[
            "a skill named 'invoice-export' already exists; pick another name",
            'the workspace already holds 100 skills; delete one first',
          ],
        ),
      );
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(entry: _entry(), onDecide: decisions.decide),
        ),
      );
      await _tap(tester, find.text('Save skill'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNWidgets(3));
      final Text nameError = tester.widget<Text>(
        _key('agents-skill-proposal-name-error'),
      );
      expect(nameError.data, contains('already exists'));
      expect(
        tester.widget<Text>(_key('agents-skill-proposal-error')).data,
        contains('100 skills'),
      );
      // Still answerable.
      expect(find.text('Save skill'), findsOneWidget);
    });

    testWidgets('no answer: a line says so and the buttons stay', (
      tester,
    ) async {
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(
            entry: _entry(),
            onDecide: _Decisions(
              () => AgentsSkillProposalResult.failed('sp_1', 'no_answer'),
            ).decide,
          ),
        ),
      );
      await _tap(tester, find.text('Save skill'));
      await tester.pumpAndSettle();
      expect(
        find.text('Your computer did not answer. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Save skill'), findsOneWidget);
    });

    testWidgets('German', (tester) async {
      await _pump(
        tester,
        _app(
          AgentsSkillProposalCard(
            entry: _entry(),
            onDecide: _Decisions().decide,
          ),
          locale: const Locale('de'),
        ),
      );
      expect(find.text('Als Skill speichern?'), findsOneWidget);
      expect(find.text('Skill speichern'), findsOneWidget);
      expect(find.text('Bearbeiten'), findsOneWidget);
      expect(find.text('Verwerfen'), findsOneWidget);
      expect(find.text('Schritte anzeigen'), findsOneWidget);
    });

    testWidgets('fits 360 px at 1.3 text scale, open and editing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(
        tester,
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 1400),
            textScaler: TextScaler.linear(1.3),
          ),
          child: _app(
            Padding(
              padding: const EdgeInsets.all(16),
              child: AgentsSkillProposalCard(
                entry: _entry(),
                onDecide: _Decisions().decide,
              ),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('Show steps'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Edit'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('in the thread', () {
    final SkillProposalsSource source = SkillProposalsSource.instance;

    setUp(() async {
      debugAgentsChatCoreOverride = true;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await VerboseService.instance.setEnabled(false);
      AgentsRelayLink.instance.reset();
      AgentsRunLedger.instance.reset();
      AgentsReplayLoader.instance.reset();
      source.reset();
      source.refreshSkillsOverride = () async => true;
      await ChatStorageService.reset();
    });

    tearDown(() async {
      debugAgentsChatCoreOverride = null;
      AgentsRelayLink.instance.reset();
      AgentsRunLedger.instance.reset();
      AgentsReplayLoader.instance.reset();
      source.reset();
      await ChatStorageService.reset();
    });

    Future<_SkillFakeController> pumpPaired(
      WidgetTester tester, {
      bool phone = false,
    }) async {
      final Size size = phone ? const Size(390, 844) : const Size(1400, 900);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _SkillFakeController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const <LocalizationsDelegate<Object>>[
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AgentsThreadView(
              controllerBuilder: () async => controller,
              sessionSource: const _FakeSessionSource(),
              threadKey: 'thread-1',
              title: 'Ada',
              phoneLayout: phone,
              fileSaver: _NoopSaver(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.set(
        const AgentsRelayState(
          phase: AgentsRelayPhase.paired,
          peerDeviceId: 'cowork-host',
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    for (final bool phone in <bool>[false, true]) {
      final String layout = phone ? 'phone' : 'desktop';

      testWidgets('$layout: a live proposal sits in the transcript; Save sends '
          'the decision and the card says it was saved', (tester) async {
        final controller = await pumpPaired(tester, phone: phone);
        controller.emit(_draft);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final Finder card = _key('agents-skill-proposal-sp_1');
        expect(card, findsOneWidget);
        expect(
          find.ancestor(of: card, matching: find.byType(CustomScrollView)),
          findsOneWidget,
        );

        await tester.tap(find.text('Save skill'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.decisions.single.$1, 'sp_1');
        expect(controller.decisions.single.$2, isTrue);
        expect(
          find.text('Saved as skill invoice-export', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('Save skill'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(minutes: 2));
      });
    }

    testWidgets('a replayed decided row draws the decided state', (
      tester,
    ) async {
      final controller = await pumpPaired(tester);
      controller.emit(
        const AgentsRelaySkillProposal(
          proposalId: 'sp_9',
          name: 'invoice-export',
          description: 'd',
          body: 'b',
          sessionKey: 'thread-1',
          replay: true,
          mid: 12,
          status: 'dismissed',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Not saved'), findsOneWidget);
      expect(find.text('Save skill'), findsNothing);
      expect(controller.decisions, isEmpty);

      // Another thread's proposal does not show here.
      controller.emit(
        const AgentsRelaySkillProposal(
          proposalId: 'sp_10',
          name: 'other',
          description: 'd',
          body: 'b',
          sessionKey: 'thread-2',
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(_key('agents-skill-proposal-sp_10'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    });
  });
}

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
}

class _FakeSessionSource implements AccountSessionSource {
  const _FakeSessionSource();

  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    userId: 'user-1',
  );

  @override
  Future<AccountSession?> refresh() async => current();
}

/// The fake transport, plus the decision a real relay client sends.
class _SkillFakeController extends FakeRelayController
    implements AgentsSkillProposalControl {
  final List<(String, bool)> decisions = <(String, bool)>[];

  @override
  Future<AgentsSkillProposalResult> sendSkillProposalDecision({
    required String proposalId,
    required bool accept,
    String? name,
    String? description,
    String? body,
  }) async {
    decisions.add((proposalId, accept));
    return AgentsSkillProposalResult(
      proposalId: proposalId,
      status: accept ? 'saved' : 'dismissed',
      name: name ?? 'invoice-export',
    );
  }
}
