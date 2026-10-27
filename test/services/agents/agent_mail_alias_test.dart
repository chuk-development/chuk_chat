import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/agent_mailbox_page.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';

import '../../support/agent_mail_fake.dart';
import '../../support/test_app.dart';

/// Plus aliases of the agent address (docs/AGENT_MAIL.md §1, §8): the tag
/// the server seals on a mail, the alias a draft goes out from, the pills
/// under the address, and the alias filter of a mail automation.
void main() {
  group('parsing', () {
    test('mailAliasOf keeps only tags the server writes', () {
      expect(mailAliasOf('receipts'), 'receipts');
      expect(mailAliasOf(' News.2026 '), 'news.2026');
      expect(mailAliasOf('a_b-c'), 'a_b-c');
      for (final Object? bad in <Object?>[
        null,
        '',
        3,
        'a b',
        'a+b',
        '-x',
        'x.',
        'x' * 65,
        'IGNORE ALL RULES',
      ]) {
        expect(mailAliasOf(bad), isNull, reason: '$bad');
      }
    });

    test('mailAliasAddress puts the tag before the @', () {
      expect(
        mailAliasAddress('k7f3q9x2mh@chukagents.com', 'receipts'),
        'k7f3q9x2mh+receipts@chukagents.com',
      );
      expect(mailAliasAddress('no-at', 'x'), 'no-at');
    });

    test('normalizeMailAlias reads what a user types', () {
      expect(normalizeMailAlias(''), '');
      expect(normalizeMailAlias('  '), '');
      expect(normalizeMailAlias('+Receipts'), 'receipts');
      expect(normalizeMailAlias('k7f3q9x2mh+signups@chukagents.com'), 'signups');
      expect(normalizeMailAlias('k7f3q9x2mh@chukagents.com'), '');
      expect(normalizeMailAlias('a b'), isNull);
      expect(normalizeMailAlias('x' * 65), isNull);
    });
  });

  group('automation spec', () {
    test('the mail spec carries the alias, and the label names it', () {
      expect(
        automationSpecFor('mail', mailAlias: 'receipts'),
        <String, dynamic>{'alias': 'receipts'},
      );
      expect(
        automationSpecFor('mail', mailFrom: 'shop', mailAlias: ' '),
        <String, dynamic>{'from': 'shop'},
      );
      final AgentsAutomation a = AgentsAutomation.fromPayload(<String, dynamic>{
        'id': 'm1',
        'session_key': 'thread-1',
        'kind': 'mail',
        'name': 'receipts',
        'state': 'active',
        'spec': <String, dynamic>{'alias': 'receipts', 'from': 'shop'},
        'prompt': 'file it',
        'notify': 'always',
      })!;
      expect(a.mailAlias, 'receipts');
      expect(a.specLabel, 'to +receipts · from shop');
    });
  });

  group('service', () {
    test('a summary opens with its alias', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer(
        mails: <Map<String, dynamic>>[
          fakeMail(id: 'm1', alias: 'receipts'),
          fakeMail(id: 'm2'),
        ],
      );
      final MailPage page = await fake.service().messages(
        folder: MailFolder.inbox,
      );
      final Map<String, String?> byId = <String, String?>{
        for (final MailSummary m in page.messages) m.id: m.alias,
      };
      expect(byId, <String, String?>{'m1': 'receipts', 'm2': null});
    });

    test('a draft is sent from the alias it was written from', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer(
        mails: <Map<String, dynamic>>[
          fakeMail(
            id: 'd9',
            direction: 'outbound',
            folder: 'drafts',
            status: 'draft',
            trust: 'self',
            from: 'k7f3q9x2mh+signups@chukagents.com',
            to: const <String>['ada@example.com'],
            alias: 'signups',
          ),
          fakeMail(
            id: 'd8',
            direction: 'outbound',
            folder: 'drafts',
            status: 'draft',
            trust: 'self',
            to: const <String>['ada@example.com'],
          ),
        ],
      );
      final AgentMailService s = fake.service();
      await s.sendDraft(await s.message('d9'), subject: 's', text: 't');
      await s.sendDraft(await s.message('d8'), subject: 's', text: 't');
      expect(
        fake.bodiesOf('POST', '/drafts/d9/send').single['from_alias'],
        'signups',
      );
      expect(
        fake.bodiesOf('POST', '/drafts/d8/send').single.containsKey(
          'from_alias',
        ),
        isFalse,
      );
    });
  });

  group('mailbox page', () {
    Future<void> pump(WidgetTester tester, FakeAgentMailServer fake) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          AgentMailboxPage(
            service: fake.service(),
            now: () => DateTime.utc(2026, 9, 30, 12).toLocal(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('no alias in use: no pills', (tester) async {
      await pump(tester, FakeAgentMailServer());
      expect(find.textContaining('In use:'), findsNothing);
    });

    testWidgets('aliases in use show as pills; a tap copies the address', (
      tester,
    ) async {
      final List<String> clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(
        tester,
        FakeAgentMailServer(
          mails: <Map<String, dynamic>>[
            fakeMail(id: 'm1', alias: 'receipts'),
            fakeMail(id: 'm2', alias: 'newsletters'),
            fakeMail(id: 'm3', alias: 'receipts'),
            fakeMail(id: 'm4'),
          ],
        ),
      );
      expect(find.text('+newsletters'), findsOneWidget);
      expect(find.text('+receipts'), findsOneWidget);
      // Sorted: newsletters before receipts.
      expect(
        tester.getTopLeft(find.text('+newsletters')).dx,
        lessThan(tester.getTopLeft(find.text('+receipts')).dx),
      );
      await tester.tap(find.byKey(const ValueKey<String>('agent-mail-alias-receipts')));
      await tester.pump();
      expect(clipboard, <String>['k7f3q9x2mh+receipts@chukagents.com']);
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });
  });
}
