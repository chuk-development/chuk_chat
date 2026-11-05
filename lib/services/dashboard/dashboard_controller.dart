// lib/services/dashboard/dashboard_controller.dart
//
// The app's copy of the Home dashboard (docs/DASHBOARD.md §1, §5).
//
// The host is the truth. This holds the last document the host sent (the
// base), plus the taps the user made that the host has not answered yet (the
// pending ops). What Home draws is the base with the pending ops applied on
// top, so a tap shows at once and survives a restart while the host is away.
//
// Both halves live in the SQLite kv cache, per signed-in user and per paired
// host: `dashboard_v1_<user>_<host>` and the same key + `_pending`. A small
// pointer, `dashboard_v1_<user>_host`, remembers the last host so Home can
// draw before the relay is attached. Nothing here survives a change of user:
// every read checks the signed-in user id first (there is no working global
// reset on sign-out).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

typedef DashboardFrameSender = Future<void> Function(
  Map<String, dynamic> frame,
);
typedef DashboardKvRead = Future<String?> Function(String key);
typedef DashboardKvWrite = Future<void> Function(String key, String value);

/// One op the host has not answered yet.
class _PendingOp {
  _PendingOp(this.op);

  final Map<String, dynamic> op;

  /// Sent during the current attach. The host answers in order, so an answer
  /// to a later op also settles this one.
  bool sent = false;

  String get id => op['op_id'] as String;
}

class DashboardController extends ChangeNotifier {
  DashboardController({
    DashboardFrameSender? send,
    ValueListenable<String?>? attachedHost,
    String? Function()? userId,
    DashboardKvRead? readKv,
    DashboardKvWrite? writeKv,
    DateTime Function()? clock,
    String Function()? newOpId,
    this.refreshTimeout = const Duration(seconds: 8),
  }) : _send = send ?? _sendOverRelay,
       _attachedHost = attachedHost ?? RelayAttachment.instance,
       _userId = userId ?? _currentUserId,
       _readKv = readKv ?? LocalChatCacheService.kvGet,
       _writeKv = writeKv ?? LocalChatCacheService.kvSet,
       _clock = clock ?? DateTime.now,
       _newOpId = newOpId ?? (() => const Uuid().v4());

  /// The one instance the app uses. The shell calls [init] once.
  static DashboardController instance = DashboardController();

  final DashboardFrameSender _send;
  final ValueListenable<String?> _attachedHost;
  final String? Function() _userId;
  final DashboardKvRead _readKv;
  final DashboardKvWrite _writeKv;
  final DateTime Function() _clock;
  final String Function() _newOpId;

  /// How long a pull-to-refresh waits for the host's answer.
  final Duration refreshTimeout;

  bool _initialised = false;
  String? _uid;
  String? _host;
  int _generation = 0;
  bool _loaded = false;
  Future<void>? _loading;
  DashboardDocument _base = DashboardDocument.empty;
  final List<_PendingOp> _pending = <_PendingOp>[];
  DashboardDocument? _view;
  Completer<void>? _refreshing;

  /// The last refusal or failure the user has to see. The page shows it and
  /// calls [clearNotice]; while no page is mounted it waits here.
  final ValueNotifier<String?> notice = ValueNotifier<String?>(null);

  /// Routes the relay's dashboard frames here and starts following the
  /// attachment. Idempotent.
  void init() {
    AgentsRelayClient.dashboardSink = handleFrame;
    if (_initialised) return;
    _initialised = true;
    _attachedHost.addListener(_onAttachment);
    _checkOwner();
    if (_attachedHost.value != null) _onAttachment();
  }

  @override
  void dispose() {
    if (_initialised) _attachedHost.removeListener(_onAttachment);
    if (AgentsRelayClient.dashboardSink == handleFrame) {
      AgentsRelayClient.dashboardSink = null;
    }
    notice.dispose();
    super.dispose();
  }

  // ── what the page reads ──────────────────────────────────────────────────

  /// What Home draws: the host's last copy with the pending taps on top.
  DashboardDocument get document {
    _checkOwner();
    return _view ??= _applyPending();
  }

  /// True once the cache was read (empty or not), so the page can tell
  /// "nothing yet" from "still reading".
  bool get loaded {
    _checkOwner();
    // Nobody signed in: there is no cache to read, so Home is empty, not
    // "still loading". A spinner here never ends.
    return _uid == null || _loaded;
  }

  /// The host is attached right now.
  bool get attached => _attachedHost.value != null;

  /// Taps waiting for the host.
  int get pendingCount {
    _checkOwner();
    return _pending.length;
  }

  DateTime now() => _clock();

  void clearNotice() => notice.value = null;

  /// Resolves once the cache has been read for the current user and host.
  Future<void> ready() {
    _checkOwner();
    return _loading ?? Future<void>.value();
  }

  // ── what a tap does ──────────────────────────────────────────────────────

  /// Asks the host for the whole document. Completes when it answered, when
  /// [refreshTimeout] ran out, or at once when no host is attached. False
  /// when nothing could be asked.
  Future<bool> refresh() async {
    if (!attached) return false;
    final Completer<void> waiter = _refreshing ??= Completer<void>();
    try {
      await _send(<String, dynamic>{'type': 'dashboard_get'});
    } catch (_) {
      _refreshing = null;
      return false;
    }
    await waiter.future.timeout(refreshTimeout, onTimeout: () {});
    if (identical(_refreshing, waiter)) _refreshing = null;
    return true;
  }

  Future<void> log(String id, double value) =>
      _op(<String, dynamic>{'action': 'log', 'id': id, 'value': value});

  Future<void> check(String id, String item, bool done) => _op(
    <String, dynamic>{'action': 'check', 'id': id, 'item': item, 'done': done},
  );

  Future<void> remove(String id) =>
      _op(<String, dynamic>{'action': 'remove', 'id': id});

  Future<void> move(String id, int index) =>
      _op(<String, dynamic>{'action': 'move', 'id': id, 'index': index});

  Future<void> update(String id, Map<String, dynamic> patch) =>
      _op(<String, dynamic>{'action': 'update', 'id': id, 'patch': patch});

  Future<void> _op(Map<String, dynamic> body) async {
    _checkOwner();
    if (_uid == null) return;
    await ready();
    final Map<String, dynamic> op = <String, dynamic>{
      'op_id': _newOpId(),
      ...body,
      if (body['action'] == 'log') 'at': isoWithOffset(_clock()),
    };
    final _PendingOp pending = _PendingOp(op);
    _pending.add(pending);
    _view = null;
    notifyListeners();
    await _persistPending();
    if (!attached) return;
    try {
      await _send(<String, dynamic>{'type': 'dashboard_op', ...op});
      pending.sent = true;
    } catch (_) {
      // Stays pending: the next attach sends it.
    }
  }

  // ── what the host says ───────────────────────────────────────────────────

  /// One `dashboard_state` or `dashboard_error` frame.
  void handleFrame(Map<String, dynamic> payload) {
    _checkOwner();
    if (_uid == null) return;
    final Object? rawOpId = payload['op_id'];
    final String? opId = rawOpId is String && rawOpId.isNotEmpty
        ? rawOpId
        : null;
    switch (payload['type']) {
      case 'dashboard_state':
        _base = DashboardDocument.fromJson(payload['dashboard']);
        _loaded = true;
        if (opId != null) _settle(opId);
        _view = null;
        notifyListeners();
        unawaited(_persistBase());
        unawaited(_persistPending());
        final Completer<void>? waiter = _refreshing;
        if (waiter != null && !waiter.isCompleted && opId == null) {
          waiter.complete();
        }
      case 'dashboard_error':
        final Object? message = payload['message'];
        if (opId != null) {
          _pending.removeWhere((_PendingOp p) => p.id == opId);
        }
        notice.value = message is String && message.trim().isNotEmpty
            ? message.trim()
            : 'Your computer refused that change.';
        _view = null;
        notifyListeners();
        unawaited(_persistPending());
    }
  }

  /// The host answered [opId]; it answers in order, so every op sent before
  /// it is settled too.
  void _settle(String opId) {
    final int i = _pending.indexWhere((_PendingOp p) => p.id == opId);
    if (i < 0) return;
    final _PendingOp hit = _pending[i];
    final Set<_PendingOp> drop = <_PendingOp>{
      hit,
      if (hit.sent) ..._pending.take(i).where((_PendingOp p) => p.sent),
    };
    _pending.removeWhere(drop.contains);
  }

  // ── attachment ───────────────────────────────────────────────────────────

  void _onAttachment() {
    final String? host = _attachedHost.value;
    notifyListeners();
    for (final _PendingOp p in _pending) {
      p.sent = false;
    }
    if (host == null) return;
    unawaited(_attached(host));
  }

  Future<void> _attached(String host) async {
    _checkOwner();
    final String? uid = _uid;
    if (uid == null) return;
    if (host != _host) {
      _switchTo(uid, host);
      unawaited(_writeKv(_hostPointerKey(uid), host).catchError((Object _) {}));
    }
    await ready();
    if (_uid != uid || _attachedHost.value != host) return;
    // Flush first, then ask (§5): the answer then already carries them.
    for (final _PendingOp p in List<_PendingOp>.of(_pending)) {
      try {
        await _send(<String, dynamic>{'type': 'dashboard_op', ...p.op});
        p.sent = true;
      } catch (_) {
        return;
      }
    }
    try {
      await _send(<String, dynamic>{'type': 'dashboard_get'});
    } catch (_) {
      // The next attach asks again.
    }
  }

  // ── scope and cache ──────────────────────────────────────────────────────

  /// Drops everything when the signed-in user is not the one the copy
  /// belongs to, and starts reading the new user's cache.
  void _checkOwner() {
    final String? uid = _userId();
    if (uid == _uid) return;
    _switchTo(uid, uid == null ? null : _attachedHost.value);
  }

  void _switchTo(String? uid, String? host) {
    _generation++;
    _uid = uid;
    _host = host;
    _base = DashboardDocument.empty;
    _pending.clear();
    _view = null;
    _loaded = false;
    _loading = null;
    if (uid == null) return;
    _loading = _load(uid, host, _generation);
  }

  Future<void> _load(String uid, String? host, int generation) async {
    try {
      final String? resolvedHost = host ?? await _readKv(_hostPointerKey(uid));
      if (generation != _generation) return;
      _host = resolvedHost;
      final String key = _docKey(uid, resolvedHost);
      final String? rawDoc = await _readKv(key);
      final String? rawPending = await _readKv('${key}_pending');
      if (generation != _generation) return;
      if (rawDoc != null) {
        final Object? decoded = _tryDecode(rawDoc);
        // A host answer that landed during the read is newer than the cache.
        if (_base.version == 0 && _base.isEmpty) {
          _base = DashboardDocument.fromJson(decoded);
        }
      }
      final Object? pending = rawPending == null
          ? null
          : _tryDecode(rawPending);
      if (pending is List) {
        for (final Object? op in pending) {
          if (op is Map &&
              op['op_id'] is String &&
              kDashboardOpActions.contains(op['action'])) {
            _pending.add(_PendingOp(Map<String, dynamic>.from(op)));
          }
        }
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[dashboard] cache read failed: $error');
    }
    if (generation != _generation) return;
    _loaded = true;
    _view = null;
    notifyListeners();
  }

  Future<void> _persistBase() async {
    final String? uid = _uid;
    if (uid == null) return;
    try {
      await _writeKv(_docKey(uid, _host), jsonEncode(_base.toJson()));
    } catch (error) {
      if (kDebugMode) debugPrint('[dashboard] cache write failed: $error');
    }
  }

  Future<void> _persistPending() async {
    final String? uid = _uid;
    if (uid == null) return;
    try {
      await _writeKv(
        '${_docKey(uid, _host)}_pending',
        jsonEncode(<Map<String, dynamic>>[
          for (final _PendingOp p in _pending) p.op,
        ]),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[dashboard] pending write failed: $error');
    }
  }

  DashboardDocument _applyPending() {
    DashboardDocument doc = _base;
    final DateTime now = _clock();
    for (final _PendingOp p in _pending) {
      doc = applyDashboardOp(doc, p.op, now);
    }
    return doc;
  }

  static String _docKey(String uid, String? host) =>
      host == null || host.isEmpty
      ? 'dashboard_v1_$uid'
      : 'dashboard_v1_${uid}_$host';

  static String _hostPointerKey(String uid) => 'dashboard_v1_${uid}_host';

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static String docKeyFor(String uid, String? host) => _docKey(uid, host);
}

String? _currentUserId() {
  if (!SupabaseService.isInitialized) return null;
  return SupabaseService.auth.currentUser?.id;
}

Future<void> _sendOverRelay(Map<String, dynamic> frame) async {
  final Object? controller = AgentsRelayLink.instance.controller.value;
  if (controller is! AgentsRelayClient) {
    throw StateError('Not connected to the host');
  }
  if (frame['type'] == 'dashboard_get') {
    await controller.sendDashboardGet();
  } else {
    await controller.sendDashboardOp(frame);
  }
}

/// The paired host's device id while the relay is attached, else null.
///
/// The link carries a fresh controller on every reconnect, and a controller
/// is bound before its pairing finishes, so this follows both the link and
/// the bound controller's phase. Each change to a non-null value is an attach.
class RelayAttachment extends ValueNotifier<String?> {
  RelayAttachment._() : super(null) {
    AgentsRelayLink.instance.controller.addListener(_rebind);
    _rebind();
  }

  static final RelayAttachment instance = RelayAttachment._();

  AgentsRelayController? _bound;

  void _rebind() {
    final AgentsRelayController? next =
        AgentsRelayLink.instance.controller.value;
    if (!identical(next, _bound)) {
      _bound?.state.removeListener(_onState);
      _bound = next;
      next?.state.addListener(_onState);
    }
    _onState();
  }

  void _onState() {
    final AgentsRelayState? state = _bound?.state.value;
    value = state != null && state.isPaired
        ? (state.peerDeviceId ?? 'host')
        : null;
  }
}
