/// An in-memory agent mail server (docs/AGENT_MAIL.md §5.3) behind a
/// `MockClient`, for the service, page and layout tests.
///
/// It behaves like the v2 server: every content field leaves it sealed to
/// the mailbox's mail key (§3.2), as a JSON string holding the text
/// envelope; the key row holds the private key sealed with a stand-in for
/// the chuk key ([FakeChukSecretBox]); a mailbox without a key answers
/// `needs_key`. The fixtures stay plain text, so a test reads and asserts
/// them directly.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/agents/agent_mail_crypto.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';

const String kFakeMailBase = 'https://api.test';
const String kFakeMailToken = 'jwt-test';
const String kFakeMailUser = 'user-test';

/// The raw private key of the fake mailbox's mail key.
final List<int> kFakeMailPrivateKey = List<int>.generate(32, (int i) => i + 1);

/// A stand-in for `EncryptionService`: reversible, marked, and lockable. It
/// is no cipher; the tests only need to see that the private key goes up
/// sealed and comes back opened.
class FakeChukSecretBox implements AgentMailSecretBox {
  static const String prefix = 'chuk-sealed:';

  /// When true, every call fails the way a locked chuk key does.
  bool locked = false;
  int seals = 0;
  int opens = 0;

  static String sealSync(String plaintext) =>
      '$prefix${base64Encode(utf8.encode(plaintext))}';

  @override
  Future<String> seal(String plaintext) async {
    if (locked) {
      throw const AgentMailException(0, AgentMailException.keyLocked);
    }
    seals++;
    return sealSync(plaintext);
  }

  @override
  Future<String> open(String sealed) async {
    if (locked) {
      throw const AgentMailException(0, AgentMailException.keyLocked);
    }
    opens++;
    if (!sealed.startsWith(prefix)) throw StateError('not sealed here');
    return utf8.decode(base64Decode(sealed.substring(prefix.length)));
  }
}

/// A mail as the fixtures keep it: plain text. The server seals it on the
/// way out. The values are the server's: `inbound` / `outbound`, `self` for
/// the agent's own mail, `received` for the status of incoming mail.
///
/// [broken] seals the summary to some other key, so it does not open: the
/// row a test uses for the unseal error.
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
  String? inReplyTo,
  String? references,
  bool? dkimAligned = true,
  String? dkimDomain = 'example.com',
  bool broken = false,
}) => <String, dynamic>{
  'id': id,
  'direction': direction,
  'thread_id': 'thread-$id',
  'from_address': from,
  'from_name': fromName,
  'to': to,
  'subject': subject,
  'snippet': snippet,
  'sender_trust': trust,
  'folder': folder,
  'read': read,
  'is_bulk': bulk,
  'has_attachments': attachments || files.isNotEmpty,
  'attachment_count': files.length,
  'status': status ?? (direction == 'outbound' ? 'sent' : 'received'),
  'importance': importance,
  'draft_reason': status == 'draft' ? 'recipient_not_allowed' : null,
  'note': note,
  'created_at': createdAt,
  'text': text,
  'cc': cc,
  'message_id': '<$id@example.com>',
  'in_reply_to': inReplyTo,
  'references': references,
  'attachments': files,
  'auth': <String, dynamic>{
    'dkim_aligned': dkimAligned,
    'dkim_domain': dkimDomain,
  },
  'broken': broken,
};

/// The opened summary of a fixture, as the service would hand it out. For a
/// page that is opened straight from a row.
MailSummary fakeSummary(Map<String, dynamic> m) => MailSummary(
  id: m['id'] as String,
  outgoing: m['direction'] == 'outbound',
  threadId: m['thread_id'] as String?,
  fromAddress: m['broken'] == true ? '' : m['from_address'] as String,
  fromName: m['broken'] == true ? null : m['from_name'] as String?,
  toAddresses: m['broken'] == true
      ? const <String>[]
      : List<String>.from(m['to'] as List),
  subject: m['broken'] == true ? '' : m['subject'] as String,
  snippet: m['broken'] == true ? null : m['snippet'] as String?,
  senderTrust: switch (m['sender_trust']) {
    'owner' => MailTrust.owner,
    'trusted' => MailTrust.trusted,
    'self' => MailTrust.self,
    _ => MailTrust.unknown,
  },
  folder: MailFolder.values.firstWhere((MailFolder f) => f.name == m['folder']),
  read: m['read'] == true,
  isBulk: m['is_bulk'] == true,
  hasAttachments: m['has_attachments'] == true,
  attachmentCount: m['attachment_count'] as int,
  status: m['status'] as String?,
  importance: switch (m['importance']) {
    'low' => MailImportance.low,
    'normal' => MailImportance.normal,
    'high' => MailImportance.high,
    _ => null,
  },
  draftReason: m['draft_reason'] as String?,
  agentNote: m['note'] as String?,
  createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
  unreadable: m['broken'] == true,
);

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
      },
      <String, dynamic>{
        'id': 'a2',
        'filename': 'board-video.mp4',
        'content_type': 'video/mp4',
        'size': 52428800,
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
    dkimAligned: false,
    dkimDomain: null,
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
    cc: const <String>['bob@example.com'],
    trust: 'self',
    folder: 'drafts',
    status: 'draft',
    subject: 'Re: Quarterly numbers',
    snippet: 'Thanks Ada, the numbers look good.',
    text: 'Thanks Ada, the numbers look good.',
    inReplyTo: '<m1@example.com>',
    references: '<m0@example.com> <m1@example.com>',
    read: true,
    dkimAligned: null,
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
    dkimAligned: null,
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
    bool hasKey = true,
    FakeChukSecretBox? secretBox,
  }) : mails = mails ?? fakeMailbox(),
       secretBox = secretBox ?? FakeChukSecretBox(),
       contacts =
           contacts ??
           <Map<String, dynamic>>[
             <String, dynamic>{
               'id': 'c1',
               'address': 'ada@example.com',
               'trusted_inbound': true,
               'allowed_outbound': true,
               'blocked': false,
               'created_at': '2026-09-01T10:00:00Z',
             },
             <String, dynamic>{
               'id': 'c2',
               'address': '@very-long-company-domain-name.example',
               'trusted_inbound': true,
               'allowed_outbound': false,
               'blocked': false,
               'created_at': '2026-09-02T10:00:00Z',
             },
             <String, dynamic>{
               'id': 'c3',
               'address': 'spam@junk.example',
               'trusted_inbound': false,
               'allowed_outbound': false,
               'blocked': true,
               'created_at': '2026-09-03T10:00:00Z',
             },
           ] {
    if (hasKey) {
      keyRow = <String, String>{
        // Filled in on the first request: the public key needs an await.
        'private_key_sealed': FakeChukSecretBox.sealSync(
          base64Encode(kFakeMailPrivateKey),
        ),
      };
    }
  }

  final List<Map<String, dynamic>> mails;
  final List<Map<String, dynamic>> contacts;

  /// The chuk key stand-in the services of this server use.
  final FakeChukSecretBox secretBox;

  /// `{public_key, private_key_sealed}`, or null: no mail key yet.
  Map<String, String>? keyRow;

  /// 200, or the error status `GET /mailbox` answers with.
  int mailboxStatus;
  String? mailboxDetail;
  bool frozen;
  bool sendSuspended;

  /// The signed-in user the services report.
  String? userId = kFakeMailUser;

  /// When set, the list answers this many rows per page and a
  /// `next_before` cursor while more are left.
  int? pageSize;

  /// When set, a request for an older page waits for it.
  Future<void>? holdOlderPages;

  /// When set, `POST /drafts/{id}/send` answers with this.
  http.Response? sendResponse;

  /// When set, every call to a path containing the key answers with it.
  final Map<String, http.Response> failures = <String, http.Response>{};

  /// The plain bytes of an attachment, by id. Unset: `bytes of <id>`.
  final Map<String, List<int>> blobs = <String, List<int>>{};

  final List<http.Request> requests = <http.Request>[];

  int _nextContact = 100;

  /// The requests, as `METHOD path?query`.
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
    userId: () => userId,
    secretBox: secretBox,
  );

  Map<String, dynamic>? fixture(String id) {
    for (final Map<String, dynamic> m in mails) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  /// The opened summary of mail [id], as a page gets it from the list.
  MailSummary summaryOf(String id) => fakeSummary(fixture(id)!);

  static http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  static http.Response errorResponse(int status, String detail) =>
      _json(<String, String>{'detail': detail}, status);

  /// The public key the server seals to.
  Future<List<int>> _publicKey() async {
    final Map<String, String> row = keyRow!;
    final String? known = row['public_key'];
    if (known != null) return base64Decode(known);
    final AgentMailKeyPair key = await AgentMailKeyPair.fromPrivateKey(
      kFakeMailPrivateKey,
    );
    row['public_key'] = key.publicKeyBase64;
    return key.publicKey;
  }

  /// A sealed field as the server sends it: the text envelope as a string.
  Future<String> _seal(Map<String, dynamic> doc, {bool broken = false}) async {
    final List<int> to = broken
        ? (await AgentMailKeyPair.generate()).publicKey
        : await _publicKey();
    return sealAgentMailText(jsonEncode(doc), to);
  }

  /// A fixture as the list sends it: plain columns and the sealed parts.
  Future<Map<String, dynamic>> _summaryRow(Map<String, dynamic> m) async {
    final String? note = m['note'] as String?;
    return <String, dynamic>{
      for (final String k in <String>[
        'id',
        'direction',
        'thread_id',
        'sender_trust',
        'folder',
        'read',
        'is_bulk',
        'has_attachments',
        'attachment_count',
        'status',
        'importance',
        'draft_reason',
        'created_at',
      ])
        k: m[k],
      'sealed_summary': await _seal(<String, dynamic>{
        'subject': m['subject'],
        'from_address': m['from_address'],
        'from_name': m['from_name'],
        'to': m['to'],
        'snippet': m['snippet'],
      }, broken: m['broken'] == true),
      'agent_note_sealed': note == null
          ? null
          : await _seal(<String, dynamic>{'note': note}),
    };
  }

  Future<Map<String, dynamic>> _messageRow(Map<String, dynamic> m) async =>
      <String, dynamic>{
        ...await _summaryRow(m),
        'sealed_body': await _seal(<String, dynamic>{
          'text': m['text'],
          'cc': m['cc'],
          'message_id': m['message_id'],
          'in_reply_to': m['in_reply_to'],
          'references': m['references'],
          'codes': const <String>[],
          'links': const <String>[],
          'attachments': m['attachments'],
          'auth': m['auth'],
        }, broken: m['broken'] == true),
      };

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
        .map(Uri.decodeComponent)
        .toList();
    final String method = request.method;

    if (path == '/mailbox' && method == 'GET') {
      if (mailboxStatus != 200) {
        return errorResponse(mailboxStatus, mailboxDetail ?? 'no_subscription');
      }
      return _json(<String, dynamic>{
        'address': 'k7f3q9x2mh@chukagents.com',
        'status': keyRow == null ? 'needs_key' : (frozen ? 'frozen' : 'active'),
        'send_suspended': sendSuspended,
        'created_at': '2026-09-01T10:00:00Z',
      });
    }

    if (path == '/key') {
      switch (method) {
        case 'GET':
          if (keyRow == null) return errorResponse(404, 'no_key');
          await _publicKey();
          return _json(keyRow!);
        case 'PUT':
          if (keyRow != null) return errorResponse(409, 'key_exists');
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          keyRow = <String, String>{
            'public_key': body['public_key'] as String,
            'private_key_sealed': body['private_key_sealed'] as String,
          };
          return _json(<String, dynamic>{'ok': true});
      }
    }

    // Every route that seals or opens needs the key.
    if (keyRow == null &&
        (path.startsWith('/messages') ||
            path.startsWith('/contacts') ||
            path.startsWith('/drafts'))) {
      return errorResponse(409, 'needs_key');
    }

    if (path == '/messages' && method == 'GET') {
      final String folder = request.url.queryParameters['folder'] ?? 'inbox';
      final String? trust = request.url.queryParameters['trust'];
      final List<Map<String, dynamic>> matching = <Map<String, dynamic>>[
        for (final Map<String, dynamic> m in mails)
          if ((folder == 'all' || m['folder'] == folder) &&
              (trust == null ||
                  (trust == 'unknown'
                      ? m['sender_trust'] == 'unknown'
                      : m['sender_trust'] != 'unknown')))
            m,
      ];
      final int? size = pageSize;
      int start = 0;
      int end = matching.length;
      if (size != null) {
        final String? before = request.url.queryParameters['before'];
        if (before != null) await holdOlderPages;
        start = before == null
            ? 0
            : int.parse(before.replaceFirst('cursor-', ''));
        start = start.clamp(0, matching.length);
        end = (start + size).clamp(0, matching.length);
      }
      return _json(<String, dynamic>{
        'messages': <Map<String, dynamic>>[
          for (final Map<String, dynamic> m in matching.sublist(start, end))
            await _summaryRow(m),
        ],
        'next_before': size != null && end < matching.length
            ? 'cursor-$end'
            : null,
      });
    }

    if (parts.length >= 2 && parts[0] == 'messages') {
      final Map<String, dynamic>? mail = fixture(parts[1]);
      if (mail == null) return errorResponse(404, 'not_found');
      if (parts.length == 4 && parts[2] == 'attachments' && method == 'GET') {
        // A file entry with `broken: true` is sealed to some other key.
        final bool broken =
            mail['broken'] == true ||
            (mail['attachments'] as List).any(
              (Object? f) =>
                  f is Map && f['id'] == parts[3] && f['broken'] == true,
            );
        final Uint8List sealed = await sealAgentMailBytes(
          blobs[parts[3]] ?? utf8.encode('bytes of ${parts[3]}'),
          broken
              ? (await AgentMailKeyPair.generate()).publicKey
              : await _publicKey(),
        );
        return http.Response.bytes(sealed, 200);
      }
      if (parts.length == 2) {
        switch (method) {
          case 'GET':
            return _json(await _messageRow(mail));
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
      final Map<String, dynamic>? mail = fixture(parts[1]);
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
          return _json(<String, dynamic>{
            'contacts': <Map<String, dynamic>>[
              for (final Map<String, dynamic> c in contacts)
                <String, dynamic>{
                  'id': c['id'],
                  'label_sealed': await _seal(<String, dynamic>{
                    'address': c['address'],
                  }, broken: c['broken'] == true),
                  'trusted_inbound': c['trusted_inbound'],
                  'allowed_outbound': c['allowed_outbound'],
                  'blocked': c['blocked'],
                  'created_at': c['created_at'],
                },
            ],
          });
        case 'PUT':
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          final Map<String, dynamic>? old = contacts
              .where(
                (Map<String, dynamic> c) => c['address'] == body['address'],
              )
              .firstOrNull;
          contacts.remove(old);
          contacts.add(<String, dynamic>{
            'id': old?['id'] ?? 'c${_nextContact++}',
            'trusted_inbound': false,
            'allowed_outbound': false,
            'blocked': false,
            'created_at': '2026-09-30T10:00:00Z',
            ...body,
          });
          return _json(<String, dynamic>{'contact': contacts.last['id']});
      }
    }
    if (parts.length == 2 && parts[0] == 'contacts' && method == 'DELETE') {
      contacts.removeWhere((Map<String, dynamic> c) => c['id'] == parts[1]);
      return http.Response('', 204);
    }
    return errorResponse(404, 'not_found');
  }
}
