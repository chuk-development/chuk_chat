// lib/services/offline_retry_manager.dart
//
// The flush of the offline outbox. Design: docs/OFFLINE_SEND.md.
//
// Two retries live here:
//
// * The chat outbox ([OfflineQueueService]). A registered [SendExecutor]
//   sends one row; preparers run before it (voice transcription, image
//   upload). The flush runs on many triggers (app start once the key is
//   ready, app resume, offline -> online, a successful /v2/ws handshake, a
//   periodic tick while rows wait, a manual Retry). Each chat drains in seq
//   order and stops at its first row that cannot go out. A row is retried
//   with backoff and marked failed when the backoff is used up. A failed row
//   is never retried by itself; only a manual Retry moves it back.
//
// * The Agents retry. A paired thread flushes its own outbox; an unpaired
//   one asks the transport to go get the host. With FEATURE_AGENTS off this
//   part is inert.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/exponential_backoff.dart';

/// Outcome of a send executor call.
class SendExecutorResult {
  const SendExecutorResult.success()
    : success = true,
      error = null,
      accepted = false,
      deferred = false;

  /// A failure. Whether it is retried is read from [error] (network, 5xx and
  /// 429 retry; everything else fails the row).
  const SendExecutorResult.failure(String this.error)
    : success = false,
      accepted = false,
      deferred = false;

  /// The server had already accepted the request (it started a reply) when
  /// the send broke. Never re-sent by itself: a second send would bill the
  /// turn twice. The row is marked failed with Retry.
  const SendExecutorResult.accepted(String this.error)
    : success = false,
      accepted = true,
      deferred = false;

  /// Not now, and not the row's fault (no session yet, no key, chat not
  /// loaded). Does not count as an attempt.
  const SendExecutorResult.deferred(String this.error)
    : success = false,
      accepted = false,
      deferred = true;

  final bool success;
  final String? error;
  final bool accepted;
  final bool deferred;
}

/// Performs the actual send for one queued message.
typedef SendExecutor = Future<SendExecutorResult> Function(QueuedMessage msg);

/// Result of a preparer. [payload] replaces the row's payload when given.
class PrepareResult {
  const PrepareResult.ok({this.payload, this.hold = false})
    : error = null,
      deferred = false;
  const PrepareResult.failure(String this.error)
    : payload = null,
      hold = false,
      deferred = false;
  const PrepareResult.deferred(String this.error)
    : payload = null,
      hold = false,
      deferred = true;

  final Map<String, dynamic>? payload;

  /// Stop after preparing and wait for the user (voice with auto-send off).
  final bool hold;
  final String? error;
  final bool deferred;
  bool get success => error == null;
}

/// A step that runs before the send: voice transcription, image upload.
class OutboxPreparer {
  const OutboxPreparer({
    required this.name,
    required this.appliesTo,
    required this.prepare,
    this.onDone,
  });

  final String name;

  /// Whether the row still needs this step.
  final bool Function(QueuedMessage msg) appliesTo;
  final Future<PrepareResult> Function(QueuedMessage msg) prepare;

  /// Runs once the row is gone (sent, deleted, or wiped on sign-out), with
  /// its last known payload. Deletes the row's files.
  final Future<void> Function(QueuedMessage msg)? onDone;
}

/// Agents: sends everything queued for the thread it was registered for, and
/// answers how many prompts went out.
typedef OutboxFlush = Future<int> Function();

/// Agents: gets the transport to try the host again, from scratch.
typedef HostReconnect = Future<void> Function();

/// Lifecycle event for retry attempts.
enum OfflineRetryEventType {
  started,
  success,
  failedNonRetryable,
  failedDeferred,
  noExecutor,
  // The Agents retry reports on the whole thread, not on one queue entry.
  succeeded,
  failed,
  exhausted,
  // A row changed its payload (transcript ready, image uploaded) or was
  // deleted. The open chat reloads.
  updated,
  discarded,
}

class OfflineRetryEvent {
  const OfflineRetryEvent({
    required this.type,
    required this.queueId,
    this.chatId,
    this.error,
  });

  final OfflineRetryEventType type;
  final String queueId;
  final String? chatId;
  final String? error;
}

class OfflineRetryManager with WidgetsBindingObserver {
  OfflineRetryManager._();

  static final OfflineRetryManager instance = OfflineRetryManager._();

  /// Delay before attempt n+1 after n failed attempts. When the list is used
  /// up the row is marked failed. About 33 minutes of trying while online.
  static const List<Duration> backoffSchedule = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
  ];

  /// While rows wait, the outbox is flushed this often.
  static Duration tickInterval = const Duration(seconds: 45);

  /// A row pending longer than this shows Retry too.
  static const Duration longPending = Duration(minutes: 2);

  /// Test seam for the clock.
  @visibleForTesting
  static int Function() now = () => DateTime.now().millisecondsSinceEpoch;

  SendExecutor? _executor;
  SendExecutor? _agentsHandoff;
  final List<OutboxPreparer> _preparers = <OutboxPreparer>[];
  bool _initialized = false;
  bool _draining = false;
  bool _rerun = false;
  bool _wasOnline = true;
  Timer? _tick;
  Timer? _boot;
  StreamSubscription<List<QueuedMessage>>? _watchSub;
  StreamSubscription<dynamic>? _authSub;
  final StreamController<OfflineRetryEvent> _events =
      StreamController<OfflineRetryEvent>.broadcast();

  /// Rows of the signed-in user, by queue id. The bubbles and the chat list
  /// read their state here.
  final ValueNotifier<Map<String, QueuedMessage>> rows =
      ValueNotifier<Map<String, QueuedMessage>>(const {});

  void Function()? _listener;

  /// Agents: set while a thread view is paired, cleared when it is not.
  OutboxFlush? _flush;
  HostReconnect? _reconnect;
  String? _sessionKey;
  bool _busy = false;

  /// Waiting rows per chat (all states), for the chat list badge.
  Map<String, int> get pendingCountByChat {
    final out = <String, int>{};
    for (final r in rows.value.values) {
      out[r.chatId] = (out[r.chatId] ?? 0) + 1;
    }
    return out;
  }

  /// Wire up the triggers. Safe to call multiple times.
  void init() {
    if (_initialized) return;
    _initialized = true;
    _wasOnline = NetworkStatusService.isOnline;
    _listener = () {
      final online = NetworkStatusService.isOnline;
      final wasOffline = !_wasOnline;
      _wasOnline = online;
      if (online && wasOffline) kick('online');
    };
    NetworkStatusService.isOnlineListenable.addListener(_listener!);
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // No binding (pure unit test).
    }
    _watchSub = OfflineQueueService.instance.watch().listen(_onRows);
    MultiplexConnection.onAuthenticated = () {
      if (rows.value.isNotEmpty) kick('multiplex');
    };
    try {
      if (SupabaseService.isInitialized) {
        _authSub = SupabaseService.auth.onAuthStateChange.listen((state) {
          // A sign-in (or the restored session) shows and flushes this
          // user's rows; a sign-out hides them.
          unawaited(refreshRows());
          if (state.session != null) kick('auth');
        });
      }
    } catch (_) {}
    unawaited(_startup());
  }

  /// Startup: rows a killed app left in preparing/sending go back to queued,
  /// then wait for a user and a key and flush once.
  Future<void> _startup() async {
    try {
      await OfflineQueueService.instance.recoverInterrupted();
    } catch (_) {}
    await refreshRows();
    var tries = 0;
    _boot?.cancel();
    _boot = Timer.periodic(const Duration(seconds: 2), (t) {
      tries++;
      final ready =
          OutboxCipher.currentUserId() != null && OutboxCipher.canOpen();
      if (ready || tries > 90) {
        t.cancel();
        if (ready) kick('startup');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) kick('resume');
  }

  void _onRows(List<QueuedMessage> all) {
    final user = OutboxCipher.currentUserId();
    final map = <String, QueuedMessage>{
      for (final r in all)
        if (user != null && (r.userId == user || r.userId == null)) r.id: r,
    };
    rows.value = map;
    _armTick();
  }

  /// Reload [rows] from the store.
  Future<void> refreshRows() async {
    try {
      _onRows(await OfflineQueueService.instance.listAll());
    } catch (_) {}
  }

  void _armTick() {
    final waiting = rows.value.values.any(
      (r) => r.state == OutboxState.queued,
    );
    if (!waiting) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(tickInterval, (_) => kick('tick'));
  }

  /// Register the function that knows how to actually send one queued payload.
  void registerExecutor(SendExecutor executor) {
    _executor = executor;
  }

  /// Agents: a prepared row of an Agents thread (a transcribed voice
  /// message) is handed to the Agents outbox instead of the executor.
  void registerAgentsHandoff(SendExecutor? handoff) {
    _agentsHandoff = handoff;
  }

  /// Adds (or replaces, by name) a step that runs before the send.
  void registerPreparer(OutboxPreparer preparer) {
    _preparers.removeWhere((p) => p.name == preparer.name);
    _preparers.add(preparer);
  }

  /// Runs every preparer's cleanup for rows that are gone.
  Future<void> runCleanup(Iterable<QueuedMessage> gone) async {
    for (final row in gone) {
      for (final p in _preparers) {
        final done = p.onDone;
        if (done == null) continue;
        try {
          await done(row);
        } catch (_) {}
      }
    }
  }

  /// Agents: called by the thread view on the `paired` transition, and with
  /// null when the socket goes away again.
  void registerFlush(String sessionKey, OutboxFlush? flush) {
    if (flush == null) {
      if (_sessionKey != null && _sessionKey != sessionKey) return;
      _flush = null;
      _sessionKey = null;
      return;
    }
    _flush = flush;
    _sessionKey = sessionKey;
  }

  /// Agents: called by the thread view for its whole life; it is what Retry
  /// falls back to when nothing is paired.
  void registerReconnect(HostReconnect? reconnect) {
    _reconnect = reconnect;
  }

  /// Starts a flush unless one runs; a running flush runs once more after
  /// it ends. [reason] is for the debug log only.
  void kick(String reason) {
    if (kDebugMode) debugPrint('[OfflineRetry] kick ($reason)');
    onKick?.call(reason);
    unawaited(_drain(manual: reason == 'manual'));
  }

  /// Runs on every [kick] (start, resume, back online, server connect, a
  /// tick, a Retry). The follow-up dispatcher and the file sweep ride on it.
  void Function(String reason)? onKick;

  /// Manual Retry of one row: back to queued, then flush.
  Future<void> retryRow(String queueId) async {
    await OfflineQueueService.instance.requeue(queueId);
    await _drain(manual: true);
  }

  /// Manual trigger — UI "Retry" buttons call this.
  ///
  /// AGENTS: with FEATURE_AGENTS off this is the outbox drain and nothing
  /// else. With it on, a mounted Agents thread view also gets the press:
  /// flush its outbox while the host is paired, otherwise go and get the
  /// host. The chat outbox is drained as well, so an Agents view in front
  /// does not strand a chuk_chat message.
  Future<void> retryNow() async {
    if (!ChatOrigin.agentsEnabled) return _drain(manual: true);
    final OutboxFlush? flush = _flush;
    final HostReconnect? reconnect = _reconnect;
    if (flush == null && reconnect == null) {
      if (_executor != null) return _drain(manual: true);
      if (await _hasQueuedMessages()) return _drain(manual: true);
      _emitThreadEvent(OfflineRetryEventType.started, chatId: '');
      _emitThreadEvent(
        OfflineRetryEventType.exhausted,
        chatId: '',
        error: 'No host connection to retry on.',
      );
      return;
    }

    await _retryAgentsThread(flush, reconnect);
    if (_executor != null && await _hasQueuedMessages()) {
      await _drain(manual: true);
    }
  }

  Future<void> _retryAgentsThread(
    OutboxFlush? flush,
    HostReconnect? reconnect,
  ) async {
    if (_busy) return;
    _busy = true;
    final String chatId = _sessionKey ?? '';
    _emitThreadEvent(OfflineRetryEventType.started, chatId: chatId);
    try {
      if (flush != null) {
        final int sent = await flush();
        if (kDebugMode) {
          debugPrint('[agents-retry] flushed $sent queued prompt(s)');
        }
        _emitThreadEvent(OfflineRetryEventType.succeeded, chatId: chatId);
        return;
      }
      if (reconnect == null) {
        _emitThreadEvent(
          OfflineRetryEventType.exhausted,
          chatId: chatId,
          error: 'No host connection to retry on.',
        );
        return;
      }
      await reconnect();
      _emitThreadEvent(OfflineRetryEventType.succeeded, chatId: chatId);
    } catch (error) {
      _emitThreadEvent(
        OfflineRetryEventType.failed,
        chatId: chatId,
        error: '$error',
      );
    } finally {
      _busy = false;
    }
  }

  Future<bool> _hasQueuedMessages() async {
    try {
      return await OfflineQueueService.instance.count() > 0;
    } catch (_) {
      return false;
    }
  }

  void _emitThreadEvent(
    OfflineRetryEventType type, {
    required String chatId,
    String? error,
  }) {
    _emit(
      OfflineRetryEvent(
        type: type,
        queueId: '',
        chatId: chatId.isEmpty ? null : chatId,
        error: error,
      ),
    );
  }

  Stream<OfflineRetryEvent> get events => _events.stream;

  /// Emits an event for a row (used by the coordinator on delete).
  void notify(OfflineRetryEvent event) => _emit(event);

  // ── The flush ───────────────────────────────────────────────────────

  Future<void> _drain({required bool manual}) async {
    if (_draining) {
      _rerun = true;
      return;
    }
    _draining = true;
    try {
      var first = true;
      do {
        _rerun = false;
        // Only the pressed flush ignores the backoff times; a rerun asked
        // for while it ran (a trigger, the socket handshake) does not.
        await _drainOnce(manual: manual && first);
        first = false;
      } while (_rerun);
    } catch (e) {
      if (kDebugMode) debugPrint('[OfflineRetry] drain failed: $e');
    } finally {
      _draining = false;
    }
  }

  Future<void> _drainOnce({required bool manual}) async {
    final queue = OfflineQueueService.instance;
    final user = OutboxCipher.currentUserId();
    // Without a user there is no session to send with; the rows wait. Rows
    // of another account are never touched.
    if (user != null) {
      await queue.claimLegacyRows(user);
      await queue.sealPlaintextRows(user);
    }
    final pending = await queue.listAll(userId: user);
    // The bubbles and the badge follow the signed-in user's rows; the user
    // may have changed since the last store event.
    await refreshRows();
    if (pending.isEmpty) return;
    if (!NetworkStatusService.isOnline) {
      // An explicit press probes once; the edge back online flushes anyway.
      if (!manual || !await NetworkStatusService.quickCheck()) return;
    }
    if (kDebugMode) {
      debugPrint('[OfflineRetry] draining ${pending.length} row(s)');
    }

    // Per chat, in seq order. A chat stops at its first row that does not
    // go out, so a later message never overtakes an earlier one.
    final byChat = <String, List<QueuedMessage>>{};
    for (final r in pending) {
      (byChat[r.chatId] ??= <QueuedMessage>[]).add(r);
    }
    for (final chatRows in byChat.values) {
      for (final row in chatRows) {
        // A row that waits for the user (failed, held) or cannot be opened
        // does not block the rows after it; the user decides about it.
        if (row.locked ||
            row.state == OutboxState.failed ||
            row.state == OutboxState.held) {
          continue;
        }
        final sent = await _processRow(row, manual: manual);
        if (!sent) break;
      }
    }
  }

  /// Returns true when the row is gone (sent), so the chat goes on.
  Future<bool> _processRow(QueuedMessage row, {required bool manual}) async {
    final queue = OfflineQueueService.instance;
    if (row.locked) return false;
    if (row.state == OutboxState.failed || row.state == OutboxState.held) {
      return false;
    }
    if (!manual && row.nextAttemptAt > now()) return false;

    final SendExecutor? send = ChatOrigin.isAgentsThread(row.chatId)
        ? _agentsHandoff
        : _executor;
    if (send == null) {
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.noExecutor,
          queueId: row.id,
          chatId: row.chatId,
        ),
      );
      return false;
    }

    _emit(
      OfflineRetryEvent(
        type: OfflineRetryEventType.started,
        queueId: row.id,
        chatId: row.chatId,
      ),
    );

    var current = row;
    for (final p in _preparers) {
      if (!p.appliesTo(current)) continue;
      await queue.setState(current.id, OutboxState.preparing);
      PrepareResult prep;
      try {
        prep = await p.prepare(current);
      } catch (e) {
        prep = PrepareResult.failure('$e');
      }
      if (!prep.success) {
        await _onFailure(
          current,
          prep.error!,
          deferred: prep.deferred,
          accepted: false,
        );
        return false;
      }
      if (prep.payload != null) {
        await queue.updatePayload(current.id, prep.payload!);
        current = current.copyWith(sendPayload: prep.payload);
        _emit(
          OfflineRetryEvent(
            type: OfflineRetryEventType.updated,
            queueId: current.id,
            chatId: current.chatId,
          ),
        );
      }
      if (prep.hold) {
        await queue.setState(current.id, OutboxState.held, clearError: true);
        return false;
      }
    }

    await queue.setState(current.id, OutboxState.sending);
    SendExecutorResult result;
    try {
      result = await send(current);
    } catch (e) {
      result = SendExecutorResult.failure('$e');
    }

    if (result.success) {
      await queue.remove(current.id);
      await runCleanup([current]);
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.success,
          queueId: current.id,
          chatId: current.chatId,
        ),
      );
      return true;
    }
    await _onFailure(
      current,
      result.error ?? 'send failed',
      deferred: result.deferred,
      accepted: result.accepted,
    );
    return false;
  }

  Future<void> _onFailure(
    QueuedMessage row,
    String error, {
    required bool deferred,
    required bool accepted,
  }) async {
    final queue = OfflineQueueService.instance;
    if (deferred) {
      // Not the row's fault: back to queued, no attempt counted.
      await queue.setState(
        row.id,
        OutboxState.queued,
        error: error,
        nextAttemptAt: now() + backoffSchedule.first.inMilliseconds,
      );
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.failedDeferred,
          queueId: row.id,
          chatId: row.chatId,
          error: error,
        ),
      );
      return;
    }
    final retryable = !accepted && ExponentialBackoff.shouldRetryError(error);
    final attempts = row.attemptCount + 1;
    if (retryable && attempts < backoffSchedule.length + 1) {
      final delay = backoffSchedule[attempts - 1];
      await queue.setState(
        row.id,
        OutboxState.queued,
        error: error,
        bumpAttempts: true,
        nextAttemptAt: now() + delay.inMilliseconds,
      );
      _emit(
        OfflineRetryEvent(
          type: OfflineRetryEventType.failedDeferred,
          queueId: row.id,
          chatId: row.chatId,
          error: error,
        ),
      );
      return;
    }
    await queue.markFailed(row.id, error);
    _emit(
      OfflineRetryEvent(
        type: OfflineRetryEventType.failedNonRetryable,
        queueId: row.id,
        chatId: row.chatId,
        error: error,
      ),
    );
  }

  void _emit(OfflineRetryEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  @visibleForTesting
  Future<void> debugRetryAll() => retryNow();

  /// Test seam: one flush that ignores backoff times, like a manual press.
  @visibleForTesting
  Future<void> debugDrain({bool manual = false}) => _drain(manual: manual);

  @visibleForTesting
  void debugReset() {
    if (_listener != null) {
      NetworkStatusService.isOnlineListenable.removeListener(_listener!);
      _listener = null;
    }
    if (_initialized) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
    }
    _watchSub?.cancel();
    _watchSub = null;
    _authSub?.cancel();
    _authSub = null;
    _tick?.cancel();
    _tick = null;
    _boot?.cancel();
    _boot = null;
    _initialized = false;
    _executor = null;
    _agentsHandoff = null;
    _preparers.clear();
    _draining = false;
    _rerun = false;
    _wasOnline = true;
    _flush = null;
    _reconnect = null;
    _sessionKey = null;
    _busy = false;
    rows.value = const {};
  }
}
