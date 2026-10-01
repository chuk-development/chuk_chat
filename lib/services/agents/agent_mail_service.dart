/// Client for the agent mailbox (docs/AGENT_MAIL.md §5.3, §8).
///
/// Each paying user has one address for the agent. The API server keeps the
/// mail, but every content field is sealed to the user's mail key (§3): the
/// app makes that X25519 key, keeps its private half sealed with the user's
/// chuk key on the server, and opens subjects, bodies, notes, contacts and
/// attachments here. Nothing is cached on the device; the opened mail key
/// lives in memory for the signed-in user only.
///
/// The client is injectable: a test passes a `MockClient`, a fixed token, a
/// user id and a [AgentMailSecretBox]; the app uses [AgentMailService.instance].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/agents/agent_mail_crypto.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// `frozen`: the subscription ended, no send, incoming mail is rejected.
/// `needsKey`: the mailbox has no mail key yet; the app makes it (§3.1).
enum MailboxStatus { active, frozen, needsKey }

/// How far the server trusts the sender of a mail (§2). [self] is the
/// agent's own sent mail and drafts: the server sets it on every outgoing
/// row (§7), except a reply derived from unknown mail, which stays
/// [unknown].
enum MailTrust { owner, trusted, unknown, self }

/// The folders the server keeps. The wire name is [MailFolder.name].
enum MailFolder { inbox, archive, trash, sent, drafts, all }

/// The `trust` query of the message list.
enum MailTrustFilter { unknown, known }

/// What the restricted run thinks of a mail.
enum MailImportance { low, normal, high }

MailTrust _trust(Object? raw) => switch (raw) {
  'owner' => MailTrust.owner,
  'trusted' => MailTrust.trusted,
  'self' => MailTrust.self,
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

List<String> _addresses(Object? raw) => raw is List
    ? <String>[
        for (final Object? a in raw)
          if (a is String && a.trim().isNotEmpty) a.trim(),
      ]
    : const <String>[];

int? _int(Object? raw) => raw is num ? raw.toInt() : null;

/// Opens one sealed JSON document of a row. Null when the row has no such
/// field; an [AgentMailSealException] when it is there and does not open.
Future<Map<String, dynamic>?> _openDocument(
  Object? sealed,
  AgentMailKeyPair key,
) async {
  if (sealed == null) return null;
  return unsealAgentMailJson(sealed, key);
}

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

  /// Three permanent bounces in a day stop sending until it is cleared.
  final bool sendSuspended;
  final DateTime? createdAt;

  bool get frozen => status == MailboxStatus.frozen;
  bool get needsKey => status == MailboxStatus.needsKey;

  factory Mailbox.fromJson(Map<String, dynamic> json) => Mailbox(
    address: _text(json['address']) ?? '',
    status: switch (json['status']) {
      'frozen' => MailboxStatus.frozen,
      'needs_key' => MailboxStatus.needsKey,
      _ => MailboxStatus.active,
    },
    sendSuspended: json['send_suspended'] == true,
    createdAt: _time(json['created_at']),
  );
}

/// One row of the message list (`Summary`), its sealed parts opened.
@immutable
class MailSummary {
  const MailSummary({
    required this.id,
    this.outgoing = false,
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
    this.attachmentCount = 0,
    this.status,
    this.importance,
    this.draftReason,
    this.agentNote,
    this.createdAt,
    this.unreadable = false,
  });

  final String id;

  /// A sent mail or a draft (`direction: outbound`).
  final bool outgoing;
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
  final int attachmentCount;

  /// Delivery state of an outgoing mail: `draft`, `sent`, `delivered`,
  /// `bounced`, `failed`. Received mail carries its own value.
  final String? status;
  final MailImportance? importance;

  /// Why the server kept an outgoing mail as a draft.
  final String? draftReason;
  final String? agentNote;
  final DateTime? createdAt;

  /// `sealed_summary` or `agent_note_sealed` did not open with the mail key.
  /// What did open is still set; the rest is empty.
  final bool unreadable;

  bool get isDraft => status == 'draft' || folder == MailFolder.drafts;

  /// Where the mail goes back to from the archive: drafts, sent or inbox,
  /// the one folder besides inbox, archive and trash that the server's
  /// `PATCH` takes for it. A sent mail moved to `inbox` would show there.
  MailFolder get homeFolder => status == 'draft'
      ? MailFolder.drafts
      : (outgoing ? MailFolder.sent : MailFolder.inbox);

  /// A sent mail that did not reach its recipient.
  bool get undeliverable => status == 'bounced' || status == 'failed';

  /// Reads a `Summary` row and opens `sealed_summary` and
  /// `agent_note_sealed` with [key]. A part that does not open sets
  /// [unreadable]; it never throws for that.
  static Future<MailSummary> open(
    Map<String, dynamic> json,
    AgentMailKeyPair key,
  ) async {
    bool unreadable = false;
    Map<String, dynamic> summary = const <String, dynamic>{};
    try {
      final Map<String, dynamic>? opened = await _openDocument(
        json['sealed_summary'],
        key,
      );
      if (opened == null) {
        unreadable = true;
      } else {
        summary = opened;
      }
    } on AgentMailSealException {
      unreadable = true;
    }
    String? note;
    try {
      note = _text(
        (await _openDocument(json['agent_note_sealed'], key))?['note'],
      );
    } on AgentMailSealException {
      unreadable = true;
    }
    return MailSummary(
      id: '${json['id'] ?? ''}',
      outgoing: json['direction'] == 'outbound',
      threadId: _text(json['thread_id']),
      fromAddress: _text(summary['from_address']) ?? '',
      fromName: _text(summary['from_name']),
      toAddresses: _addresses(summary['to']),
      subject: _raw(summary['subject']) ?? '',
      snippet: _text(summary['snippet']),
      senderTrust: _trust(json['sender_trust']),
      folder: _folder(json['folder']),
      read: json['read'] == true,
      isBulk: json['is_bulk'] == true,
      hasAttachments: json['has_attachments'] == true,
      attachmentCount: _int(json['attachment_count']) ?? 0,
      status: _text(json['status']),
      importance: _importance(json['importance']),
      draftReason: _text(json['draft_reason']),
      agentNote: note,
      createdAt: _time(json['created_at']),
      unreadable: unreadable,
    );
  }

  MailSummary copyWith({bool? read, MailFolder? folder}) => MailSummary(
    id: id,
    outgoing: outgoing,
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
    attachmentCount: attachmentCount,
    status: status,
    importance: importance,
    draftReason: draftReason,
    agentNote: agentNote,
    createdAt: createdAt,
    unreadable: unreadable,
  );
}

/// One attachment of a mail, as `sealed_body.attachments` lists it.
@immutable
class MailAttachment {
  const MailAttachment({
    required this.id,
    required this.filename,
    this.contentType,
    this.size,
    this.tooLarge = false,
  });

  final String id;
  final String filename;
  final String? contentType;
  final int? size;

  /// Over the size limit (§4): listed, but the server keeps no copy.
  final bool tooLarge;

  bool get available => !tooLarge;

  factory MailAttachment.fromJson(Map<String, dynamic> json) => MailAttachment(
    id: '${json['id'] ?? ''}',
    filename: _text(json['filename']) ?? 'attachment',
    contentType: _text(json['content_type']),
    size: _int(json['size']),
    tooLarge: json['too_large'] == true,
  );
}

/// The DKIM result of an incoming mail (§2): did a signature whose `d=`
/// domain aligns with the From domain pass.
@immutable
class MailAuth {
  const MailAuth({this.dkimAligned, this.dkimDomain});

  final bool? dkimAligned;
  final String? dkimDomain;

  bool get isEmpty => dkimAligned == null;

  factory MailAuth.fromJson(Object? raw) {
    if (raw is! Map) return const MailAuth();
    final Object? aligned = raw['dkim_aligned'];
    return MailAuth(
      dkimAligned: aligned is bool ? aligned : null,
      dkimDomain: _text(raw['dkim_domain']),
    );
  }
}

/// `GET /v1/agent-mail/messages/{id}`: the summary plus the opened body.
@immutable
class MailMessage {
  const MailMessage({
    required this.summary,
    this.ccAddresses = const <String>[],
    this.textBody = '',
    this.inReplyTo,
    this.references,
    this.attachments = const <MailAttachment>[],
    this.auth = const MailAuth(),
    this.bodyUnreadable = false,
  });

  final MailSummary summary;
  final List<String> ccAddresses;

  /// The plain text. The app never renders the HTML part.
  final String textBody;

  /// The threading headers, sent back unchanged when a draft is sent.
  final String? inReplyTo;
  final String? references;
  final List<MailAttachment> attachments;
  final MailAuth auth;

  /// `sealed_body` did not open with the mail key.
  final bool bodyUnreadable;

  String get id => summary.id;

  /// Some sealed part of this mail did not open.
  bool get unreadable => summary.unreadable || bodyUnreadable;

  /// Reads a `Message` and opens its sealed parts with [key]. Never throws
  /// for a part that does not open; [unreadable] says so.
  static Future<MailMessage> open(
    Map<String, dynamic> json,
    AgentMailKeyPair key,
  ) async {
    final MailSummary summary = await MailSummary.open(json, key);
    Map<String, dynamic>? body;
    try {
      body = await _openDocument(json['sealed_body'], key);
    } on AgentMailSealException {
      body = null;
    }
    if (body == null) {
      return MailMessage(summary: summary, bodyUnreadable: true);
    }
    final Object? files = body['attachments'];
    final Object? references = body['references'];
    return MailMessage(
      summary: summary,
      ccAddresses: _addresses(body['cc']),
      textBody: _raw(body['text']) ?? '',
      inReplyTo: _text(body['in_reply_to']),
      references: references is List
          ? _text(_addresses(references).join(' '))
          : _text(references),
      attachments: files is List
          ? <MailAttachment>[
              for (final Object? a in files)
                if (a is Map<String, dynamic>) MailAttachment.fromJson(a),
            ]
          : const <MailAttachment>[],
      auth: MailAuth.fromJson(body['auth']),
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
}

/// An address or an `@domain.tld` the mailbox knows. The server keeps only
/// a hash and the sealed label; [address] is the opened label.
@immutable
class MailContact {
  const MailContact({
    required this.id,
    required this.address,
    this.trustedInbound = false,
    this.allowedOutbound = false,
    this.blocked = false,
    this.createdAt,
    this.unreadable = false,
  });

  final String id;

  /// Empty when [unreadable].
  final String address;

  /// Mail from here starts a full run.
  final bool trustedInbound;

  /// The agent may mail here without a draft.
  final bool allowedOutbound;

  /// Mail from here is dropped.
  final bool blocked;
  final DateTime? createdAt;

  /// `label_sealed` did not open with the mail key.
  final bool unreadable;

  bool get isDomain => address.startsWith('@');

  /// Reads a contact row and opens `label_sealed` with [key].
  static Future<MailContact> open(
    Map<String, dynamic> json,
    AgentMailKeyPair key,
  ) async {
    String? address;
    try {
      address = _text(
        (await _openDocument(json['label_sealed'], key))?['address'],
      );
    } on AgentMailSealException {
      address = null;
    }
    return MailContact(
      id: '${json['id'] ?? ''}',
      address: address ?? '',
      trustedInbound: json['trusted_inbound'] == true,
      allowedOutbound: json['allowed_outbound'] == true,
      blocked: json['blocked'] == true,
      createdAt: _time(json['created_at']),
      unreadable: address == null,
    );
  }
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

/// A non-2xx answer, no answer, or a mail key problem. [code] is the
/// FastAPI `detail` code (`no_subscription`, `mailbox_frozen`, ...) or one
/// of the client codes below.
class AgentMailException implements Exception {
  const AgentMailException(this.statusCode, this.code);

  /// 0 when the request did not reach the server, or the problem is local.
  final int statusCode;
  final String code;

  static const String notSignedIn = 'not_signed_in';
  static const String network = 'network';

  /// `GET /key` answered 404: the mailbox has no mail key yet.
  static const String noKey = 'no_key';

  /// The chuk key is not unlocked, so the mail key cannot be opened.
  static const String keyLocked = 'key_locked';

  /// The sealed mail key does not open with the chuk key, or it does not
  /// match the public key the server holds.
  static const String keyUnreadable = 'key_unreadable';

  bool get noSubscription => statusCode == 402 || code == 'no_subscription';
  bool get unavailable => code == 'agent_mail_unavailable';

  @override
  String toString() => 'AgentMailException($statusCode): $code';
}

/// Seals the raw mail private key with the user's chuk key, and opens it
/// again (§3.1: "the same way as chats").
abstract interface class AgentMailSecretBox {
  Future<String> seal(String plaintext);
  Future<String> open(String sealed);
}

/// [AgentMailSecretBox] over [EncryptionService]: AES-256-GCM under the
/// per-user chuk key, the envelope every small secret of the app uses.
class ChukKeySecretBox implements AgentMailSecretBox {
  const ChukKeySecretBox();

  static Future<void> _unlock() async {
    if (EncryptionService.hasKey) return;
    bool loaded = false;
    try {
      loaded = await EncryptionService.tryLoadKey();
    } catch (_) {
      loaded = false;
    }
    if (!loaded) {
      throw const AgentMailException(0, AgentMailException.keyLocked);
    }
  }

  @override
  Future<String> seal(String plaintext) async {
    await _unlock();
    return EncryptionService.encrypt(plaintext);
  }

  @override
  Future<String> open(String sealed) async {
    await _unlock();
    return EncryptionService.decrypt(sealed);
  }
}

/// Hands out a usable access token, or null when signed out.
typedef AgentMailTokenSource = Future<String?> Function();

/// The id of the signed-in user, or null.
typedef AgentMailUserSource = String? Function();

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

String? _supabaseUserId() {
  if (!SupabaseService.isInitialized) return null;
  try {
    return SupabaseService.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

/// Attachments at least this large are opened off the UI isolate.
const int _backgroundUnsealMinBytes = 256 * 1024;

/// The most attachment bytes (raw, all files together) one sent mail may
/// carry. The server answers `422 attachments_too_large` above it.
const int kAgentMailOutboundAttachmentsMax = 3 * 1024 * 1024;

Future<Uint8List> _unsealBytesInBackground(
  (Uint8List, Uint8List, Uint8List) job,
) async => unsealAgentMailBytes(
  job.$1,
  AgentMailKeyPair(privateKey: job.$2, publicKey: job.$3),
);

class AgentMailService {
  AgentMailService({
    http.Client? client,
    String? baseUrl,
    AgentMailTokenSource? token,
    AgentMailUserSource? userId,
    AgentMailSecretBox secretBox = const ChukKeySecretBox(),
    this.timeout = const Duration(seconds: 15),
  }) : _client = client, // ignore: prefer_initializing_formals
       _baseUrl = baseUrl, // ignore: prefer_initializing_formals
       _token = token ?? supabaseAgentMailToken,
       _userId = userId ?? _supabaseUserId,
       _secretBox = secretBox; // ignore: prefer_initializing_formals

  /// The app's client: live token, default base URL, one client per call.
  static final AgentMailService instance = AgentMailService();

  final http.Client? _client;
  final String? _baseUrl;
  final AgentMailTokenSource _token;
  final AgentMailUserSource _userId;
  final AgentMailSecretBox _secretBox;
  final Duration timeout;

  static const String _root = '/v1/agent-mail';

  // --- the mail key, per user, in memory only --------------------------------

  /// The user [_key] belongs to. Checked on every access: a different user
  /// (or none) drops the key, so a second account never reads the first's.
  String? _keyUserId;
  AgentMailKeyPair? _key;
  Future<AgentMailKeyPair>? _keyLoad;
  Future<AgentMailKeyPair>? _keyCreate;

  final StreamController<AgentMailKeyPair> _created =
      StreamController<AgentMailKeyPair>.broadcast();

  /// Every mail key this service made and stored with `PUT /key`. The host
  /// hand-over listens, so a new key reaches the host at once (§6.1).
  Stream<AgentMailKeyPair> get createdKeys => _created.stream;

  /// The opened mail key of the signed-in user, when it is in memory.
  AgentMailKeyPair? get cachedKey {
    final String? uid = _userId();
    return uid != null && uid == _keyUserId ? _key : null;
  }

  /// Drops the mail key from memory (sign-out).
  void forgetKey() {
    _keyUserId = null;
    _key = null;
    _keyLoad = null;
    _keyCreate = null;
  }

  String _currentUser() {
    final String? uid = _userId();
    if (uid == null || uid.isEmpty) {
      forgetKey();
      throw const AgentMailException(401, AgentMailException.notSignedIn);
    }
    if (uid != _keyUserId) {
      forgetKey();
      _keyUserId = uid;
    }
    return uid;
  }

  /// The user's mail key, opened. From memory when it is there, else
  /// `GET /key` and the chuk key. With [create], a mailbox without a key
  /// (`404 no_key`) gets a new one (§3.1); without it that is an
  /// [AgentMailException] with [AgentMailException.noKey].
  Future<AgentMailKeyPair> mailKey({bool create = false}) async {
    final String uid = _currentUser();
    final AgentMailKeyPair? cached = _key;
    if (cached != null) return cached;
    try {
      return await (_keyLoad ??= _fetchKey(uid).whenComplete(() {
        _keyLoad = null;
      }));
    } on AgentMailException catch (error) {
      if (!create || error.code != AgentMailException.noKey) rethrow;
    }
    return _keyCreate ??= _createKey(uid).whenComplete(() {
      _keyCreate = null;
    });
  }

  AgentMailKeyPair _keep(String uid, AgentMailKeyPair key) {
    if (_userId() != uid) {
      throw const AgentMailException(401, AgentMailException.notSignedIn);
    }
    _keyUserId = uid;
    _key = key;
    return key;
  }

  Future<AgentMailKeyPair> _fetchKey(String uid) async {
    final http.Response response;
    try {
      response = await _send('GET', _uri('/key'));
    } on AgentMailException catch (error) {
      if (error.statusCode == 404) {
        throw const AgentMailException(404, AgentMailException.noKey);
      }
      rethrow;
    }
    return _keep(uid, await _openStoredKey(_json(response)));
  }

  Future<AgentMailKeyPair> _openStoredKey(Map<String, dynamic> json) async {
    final Object? public = json['public_key'];
    final Object? sealed = json['private_key_sealed'];
    if (public is! String || sealed is! String) {
      throw const AgentMailException(200, 'bad_response');
    }
    final String raw;
    try {
      raw = await _secretBox.open(sealed);
    } on AgentMailException {
      rethrow;
    } catch (_) {
      throw const AgentMailException(0, AgentMailException.keyUnreadable);
    }
    final AgentMailKeyPair key;
    final List<int> serverPublic;
    try {
      key = await AgentMailKeyPair.fromPrivateKey(base64Decode(raw.trim()));
      serverPublic = base64Decode(public);
    } catch (_) {
      throw const AgentMailException(0, AgentMailException.keyUnreadable);
    }
    if (!listEquals(key.publicKey, serverPublic)) {
      throw const AgentMailException(0, AgentMailException.keyUnreadable);
    }
    return key;
  }

  Future<AgentMailKeyPair> _createKey(String uid) async {
    final AgentMailKeyPair key = await AgentMailKeyPair.generate();
    final String sealed;
    try {
      sealed = await _secretBox.seal(key.privateKeyBase64);
    } on AgentMailException {
      rethrow;
    } catch (_) {
      throw const AgentMailException(0, AgentMailException.keyLocked);
    }
    try {
      await _send(
        'PUT',
        _uri('/key'),
        body: <String, String>{
          'public_key': key.publicKeyBase64,
          'private_key_sealed': sealed,
        },
      );
    } on AgentMailException catch (error) {
      // Another device made one first: use that one.
      if (error.statusCode == 409 || error.code == 'key_exists') {
        return _fetchKey(uid);
      }
      rethrow;
    }
    _keep(uid, key);
    _created.add(key);
    return key;
  }

  // --- requests --------------------------------------------------------------

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

  static List<Map<String, dynamic>> _rows(Object? raw) => raw is List
      ? <Map<String, dynamic>>[
          for (final Object? r in raw)
            if (r is Map<String, dynamic>) r,
        ]
      : const <Map<String, dynamic>>[];

  /// The user's mailbox as the server reports it. The server makes it on
  /// the first call when the user has a subscription; without one this
  /// throws `402 no_subscription`.
  Future<Mailbox> mailbox() async =>
      Mailbox.fromJson(_json(await _send('GET', _uri('/mailbox'))));

  /// The mailbox with its mail key ready: what the mailbox page opens with.
  /// A mailbox that `needs_key` (or whose `GET /key` is 404) gets a new key
  /// here, and is then asked again for its real status.
  Future<Mailbox> openMailbox() async {
    final Mailbox box = await mailbox();
    await mailKey(create: true);
    return box.needsKey ? mailbox() : box;
  }

  /// One page of mail, newest first, opened.
  Future<MailPage> messages({
    MailFolder folder = MailFolder.inbox,
    MailTrustFilter? trust,
    bool? undelivered,
    int? limit,
    String? before,
  }) async {
    final AgentMailKeyPair key = await mailKey();
    final Map<String, String> query = <String, String>{
      'folder': folder.name,
      if (trust != null) 'trust': trust.name,
      if (undelivered != null) 'undelivered': '$undelivered',
      if (limit != null) 'limit': '${limit.clamp(1, 100)}',
      if (before != null && before.isNotEmpty) 'before': before,
    };
    final Map<String, dynamic> json = _json(
      await _send('GET', _uri('/messages', query)),
    );
    return MailPage(
      messages: <MailSummary>[
        for (final Map<String, dynamic> row in _rows(json['messages']))
          await MailSummary.open(row, key),
      ],
      nextBefore: _text(json['next_before']),
    );
  }

  /// The full mail, text body and attachment list included, opened.
  Future<MailMessage> message(String id) async {
    final AgentMailKeyPair key = await mailKey();
    return MailMessage.open(
      _json(await _send('GET', _uri('/messages/${_seg(id)}'))),
      key,
    );
  }

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

  /// The bytes of one stored attachment, opened. Throws an
  /// [AgentMailSealException] when the object does not open.
  Future<Uint8List> attachment(String messageId, String attachmentId) async {
    final AgentMailKeyPair key = await mailKey();
    final http.Response response = await _send(
      'GET',
      _uri('/messages/${_seg(messageId)}/attachments/${_seg(attachmentId)}'),
    );
    final Uint8List sealed = response.bodyBytes;
    if (kIsWeb || sealed.length < _backgroundUnsealMinBytes) {
      return unsealAgentMailBytes(sealed, key);
    }
    return compute(_unsealBytesInBackground, (
      sealed,
      key.privateKey,
      key.publicKey,
    ));
  }

  /// Sends a draft the agent wrote. The body is the whole draft (§5.3): the
  /// recipients and threading headers of [draft], with [subject] and [text]
  /// as the user left them. The server cannot read the draft's sealed
  /// attachments, so each stored one is opened here and sent again in the
  /// body; the server replaces the old objects with them. The recipients
  /// become `allowed_outbound` contacts on the server.
  Future<MailSendResult> sendDraft(
    MailMessage draft, {
    required String subject,
    required String text,
  }) async {
    if (draft.unreadable) {
      throw const AgentMailSealException('draft does not open');
    }
    final List<Map<String, String>> files = <Map<String, String>>[];
    int total = 0;
    for (final MailAttachment file in draft.attachments) {
      if (!file.available) continue;
      final Uint8List bytes = await attachment(draft.id, file.id);
      total += bytes.length;
      if (total > kAgentMailOutboundAttachmentsMax) {
        throw const AgentMailException(422, 'attachments_too_large');
      }
      files.add(<String, String>{
        'filename': file.filename,
        'content_type': file.contentType ?? 'application/octet-stream',
        'content_base64': base64Encode(bytes),
      });
    }
    final http.Response response = await _send(
      'POST',
      _uri('/drafts/${_seg(draft.id)}/send'),
      body: <String, Object>{
        'to': draft.summary.toAddresses,
        if (draft.ccAddresses.isNotEmpty) 'cc': draft.ccAddresses,
        'subject': subject,
        'text': text,
        'in_reply_to': ?draft.inReplyTo,
        'references': ?draft.references,
        if (files.isNotEmpty) 'attachments': files,
      },
    );
    try {
      final Object? data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) return MailSendResult.fromJson(data);
    } catch (_) {}
    return MailSendResult(id: draft.id, status: 'sent');
  }

  /// Every contact: trusted, allowed and blocked, labels opened.
  Future<List<MailContact>> contacts() async {
    final AgentMailKeyPair key = await mailKey();
    final Object? rows = _json(
      await _send('GET', _uri('/contacts')),
    )['contacts'];
    return <MailContact>[
      for (final Map<String, dynamic> row in _rows(rows))
        await MailContact.open(row, key),
    ];
  }

  /// Adds or changes a contact. [address] is an address or `@domain.tld`,
  /// in plain text: the server hashes and seals it.
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

  /// Removes the contact by its id. Its mail is then `unknown` again.
  Future<void> deleteContact(String id) async {
    await _send('DELETE', _uri('/contacts/${_seg(id)}'));
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
