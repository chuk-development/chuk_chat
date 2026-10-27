import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_draft_history.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/agents_action_approval_card.dart';
import 'package:chuk_chat/widgets/draft_diff_text.dart';
import 'package:chuk_chat/utils/word_diff.dart';

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

AgentsRelayApprovalRequest _mail(
  String id, {
  String subject = 'Meeting',
  String preview = 'Hi Bob, can we meet on Monday at noon?',
}) => AgentsRelayApprovalRequest(
  approvalId: id,
  action: 'action_approval',
  path: '',
  name: '',
  fileCount: 0,
  totalBytes: 0,
  baseUrl: '',
  public: false,
  sessionKey: 'thread-1',
  actionClass: 'send_external',
  options: const <String>['once', 'deny'],
  summary: 'Send a mail to bob@example.com',
  details: <String, dynamic>{
    'to': <String>['bob@example.com'],
    'subject': subject,
    'preview': preview,
  },
);

AgentsRelayApprovalRequest _slack(String id, String text) =>
    AgentsRelayApprovalRequest(
      approvalId: id,
      action: 'action_approval',
      path: '',
      name: '',
      fileCount: 0,
      totalBytes: 0,
      baseUrl: '',
      public: false,
      sessionKey: 'thread-1',
      actionClass: 'mcp_destructive',
      options: const <String>['once', 'deny'],
      summary: 'Post a message in Slack',
      details: <String, dynamic>{
        'server': 'Slack',
        'remote_tool': 'post_message',
        'arguments': <String, dynamic>{'channel': '#team', 'text': text},
      },
    );

List<TextSpan> _spans(WidgetTester tester, Key key) {
  final RichText rich = tester.widget<RichText>(
    find.descendant(of: find.byKey(key), matching: find.byType(RichText)),
  );
  final List<TextSpan> out = <TextSpan>[];
  rich.text.visitChildren((InlineSpan span) {
    if (span is TextSpan && span.text != null) out.add(span);
    return true;
  });
  return out;
}

void main() {
  group('AgentsDraftHistory', () {
    test('a revised mail finds the previous mail, not itself', () {
      final AgentsDraftHistory h = AgentsDraftHistory();
      final AgentsRelayApprovalRequest first = _mail('a1');
      final AgentsRelayApprovalRequest second = _mail(
        'a2',
        preview: 'Hi Bob, can we meet on Tuesday at noon?',
      );
      expect(h.previousFor('t', first), isNull);
      h.record('t', first);
      // A replay of the same card is not its own previous draft.
      expect(h.previousFor('t', first), isNull);
      expect(h.previousFor('t', second)?.approvalId, 'a1');
      expect(h.previousFor('other-thread', second), isNull);
      h.record('t', second);
      expect(h.previousFor('t', _mail('a3'))?.approvalId, 'a2');
    });

    test('a connector call compares with the same tool only', () {
      final AgentsDraftHistory h = AgentsDraftHistory();
      h.record('t', _mail('m1'));
      h.record('t', _slack('s1', 'Deploy at 5'));
      final AgentsDraft? prev = h.previousFor('t', _slack('s2', 'Deploy at 6'));
      expect(prev?.approvalId, 's1');
      expect(prev?.body, contains('Deploy at 5'));
      expect(h.previousFor('t', _mail('m2'))?.approvalId, 'm1');
    });

    test('a browser step is no draft', () {
      final AgentsRelayApprovalRequest click = AgentsRelayApprovalRequest(
        approvalId: 'b1',
        action: 'action_approval',
        path: '',
        name: '',
        fileCount: 0,
        totalBytes: 0,
        baseUrl: '',
        public: false,
        actionClass: 'browser_act',
        details: const <String, dynamic>{'element': 'Buy'},
      );
      expect(AgentsDraftHistory.draftOf(click), isNull);
    });

    test('keeps a short list per thread', () {
      final AgentsDraftHistory h = AgentsDraftHistory();
      for (int i = 0; i < 20; i++) {
        h.record('t', _mail('m$i'));
      }
      // The oldest are gone; the latest is still the previous one.
      expect(h.previousFor('t', _mail('new'))?.approvalId, 'm19');
    });
  });

  group('draftDiffWorthShowing', () {
    test('no change is not worth showing', () {
      expect(draftDiffWorthShowing(wordDiff('a b', 'a b')), isFalse);
    });

    test('a small revision is', () {
      expect(
        draftDiffWorthShowing(wordDiff('see you Monday', 'see you Tuesday')),
        isTrue,
      );
    });

    test('a different mail is not', () {
      expect(
        draftDiffWorthShowing(
          wordDiff(
            'Your invoice for September is attached.',
            'Happy birthday, have a great party tonight!',
          ),
        ),
        isFalse,
      );
    });
  });

  group('the approval card', () {
    testWidgets('a revised mail marks inserted and removed words', (
      tester,
    ) async {
      final AgentsDraft prev = AgentsDraftHistory.draftOf(_mail('a1'))!;
      await tester.pumpWidget(
        _app(
          AgentsActionApprovalCard(
            request: _mail(
              'a2',
              preview: 'Hi Bob, can we meet on Tuesday at noon?',
            ),
            agentName: 'Ada',
            onSelect: (_) {},
            previousDraft: prev,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Changed since the last draft'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('agents-approval-draft-changed')),
        findsOneWidget,
      );
      final List<TextSpan> spans = _spans(
        tester,
        const ValueKey<String>('agents-approval-diff'),
      );
      final ColorScheme scheme = Theme.of(
        tester.element(find.byType(AgentsActionApprovalCard)),
      ).colorScheme;
      final TextSpan removed = spans.firstWhere(
        (TextSpan s) => s.text == 'Monday',
      );
      final TextSpan inserted = spans.firstWhere(
        (TextSpan s) => s.text == 'Tuesday',
      );
      expect(removed.style?.decoration, TextDecoration.lineThrough);
      expect(removed.style?.color, scheme.error);
      expect(inserted.style?.backgroundColor, scheme.primaryContainer);
      expect(inserted.style?.color, scheme.onPrimaryContainer);
      // No plain preview next to the diff.
      expect(
        find.byKey(const ValueKey<String>('agents-approval-preview')),
        findsNothing,
      );
    });

    testWidgets('a changed subject is marked too', (tester) async {
      final AgentsDraft prev = AgentsDraftHistory.draftOf(_mail('a1'))!;
      await tester.pumpWidget(
        _app(
          AgentsActionApprovalCard(
            request: _mail('a2', subject: 'Meeting moved'),
            agentName: 'Ada',
            onSelect: (_) {},
            previousDraft: prev,
          ),
        ),
      );
      await tester.pump();
      final List<TextSpan> spans = _spans(
        tester,
        const ValueKey<String>('agents-approval-subject-diff'),
      );
      final TextSpan inserted = spans.firstWhere(
        (TextSpan s) => s.text?.contains('moved') ?? false,
      );
      expect(inserted.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('no previous draft: the plain preview', (tester) async {
      await tester.pumpWidget(
        _app(
          AgentsActionApprovalCard(
            request: _mail('a1'),
            agentName: 'Ada',
            onSelect: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('agents-approval-preview')),
        findsOneWidget,
      );
      expect(find.text('Changed since the last draft'), findsNothing);
    });

    testWidgets('a revised Slack message marks the changed argument', (
      tester,
    ) async {
      final AgentsDraft prev = AgentsDraftHistory.draftOf(
        _slack('s1', 'Deploy at 5 today'),
      )!;
      await tester.pumpWidget(
        _app(
          AgentsActionApprovalCard(
            request: _slack('s2', 'Deploy at 6 today'),
            agentName: 'Ada',
            onSelect: (_) {},
            previousDraft: prev,
          ),
        ),
      );
      await tester.pump();
      final List<TextSpan> spans = _spans(
        tester,
        const ValueKey<String>('agents-approval-args-diff'),
      );
      expect(
        spans.any(
          (TextSpan s) =>
              s.text == '5' &&
              s.style?.decoration == TextDecoration.lineThrough,
        ),
        isTrue,
      );
    });

    testWidgets('German label, and it fits 360 px at 1.3 text scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final AgentsDraft prev = AgentsDraftHistory.draftOf(_mail('a1'))!;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(1.3),
          ),
          child: _app(
            AgentsActionApprovalCard(
              request: _mail(
                'a2',
                subject: 'Meeting moved to a much later day of the week',
                preview:
                    'Hi Bob, can we meet on Tuesday at noon? The room is '
                    'booked.',
              ),
              agentName: 'Ada',
              onSelect: (_) {},
              previousDraft: prev,
            ),
            locale: const Locale('de'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Geändert seit dem letzten Entwurf'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
