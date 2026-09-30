/// Client for the agent mailbox (docs/AGENT_MAIL.md §4.3).
///
/// Each paying user has one address for the agent. The API server keeps the
/// mail; the app only reads and manages it over REST with the account's
/// Supabase access token. Nothing is cached on the device.
///
/// The client is injectable: a test passes a `MockClient` and a fixed token,
/// the app uses [AgentMailService.instance].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// The mailbox is frozen when the subscription ended: no send, incoming mail
/// is dropped. A new subscription unfreezes the same address.
enum MailboxStatus { active, frozen }

/// How far the server trusts the sender of an incoming mail (§2).
enum MailTrust { owner, trusted, unknown }

/// The folders the server keeps. The wire name is [MailFolder.name].
enum MailFolder { inbox, archive, trash, sent, drafts, all }

/// The `trust` query of the message list.
enum MailTrustFilter { unknown, known }

/// What the restricted run thinks of a mail (§5.3).
enum MailImportance { low, normal, high }

MailTrust _trust(Object? raw) => switch (raw) {
  'owner' => MailTrust.owner,
  'trusted' => MailTrust.trusted,
  _ => MailTrust.unknown,
};

MailFolder? _folder(Object? raw) {
  for (final MailFolder f in MailFolder.values) {
    if (f.name == raw) return f;
  }
  return null;
}

MailImportance? _importance(Object? raw) => switch (raw) {
  'low' => MailImportance.low,
  'normal' => MailImportance.normal,
  'high' => MailImportance.high,
  _ => null,
};

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

String? _text(Object? raw) {
  if (raw is! String) return null;
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The value when it is a string, as is (no trim): subjects and bodies.
String? _raw(Object? raw) => raw is String ? raw : null;

bool _outbound(Object? raw) => raw == 'outbound' || raw == 'out';

List<String> _addresses(Object? raw) => raw is List
    ? <String>[
        for (final Object? a in raw)
          if (a is String && a.trim().isNotEmpty) a.trim(),
      ]
    : const <String>[];

int? _int(Object? raw) => raw is num ? raw.toInt() : null;

/// `GET /v1/agent-mail/mailbox`.
@immutable
class Mailbox {
  const Mailbox({
    required this.address,
    required this.status,
    this.sendSuspended = false,
    this.createdAt,
  });

  final String address;
  final MailboxStatus status;

  /// Three bounces or complaints in a day stop sending until it is cleared.
  final bool sendSuspended;
  final DateTime? createdAt;

  bool get frozen => status == MailboxStatus.frozen;

  factory Mailbox.fromJson(Map<String, dynamic> json) => Mailbox(
    address: _text(json['address']) ?? '',
    status: json['status'] == 'frozen'
        ? MailboxStatus.frozen
        : MailboxStatus.active,
    sendSuspended: json['send_suspended'] == true,
    createdAt: _time(json['created_at']),
  );
}

/// One row of the message list (`Summary`).
@immutable
class MailSummary {
  const MailSummary({
    required this.id,
    this.direction = 'in',
    this.threadId,
    this.fromAddress = '',
    this.fromName,
    this.toAddresses = const <String>[],
    this.subject = '',
    this.snippet,
    this.senderTrust = MailTrust.unknown,
    this.folder,
    this.read = false,
    this.isBulk = false,
    this.hasAttachments = false,
    this.status,
    this.importance,
    this.agentNote,
    this.createdAt,
  });

  final String id;

  /// `in` for received mail, `out` for sent mail and drafts.
  final String direction;
  final String? threadId;
  final String fromAddress;
  final String? fromName;
  final List<String> toAddresses;
  final String subject;
  final String? snippet;
  final MailTrust senderTrust;
  final MailFolder? folder;
  final bool read;
  final bool isBulk;
  final bool hasAttachments;

  /// Delivery state of an outgoing mail: `draft`, `sent`, `delivered`,
  /// `bounced`, `complained`, `failed`. Received mail carries its own value.
  final String? status;
  final MailImportance? importance;
  final String? agentNote;
  final DateTime? createdAt;

  bool get outgoing => direction == 'out';
  bool get isDraft => status == 'draft' || folder == MailFolder.drafts;

  /// Where the mail goes back to from the archive: drafts, sent or inbox,
  /// the one folder besides inbox, archive and trash that the server's
  /// `PATCH` takes for it. A sent mail moved to `inbox` would show there.
  MailFolder get homeFolder => status == 'draft'
      ? MailFolder.drafts
      : (outgoing ? MailFolder.sent : MailFolder.inbox);

  /// A sent mail that did not reach its recipient.
  bool get undeliverable =>
      status == 'bounced' || status == 'failed' || status == 'complained';

  factory MailSummary.fromJson(Map<String, dynamic> json) => MailSummary(
    id: '${json['id'] ?? ''}',
    // The server says `inbound` / `outbound`.
    direction: _outbound(json['direction']) ? 'out' : 'in',
    threadId: _text(json['thread_id']),
    fromAddress: _text(json['from_address']) ?? '',
    fromName: _text(json['from_name']),
    toAddresses: _addresses(json['to_addresses']),
    subject: _raw(json['subject']) ?? '',
    snippet: _text(json['snippet']),
    senderTrust: _trust(json['sender_trust']),
    folder: _folder(json['folder']),
    read: json['read'] == true,
    isBulk: json['is_bulk'] == true,
    hasAttachments: json['has_attachments'] == true,
    status: _text(json['status']),
    importance: _importance(json['importance']),
    agentNote: _text(json['agent_note']),
    createdAt: _time(json['created_at']),
  );

  MailSummary copyWith({bool? read, MailFolder? folder}) => MailSummary(
    id: id,
    direction: direction,
    threadId: threadId,
    fromAddress: fromAddress,
    fromName: fromName,
    toAddresses: toAddresses,
    subject: subject,
    snippet: snippet,
    senderTrust: senderTrust,
    folder: folder ?? this.folder,
    read: read ?? this.read,
    isBulk: isBulk,
    hasAttachments: hasAttachments,
    status: status,
    importance: importance,
    agentNote: agentNote,
    createdAt: createdAt,
  );
}

/// One stored attachment of a mail.
@immutable
class MailAttachment {
  const MailAttachment({
    required this.id,
    required this.filename,
    this.contentType,
    this.size,
    this.available = true,
    this.tooLarge = false,
  });

  final String id;
  final String filename;
  final String? contentType;
  final int? size;

  /// False when the server holds no copy: it is listed, not stored.
  final bool available;

  /// Why it is not stored: over the size limit (`too_large`). Unavailable
  /// and not too large means the download from the provider failed.
  final bool tooLarge;

  factory MailAttachment.fromJson(Map<String, dynamic> json) => MailAttachment(
    id: '${json['id'] ?? ''}',
    filename: _text(json['filename']) ?? 'attachment',
    contentType: _text(json['content_type']),
    size: _int(json['size']),
    available: json['available'] != false,
    tooLarge: json['too_large'] == true,
  );
}

/// SPF, DKIM and DMARC results of an incoming mail.
@immutable
class MailAuth {
  const MailAuth({this.spf, this.dkim, this.dmarc});

  final String? spf;
  final String? dkim;
  final String? dmarc;

  bool get isEmpty => spf == null && dkim == null && dmarc == null;

  factory MailAuth.fromJson(Object? raw) {
    if (raw is! Map) return const MailAuth();
    return MailAuth(
      spf: _text(raw['spf']),
      dkim: _text(raw['dkim']),
      dmarc: _text(raw['dmarc']),
    );
  }
}

/// `GET /v1/agent-mail/messages/{id}`: the summary plus the body.
@immutable
class MailMessage {
  const MailMessage({
    required this.summary,
    this.ccAddresses = const <String>[],
    this.textBody = '',
    this.messageId,
    this.inReplyTo,
    this.attachments = const <MailAttachment>[],
    this.auth = const MailAuth(),
  });

  final MailSummary summary;
  final List<String> ccAddresses;

  /// The plain text. The app never renders the HTML part.
  final String textBody;
  final String? messageId;
  final String? inReplyTo;
  final List<MailAttachment> attachments;
  final MailAuth auth;

  String get id => summary.id;

  factory MailMessage.fromJson(Map<String, dynamic> json) {
    final Object? attachments = json['attachments'];
    return MailMessage(
      summary: MailSummary.fromJson(json),
      ccAddresses: _addresses(json['cc_addresses']),
      textBody: _raw(json['text_body']) ?? '',
      messageId: _text(json['message_id']),
      inReplyTo: _text(json['in_reply_to']),
      attachments: attachments is List
          ? <MailAttachment>[
              for (final Object? a in attachments)
                if (a is Map<String, dynamic>) MailAttachment.fromJson(a),
            ]
          : const <MailAttachment>[],
      auth: MailAuth.fromJson(json['auth']),
    );
  }
}

/// One page of the message list. [nextBefore] goes back as `before` for the
/// next page; null means there is no more.
@immutable
class MailPage {
  const MailPage({required this.messages, this.nextBefore});

  final List<MailSummary> messages;
  final String? nextBefore;

  factory MailPage.fromJson(Map<String, dynamic> json) {
    final Object? rows = json['messages'];
    return MailPage(
      messages: rows is List
          ? <MailSummary>[
              for (final Object? r in rows)
                if (r is Map<String, dynamic>) MailSummary.fromJson(r),
            ]
          : const <MailSummary>[],
      nextBefore: _text(json['next_before']),
    );
  }
}

/// An address or an `@domain.tld` the mailbox knows.
@immutable
class MailContact {
  const MailContact({
    required this.address,
    this.trustedInbound = false,
    this.allowedOutbound = false,
    this.blocked = false,
    this.createdAt,
  });

  final String address;

  /// Mail from here starts a full run.
  final bool trustedInbound;

  /// The agent may mail here without a draft.
  final bool allowedOutbound;

  /// Mail from here is dropped.
  final bool blocked;
  final DateTime? createdAt;

  bool get isDomain => address.startsWith('@');

  factory MailContact.fromJson(Map<String, dynamic> json) => MailContact(
    address: _text(json['address']) ?? '',
    trustedInbound: json['trusted_inbound'] == true,
    allowedOutbound: json['allowed_outbound'] == true,
    blocked: json['blocked'] == true,
    createdAt: _time(json['created_at']),
  );
}

/// What `POST /v1/agent-mail/drafts/{id}/send` answered.
@immutable
class MailSendResult {
  const MailSendResult({required this.id, required this.status, this.reason});

  final String id;

  /// `sent`, or `draft` when the server kept it as a draft.
  final String status;
  final String? reason;

  bool get sent => status == 'sent';

  factory MailSendResult.fromJson(Map<String, dynamic> json) => MailSendResult(
    id: '${json['id'] ?? ''}',
    status: _text(json['status']) ?? 'sent',
    reason: _text(json['reason']),
  );
}

/// A non-2xx answer, or no answer. [code] is the FastAPI `detail` code
/// (`no_subscription`, `mailbox_frozen`, `rate_limited`, ...).
class AgentMailException implements Exception {
  const AgentMailException(this.statusCode, this.code);

  /// 0 when the request did not reach the server.
  final int statusCode;
  final String code;

  static const String notSignedIn = 'not_signed_in';
  static const String network = 'network';

  bool get noSubscription => statusCode == 402 || code == 'no_subscription';
  bool get unavailable => code == 'agent_mail_unavailable';

  @override
  String toString() => 'AgentMailException($statusCode): $code';
}

/// Hands out a usable access token, or null when signed out.
typedef AgentMailTokenSource = Future<String?> Function();

/// The live account's token: refreshed only when it is about to lapse.
Future<String?> supabaseAgentMailToken() async {
  if (!SupabaseService.isInitialized) return null;
  try {
    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    return session?.accessToken;
  } catch (_) {
    try {
      return SupabaseService.auth.currentSession?.accessToken;
    } catch (_) {
      return null;
    }
  }
}

class AgentMailService {
  AgentMailService({
    http.Client? client,
    String? baseUrl,
    AgentMailTokenSource? token,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client, // ignore: prefer_initializing_formals
       _baseUrl = baseUrl, // ignore: prefer_initializing_formals
       _token = token ?? supabaseAgentMailToken;

  /// The app's client: live token, default base URL, one client per call.
  static final AgentMailService instance = AgentMailService();

  final http.Client? _client;
  final String? _baseUrl;
  final AgentMailTokenSource _token;
  final Duration timeout;

  static const String _root = '/v1/agent-mail';

  Uri _uri(String path, [Map<String, String>? query]) {
    final Uri uri = Uri.parse(
      '${_baseUrl ?? ApiConfigService.apiBaseUrl}$_root$path',
    );
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  static String _seg(String value) => Uri.encodeComponent(value);

  /// Sends one request with the bearer token and gives back the response
  /// when it is 2xx. Anything else becomes an [AgentMailException].
  Future<http.Response> _send(String method, Uri uri, {Object? body}) async {
    final String? token = await _token();
    if (token == null || token.isEmpty) {
      throw const AgentMailException(401, AgentMailException.notSignedIn);
    }
    final http.Request request = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final bool owned = _client == null;
    final http.Client client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      ).timeout(timeout);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          'agent mail: $method ${uri.path} failed '
          '(${error.runtimeType})',
        );
      }
      throw const AgentMailException(0, AgentMailException.network);
    } finally {
      if (owned) client.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (kDebugMode) {
        debugPrint(
          'agent mail: $method ${uri.path} -> '
          '${response.statusCode}',
        );
      }
      throw AgentMailException(response.statusCode, _detail(response));
    }
    return response;
  }

  static String _detail(http.Response response) {
    try {
      final Object? data = jsonDecode(response.body);
      if (data is Map) {
        final Object? detail = data['detail'];
        if (detail is String && detail.isNotEmpty) return detail;
        if (detail is Map && detail['code'] is String) {
          return detail['code'] as String;
        }
      }
    } catch (_) {}
    return 'http_${response.statusCode}';
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final Object? data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    throw AgentMailException(response.statusCode, 'bad_response');
  }

  /// The user's mailbox. The server makes it on the first call when the
  /// user has a subscription; without one this throws `402 no_subscription`.
  Future<Mailbox> mailbox() async =>
      Mailbox.fromJson(_json(await _send('GET', _uri('/mailbox'))));

  /// One page of mail, newest first.
  Future<MailPage> messages({
    MailFolder folder = MailFolder.inbox,
    MailTrustFilter? trust,
    bool? undelivered,
    int? limit,
    String? before,
  }) async {
    final Map<String, String> query = <String, String>{
      'folder': folder.name,
      if (trust != null) 'trust': trust.name,
      if (undelivered != null) 'undelivered': '$undelivered',
      if (limit != null) 'limit': '${limit.clamp(1, 100)}',
      if (before != null && before.isNotEmpty) 'before': before,
    };
    return MailPage.fromJson(
      _json(await _send('GET', _uri('/messages', query))),
    );
  }

  /// The full mail, text body and attachment list included.
  Future<MailMessage> message(String id) async => MailMessage.fromJson(
    _json(await _send('GET', _uri('/messages/${_seg(id)}'))),
  );

  /// Moves a mail or sets its read mark.
  Future<void> update(String id, {MailFolder? folder, bool? read}) async {
    final Map<String, Object> body = <String, Object>{
      if (folder != null) 'folder': folder.name,
      'read': ?read,
    };
    if (body.isEmpty) return;
    await _send('PATCH', _uri('/messages/${_seg(id)}'), body: body);
  }

  /// Deletes the mail and its stored attachments. This cannot be undone.
  Future<void> delete(String id) async {
    await _send('DELETE', _uri('/messages/${_seg(id)}'));
  }

  /// The bytes of one stored attachment.
  Future<Uint8List> attachment(String messageId, String attachmentId) async {
    final http.Response response = await _send(
      'GET',
      _uri('/messages/${_seg(messageId)}/attachments/${_seg(attachmentId)}'),
    );
    return response.bodyBytes;
  }

  /// Sends a draft the agent wrote. [text] and [subject] replace the draft's
  /// own when the user edited them. The recipients become
  /// `allowed_outbound` contacts on the server.
  Future<MailSendResult> sendDraft(
    String id, {
    String? text,
    String? subject,
  }) async {
    final http.Response response = await _send(
      'POST',
      _uri('/drafts/${_seg(id)}/send'),
      body: <String, Object>{'text': ?text, 'subject': ?subject},
    );
    try {
      final Object? data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) return MailSendResult.fromJson(data);
    } catch (_) {}
    return MailSendResult(id: id, status: 'sent');
  }

  /// Every contact: trusted, allowed and blocked.
  Future<List<MailContact>> contacts() async {
    final Object? rows = _json(
      await _send('GET', _uri('/contacts')),
    )['contacts'];
    return rows is List
        ? <MailContact>[
            for (final Object? r in rows)
              if (r is Map<String, dynamic>) MailContact.fromJson(r),
          ]
        : const <MailContact>[];
  }

  /// Adds or changes a contact. [address] is an address or `@domain.tld`.
  Future<void> putContact(
    String address, {
    bool? trustedInbound,
    bool? allowedOutbound,
    bool? blocked,
  }) async {
    await _send(
      'PUT',
      _uri('/contacts'),
      body: <String, Object>{
        'address': address.trim(),
        'trusted_inbound': ?trustedInbound,
        'allowed_outbound': ?allowedOutbound,
        'blocked': ?blocked,
      },
    );
  }

  /// "Trust a sender" in the app sets both directions (§2, rule 4).
  Future<void> trust(String address) => putContact(
    address,
    trustedInbound: true,
    allowedOutbound: true,
    blocked: false,
  );

  /// Mail from a blocked address is dropped, and the agent may not mail it.
  Future<void> block(String address) => putContact(
    address,
    trustedInbound: false,
    allowedOutbound: false,
    blocked: true,
  );

  /// Removes the contact. Its mail is then `unknown` again.
  Future<void> deleteContact(String address) async {
    await _send(
      'DELETE',
      _uri('/contacts', <String, String>{'address': address.trim()}),
    );
  }
}

/// A plain address or `@domain.tld`, as `PUT /contacts` takes it.
bool isValidMailContactAddress(String raw) {
  final String value = raw.trim();
  final RegExp domain = RegExp(
    r'^@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$',
  );
  final RegExp address = RegExp(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$",
  );
  return domain.hasMatch(value) || address.hasMatch(value);
}
