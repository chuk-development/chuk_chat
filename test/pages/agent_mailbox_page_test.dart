import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/agent_mail_contacts_page.dart';
import 'package:chuk_chat/pages/agent_mail_detail_page.dart';
import 'package:chuk_chat/pages/agent_mailbox_page.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';

import '../support/agent_mail_fake.dart';
import '../support/test_app.dart';
import '../widgets/charts/chart_test_support.dart' show loadChartFonts;

/// Settings > Agents > Mailbox (docs/AGENT_MAIL.md §6): the address with a
/// copy action, the folder switch and the list, and the info card that
/// stands in for all of it without a subscription.
void main() {
  final DateTime now = DateTime.utc(2026, 9, 30, 12).toLocal();

  Future<FakeAgentMailServer> pump(
    WidgetTester tester, {
    FakeAgentMailServer? server,
  }) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeAgentMailServer fake = server ?? FakeAgentMailServer();
    await tester.pumpWidget(
      testApp(AgentMailboxPage(service: fake.service(), now: () => now)),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  Finder segment(String label) => find.descendant(
    of: find.byType(ConnectedGroup),
    matching: find.text(label),
  );

  testWidgets('shows the address and the known inbox', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);

    expect(find.text('k7f3q9x2mh@chukagents.com'), findsOneWidget);
    expect(fake.calls, <String>[
      'GET /mailbox',
      'GET /messages?folder=inbox&trust=known&limit=50',
    ]);
    // Known senders only: Ada (trusted) and the owner, not the unknown ones.
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m3')),
      findsNothing,
    );
    // Sender, subject, the agent's note instead of the snippet, the badges.
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(
      find.text('Quarterly numbers for the board meeting next Thursday'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Ada sent the Q3 numbers. Revenue is up; she asks for a reply.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Here are the numbers you asked for last week.'),
      findsNothing,
    );
    expect(find.text('Trusted'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    // One unread mail, one dot.
    expect(
      find.byKey(const ValueKey<String>('agent-mail-unread')),
      findsOneWidget,
    );
    // Four segments over the list; the archive is a row of its own.
    expect(find.byType(ConnectedGroup), findsOneWidget);
    for (final String label in <String>['Inbox', 'Unknown', 'Drafts', 'Sent']) {
      expect(segment(label), findsOneWidget, reason: label);
    }
    expect(segment('Archive'), findsNothing);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Mail you put away'), findsOneWidget);
    // The owner's own mail: "You" is the name line, not a tag on an address.
    expect(find.text('You'), findsOneWidget);
    expect(find.text('me@example.com'), findsNothing);
  });

  group('on a phone at a large text size', () {
    // Real glyphs: the test font draws every letter as a 1 em box, which says
    // nothing about whether a label fits.
    setUpAll(loadChartFonts);

    for (final (Locale, List<String>) c in <(Locale, List<String>)>[
      (const Locale('en'), <String>['Inbox', 'Unknown', 'Drafts', 'Sent']),
      (
        const Locale('de'),
        <String>['Eingang', 'Unbekannt', 'Entwürfe', 'Gesendet'],
      ),
    ]) {
      testWidgets('no folder label is cut or scrolled (${c.$1})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final FakeAgentMailServer fake = FakeAgentMailServer();
        await tester.pumpWidget(
          MaterialApp(
            locale: c.$1,
            localizationsDelegates: kTestLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: AgentMailboxPage(service: fake.service(), now: () => now),
          ),
        );
        await tester.pumpAndSettle();

        // One pill inside the page's gutters: no sideways scroll, no clip.
        final Rect pill = tester.getRect(find.byType(ConnectedGroup));
        expect(pill.left, greaterThanOrEqualTo(16));
        expect(pill.right, lessThanOrEqualTo(360 - 16));
        expect(
          find.ancestor(
            of: find.byType(ConnectedGroup),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.horizontal,
            ),
          ),
          findsNothing,
        );
        for (final String label in c.$2) {
          final RenderParagraph paragraph = tester
              .renderObject<RenderParagraph>(segment(label));
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
          // Set smaller than the reader's 1.3 so it fits, never under 10 px.
          final double size = paragraph.textScaler.scale(14);
          expect(size, lessThan(14 * 1.3), reason: label);
          expect(size, greaterThanOrEqualTo(10), reason: label);
        }
        // The address is never cut either: it scales down on its own line.
        final RenderParagraph address = tester.renderObject<RenderParagraph>(
          find.byKey(const ValueKey<String>('agent-mail-address')),
        );
        expect(address.didExceedMaxLines, isFalse);
      });
    }
  });

  testWidgets('each segment asks for its own folder and trust', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);

    Future<void> pick(String label) async {
      await tester.tap(segment(label));
      await tester.pumpAndSettle();
    }

    await pick('Unknown');
    expect(
      fake.calls.last,
      'GET /messages?folder=inbox&trust=unknown&limit=50',
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m1')),
      findsNothing,
    );
    expect(find.text('Bulk'), findsOneWidget);

    await pick('Drafts');
    expect(fake.calls.last, 'GET /messages?folder=drafts&limit=50');
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-d1')),
      findsOneWidget,
    );
    expect(find.text('To: ada@example.com'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);

    await pick('Sent');
    expect(fake.calls.last, 'GET /messages?folder=sent&limit=50');
    expect(find.text('To: bob@example.com, carol@example.com'), findsOneWidget);
    expect(find.text('Not delivered'), findsOneWidget);

    await pick('Inbox');
    expect(fake.calls.last, 'GET /messages?folder=inbox&trust=known&limit=50');
  });

  testWidgets('without a subscription: an info card and no list', (
    tester,
  ) async {
    final FakeAgentMailServer fake = await pump(
      tester,
      server: FakeAgentMailServer(mailboxStatus: 402),
    );

    expect(
      find.text(
        'The mailbox comes with a subscription. Subscribe to give your agent '
        'its own email address.',
      ),
      findsOneWidget,
    );
    expect(find.text('See plans'), findsOneWidget);
    expect(find.byType(ConnectedGroup), findsNothing);
    expect(fake.calls, <String>['GET /mailbox']);
  });

  testWidgets('mail off on the server says so, with a retry', (tester) async {
    final FakeAgentMailServer fake = await pump(
      tester,
      server: FakeAgentMailServer(
        mailboxStatus: 503,
        mailboxDetail: 'agent_mail_unavailable',
      ),
    );
    expect(
      find.text('Mail is not available right now. Try again later.'),
      findsOneWidget,
    );
    fake.mailboxStatus = 200;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('k7f3q9x2mh@chukagents.com'), findsOneWidget);
    expect(find.byType(ConnectedGroup), findsOneWidget);
  });

  testWidgets('a failed list is on screen, not swallowed', (tester) async {
    final FakeAgentMailServer server = FakeAgentMailServer();
    server.failures['/messages'] = FakeAgentMailServer.errorResponse(
      500,
      'boom',
    );
    await pump(tester, server: server);
    expect(find.text('Something went wrong (boom).'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a frozen and suspended mailbox says why', (tester) async {
    await pump(
      tester,
      server: FakeAgentMailServer(frozen: true, sendSuspended: true),
    );
    expect(find.textContaining('This mailbox is frozen'), findsOneWidget);
    expect(find.textContaining('Sending is paused'), findsOneWidget);
    // The mail that is there stays readable.
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m1')),
      findsOneWidget,
    );
  });

  testWidgets('an empty folder says so', (tester) async {
    await pump(
      tester,
      server: FakeAgentMailServer(mails: <Map<String, dynamic>>[]),
    );
    expect(find.text('No mail yet'), findsOneWidget);
    await tester.tap(segment('Drafts'));
    await tester.pumpAndSettle();
    expect(find.text('No drafts'), findsOneWidget);
  });

  testWidgets('copy puts the address on the clipboard', (tester) async {
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
    await pump(tester);
    await tester.tap(find.byTooltip('Copy address'));
    await tester.pump();
    expect(clipboard, <String>['k7f3q9x2mh@chukagents.com']);
    expect(find.text('Address copied'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('opening a mail shows it and marks it read', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);

    await tester.tap(find.byKey(const ValueKey<String>('agent-mail-row-m1')));
    await tester.pumpAndSettle();

    expect(find.byType(AgentMailDetailPage), findsOneWidget);
    expect(fake.calls, contains('GET /messages/m1'));
    expect(fake.bodiesOf('PATCH', '/messages/m1'), <Map<String, dynamic>>[
      <String, dynamic>{'read': true},
    ]);

    // Back on the list the dot is gone.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentMailDetailPage), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('agent-mail-unread')),
      findsNothing,
    );
  });

  testWidgets('archiving from the mail page drops the row', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey<String>('agent-mail-row-m1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Archive').last);
    await tester.tap(find.text('Archive').last);
    await tester.pumpAndSettle();

    expect(find.byType(AgentMailDetailPage), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m1')),
      findsNothing,
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('the archive row opens the archive list', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(fake.calls.last, 'GET /messages?folder=archive&limit=50');
    expect(find.text('Old invoice'), findsOneWidget);
    // Only the list: no address, no switch, no second archive row.
    expect(find.byType(ConnectedGroup), findsNothing);
    expect(find.text('k7f3q9x2mh@chukagents.com'), findsNothing);
    expect(find.text('Mail you put away'), findsNothing);

    // Back on the mailbox the inbox is asked again: a mail moved back
    // from the archive shows up there.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(fake.calls.last, 'GET /messages?folder=inbox&trust=known&limit=50');
  });

  testWidgets('leaving a segment while it pages never blocks paging', (
    tester,
  ) async {
    final FakeAgentMailServer server = FakeAgentMailServer()..pageSize = 1;
    final Completer<void> hold = Completer<void>();
    server.holdOlderPages = hold.future;
    await pump(tester, server: server);
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m2')),
      findsNothing,
    );

    // An older inbox page is on its way when the user leaves the segment.
    await tester.tap(find.text('Load older mail'));
    await tester.pump();
    await tester.tap(segment('Unknown'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m3')),
      findsOneWidget,
    );

    // The inbox page lands late and is dropped.
    hold.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m2')),
      findsNothing,
    );

    // Paging in the new segment still works.
    await tester.tap(find.text('Load older mail'));
    await tester.pumpAndSettle();
    expect(
      server.calls.last,
      'GET /messages?folder=inbox&trust=unknown&limit=50&before=cursor-1',
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-row-m4')),
      findsOneWidget,
    );
    expect(find.text('Load older mail'), findsNothing);
  });

  testWidgets('the contacts row opens the contacts page', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Contacts'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentMailContactsPage), findsOneWidget);
  });
}
