import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/agents/agent_mail_service.dart';

/// The agent mail client against the REST contract (docs/AGENT_MAIL.md §4.3):
/// the bearer token, the paths and queries, the bodies, and every error as a
/// typed exception with the server's `detail` code.
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
      expect(box.sendSuspended, isFalse);
    });

    test('a frozen, suspended mailbox reads as such', () async {
      final Mailbox box = await service(
        (_) => json(<String, dynamic>{
          'address': 'a@chukagents.com',
          'status': 'frozen',
          'send_suspended': true,
        }),
      ).mailbox();
      expect(box.status, MailboxStatus.frozen);
      expect(box.sendSuspended, isTrue);
    });

    test('the message list sends folder, trust, limit and before', () async {
      final AgentMailService s = service(
        (_) => json(<String, dynamic>{
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'm1',
              'direction': 'in',
              'from_address': 'ada@example.com',
              'from_name': 'Ada',
              'to_addresses': <String>['a@chukagents.com'],
              'subject': 'Hi',
              'snippet': 'Hello there',
              'sender_trust': 'trusted',
              'folder': 'inbox',
              'read': false,
              'is_bulk': false,
              'has_attachments': true,
              'status': 'received',
              'importance': 'high',
              'agent_note': 'Asks for a call.',
              'created_at': '2026-09-30T09:15:00Z',
            },
          ],
          'next_before': '2026-09-30T09:15:00Z',
        }),
      );
      final MailPage page = await s.messages(
        folder: MailFolder.inbox,
        trust: MailTrustFilter.unknown,
        limit: 500,
        before: '2026-09-30T10:00:00Z',
      );

      final Uri url = seen.single.url;
      expect(url.path, '/v1/agent-mail/messages');
      expect(url.queryParameters, <String, String>{
        'folder': 'inbox',
        'trust': 'unknown',
        // The server takes at most 100.
        'limit': '100',
        'before': '2026-09-30T10:00:00Z',
      });
      expect(page.nextBefore, '2026-09-30T09:15:00Z');
      final MailSummary m = page.messages.single;
      expect(m.id, 'm1');
      expect(m.fromName, 'Ada');
      expect(m.senderTrust, MailTrust.trusted);
      expect(m.importance, MailImportance.high);
      expect(m.agentNote, 'Asks for a call.');
      expect(m.hasAttachments, isTrue);
      expect(m.read, isFalse);
      expect(m.outgoing, isFalse);
    });

    test('drafts are asked for without a trust filter', () async {
      final AgentMailService s = service(
        (_) => json(<String, dynamic>{'messages': <Object>[]}),
      );
      final MailPage page = await s.messages(folder: MailFolder.drafts);
      expect(seen.single.url.queryParameters, <String, String>{
        'folder': 'drafts',
      });
      expect(page.messages, isEmpty);
      expect(page.nextBefore, isNull);
    });

    test('a mail id is escaped in the path', () async {
      final AgentMailService s = service(
        (_) => json(<String, dynamic>{
          'id': 'a/b',
          'subject': 'x',
          'text_body': 'Plain text.',
          'cc_addresses': <String>['c@example.com'],
          'attachments': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'f1',
              'filename': 'report.pdf',
              'content_type': 'application/pdf',
              'size': 2048,
              'available': true,
            },
            <String, dynamic>{
              'id': 'f2',
              'filename': 'huge.zip',
              'size': 99999999,
              'available': false,
            },
          ],
          'auth': <String, String>{
            'spf': 'pass',
            'dkim': 'fail',
            'dmarc': 'fail',
          },
        }),
      );
      final MailMessage m = await s.message('a/b');
      expect(seen.single.url.path, '/v1/agent-mail/messages/a%2Fb');
      expect(m.textBody, 'Plain text.');
      expect(m.ccAddresses, <String>['c@example.com']);
      expect(m.attachments.map((MailAttachment a) => a.available), <bool>[
        true,
        false,
      ]);
      expect(m.attachments.first.size, 2048);
      expect(m.attachments.last.tooLarge, isFalse);
      expect(m.auth.dmarc, 'fail');
    });

    test('too_large says why a file is missing', () async {
      final AgentMailService s = service(
        (_) => json(<String, dynamic>{
          'id': 'm1',
          'attachments': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'f1',
              'filename': 'huge.zip',
              'available': false,
              'too_large': true,
            },
          ],
        }),
      );
      final MailAttachment a = (await s.message('m1')).attachments.single;
      expect(a.available, isFalse);
      expect(a.tooLarge, isTrue);
    });

    test('the home folder is the one the server PATCH takes back', () {
      MailFolder home(Map<String, dynamic> json) =>
          MailSummary.fromJson(json).homeFolder;
      expect(
        home(<String, dynamic>{'id': 'a', 'direction': 'inbound'}),
        MailFolder.inbox,
      );
      expect(
        home(<String, dynamic>{
          'id': 'b',
          'direction': 'outbound',
          'status': 'sent',
          'folder': 'archive',
        }),
        MailFolder.sent,
      );
      expect(
        home(<String, dynamic>{
          'id': 'c',
          'direction': 'outbound',
          'status': 'draft',
        }),
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

    test('an attachment comes back as its bytes', () async {
      final AgentMailService s = service(
        (_) => http.Response.bytes(<int>[1, 2, 3, 250], 200),
      );
      final List<int> bytes = await s.attachment('m1', 'f1');
      expect(seen.single.url.path, '/v1/agent-mail/messages/m1/attachments/f1');
      expect(bytes, <int>[1, 2, 3, 250]);
    });

    test('a draft is sent with only the edited fields', () async {
      final AgentMailService s = service(
        (_) => json(<String, dynamic>{'id': 'd1', 'status': 'sent'}),
      );
      final MailSendResult sent = await s.sendDraft('d1', text: 'Edited');
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/v1/agent-mail/drafts/d1/send');
      expect(jsonDecode(seen.single.body), <String, dynamic>{'text': 'Edited'});
      expect(sent.sent, isTrue);

      final AgentMailService kept = service(
        (_) => json(<String, dynamic>{
          'id': 'd1',
          'status': 'draft',
          'reason': 'recipient_not_allowed',
        }, 202),
      );
      final MailSendResult draft = await kept.sendDraft(
        'd1',
        subject: 'New subject',
        text: 'New text',
      );
      expect(jsonDecode(seen.single.body), <String, dynamic>{
        'text': 'New text',
        'subject': 'New subject',
      });
      expect(draft.sent, isFalse);
      expect(draft.reason, 'recipient_not_allowed');
    });

    test('contacts list, upsert and delete', () async {
      final AgentMailService s = service((http.Request r) {
        if (r.method == 'GET') {
          return json(<String, dynamic>{
            'contacts': <Map<String, dynamic>>[
              <String, dynamic>{
                'address': '@example.com',
                'trusted_inbound': true,
                'allowed_outbound': false,
                'blocked': false,
              },
            ],
          });
        }
        return r.method == 'DELETE'
            ? http.Response('', 204)
            : json(<String, dynamic>{});
      });
      final List<MailContact> contacts = await s.contacts();
      expect(contacts.single.isDomain, isTrue);
      expect(contacts.single.trustedInbound, isTrue);

      await s.trust('ada@example.com');
      await s.block('spam@junk.example');
      await s.deleteContact('a+b@example.com');

      expect(seen.map((http.Request r) => r.method), <String>[
        'GET',
        'PUT',
        'PUT',
        'DELETE',
      ]);
      expect(jsonDecode(seen[1].body), <String, dynamic>{
        'address': 'ada@example.com',
        'trusted_inbound': true,
        'allowed_outbound': true,
        'blocked': false,
      });
      expect(jsonDecode(seen[2].body), <String, dynamic>{
        'address': 'spam@junk.example',
        'trusted_inbound': false,
        'allowed_outbound': false,
        'blocked': true,
      });
      expect(seen[3].url.path, '/v1/agent-mail/contacts');
      expect(seen[3].url.queryParameters, <String, String>{
        'address': 'a+b@example.com',
      });
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
        ).messages(),
      );
      expect(e.unavailable, isTrue);
      expect(e.noSubscription, isFalse);
    });

    test('send errors keep the server code', () async {
      for (final (int, String) c in <(int, String)>[
        (403, 'mailbox_frozen'),
        (403, 'send_suspended'),
        (422, 'too_many_recipients'),
        (429, 'rate_limited'),
        (429, 'quota_exhausted'),
      ]) {
        final AgentMailException e = await failure(
          service((_) => json(<String, String>{'detail': c.$2}, c.$1))
              .sendDraft('d1'),
        );
        expect((e.statusCode, e.code), c);
      }
    });

    test('a body with no detail falls back to the status', () async {
      final AgentMailException e = await failure(
        service((_) => http.Response('<html>bad gateway</html>', 502))
            .contacts(),
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
