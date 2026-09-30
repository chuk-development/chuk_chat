import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/agent_mail_detail_page.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

import '../support/agent_mail_fake.dart';
import '../support/test_app.dart';

class _RecordingSaver implements AgentFileSaver {
  final List<AgentsRelayFile> saved = <AgentsRelayFile>[];

  @override
  Future<String> save(AgentsRelayFile file) async {
    saved.add(file);
    return '/downloads/${file.name}';
  }
}

/// One mail (docs/AGENT_MAIL.md §6): what it shows, and which endpoint each
/// action calls. Every page is opened from a host route, so the result it
/// pops with is checked too.
void main() {
  late FakeAgentMailServer fake;
  late _RecordingSaver saver;
  AgentMailOutcome? popped;
  bool poppedAtAll = false;

  MailSummary summaryOf(String id) => MailSummary.fromJson(
    fake.mails.firstWhere((Map<String, dynamic> m) => m['id'] == id),
  );

  Future<void> open(WidgetTester tester, String id) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    popped = null;
    poppedAtAll = false;
    final MailSummary summary = summaryOf(id);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push(
                    MaterialPageRoute<AgentMailOutcome>(
                      builder: (_) => AgentMailDetailPage(
                        summary: summary,
                        service: fake.service(),
                        fileSaver: saver,
                      ),
                    ),
                  );
                  poppedAtAll = true;
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    // The localisation delegates load asynchronously; the first frame is
    // empty.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String label) async {
    final Finder f = find.text(label).last;
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  setUp(() {
    fake = FakeAgentMailServer();
    saver = _RecordingSaver();
  });

  testWidgets('shows sender, trust, date, the note, the text and the files', (
    tester,
  ) async {
    await open(tester, 'm1');

    expect(fake.calls.take(2), <String>[
      'GET /messages/m1',
      'PATCH /messages/m1',
    ]);
    expect(fake.bodiesOf('PATCH', '/messages/m1').single, <String, dynamic>{
      'read': true,
    });
    expect(
      find.text('Quarterly numbers for the board meeting next Thursday'),
      findsOneWidget,
    );
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(find.text('ada@example.com'), findsOneWidget);
    expect(find.text('Trusted'), findsOneWidget);
    expect(find.text('k7f3q9x2mh@chukagents.com'), findsOneWidget);
    expect(find.text('SPF pass · DKIM pass · DMARC pass'), findsOneWidget);
    expect(find.text('Agent note'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(
      find.text(
        'Ada sent the Q3 numbers. Revenue is up; she asks for a reply.',
      ),
      findsOneWidget,
    );
    // The plain text, never HTML.
    expect(
      find.byKey(const ValueKey<String>('agent-mail-text')),
      findsOneWidget,
    );
    expect(find.text('Hello,\n\nhere are the numbers.\n\nAda'), findsOneWidget);
    expect(find.text('q3-revenue-by-region-final-v2.xlsx'), findsOneWidget);
    expect(find.text('47 KB · application/vnd.ms-excel'), findsOneWidget);
    expect(find.text('board-video.mp4'), findsOneWidget);
    expect(find.text('Too large, not stored'), findsOneWidget);
    // Only the stored file can be saved.
    expect(
      find.byKey(const ValueKey<String>('agent-mail-attachment-save-a1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('agent-mail-attachment-save-a2')),
      findsNothing,
    );
    // Already trusted: no trust action, but block and the rest.
    expect(find.text('Trust sender'), findsNothing);
    expect(find.text('Block sender'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('a mail already read is not marked again', (tester) async {
    await open(tester, 'm2');
    expect(fake.calls, <String>['GET /messages/m2']);
    // The owner's own mail: "You" as the name, the address under it, no
    // tag saying it twice, and nothing to trust or block.
    expect(find.text('You'), findsOneWidget);
    expect(find.text('me@example.com'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('You')).dy,
      lessThan(tester.getTopLeft(find.text('me@example.com')).dy),
    );
    expect(find.text('Trust sender'), findsNothing);
    expect(find.text('Block sender'), findsNothing);
  });

  testWidgets('saving an attachment downloads and stores its bytes', (
    tester,
  ) async {
    await open(tester, 'm1');
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-attachment-save-a1')),
    );
    await tester.pumpAndSettle();
    expect(fake.calls, contains('GET /messages/m1/attachments/a1'));
    expect(saver.saved.single.name, 'q3-revenue-by-region-final-v2.xlsx');
    expect(String.fromCharCodes(saver.saved.single.bytes!), 'bytes of a1');
    expect(
      find.text('Saved to /downloads/q3-revenue-by-region-final-v2.xlsx'),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('archive moves the mail and leaves the page', (tester) async {
    await open(tester, 'm1');
    await tapText(tester, 'Archive');
    expect(fake.bodiesOf('PATCH', '/messages/m1').last, <String, dynamic>{
      'folder': 'archive',
    });
    expect(poppedAtAll, isTrue);
    expect(popped, AgentMailOutcome.removed);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('an archived mail moves back to the inbox', (tester) async {
    await open(tester, 'r1');
    expect(find.text('Archive'), findsNothing);
    await tapText(tester, 'Move to inbox');
    expect(fake.bodiesOf('PATCH', '/messages/r1').last, <String, dynamic>{
      'folder': 'inbox',
    });
    expect(popped, AgentMailOutcome.removed);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('an archived sent mail moves back to Sent, not the inbox', (
    tester,
  ) async {
    // The server's PATCH also takes `inbox` for a sent mail, and the mail
    // would then show in the Inbox (its trust `self` counts as known).
    fake.mails.add(
      fakeMail(
        id: 'r2',
        direction: 'outbound',
        from: 'k7f3q9x2mh@chukagents.com',
        to: const <String>['bob@example.com'],
        trust: 'self',
        folder: 'archive',
        status: 'delivered',
        read: true,
      ),
    );
    await open(tester, 'r2');
    expect(find.text('Move to inbox'), findsNothing);
    await tapText(tester, 'Move back to Sent');
    expect(fake.bodiesOf('PATCH', '/messages/r2').last, <String, dynamic>{
      'folder': 'sent',
    });
    expect(popped, AgentMailOutcome.removed);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a file that failed to download is not called too large', (
    tester,
  ) async {
    fake.mails.add(
      fakeMail(
        id: 'm9',
        files: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'a9',
            'filename': 'scan.pdf',
            'size': 1200,
            'available': false,
            'too_large': false,
          },
        ],
      ),
    );
    await open(tester, 'm9');
    expect(find.text('Not available'), findsOneWidget);
    expect(find.text('Too large, not stored'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('agent-mail-attachment-save-a9')),
      findsNothing,
    );
  });

  testWidgets('delete asks first, then deletes', (tester) async {
    await open(tester, 'm1');
    await tapText(tester, 'Delete');
    expect(find.text('Delete this mail?'), findsOneWidget);

    // Cancel keeps it.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.calls.where((String c) => c.startsWith('DELETE')), isEmpty);

    await tapText(tester, 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('DELETE /messages/m1'));
    expect(popped, AgentMailOutcome.removed);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('an unknown sender can be trusted', (tester) async {
    await open(tester, 'm3');
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.textContaining('This sender is not trusted'), findsOneWidget);

    await tapText(tester, 'Trust sender');
    expect(fake.bodiesOf('PUT', '/contacts').single, <String, dynamic>{
      'address': 'noreply@verification.some-service.example',
      'trusted_inbound': true,
      'allowed_outbound': true,
      'blocked': false,
    });
    expect(find.text('Trust sender'), findsNothing);
    expect(find.text('Trusted'), findsOneWidget);

    // Back: the list is told something changed.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(popped, AgentMailOutcome.changed);
  });

  testWidgets('blocking asks first, then blocks', (tester) async {
    await open(tester, 'm3');
    await tapText(tester, 'Block sender');
    expect(
      find.text('Block noreply@verification.some-service.example?'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();
    expect(fake.bodiesOf('PUT', '/contacts').single, <String, dynamic>{
      'address': 'noreply@verification.some-service.example',
      'trusted_inbound': false,
      'allowed_outbound': false,
      'blocked': true,
    });
    expect(find.text('Block sender'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a draft is edited and sent', (tester) async {
    await open(tester, 'd1');
    expect(find.textContaining('may not send it on its own'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey<String>('agent-mail-draft-text')),
      'Thanks Ada, see you Thursday.',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-draft-send')),
    );
    await tester.pumpAndSettle();

    // Only the edited text goes back; the subject stays the agent's.
    expect(fake.bodiesOf('POST', '/drafts/d1/send').single, <String, dynamic>{
      'text': 'Thanks Ada, see you Thursday.',
    });
    expect(popped, AgentMailOutcome.removed);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('the draft fields carry their label inside, text aligned', (
    tester,
  ) async {
    await open(tester, 'd1');
    for (final (String, String) f in <(String, String)>[
      ('Subject', 'agent-mail-draft-subject'),
      ('Text', 'agent-mail-draft-text'),
    ]) {
      final Finder field = find.byKey(ValueKey<String>(f.$2));
      final Finder box = find.ancestor(
        of: field,
        matching: find.byType(ExpressiveField),
      );
      // The label sits inside the filled field, above the text.
      expect(
        find.descendant(of: box, matching: find.text(f.$1)),
        findsOneWidget,
        reason: f.$1,
      );
      final Rect outer = tester.getRect(box);
      final Rect label = tester.getRect(
        find.descendant(of: box, matching: find.text(f.$1)),
      );
      final Rect text = tester.getRect(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(label.top, greaterThan(outer.top), reason: f.$1);
      expect(label.bottom, lessThanOrEqualTo(text.top), reason: f.$1);
      // No second inset: the text starts where the label starts.
      expect(text.left, label.left, reason: f.$1);
      expect(text.left - outer.left, 16, reason: f.$1);
    }
    // The subject wraps up to three lines instead of cutting.
    final TextField subject = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('agent-mail-draft-subject')),
    );
    expect(subject.minLines, 1);
    expect(subject.maxLines, 3);
  });

  testWidgets('an edited subject is sent too', (tester) async {
    await open(tester, 'd1');
    await tester.enterText(
      find.byKey(const ValueKey<String>('agent-mail-draft-subject')),
      'Re: Q3',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-draft-send')),
    );
    await tester.pumpAndSettle();
    expect(fake.bodiesOf('POST', '/drafts/d1/send').single, <String, dynamic>{
      'subject': 'Re: Q3',
    });
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a refused send stays on the page and says why', (tester) async {
    fake.sendResponse = FakeAgentMailServer.errorResponse(429, 'rate_limited');
    await open(tester, 'd1');
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-draft-send')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Too many mails sent. Try again later.'), findsOneWidget);
    expect(poppedAtAll, isFalse);
    expect(find.byType(AgentMailDetailPage), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a draft is discarded after asking', (tester) async {
    await open(tester, 'd1');
    await tester.tap(
      find.byKey(const ValueKey<String>('agent-mail-draft-discard')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Discard this draft?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('DELETE /messages/d1'));
    expect(popped, AgentMailOutcome.removed);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a mail that fails to load says so, with a retry', (
    tester,
  ) async {
    fake.failures['/messages/m1'] = FakeAgentMailServer.errorResponse(
      404,
      'not_found',
    );
    await open(tester, 'm1');
    expect(
      find.text('Could not open this mail. This mail no longer exists.'),
      findsOneWidget,
    );
    fake.failures.clear();
    await tapText(tester, 'Retry');
    expect(
      find.byKey(const ValueKey<String>('agent-mail-text')),
      findsOneWidget,
    );
  });
}
