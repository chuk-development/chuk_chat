/// An in-memory agent mail server (docs/AGENT_MAIL.md §4.3) behind a
/// `MockClient`, for the service, page and layout tests.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/agents/agent_mail_service.dart';

const String kFakeMailBase = 'https://api.test';
const String kFakeMailToken = 'jwt-test';

/// A received mail as the server lists it. The values are the server's:
/// `inbound` / `outbound`, `self` for the agent's own mail, `received` for
/// the status of incoming mail.
Map<String, dynamic> fakeMail({
  required String id,
  String direction = 'inbound',
  String from = 'ada@example.com',
  String? fromName = 'Ada Lovelace',
  List<String> to = const <String>['k7f3q9x2mh@chukagents.com'],
  String subject = 'Quarterly numbers',
  String? snippet = 'Here are the numbers you asked for last week.',
  String trust = 'trusted',
  String folder = 'inbox',
  bool read = false,
  bool bulk = false,
  bool attachments = false,
  String? status,
  String? importance,
  String? note,
  String createdAt = '2026-09-30T09:15:00Z',
  String text = 'Hello,\n\nhere are the numbers.\n\nAda',
  List<Map<String, dynamic>> files = const <Map<String, dynamic>>[],
  List<String> cc = const <String>[],
}) => <String, dynamic>{
  'id': id,
  'direction': direction,
  'thread_id': 'thread-$id',
  'from_address': from,
  'from_name': fromName,
  'to_addresses': to,
  'subject': subject,
  'snippet': snippet,
  'sender_trust': trust,
  'folder': folder,
  'read': read,
  'is_bulk': bulk,
  'has_attachments': attachments || files.isNotEmpty,
  'status': status ?? (direction == 'outbound' ? 'sent' : 'received'),
  'importance': importance,
  'agent_note': note,
  'created_at': createdAt,
  // Detail only; the fake strips these from list rows.
  'cc_addresses': cc,
  'text_body': text,
  'message_id': '<$id@example.com>',
  'in_reply_to': null,
  'attachments': files,
  'auth': <String, dynamic>{'spf': 'pass', 'dkim': 'pass', 'dmarc': 'pass'},
};

const Set<String> _detailOnly = <String>{
  'cc_addresses',
  'text_body',
  'message_id',
  'in_reply_to',
  'attachments',
  'auth',
};

/// A few mails over every folder, long enough to test a narrow window.
List<Map<String, dynamic>> fakeMailbox() => <Map<String, dynamic>>[
  fakeMail(
    id: 'm1',
    subject: 'Quarterly numbers for the board meeting next Thursday',
    note: 'Ada sent the Q3 numbers. Revenue is up; she asks for a reply.',
    importance: 'high',
    files: <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'a1',
        'filename': 'q3-revenue-by-region-final-v2.xlsx',
        'content_type': 'application/vnd.ms-excel',
        'size': 48213,
        'available': true,
      },
      <String, dynamic>{
        'id': 'a2',
        'filename': 'board-video.mp4',
        'content_type': 'video/mp4',
        'size': 52428800,
        'available': false,
        'too_large': true,
      },
    ],
  ),
  fakeMail(
    id: 'm2',
    from: 'me@example.com',
    fromName: null,
    trust: 'owner',
    subject: 'Book the train to Hamburg',
    snippet: 'Please book the early train on Friday.',
    read: true,
    createdAt: '2026-09-12T18:02:00Z',
  ),
  fakeMail(
    id: 'm3',
    from: 'noreply@verification.some-service.example',
    fromName: 'Some Service',
    trust: 'unknown',
    subject: 'Your code is 481516',
    snippet: 'Use 481516 to finish signing in.',
    note: 'A sign-in code from Some Service.',
    importance: 'low',
  ),
  fakeMail(
    id: 'm4',
    from: 'news@shop.example',
    fromName: 'Shop',
    trust: 'unknown',
    bulk: true,
    subject: 'Autumn sale',
    read: true,
  ),
  fakeMail(
    id: 'd1',
    direction: 'outbound',
    from: 'k7f3q9x2mh@chukagents.com',
    fromName: null,
    to: const <String>['ada@example.com'],
    trust: 'self',
    folder: 'drafts',
    status: 'draft',
    subject: 'Re: Quarterly numbers',
    snippet: 'Thanks Ada, the numbers look good.',
    text: 'Thanks Ada, the numbers look good.',
    read: true,
  ),
  fakeMail(
    id: 's1',
    direction: 'outbound',
    from: 'k7f3q9x2mh@chukagents.com',
    fromName: null,
    to: const <String>['bob@example.com', 'carol@example.com'],
    trust: 'self',
    folder: 'sent',
    status: 'bounced',
    subject: 'Meeting notes',
    read: true,
  ),
  fakeMail(
    id: 'r1',
    folder: 'archive',
    subject: 'Old invoice',
    read: true,
    createdAt: '2025-03-01T08:00:00Z',
  ),
];

class FakeAgentMailServer {
  FakeAgentMailServer({
    List<Map<String, dynamic>>? mails,
    List<Map<String, dynamic>>? contacts,
    this.mailboxStatus = 200,
    this.mailboxDetail,
    this.frozen = false,
    this.sendSuspended = false,
  }) : mails = mails ?? fakeMailbox(),
       contacts =
           contacts ??
           <Map<String, dynamic>>[
             <String, dynamic>{
               'address': 'ada@example.com',
               'trusted_inbound': true,
               'allowed_outbound': true,
               'blocked': false,
               'created_at': '2026-09-01T10:00:00Z',
             },
             <String, dynamic>{
               'address': '@very-long-company-domain-name.example',
               'trusted_inbound': true,
               'allowed_outbound': false,
               'blocked': false,
               'created_at': '2026-09-02T10:00:00Z',
             },
             <String, dynamic>{
               'address': 'spam@junk.example',
               'trusted_inbound': false,
               'allowed_outbound': false,
               'blocked': true,
               'created_at': '2026-09-03T10:00:00Z',
             },
           ];

  final List<Map<String, dynamic>> mails;
  final List<Map<String, dynamic>> contacts;

  /// 200, or the error status `GET /mailbox` answers with.
  int mailboxStatus;
  String? mailboxDetail;
  bool frozen;
  bool sendSuspended;

  /// When set, the list answers this many rows per page and a
  /// `next_before` cursor while more are left.
  int? pageSize;

  /// When set, a request for an older page waits for it.
  Future<void>? holdOlderPages;

  /// When set, `POST /drafts/{id}/send` answers with this.
  http.Response? sendResponse;

  /// When set, every call to a path containing the key answers with it.
  final Map<String, http.Response> failures = <String, http.Response>{};

  final List<http.Request> requests = <http.Request>[];

  /// The requests that were not the initial reads, as `METHOD path?query`.
  List<String> get calls => <String>[
    for (final http.Request r in requests)
      '${r.method} ${r.url.path.replaceFirst('/v1/agent-mail', '')}'
          '${r.url.hasQuery ? '?${r.url.query}' : ''}',
  ];

  List<Map<String, dynamic>> bodiesOf(String method, String path) =>
      <Map<String, dynamic>>[
        for (final http.Request r in requests)
          if (r.method == method && r.url.path == '/v1/agent-mail$path')
            jsonDecode(r.body) as Map<String, dynamic>,
      ];

  AgentMailService service() => AgentMailService(
    client: MockClient(handle),
    baseUrl: kFakeMailBase,
    token: () async => kFakeMailToken,
  );

  static http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  static http.Response errorResponse(int status, String detail) =>
      _json(<String, String>{'detail': detail}, status);

  Map<String, dynamic>? _find(String id) {
    for (final Map<String, dynamic> m in mails) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.headers['Authorization'] != 'Bearer $kFakeMailToken') {
      return errorResponse(401, 'unauthorized');
    }
    final String path = request.url.path.replaceFirst('/v1/agent-mail', '');
    for (final MapEntry<String, http.Response> f in failures.entries) {
      if (path.contains(f.key)) return f.value;
    }
    final List<String> parts = path
        .split('/')
        .where((String p) => p.isNotEmpty)
        .toList();
    final String method = request.method;

    if (path == '/mailbox' && method == 'GET') {
      if (mailboxStatus != 200) {
        return errorResponse(mailboxStatus, mailboxDetail ?? 'no_subscription');
      }
      return _json(<String, dynamic>{
        'address': 'k7f3q9x2mh@chukagents.com',
        'status': frozen ? 'frozen' : 'active',
        'send_suspended': sendSuspended,
        'created_at': '2026-09-01T10:00:00Z',
      });
    }

    if (path == '/messages' && method == 'GET') {
      final String folder = request.url.queryParameters['folder'] ?? 'inbox';
      final String? trust = request.url.queryParameters['trust'];
      final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
        for (final Map<String, dynamic> m in mails)
          if ((folder == 'all' || m['folder'] == folder) &&
              (trust == null ||
                  (trust == 'unknown'
                      ? m['sender_trust'] == 'unknown'
                      : m['sender_trust'] != 'unknown')))
            <String, dynamic>{
              for (final MapEntry<String, dynamic> e in m.entries)
                if (!_detailOnly.contains(e.key)) e.key: e.value,
            },
      ];
      final int? size = pageSize;
      if (size == null) {
        return _json(<String, dynamic>{'messages': rows, 'next_before': null});
      }
      final String? before = request.url.queryParameters['before'];
      if (before != null) await holdOlderPages;
      final int start = before == null
          ? 0
          : int.parse(before.replaceFirst('cursor-', ''));
      final int end = (start + size).clamp(0, rows.length);
      return _json(<String, dynamic>{
        'messages': rows.sublist(start.clamp(0, rows.length), end),
        'next_before': end < rows.length ? 'cursor-$end' : null,
      });
    }

    if (parts.length >= 2 && parts[0] == 'messages') {
      final Map<String, dynamic>? mail = _find(parts[1]);
      if (mail == null) return errorResponse(404, 'not_found');
      if (parts.length == 4 && parts[2] == 'attachments' && method == 'GET') {
        return http.Response.bytes(utf8.encode('bytes of ${parts[3]}'), 200);
      }
      if (parts.length == 2) {
        switch (method) {
          case 'GET':
            return _json(mail);
          case 'PATCH':
            final Map<String, dynamic> body =
                jsonDecode(request.body) as Map<String, dynamic>;
            mail.addAll(body);
            return _json(<String, dynamic>{'ok': true});
          case 'DELETE':
            mails.remove(mail);
            return http.Response('', 204);
        }
      }
    }

    if (parts.length == 3 &&
        parts[0] == 'drafts' &&
        parts[2] == 'send' &&
        method == 'POST') {
      final Map<String, dynamic>? mail = _find(parts[1]);
      if (mail == null) return errorResponse(404, 'not_found');
      final http.Response? canned = sendResponse;
      if (canned != null) return canned;
      mail['folder'] = 'sent';
      mail['status'] = 'sent';
      return _json(<String, dynamic>{'id': parts[1], 'status': 'sent'});
    }

    if (path == '/contacts') {
      switch (method) {
        case 'GET':
          return _json(<String, dynamic>{'contacts': contacts});
        case 'PUT':
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          contacts.removeWhere(
            (Map<String, dynamic> c) => c['address'] == body['address'],
          );
          contacts.add(<String, dynamic>{
            'trusted_inbound': false,
            'allowed_outbound': false,
            'blocked': false,
            'created_at': '2026-09-30T10:00:00Z',
            ...body,
          });
          return _json(contacts.last);
        case 'DELETE':
          final String? address = request.url.queryParameters['address'];
          contacts.removeWhere(
            (Map<String, dynamic> c) => c['address'] == address,
          );
          return http.Response('', 204);
      }
    }
    return errorResponse(404, 'not_found');
  }
}
