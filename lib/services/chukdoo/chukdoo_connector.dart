// lib/services/chukdoo/chukdoo_connector.dart
//
// The built-in Chukdoo connector: pair this account with the user's chukdoo
// account once, then the model can read and change tasks, events, notes and
// habits in any chat.
//
// Pairing is chukdoo's device pairing (vendor/chukdoo_core, chukdoo's
// docs/AI_ACCESS.md): this app opens a request and shows a code, the user
// types it into Chukdoo -> Settings -> AI access -> Pair a device, and the
// approval hands back a device token plus the chukdoo data key, sealed to
// this app.
//
// Those credentials are the connector. They live in two places:
// - a local copy in secure storage, keyed by the signed-in user id;
// - an end-to-end encrypted copy in chuk_chat's Supabase
//   ([ChukdooMirror]), so every other install of the same account picks the
//   connector up on its next sync tick, without a second pairing.
//
// Both copies hold a [ChukdooRecord]: the credentials, or a tombstone after
// a disconnect (or after Chukdoo revoked the device). The newer record wins
// on every pull, so "Disconnect" on one device removes the connector on all
// of them, and a revoke seen by one device reaches the rest.

import 'dart:async';
import 'dart:convert';

import 'package:chukdoo_core/chukdoo_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore, FlutterSecureKeyValueStore;
import 'package:chuk_chat/services/chukdoo/chukdoo_config.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_connector_sync.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_tool_bridge.dart'
    show isDestructiveChukdooCall;
import 'package:chuk_chat/services/supabase_service.dart';

/// Why the connector is not connected any more.
enum ChukdooEndReason {
  /// The user pressed Disconnect (on any device).
  disconnected,

  /// The device was removed in the Chukdoo app; its token stopped working.
  revoked,
}

/// What both the local copy and the cloud copy hold.
@immutable
class ChukdooRecord {
  const ChukdooRecord.connected(ChukdooCredentials this.credentials, this.updatedAt)
    : ended = null;

  const ChukdooRecord.ended(ChukdooEndReason this.ended, this.updatedAt)
    : credentials = null;

  final ChukdooCredentials? credentials;
  final ChukdooEndReason? ended;

  /// When this record was written. The newer record wins.
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'credentials': credentials?.toJson(),
    'ended': ended?.name,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  /// Null when [json] is not a record this build understands.
  static ChukdooRecord? tryParse(Object? json) {
    if (json is! Map) return null;
    if (json['v'] != 1) return null;
    final updatedAt = DateTime.tryParse(json['updated_at']?.toString() ?? '');
    if (updatedAt == null) return null;
    final creds = json['credentials'];
    if (creds is Map) {
      try {
        return ChukdooRecord.connected(
          ChukdooCredentials.fromJson(Map<String, dynamic>.from(creds)),
          updatedAt,
        );
      } catch (_) {
        return null;
      }
    }
    final ended = ChukdooEndReason.values
        .where((r) => r.name == json['ended'])
        .firstOrNull;
    return ChukdooRecord.ended(
      ended ?? ChukdooEndReason.disconnected,
      updatedAt,
    );
  }
}

/// What the UI and the tool bridge read.
@immutable
class ChukdooConnectorState {
  const ChukdooConnectorState({this.credentials, this.revoked = false});

  /// Null while not connected.
  final ChukdooCredentials? credentials;

  /// True when the last connection ended because Chukdoo removed the device.
  final bool revoked;

  bool get connected => credentials != null;
}

/// A running pairing: the code to show, and how it ends.
class ChukdooPairing {
  ChukdooPairing._(this.displayCode, this.expiresAt, this._client);

  /// The code as the user types it, `XXXXX-XXXXX`.
  final String displayCode;
  final DateTime expiresAt;
  final _CancellableClient _client;
  late final Future<void> done;

  /// Stops the polling. [done] then fails with [ChukdooPairingCancelled].
  void cancel() => _client.cancel();
}

/// The pairing was cancelled by the user.
class ChukdooPairingCancelled implements Exception {
  const ChukdooPairingCancelled();
}

/// The pairing failed; [message] is safe to show.
class ChukdooPairingFailed implements Exception {
  const ChukdooPairingFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The result of one tool call, in the shape the executor needs.
typedef ChukdooCallResult = ({String text, bool isError});

typedef ChukdooToolsFactory = ChukdooTools Function(ChukdooCredentials);
typedef ChukdooPairingClientFactory = PairingClient Function(http.Client);

class ChukdooConnector {
  ChukdooConnector._({
    AgentsSecureKeyValueStore? secrets,
    ChukdooMirror? mirror,
    String? Function()? currentUserId,
    ChukdooToolsFactory? toolsFactory,
    ChukdooPairingClientFactory? pairingClientFactory,
    http.Client Function()? httpClientFactory,
    DateTime Function()? clock,
  }) : _secrets = secrets ?? const FlutterSecureKeyValueStore(),
       _mirror = mirror ?? const SupabaseChukdooMirror(),
       _currentUserId = currentUserId ?? _supabaseUserId,
       _toolsFactory = toolsFactory ?? ((c) => ChukdooTools.fromCredentials(c)),
       _pairingClientFactory =
           pairingClientFactory ??
           ((client) => PairingClient(
             supabaseUrl: ChukdooConfig.supabaseUrl.trim(),
             anonKey: ChukdooConfig.anonKey.trim(),
             client: client,
           )),
       _httpClientFactory = httpClientFactory ?? http.Client.new,
       _clock = clock ?? DateTime.now;

  static ChukdooConnector _instance = ChukdooConnector._();
  static ChukdooConnector get instance => _instance;

  /// A fresh connector with test doubles; replaces [instance].
  @visibleForTesting
  static ChukdooConnector resetForTest({
    AgentsSecureKeyValueStore? secrets,
    ChukdooMirror? mirror,
    String? Function()? currentUserId,
    ChukdooToolsFactory? toolsFactory,
    ChukdooPairingClientFactory? pairingClientFactory,
    http.Client Function()? httpClientFactory,
    DateTime Function()? clock,
  }) {
    _instance._tools?.close();
    return _instance = ChukdooConnector._(
      secrets: secrets,
      mirror: mirror,
      currentUserId: currentUserId,
      toolsFactory: toolsFactory,
      pairingClientFactory: pairingClientFactory,
      httpClientFactory: httpClientFactory,
      clock: clock,
    );
  }

  static String? _supabaseUserId() {
    if (!SupabaseService.isInitialized) return null;
    return SupabaseService.auth.currentUser?.id;
  }

  /// Every registered tool name starts with this, so it never collides with
  /// a built-in or an MCP tool.
  static const String toolPrefix = 'chukdoo_';

  /// The name the connector carries in the list and in the prompt.
  static const String displayName = 'Chukdoo';

  /// The kind chukdoo shows next to the device in Settings -> AI access.
  static const String deviceKind = 'chuk_chat';

  /// The device name chukdoo shows. One name for every install: they all
  /// share one device entry.
  static const String deviceName = 'Chuk Chat';

  static const Duration _pullInterval = Duration(seconds: 60);

  final AgentsSecureKeyValueStore _secrets;
  final ChukdooMirror _mirror;
  final String? Function() _currentUserId;
  final ChukdooToolsFactory _toolsFactory;
  final ChukdooPairingClientFactory _pairingClientFactory;
  final http.Client Function() _httpClientFactory;
  final DateTime Function() _clock;

  /// What the page and the tool bridge listen to.
  final ValueNotifier<ChukdooConnectorState> state =
      ValueNotifier<ChukdooConnectorState>(const ChukdooConnectorState());

  String? _loadedFor;
  ChukdooRecord? _record;
  ChukdooTools? _tools;
  Future<void>? _loading;
  Future<void>? _pulling;

  /// Pairings still polling. A sign-out cancels them, so an approval cannot
  /// land in the next account that signs in.
  final Set<_CancellableClient> _activePairings = <_CancellableClient>{};

  /// Bumped on every write, so a slow local read cannot undo a newer record.
  int _generation = 0;
  DateTime? _lastPull;

  /// Whether the last cloud read gave an answer this device can act on: a
  /// record, no row, or a row no key of this account can open any more.
  bool _lastReadSettled = false;

  /// The connector shows only when the build knows the chukdoo project.
  static bool get isAvailable => ChukdooConfig.isConfigured;

  static String _localKey(String userId) => 'chukdoo_connector_v1_$userId';

  // ─── Tools ───────────────────────────────────────────────────────────────

  /// The tools of the connected account; empty while not connected.
  List<ChukdooToolSpec> get specs => _tools?.specs ?? const [];

  /// Whether [registeredName] is a Chukdoo tool (prefixed name).
  static bool isChukdooTool(String registeredName) =>
      registeredName.startsWith(toolPrefix);

  /// True for a Chukdoo tool that only reads.
  bool isReadOnlyTool(String registeredName) {
    if (!isChukdooTool(registeredName)) return false;
    final name = registeredName.substring(toolPrefix.length);
    return specs.any((s) => s.name == name && s.readOnly);
  }

  /// Runs one tool. Never throws: errors come back as text for the model.
  Future<ChukdooCallResult> callTool(
    String registeredName,
    Map<String, dynamic> args,
  ) async {
    final tools = _tools;
    if (tools == null) {
      return (
        text:
            'Error: Chukdoo is not connected. The user can connect it in '
            'Settings > Connectors > Chukdoo.',
        isError: true,
      );
    }
    final name = isChukdooTool(registeredName)
        ? registeredName.substring(toolPrefix.length)
        : registeredName;
    if (isDestructiveChukdooCall(name, args)) {
      return (
        text:
            'Error: deleting in Chukdoo or replacing a whole note is not '
            'available from chat yet. Use "append" for notes, or ask the user '
            'to do it in the Chukdoo app.',
        isError: true,
      );
    }
    try {
      final result = await tools.callTool(name, args);
      return (text: jsonEncode(result), isError: false);
    } on ChukdooToolError catch (e) {
      return (text: 'Error: ${e.message}', isError: true);
    } on ChukdooApiException catch (e) {
      // A bare 401 can come from the gateway. Only the device-token
      // rejection means Chukdoo removed this device.
      final revoked =
          e.code == '28000' || e.message.contains('invalid device token');
      if (revoked) {
        await _endBecauseRevoked(tools);
        if (state.value.connected) {
          final repaired =
              state.value.credentials!.deviceToken !=
              tools.store.credentials.deviceToken;
          return (
            text: repaired
                // Another install had already paired again; this one now
                // uses the new pairing.
                ? 'Error: the Chukdoo pairing changed on another device. '
                      'Call the tool again.'
                : 'Error: Chukdoo did not accept this device right now. Try '
                      'again later.',
            isError: true,
          );
        }
        return (
          text:
              'Error: Chukdoo access was removed in the Chukdoo app, so the '
              'connector is now disconnected. Tell the user to connect '
              'Chukdoo again in Settings > Connectors > Chukdoo.',
          isError: true,
        );
      }
      return (
        text: 'Error: the Chukdoo server answered ${e.statusCode}: ${e.message}',
        isError: true,
      );
    } on TimeoutException {
      return (text: 'Error: Chukdoo did not answer in time.', isError: true);
    } catch (e) {
      return (
        text: 'Error: could not reach Chukdoo (${e.runtimeType}).',
        isError: true,
      );
    }
  }

  // ─── Local copy ──────────────────────────────────────────────────────────

  /// Reads the local copy for the signed-in user. Single-flight; switches
  /// over when another user signs in.
  Future<void> load() {
    final userId = _currentUserId();
    if (userId == null) {
      _apply(null, userId: null);
      return Future<void>.value();
    }
    if (_loadedFor == userId) return _loading ?? Future<void>.value();
    _loadedFor = userId;
    final generation = _generation;
    return _loading = () async {
      ChukdooRecord? record;
      try {
        final raw = await _secrets.read(_localKey(userId));
        if (raw != null && raw.isNotEmpty) {
          record = ChukdooRecord.tryParse(jsonDecode(raw));
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[Chukdoo] local read failed: ${error.runtimeType}');
        }
      }
      if (_loadedFor == userId && _generation == generation) {
        _apply(record, userId: userId);
      }
    }();
  }

  /// Drops the local copy of [userId] (sign-out). The cloud copy stays, so
  /// signing in again brings the connector back.
  Future<void> forgetLocal(String? userId) async {
    if (userId != null) {
      try {
        await _secrets.delete(_localKey(userId));
      } catch (_) {}
    }
    _loadedFor = null;
    _loading = null;
    _lastPull = null;
    for (final pairing in _activePairings) {
      pairing.cancel();
    }
    _generation++;
    _apply(null, userId: null);
  }

  /// Writes [record] for [owner] (default: the signed-in user). Returns
  /// false when nothing was stored because another user is signed in.
  Future<bool> _store(ChukdooRecord record, {String? owner}) async {
    final userId = _currentUserId();
    if (userId == null || (owner != null && owner != userId)) return false;
    final generation = ++_generation;
    await _secrets.write(_localKey(userId), jsonEncode(record.toJson()));
    if (_currentUserId() != userId) {
      // Signed out while writing: leave no key material behind.
      try {
        await _secrets.delete(_localKey(userId));
      } catch (_) {}
      return false;
    }
    // A newer write or a sign-out in the meantime wins.
    if (_generation != generation) return false;
    _loadedFor = userId;
    _apply(record, userId: userId);
    return true;
  }

  void _apply(ChukdooRecord? record, {required String? userId}) {
    _record = record;
    final creds = record?.credentials;
    final current = state.value.credentials;
    final sameDevice =
        creds != null &&
        current != null &&
        creds.deviceToken == current.deviceToken &&
        creds.dataKey == current.dataKey &&
        creds.supabaseUrl == current.supabaseUrl;
    if (!sameDevice) {
      _tools?.close();
      _tools = creds == null ? null : _toolsFactory(creds);
    }
    state.value = ChukdooConnectorState(
      credentials: creds,
      revoked: record?.ended == ChukdooEndReason.revoked,
    );
  }

  // ─── Cloud copy ──────────────────────────────────────────────────────────

  /// Levels the local copy with the cloud copy: adopts a newer cloud record
  /// (a connect or a disconnect on another device), pushes a newer local
  /// one. Throttled unless [force]; never throws.
  Future<void> pull({bool force = false}) {
    if (_pulling != null) return _pulling!;
    final last = _lastPull;
    if (!force && last != null && _clock().difference(last) < _pullInterval) {
      return Future<void>.value();
    }
    return _pulling = () async {
      try {
        await load();
        final owner = _currentUserId();
        if (owner == null) return;
        final generation = _generation;
        final read = await _mirror.load();
        // Signed out, switched account or a newer write while reading: this
        // answer belongs to a state that is gone.
        if (_currentUserId() != owner || _generation != generation) return;
        _lastReadSettled = read.ok || read.unreadable;
        if (!read.ok) return;
        _lastPull = _clock();
        final local = _record;
        final payload = read.payload;
        if (payload == null) {
          if (local != null) await _mirror.save(local.toJson());
          return;
        }
        final remote = ChukdooRecord.tryParse(payload);
        if (remote == null) return;
        if (local == null || remote.updatedAt.isAfter(local.updatedAt)) {
          await _store(remote, owner: owner);
        } else if (local.updatedAt.isAfter(remote.updatedAt)) {
          await _mirror.save(local.toJson());
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[Chukdoo] pull failed: ${error.runtimeType}');
        }
      } finally {
        _pulling = null;
      }
    }();
  }

  /// A forced [pull] for the password change. True when the cloud copy was
  /// read (or is known to be unreadable anyway), so [recordSnapshot] holds
  /// the newest record. False when the read failed and the change should
  /// wait: re-keying then would leave the cloud copy under the old key.
  Future<bool> pullForRekey() async {
    // A pull already running may have read before this call; wait for it,
    // then read again so the answer belongs to this call.
    final running = _pulling;
    if (running != null) await running;
    _lastReadSettled = false;
    await pull(force: true);
    if (_currentUserId() == null) return true;
    return _lastReadSettled;
  }

  /// The local record, for the password change to seal again with the new
  /// key. Null when there is none.
  Map<String, dynamic>? recordSnapshot() => _record?.toJson();

  /// Seals [snapshot] again with the current key (password change). Throws
  /// when the cloud write fails and [strict] is set, so the key rotation
  /// rolls back instead of leaving the cloud copy under the old key, where
  /// no install could read it any more.
  Future<void> remirror(
    Map<String, dynamic>? snapshot, {
    bool strict = true,
  }) async {
    if (snapshot == null) return;
    if (!await _mirror.save(snapshot) && strict) {
      throw StateError('Could not re-encrypt the Chukdoo connector.');
    }
  }

  // ─── Connect / disconnect ────────────────────────────────────────────────

  /// Opens a pairing request and returns the code to show. Throws
  /// [ChukdooPairingFailed] when the request cannot be opened.
  Future<ChukdooPairing> startPairing() async {
    final owner = _currentUserId();
    if (owner == null) {
      throw const ChukdooPairingFailed('Sign in to chuk_chat first.');
    }
    final _CancellableClient client;
    final PairingClient pairingClient;
    try {
      await ChukdooConfig.ensureLoaded();
      if (!ChukdooConfig.isConfigured) {
        throw const ChukdooPairingFailed('This build has no Chukdoo project.');
      }
      client = _CancellableClient(_httpClientFactory());
      pairingClient = _pairingClientFactory(client);
    } on ChukdooPairingFailed {
      rethrow;
    } catch (e) {
      throw ChukdooPairingFailed(_pairingMessage(e));
    }
    final PairingSession session;
    try {
      session = await pairingClient.start(
        deviceName: deviceName,
        deviceKind: deviceKind,
      );
    } catch (e) {
      pairingClient.close();
      throw ChukdooPairingFailed(_pairingMessage(e));
    }
    final pairing = ChukdooPairing._(
      session.displayCode,
      session.expiresAt,
      client,
    );
    final timeout =
        session.expiresAt.difference(_clock()) + const Duration(seconds: 30);
    pairing.done = () async {
      try {
        final creds = await session.waitForApproval(
          interval: const Duration(seconds: 2),
          timeout: timeout.isNegative ? const Duration(minutes: 11) : timeout,
        );
        if (client.cancelled || _currentUserId() != owner) {
          throw const ChukdooPairingCancelled();
        }
        await connectWith(creds, owner: owner);
      } on ChukdooPairingCancelled {
        rethrow;
      } catch (e) {
        if (client.cancelled) throw const ChukdooPairingCancelled();
        throw ChukdooPairingFailed(_pairingMessage(e));
      } finally {
        _activePairings.remove(client);
        pairingClient.close();
      }
    }();
    _activePairings.add(client);
    return pairing;
  }

  /// Stores fresh [creds] locally and in the cloud and turns the tools on.
  /// [owner] pins the write to the account that started the pairing.
  Future<void> connectWith(ChukdooCredentials creds, {String? owner}) async {
    final record = ChukdooRecord.connected(creds, _clock().toUtc());
    if (!await _store(record, owner: owner)) {
      throw const ChukdooPairingCancelled();
    }
    await _mirror.save(record.toJson());
  }

  /// Removes the connector on every install of this account and revokes the
  /// device in Chukdoo (best effort: offline, only the local and cloud copies
  /// go, and the device stays listed in Chukdoo until removed there).
  Future<void> disconnect() async {
    final creds = state.value.credentials;
    if (creds != null) {
      final store = _tools?.store;
      if (store != null) {
        try {
          await store.api.unpair().timeout(const Duration(seconds: 8));
        } catch (error) {
          if (kDebugMode) {
            debugPrint('[Chukdoo] unpair failed: ${error.runtimeType}');
          }
        }
      }
    }
    final record = ChukdooRecord.ended(
      ChukdooEndReason.disconnected,
      _clock().toUtc(),
    );
    if (await _store(record)) await _mirror.save(record.toJson());
  }

  Future<void> _endBecauseRevoked(ChukdooTools tools) async {
    // Only once, and only for the device that failed: a reconnect in the
    // meantime must not be undone by a late answer of the old one.
    if (!identical(tools, _tools)) return;
    // An install that has not pulled yet may still run an old token that a
    // disconnect revoked, while the cloud already holds a newer pairing. Its
    // 401 must not wipe that pairing everywhere: adopt the cloud record
    // instead, and write the tombstone only for the token that failed.
    final failedToken = tools.store.credentials.deviceToken;
    final read = await _mirror.load();
    // Without the cloud answer this device cannot tell a revoke from a newer
    // pairing elsewhere, and a tombstone could replace that pairing on every
    // install. Wait for a read that works; the next 401 checks again.
    if (!read.ok && !read.unreadable) return;
    final remote = read.ok ? ChukdooRecord.tryParse(read.payload) : null;
    if (remote != null && remote.credentials?.deviceToken != failedToken) {
      if (identical(tools, _tools)) await _store(remote);
      return;
    }
    if (!identical(tools, _tools)) return;
    final record = ChukdooRecord.ended(
      ChukdooEndReason.revoked,
      _clock().toUtc(),
    );
    if (await _store(record)) await _mirror.save(record.toJson());
  }

  static String _pairingMessage(Object e) {
    if (e is PairingException) return e.message;
    if (e is ChukdooApiException) {
      return 'Chukdoo refused the pairing request (${e.statusCode}).';
    }
    if (e is TimeoutException) return 'Chukdoo did not answer in time.';
    return 'Could not reach Chukdoo. Check the connection and try again.';
  }
}

/// An HTTP client the pairing page can stop. After [cancel], every request
/// fails with a [ChukdooApiException], which `waitForApproval` does not
/// retry, so the polling ends at once.
class _CancellableClient extends http.BaseClient {
  _CancellableClient(this._inner);

  final http.Client _inner;
  bool cancelled = false;

  void cancel() => cancelled = true;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (cancelled) {
      return Future<http.StreamedResponse>.error(
        const ChukdooApiException(499, 'cancelled', code: 'cancelled'),
      );
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
