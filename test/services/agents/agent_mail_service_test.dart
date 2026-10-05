import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/agents/agent_mail_crypto.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';

import '../../support/agent_mail_fake.dart';

/// The agent mail client against the v2 contract (docs/AGENT_MAIL.md §3,
/// §5.3): the bearer token, the paths and queries, the bodies, the mail key
/// (made, sealed with the chuk key, kept per user), every sealed field
/// opened, and every error as a typed exception with the server's code.
void main() {
  late List<http.Request> seen;

  AgentMailService service(
    http.Response Function(http.Request request) answer, {
    String? token = 'jwt',
  }) {
    seen = <http.Request>[];
    return AgentMailService(
      client: MockClient((http.Request r) async {
        seen.add(r);
        return answer(r);
      }),
      baseUrl: 'https://api.test',
      token: () async => token,
      userId: () => 'u1',
      secretBox: FakeChukSecretBox(),
    );
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{'content-type': 'application/json'},
  );

  Future<AgentMailException> failure(Future<Object?> call) async {
    try {
      await call;
    } on AgentMailException catch (e) {
      return e;
    }
    fail('expected an AgentMailException');
  }

  group('requests', () {
    test('every call carries the bearer token and asks for JSON', () async {
      final AgentMailService s = service(
        (_) => json(<String, dynamic>{
          'address': 'k7f3q9x2mh@chukagents.com',
          'status': 'active',
          'send_suspended': false,
          'created_at': '2026-09-01T10:00:00Z',
        }),
      );
      final Mailbox box = await s.mailbox();

      expect(seen.single.method, 'GET');
      expect(
        seen.single.url.toString(),
        'https://api.test/v1/agent-mail/mailbox',
      );
      expect(seen.single.headers['Authorization'], 'Bearer jwt');
      expect(seen.single.headers['Accept'], 'application/json');
      expect(box.address, 'k7f3q9x2mh@chukagents.com');
      expect(box.frozen, isFalse);
      expect(box.needsKey, isFalse);
      expect(box.sendSuspended, isFalse);
    });

    test('frozen, suspended and needs_key read as such', () async {
      Future<Mailbox> box(String status) => service(
        (_) => json(<String, dynamic>{
          'address': 'a@chukagents.com',
          'status': status,
          'send_suspended': true,
        }),
      ).mailbox();
      expect((await box('frozen')).status, MailboxStatus.frozen);
      expect((await box('frozen')).sendSuspended, isTrue);
      expect((await box('needs_key')).needsKey, isTrue);
    });

    test('the message list sends folder, trust, limit and before', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final AgentMailService s = fake.service();
      final MailPage page = await s.messages(
        folder: MailFolder.inbox,
        trust: MailTrustFilter.unknown,
        limit: 500,
        before: '2026-09-30T10:00:00Z',
      );

      expect(fake.calls.first, 'GET /key');
      final Uri url = fake.requests.last.url;
      expect(url.path, '/v1/agent-mail/messages');
      expect(url.queryParameters, <String, String>{
        'folder': 'inbox',
        'trust': 'unknown',
        // The server takes at most 100.
        'limit': '100',
        'before': '2026-09-30T10:00:00Z',
      });
      expect(page.messages.map((MailSummary m) => m.id), <String>['m3', 'm4']);
    });

    test('drafts are asked for without a trust filter', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final MailPage page = await fake.service().messages(
        folder: MailFolder.drafts,
      );
      expect(fake.requests.last.url.queryParameters, <String, String>{
        'folder': 'drafts',
      });
      expect(page.messages.single.id, 'd1');
      expect(page.nextBefore, isNull);
    });

    test('a mail id is escaped in the path', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.mails.add(fakeMail(id: 'a/b'));
      await fake.service().message('a/b');
      expect(fake.requests.last.url.path, '/v1/agent-mail/messages/a%2Fb');
    });

    test('the home folder is the one the server PATCH takes back', () {
      expect(const MailSummary(id: 'a').homeFolder, MailFolder.inbox);
      expect(
        const MailSummary(
          id: 'b',
          outgoing: true,
          status: 'sent',
          folder: MailFolder.archive,
        ).homeFolder,
        MailFolder.sent,
      );
      expect(
        const MailSummary(id: 'c', outgoing: true, status: 'draft').homeFolder,
        MailFolder.drafts,
      );
    });

    test('update patches only the fields it is given', () async {
      final AgentMailService s = service((_) => json(<String, dynamic>{}));
      await s.update('m1', read: true);
      await s.update('m1', folder: MailFolder.archive);
      await s.update('m1');

      expect(seen, hasLength(2), reason: 'an empty update is not sent');
      expect(seen.map((http.Request r) => r.method), <String>[
        'PATCH',
        'PATCH',
      ]);
      expect(seen.first.url.path, '/v1/agent-mail/messages/m1');
      expect(
        seen.first.headers['Content-Type'],
        startsWith('application/json'),
      );
      expect(jsonDecode(seen.first.body), <String, dynamic>{'read': true});
      expect(jsonDecode(seen.last.body), <String, dynamic>{
        'folder': 'archive',
      });
    });

    test('delete accepts an empty 204', () async {
      final AgentMailService s = service((_) => http.Response('', 204));
      await s.delete('m1');
      expect(seen.single.method, 'DELETE');
      expect(seen.single.url.path, '/v1/agent-mail/messages/m1');
    });
  });

  group('the mail key', () {
    test('needs_key: a new pair goes up with its private key sealed', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer(hasKey: false);
      final AgentMailService s = fake.service();
      final List<AgentMailKeyPair> created = <AgentMailKeyPair>[];
      s.createdKeys.listen(created.add);

      final Mailbox box = await s.openMailbox();

      expect(fake.calls, <String>[
        'GET /mailbox',
        'GET /key',
        'PUT /key',
        // Asked again: the real status, now that the key is there.
        'GET /mailbox',
      ]);
      expect(box.needsKey, isFalse);
      final Map<String, dynamic> put = fake.bodiesOf('PUT', '/key').single;
      expect(
        put.keys,
        unorderedEquals(<String>['public_key', 'private_key_sealed']),
      );
      final AgentMailKeyPair key = s.cachedKey!;
      expect(put['public_key'], key.publicKeyBase64);
      // The private key never goes up in the clear: it is sealed with the
      // chuk key, and opens to the raw key again.
      final String sealed = put['private_key_sealed'] as String;
      expect(sealed, isNot(contains(key.privateKeyBase64)));
      expect(sealed, startsWith(FakeChukSecretBox.prefix));
      expect(await fake.secretBox.open(sealed), key.privateKeyBase64);
      await pumpEventQueue();
      expect(created.single.sameAs(key), isTrue);

      // The server now seals to that key, and the service opens it.
      final MailPage page = await s.messages();
      expect(page.messages, isNotEmpty);
      expect(page.messages.every((MailSummary m) => !m.unreadable), isTrue);
    });

    test('409 key_exists: the key another device made is fetched', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      // The key row exists, yet the first read says there is none: the
      // other device's PUT landed in between.
      int keyReads = 0;
      final AgentMailService s = AgentMailService(
        client: MockClient((http.Request r) async {
          if (r.method == 'GET' &&
              r.url.path.endsWith('/key') &&
              keyReads++ == 0) {
            fake.requests.add(r);
            return FakeAgentMailServer.errorResponse(404, 'no_key');
          }
          return fake.handle(r);
        }),
        baseUrl: kFakeMailBase,
        token: () async => kFakeMailToken,
        userId: () => kFakeMailUser,
        secretBox: fake.secretBox,
      );
      final List<AgentMailKeyPair> created = <AgentMailKeyPair>[];
      s.createdKeys.listen(created.add);

      final AgentMailKeyPair key = await s.mailKey(create: true);

      expect(fake.calls, <String>['GET /key', 'PUT /key', 'GET /key']);
      expect(key.privateKey, isNot(isEmpty));
      final AgentMailKeyPair theirs = await AgentMailKeyPair.fromPrivateKey(
        kFakeMailPrivateKey,
      );
      expect(key.sameAs(theirs), isTrue);
      await pumpEventQueue();
      expect(created, isEmpty, reason: 'this service made no key');
    });

    test('the opened key stays in memory, per user', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final AgentMailService s = fake.service();
      await s.mailKey();
      await s.mailKey();
      await s.messages();
      expect(
        fake.calls.where((String c) => c == 'GET /key'),
        hasLength(1),
        reason: 'one read for the whole session',
      );
      expect(fake.secretBox.opens, 1);
      expect(s.cachedKey, isNotNull);

      // Another account signs in: the first one's key is gone at once.
      fake.userId = 'someone-else';
      expect(s.cachedKey, isNull);
      await s.mailKey();
      expect(fake.calls.where((String c) => c == 'GET /key'), hasLength(2));

      // Signed out: nothing, and no request.
      fake.userId = null;
      expect(s.cachedKey, isNull);
      final AgentMailException e = await failure(s.mailKey());
      expect(e.code, AgentMailException.notSignedIn);
      expect(fake.calls.where((String c) => c == 'GET /key'), hasLength(2));
    });

    test('forgetKey drops it (sign-out)', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final AgentMailService s = fake.service();
      await s.mailKey();
      s.forgetKey();
      expect(s.cachedKey, isNull);
    });

    test('without create, a missing key is no_key', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer(hasKey: false);
      final AgentMailException e = await failure(fake.service().mailKey());
      expect((e.statusCode, e.code), (404, AgentMailException.noKey));
      expect(fake.calls, <String>['GET /key']);
    });

    test('a locked chuk key is key_locked, and nothing goes up', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer(hasKey: false);
      fake.secretBox.locked = true;
      final AgentMailException e = await failure(
        fake.service().mailKey(create: true),
      );
      expect(e.code, AgentMailException.keyLocked);
      expect(fake.calls, <String>['GET /key']);
    });

    test('a sealed key that does not open is key_unreadable', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.keyRow!['private_key_sealed'] = 'sealed under another password';
      final AgentMailException e = await failure(fake.service().mailKey());
      expect(e.code, AgentMailException.keyUnreadable);
    });

    test('a key that is not the server public key is key_unreadable', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.keyRow!['public_key'] =
          (await AgentMailKeyPair.generate()).publicKeyBase64;
      final AgentMailException e = await failure(fake.service().mailKey());
      expect(e.code, AgentMailException.keyUnreadable);
    });
  });

  group('opening', () {
    test('a list row: summary and agent note', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final MailSummary m = (await fake.service().messages()).messages
          .firstWhere((MailSummary m) => m.id == 'm1');
      expect(
        m.subject,
        'Quarterly numbers for the board meeting next Thursday',
      );
      expect(m.fromAddress, 'ada@example.com');
      expect(m.fromName, 'Ada Lovelace');
      expect(m.toAddresses, <String>['k7f3q9x2mh@chukagents.com']);
      expect(m.snippet, 'Here are the numbers you asked for last week.');
      expect(
        m.agentNote,
        'Ada sent the Q3 numbers. Revenue is up; she asks for a reply.',
      );
      expect(m.senderTrust, MailTrust.trusted);
      expect(m.importance, MailImportance.high);
      expect(m.hasAttachments, isTrue);
      expect(m.attachmentCount, 2);
      expect(m.read, isFalse);
      expect(m.outgoing, isFalse);
      expect(m.unreadable, isFalse);
    });

    test('the full mail: text, cc, files and the DKIM result', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final MailMessage m = await fake.service().message('m1');
      expect(m.textBody, 'Hello,\n\nhere are the numbers.\n\nAda');
      expect(m.attachments.map((MailAttachment a) => a.id), <String>[
        'a1',
        'a2',
      ]);
      expect(m.attachments.first.size, 48213);
      expect(m.attachments.first.available, isTrue);
      expect(m.attachments.last.tooLarge, isTrue);
      expect(m.auth.dkimAligned, isTrue);
      expect(m.auth.dkimDomain, 'example.com');
      expect(m.unreadable, isFalse);
    });

    test('a part that does not open marks the row, it never throws', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.mails.add(fakeMail(id: 'x1', broken: true, note: 'Opens fine.'));
      final AgentMailService s = fake.service();
      final MailSummary row = (await s.messages()).messages.firstWhere(
        (MailSummary m) => m.id == 'x1',
      );
      expect(row.unreadable, isTrue);
      expect(row.subject, isEmpty);
      expect(row.fromAddress, isEmpty);
      // What did open is still there.
      expect(row.agentNote, 'Opens fine.');
      expect(row.senderTrust, MailTrust.trusted);

      final MailMessage full = await s.message('x1');
      expect(full.unreadable, isTrue);
      expect(full.bodyUnreadable, isTrue);
      expect(full.textBody, isEmpty);
    });

    test(
      'sender_trust "self" (the agent\'s own mail) is not "unknown"',
      () async {
        // The server sets `self` on every sent mail and draft (§7); only a
        // reply derived from unknown mail stays `unknown`.
        final FakeAgentMailServer fake = FakeAgentMailServer();
        fake.mails.addAll(<Map<String, dynamic>>[
          fakeMail(
            id: 't-self',
            direction: 'outbound',
            trust: 'self',
            folder: 'sent',
          ),
          fakeMail(id: 't-unknown', trust: 'unknown'),
          fakeMail(id: 't-owner', trust: 'owner'),
          fakeMail(id: 't-new', trust: 'not_a_value_yet'),
        ]);
        final AgentMailService s = fake.service();
        final List<MailSummary> all = (await s.messages(folder: MailFolder.all))
            .messages;
        MailTrust of(String id) =>
            all.firstWhere((MailSummary m) => m.id == id).senderTrust;
        expect(of('t-self'), MailTrust.self);
        expect(of('t-unknown'), MailTrust.unknown);
        expect(of('t-owner'), MailTrust.owner);
        expect(of('t-new'), MailTrust.unknown);
        expect((await s.message('t-self')).summary.senderTrust, MailTrust.self);
      },
    );

    test('an attachment comes back opened', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final List<int> bytes = await fake.service().attachment('m1', 'a1');
      expect(
        fake.requests.last.url.path,
        '/v1/agent-mail/messages/m1/attachments/a1',
      );
      expect(utf8.decode(bytes), 'bytes of a1');
    });

    test('an attachment that does not open is a seal error', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.mails.add(fakeMail(id: 'x1', broken: true));
      await expectLater(
        fake.service().attachment('x1', 'a1'),
        throwsA(isA<AgentMailSealException>()),
      );
    });
  });

  group('drafts', () {
    test('send posts the whole draft, with the user edits', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final AgentMailService s = fake.service();
      final MailMessage draft = await s.message('d1');
      final MailSendResult sent = await s.sendDraft(
        draft,
        subject: 'Re: Q3',
        text: 'Thanks Ada, see you Thursday.',
      );
      expect(fake.requests.last.url.path, '/v1/agent-mail/drafts/d1/send');
      expect(fake.bodiesOf('POST', '/drafts/d1/send').single, <String, dynamic>{
        'to': <String>['ada@example.com'],
        'cc': <String>['bob@example.com'],
        'subject': 'Re: Q3',
        'text': 'Thanks Ada, see you Thursday.',
        'in_reply_to': '<m1@example.com>',
        'references': '<m0@example.com> <m1@example.com>',
      });
      expect(sent.sent, isTrue);
    });

    test('the draft attachments are opened and sent again', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.mails.add(
        fakeMail(
          id: 'd2',
          direction: 'outbound',
          folder: 'drafts',
          status: 'draft',
          to: const <String>['ada@example.com'],
          files: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'f1',
              'filename': 'report.pdf',
              'content_type': 'application/pdf',
              'size': 10,
            },
            <String, dynamic>{'id': 'f2', 'filename': 'notes.txt', 'size': 3},
            // Listed, never stored: nothing to send.
            <String, dynamic>{
              'id': 'f3',
              'filename': 'huge.zip',
              'size': 99999999,
              'too_large': true,
            },
          ],
        ),
      );
      fake.blobs['f2'] = <int>[0, 1, 255];
      final AgentMailService s = fake.service();
      await s.sendDraft(
        await s.message('d2'),
        subject: 'Report',
        text: 'Here.',
      );

      expect(
        fake.calls,
        containsAllInOrder(<String>[
          'GET /messages/d2/attachments/f1',
          'GET /messages/d2/attachments/f2',
          'POST /drafts/d2/send',
        ]),
      );
      expect(fake.calls, isNot(contains('GET /messages/d2/attachments/f3')));
      final Map<String, dynamic> body = fake
          .bodiesOf('POST', '/drafts/d2/send')
          .single;
      expect(body['attachments'], <Map<String, dynamic>>[
        <String, dynamic>{
          'filename': 'report.pdf',
          'content_type': 'application/pdf',
          'content_base64': base64Encode(utf8.encode('bytes of f1')),
        },
        <String, dynamic>{
          'filename': 'notes.txt',
          'content_type': 'application/octet-stream',
          'content_base64': base64Encode(<int>[0, 1, 255]),
        },
      ]);
    });

    test('over 3 MiB of attachments is refused before the send', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.mails.add(
        fakeMail(
          id: 'd3',
          direction: 'outbound',
          folder: 'drafts',
          status: 'draft',
          files: <Map<String, dynamic>>[
            <String, dynamic>{'id': 'b1', 'filename': 'a.bin'},
            <String, dynamic>{'id': 'b2', 'filename': 'b.bin'},
          ],
        ),
      );
      fake.blobs['b1'] = List<int>.filled(2 * 1024 * 1024, 7);
      fake.blobs['b2'] = List<int>.filled(1024 * 1024 + 1, 7);
      final AgentMailService s = fake.service();
      final AgentMailException e = await failure(
        s.sendDraft(await s.message('d3'), subject: 's', text: 't'),
      );
      expect((e.statusCode, e.code), (422, 'attachments_too_large'));
      expect(fake.bodiesOf('POST', '/drafts/d3/send'), isEmpty);
    });

    test('kept as a draft, with the reason', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer()
        ..sendResponse = http.Response(
          jsonEncode(<String, dynamic>{
            'id': 'd1',
            'status': 'draft',
            'reason': 'recipient_not_allowed',
          }),
          202,
        );
      final AgentMailService s = fake.service();
      final MailSendResult kept = await s.sendDraft(
        await s.message('d1'),
        subject: 's',
        text: 't',
      );
      expect(kept.sent, isFalse);
      expect(kept.reason, 'recipient_not_allowed');
    });

    test('a draft that did not open is not sent', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.mails.add(
        fakeMail(
          id: 'd9',
          direction: 'outbound',
          status: 'draft',
          broken: true,
        ),
      );
      final AgentMailService s = fake.service();
      final MailMessage draft = await s.message('d9');
      await expectLater(
        s.sendDraft(draft, subject: 's', text: 't'),
        throwsA(isA<AgentMailSealException>()),
      );
      expect(fake.bodiesOf('POST', '/drafts/d9/send'), isEmpty);
    });
  });

  group('contacts', () {
    test('labels are opened; trust, block and delete by id', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      fake.contacts.add(<String, dynamic>{
        'id': 'c9',
        'address': 'lost@example.com',
        'trusted_inbound': true,
        'allowed_outbound': false,
        'blocked': false,
        'broken': true,
      });
      final AgentMailService s = fake.service();
      final List<MailContact> contacts = await s.contacts();
      expect(contacts.map((MailContact c) => c.id), <String>[
        'c1',
        'c2',
        'c3',
        'c9',
      ]);
      expect(contacts[1].address, '@very-long-company-domain-name.example');
      expect(contacts[1].isDomain, isTrue);
      expect(contacts[1].trustedInbound, isTrue);
      expect(contacts[3].unreadable, isTrue);
      expect(contacts[3].address, isEmpty);

      await s.trust('ada@example.com');
      await s.block('spam@junk.example');
      await s.deleteContact('c3');

      expect(fake.bodiesOf('PUT', '/contacts'), <Map<String, dynamic>>[
        <String, dynamic>{
          'address': 'ada@example.com',
          'trusted_inbound': true,
          'allowed_outbound': true,
          'blocked': false,
        },
        <String, dynamic>{
          'address': 'spam@junk.example',
          'trusted_inbound': false,
          'allowed_outbound': false,
          'blocked': true,
        },
      ]);
      expect(fake.calls.last, 'DELETE /contacts/c3');
    });
  });

  group('errors', () {
    test('402 no_subscription is typed', () async {
      final AgentMailException e = await failure(
        service((_) => json(<String, String>{'detail': 'no_subscription'}, 402))
            .mailbox(),
      );
      expect(e.statusCode, 402);
      expect(e.code, 'no_subscription');
      expect(e.noSubscription, isTrue);
    });

    test('503 agent_mail_unavailable is typed', () async {
      final AgentMailException e = await failure(
        service(
          (_) =>
              json(<String, String>{'detail': 'agent_mail_unavailable'}, 503),
        ).mailbox(),
      );
      expect(e.unavailable, isTrue);
      expect(e.noSubscription, isFalse);
    });

    test('send errors keep the server code', () async {
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final AgentMailService s = fake.service();
      final MailMessage draft = await s.message('d1');
      for (final (int, String) c in <(int, String)>[
        (403, 'mailbox_frozen'),
        (403, 'send_suspended'),
        (422, 'too_many_recipients'),
        (422, 'recipient_suppressed'),
        (422, 'attachments_too_large'),
        (429, 'rate_limited'),
        (429, 'quota_exhausted'),
        (409, 'needs_key'),
      ]) {
        fake.sendResponse = FakeAgentMailServer.errorResponse(c.$1, c.$2);
        final AgentMailException e = await failure(
          s.sendDraft(draft, subject: 's', text: 't'),
        );
        expect((e.statusCode, e.code), c);
      }
    });

    test('a route that needs the key says needs_key', () async {
      // The server lost the key the app still holds in memory.
      final FakeAgentMailServer fake = FakeAgentMailServer();
      final AgentMailService s = fake.service();
      await s.mailKey();
      fake.keyRow = null;
      final AgentMailException e = await failure(s.messages());
      expect((e.statusCode, e.code), (409, 'needs_key'));
    });

    test('a body with no detail falls back to the status', () async {
      final AgentMailException e = await failure(
        service((_) => http.Response('<html>bad gateway</html>', 502))
            .mailbox(),
      );
      expect(e.code, 'http_502');
    });

    test('no token means no request', () async {
      final AgentMailException e = await failure(
        service((_) => json(<String, dynamic>{}), token: null).mailbox(),
      );
      expect(e.code, AgentMailException.notSignedIn);
      expect(seen, isEmpty);
    });

    test('a transport failure is a network error', () async {
      final AgentMailService s = AgentMailService(
        client: MockClient((_) async => throw http.ClientException('down')),
        baseUrl: 'https://api.test',
        token: () async => 'jwt',
        userId: () => 'u1',
        secretBox: FakeChukSecretBox(),
      );
      final AgentMailException e = await failure(s.mailbox());
      expect(e.statusCode, 0);
      expect(e.code, AgentMailException.network);
    });
  });

  test('contact addresses: an address or @domain.tld', () {
    expect(isValidMailContactAddress('ada@example.com'), isTrue);
    expect(isValidMailContactAddress(' @example.co.uk '), isTrue);
    expect(isValidMailContactAddress('@localhost'), isFalse);
    expect(isValidMailContactAddress('ada'), isFalse);
    expect(isValidMailContactAddress('ada@'), isFalse);
    expect(isValidMailContactAddress('a b@example.com'), isFalse);
  });
}
