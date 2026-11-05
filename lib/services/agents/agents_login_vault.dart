/// The login vault of the host (docs/WIRE_CONTRACT.md, "Login vault for the
/// browser").
///
/// The user saves a login for one site; the host keeps it encrypted and the
/// agent's browser fills it in through a placeholder. The model never sees
/// the password, the TOTP key or the code.
///
/// This app never keeps a password or a TOTP key: [AgentsLoginVault.save]
/// puts them straight into the sealed `login_vault_set` frame and holds no
/// copy in a field, a cache, a log or Supabase. What the app keeps is the
/// public list the host sends back ([AgentsLoginEntry]).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_reply_frames.dart';

/// One saved login as the host shows it. Never a password or a TOTP key.
@immutable
class AgentsLoginEntry {
  const AgentsLoginEntry({
    required this.id,
    required this.origin,
    required this.username,
    this.label,
    this.hasTotp = false,
    this.createdAt,
    this.lastUsedAt,
  });

  final String id;
  final String origin;
  final String username;
  final String? label;
  final bool hasTotp;
  final DateTime? createdAt;

  /// Null until the host filled the login the first time.
  final DateTime? lastUsedAt;

  /// Reads one public entry. Null when the id, the origin or the username
  /// is missing: such a row cannot be edited or deleted.
  static AgentsLoginEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? origin = raw['origin'];
    final Object? username = raw['username'];
    if (id is! String || id.isEmpty) return null;
    if (origin is! String || origin.isEmpty) return null;
    if (username is! String) return null;
    final Object? label = raw['label'];
    return AgentsLoginEntry(
      id: id,
      origin: origin,
      username: username,
      label: label is String && label.trim().isNotEmpty ? label.trim() : null,
      hasTotp: raw['has_totp'] == true,
      createdAt: _millis(raw['created_at']),
      lastUsedAt: _millis(raw['last_used_at']),
    );
  }

  static DateTime? _millis(Object? value) =>
      value is num ? DateTime.fromMillisecondsSinceEpoch(value.toInt()) : null;
}

/// One `login_vault` reply: the full public list, and what the request did.
@immutable
class AgentsLoginVaultReply {
  const AgentsLoginVaultReply({
    this.entries = const <AgentsLoginEntry>[],
    this.saved,
    this.deleted,
    this.error,
  });

  final List<AgentsLoginEntry> entries;

  /// The public entry, after a `login_vault_set`.
  final AgentsLoginEntry? saved;

  /// The id, after a `login_vault_delete`.
  final String? deleted;

  /// The host's short text when it refused the frame.
  final String? error;

  bool get ok => error == null;

  static AgentsLoginVaultReply fromPayload(Map<String, dynamic> payload) {
    final Object? raw = payload['entries'];
    final Object? deleted = payload['deleted'];
    final Object? error = payload['error'];
    return AgentsLoginVaultReply(
      entries: <AgentsLoginEntry>[
        if (raw is List)
          for (final Object? row in raw)
            if (AgentsLoginEntry.fromJson(row) case final AgentsLoginEntry e) e,
      ],
      saved: AgentsLoginEntry.fromJson(payload['saved']),
      deleted: deleted is String && deleted.isNotEmpty ? deleted : null,
      error: error is String && error.trim().isNotEmpty ? error.trim() : null,
    );
  }
}

/// The origin the host keeps for [input] (`scheme://host[:port]`, lower
/// case, no default port, no path), or null when the host would refuse it:
/// only `https`, and `http` only for `localhost`, `127.0.0.1` and `::1`.
/// A bare host name (`github.com`) is read as `https://github.com`.
String? loginOriginOf(String input) {
  String text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final Uri? uri = Uri.tryParse(text);
  if (uri == null) return null;
  final String scheme = uri.scheme.toLowerCase();
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  const Set<String> local = <String>{'localhost', '127.0.0.1', '::1'};
  if (scheme != 'https' && !(scheme == 'http' && local.contains(host))) {
    return null;
  }
  final int port = uri.hasPort ? uri.port : 0;
  final bool defaultPort =
      !uri.hasPort ||
      (scheme == 'https' && port == 443) ||
      (scheme == 'http' && port == 80);
  final String shownHost = host.contains(':') ? '[$host]' : host;
  return defaultPort ? '$scheme://$shownHost' : '$scheme://$shownHost:$port';
}

/// The app side of the vault: the list as the host last sent it, and the
/// three requests.
class AgentsLoginVault extends ChangeNotifier {
  AgentsLoginVault({
    AgentsFrameSender? send,
    AgentsReplyFrames? replies,
    this.timeout = const Duration(seconds: 20),
  }) : _sendFrame = send,
       _replies = replies ?? AgentsReplyFrames.instance;

  static final AgentsLoginVault instance = AgentsLoginVault();

  final AgentsFrameSender? _sendFrame;
  final AgentsReplyFrames _replies;
  final Duration timeout;

  List<AgentsLoginEntry> _entries = const <AgentsLoginEntry>[];
  bool _loaded = false;

  /// The public list from the newest reply.
  List<AgentsLoginEntry> get entries => _entries;

  /// True once a reply came in.
  bool get loaded => _loaded;

  /// `login_vault_list`.
  Future<AgentsLoginVaultReply> refresh() =>
      _request(<String, dynamic>{'type': 'login_vault_list'});

  /// `login_vault_set`. [password] and [totpSecret] go into the frame and
  /// nowhere else. [totpSecret]: [keepTotp] leaves the key out (the host
  /// keeps the stored key), an empty text or [removeTotp] sends `null`.
  /// [label] null leaves the stored label.
  Future<AgentsLoginVaultReply> save({
    required String origin,
    required String username,
    required String password,
    String? totpSecret,
    bool removeTotp = false,
    String? label,
  }) {
    final String? totp = totpSecret?.trim();
    return _request(<String, dynamic>{
      'type': 'login_vault_set',
      'origin': origin.trim(),
      'username': username.trim(),
      'password': password,
      if (removeTotp)
        'totp_secret': null
      else if (totp != null && totp.isNotEmpty)
        'totp_secret': totp,
      if (label != null) 'label': label.trim(),
    });
  }

  /// `login_vault_delete`.
  Future<AgentsLoginVaultReply> delete(String id) =>
      _request(<String, dynamic>{'type': 'login_vault_delete', 'id': id});

  Future<AgentsLoginVaultReply> _request(Map<String, dynamic> frame) async {
    final Map<String, dynamic> payload;
    try {
      payload = await _replies.request(
        frame,
        replyType: 'login_vault',
        send: _sendFrame,
        timeout: timeout,
      );
    } on AgentsReplyTimeout {
      if (kDebugMode) debugPrint('[login-vault] no reply');
      return const AgentsLoginVaultReply(error: kLoginVaultNoReply);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[login-vault] send failed (${error.runtimeType})');
      }
      return const AgentsLoginVaultReply(error: kLoginVaultNotConnected);
    }
    final AgentsLoginVaultReply reply = AgentsLoginVaultReply.fromPayload(
      payload,
    );
    // The reply always holds the full public list, also next to an error.
    if (payload['entries'] is List) {
      _entries = List<AgentsLoginEntry>.unmodifiable(reply.entries);
      _loaded = true;
      notifyListeners();
    }
    return reply;
  }

  /// Sign-out or tests: forget the list.
  void clear() {
    _entries = const <AgentsLoginEntry>[];
    _loaded = false;
    notifyListeners();
  }
}

/// Marker errors the page translates; the host's own texts are shown as
/// they are.
const String kLoginVaultNotConnected = 'login_vault:not_connected';
const String kLoginVaultNoReply = 'login_vault:no_reply';
