import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/agent_mail_contacts_page.dart';

import '../support/agent_mail_fake.dart';
import '../support/test_app.dart';

/// Mailbox > Contacts (docs/AGENT_MAIL.md §2, §8): trusted and blocked
/// addresses and domains, their sealed labels opened, added over
/// `PUT /contacts` and removed by id over `DELETE /contacts/{id}`.
void main() {
  Future<FakeAgentMailServer> pump(
    WidgetTester tester, {
    FakeAgentMailServer? server,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeAgentMailServer fake = server ?? FakeAgentMailServer();
    await tester.pumpWidget(
      testApp(AgentMailContactsPage(service: fake.service())),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('lists trusted and blocked contacts apart', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);

    expect(fake.calls, <String>['GET /key', 'GET /contacts']);
    expect(find.text('ada@example.com'), findsOneWidget);
    expect(find.text('@very-long-company-domain-name.example'), findsOneWidget);
    expect(find.text('spam@junk.example'), findsOneWidget);
    expect(find.text('Starts normal runs · Agent may write'), findsOneWidget);
    expect(find.text('Whole domain · Starts normal runs'), findsOneWidget);
    // Trusted first, then Blocked with the blocked address under it.
    expect(top(tester, 'Trusted'), lessThan(top(tester, 'ada@example.com')));
    expect(top(tester, 'ada@example.com'), lessThan(top(tester, 'Blocked')));
    expect(top(tester, 'Blocked'), lessThan(top(tester, 'spam@junk.example')));
  });

  testWidgets('empty sections say so', (tester) async {
    await pump(
      tester,
      server: FakeAgentMailServer(contacts: <Map<String, dynamic>>[]),
    );
    expect(find.text('No trusted senders'), findsOneWidget);
    expect(find.text('No blocked senders'), findsOneWidget);
  });

  testWidgets('remove deletes the contact by id', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-contact-remove-c3')),
    );
    await tester.pumpAndSettle();
    expect(fake.calls.last, 'DELETE /contacts/c3');
    expect(find.text('spam@junk.example'), findsNothing);
    expect(find.text('No blocked senders'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a failed remove keeps the row and says why', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);
    fake.failures['/contacts'] = FakeAgentMailServer.errorResponse(500, 'boom');
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-contact-remove-c3')),
    );
    await tester.pumpAndSettle();
    expect(find.text('spam@junk.example'), findsOneWidget);
    expect(find.text('Something went wrong (boom).'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('add trusts an address, lower-cased', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);
    await tester.tap(find.text('Add address or domain'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('agent-mail-contact-field')),
      ' Bob@Example.com ',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Trust'));
    await tester.pumpAndSettle();

    expect(fake.bodiesOf('PUT', '/contacts').single, <String, dynamic>{
      'address': 'bob@example.com',
      'trusted_inbound': true,
      'allowed_outbound': true,
      'blocked': false,
    });
    // The list is read again and shows the new contact.
    expect(fake.calls.last, 'GET /contacts');
    expect(find.text('bob@example.com'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('add can block a whole domain', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);
    await tester.tap(find.text('Add address or domain'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('agent-mail-contact-field')),
      '@spam.example',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Block'));
    await tester.pumpAndSettle();

    expect(fake.bodiesOf('PUT', '/contacts').single, <String, dynamic>{
      'address': '@spam.example',
      'trusted_inbound': false,
      'allowed_outbound': false,
      'blocked': true,
    });
    expect(find.text('@spam.example'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a bad address is refused before any request', (tester) async {
    final FakeAgentMailServer fake = await pump(tester);
    await tester.tap(find.text('Add address or domain'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('agent-mail-contact-field')),
      'not an address',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Trust'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an address or @domain.tld'), findsOneWidget);
    expect(fake.bodiesOf('PUT', '/contacts'), isEmpty);
  });

  testWidgets('a label that does not open says so and can be removed', (
    tester,
  ) async {
    final FakeAgentMailServer server = FakeAgentMailServer();
    server.contacts.add(<String, dynamic>{
      'id': 'c9',
      'address': 'lost@example.com',
      'trusted_inbound': false,
      'allowed_outbound': false,
      'blocked': true,
      'broken': true,
    });
    final FakeAgentMailServer fake = await pump(tester, server: server);
    final Finder tile = find.byKey(
      const ValueKey<String>('agent-mail-contact-c9'),
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.text('This contact could not be decrypted.'),
      ),
      findsOneWidget,
    );
    expect(find.text('lost@example.com'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-contact-remove-c9')),
    );
    await tester.pumpAndSettle();
    expect(fake.calls.last, 'DELETE /contacts/c9');
    expect(tile, findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a failed load says so, with a retry', (tester) async {
    final FakeAgentMailServer server = FakeAgentMailServer();
    server.failures['/contacts'] = FakeAgentMailServer.errorResponse(
      402,
      'no_subscription',
    );
    await pump(tester, server: server);
    expect(find.text('This needs a subscription.'), findsOneWidget);
    server.failures.clear();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('ada@example.com'), findsOneWidget);
  });
}
