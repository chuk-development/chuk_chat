/// Prompts the app accepted but could not hand to the host yet.
///
/// A send goes out over the relay socket. When that socket is down — the host
/// asleep, the phone on a dead train, the app just launched — the send used to
/// end in `Not connected to your CoWork host.` and the prompt was gone: not
/// stored anywhere, not retried, not sent when the host came back. The user's
/// own words for it were "ob die Nachrichten im Backend ankommen, ist irgendwie
/// nicht klar" (bead cowork-i7sd).
///
/// This is where such a prompt waits. It is deliberately NOT the chat cache:
/// a full replay REPLACES that cache with the host's transcript, so a queued
/// prompt stored only as a cache row disappears the moment the socket comes
/// back — which is exactly the wrong moment. It lives in the SQLite `kv_cache`
/// table instead, one row per thread, and survives a process restart.
///
/// The prompt is kept VERBATIM as it will be sent. The replay's repeat guard
/// aligns the host's copy of a turn with the local one by comparing text, so a
/// queued prompt that differs from the row on screen would show the turn twice
/// (bead cowork-4rpt).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/cowork_backoff.dart';
import 'package:cowork/services/local_chat_cache_service.dart';

/// Prefix of the per-thread outbox key in the SQLite `kv_cache` table.
const String kTaskOutboxPrefix = 'cowork.task_outbox.';

/// One prompt waiting for a socket.
@immutable
class OutboxTask {
  const OutboxTask({
    required this.localId,
    required this.sessionKey,
    required this.prompt,
    required this.createdAt,
    this.modelId,
    this.providerSlug,
    this.reasoningEffort,
    this.attempts = 0,
    this.lastError,
    this.nextAttemptAt,
  });

  /// This app's own id for the prompt. The host never sees it; it is how the
  /// queue and the bubble on screen name the same thing.
  final String localId;
  final String sessionKey;

  /// Exactly the string that will be sent.
  final String prompt;
  final DateTime createdAt;
  final String? modelId;
  final String? providerSlug;
  final String? reasoningEffort;

  /// How often a flush has tried and failed. At [CoworkTaskOutbox.maxAttempts]
  /// the entry is given up on, so one poison prompt cannot loop forever.
  final int attempts;
  final String? lastError;

  /// Not before this instant. A trigger that arrives earlier leaves the entry
  /// alone, so a reconnect, a resume and a watchdog tick in the same second
  /// are one attempt, not three.
  final DateTime? nextAttemptAt;

  /// True when [now] is at or past [nextAttemptAt] (or nothing is set).
  bool isDue(DateTime now) =>
      nextAttemptAt == null || !now.isBefore(nextAttemptAt!);

  OutboxTask copyWith({
    int? attempts,
    String? lastError,
    DateTime? nextAttemptAt,
  }) => OutboxTask(
    localId: localId,
    sessionKey: sessionKey,
    prompt: prompt,
    createdAt: createdAt,
    modelId: modelId,
    providerSlug: providerSlug,
    reasoningEffort: reasoningEffort,
    attempts: attempts ?? this.attempts,
    lastError: lastError ?? this.lastError,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'localId': localId,
    'sessionKey': sessionKey,
    'prompt': prompt,
    'createdAt': createdAt.toIso8601String(),
    if (modelId != null) 'modelId': modelId,
    if (providerSlug != null) 'providerSlug': providerSlug,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    if (attempts > 0) 'attempts': attempts,
    if (lastError != null) 'lastError': lastError,
    if (nextAttemptAt != null)
      'nextAttemptAt': nextAttemptAt!.toIso8601String(),
  };

  /// Null for a row this version cannot read: a queue entry is a convenience,
  /// never a reason to fail a launch.
  static OutboxTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['localId'];
    final Object? session = raw['sessionKey'];
    final Object? prompt = raw['prompt'];
    if (id is! String || id.isEmpty) return null;
    if (session is! String || session.isEmpty) return null;
    if (prompt is! String || prompt.isEmpty) return null;
    return OutboxTask(
      localId: id,
      sessionKey: session,
      prompt: prompt,
      createdAt:
          DateTime.tryParse('${raw['createdAt']}') ?? DateTime.now().toUtc(),
      modelId: raw['modelId'] as String?,
      providerSlug: raw['providerSlug'] as String?,
      reasoningEffort: raw['reasoningEffort'] as String?,
      attempts: raw['attempts'] is int ? raw['attempts'] as int : 0,
      lastError: raw['lastError'] as String?,
      nextAttemptAt: raw['nextAttemptAt'] is String
          ? DateTime.tryParse(raw['nextAttemptAt'] as String)
          : null,
    );
  }
}

/// Reads and writes the per-thread queue. Static because there is one queue
/// per install, like the chat cache it sits next to.
class CoworkTaskOutbox {
  CoworkTaskOutbox._();

  /// After this many failed flushes an entry is dropped and reported, rather
  /// than retried on every reconnect for the rest of the install's life.
  static const int maxAttempts = 5;

  /// How long a failed entry waits before the next trigger may take it.
  /// `chat`: 500 ms, doubling, capped at 10 s (bead cowork-i7sd follow-up).
  static const CoworkBackoff backoff = CoworkBackoff.chat;

  /// The clock. A test moves it forward instead of waiting for real seconds.
  @visibleForTesting
  static DateTime Function() now = () => DateTime.now().toUtc();

  /// Test seams. Production leaves them null and goes to SQLite.
  @visibleForTesting
  static Future<String?> Function(String key)? read;
  @visibleForTesting
  static Future<void> Function(String key, String value)? write;
  @visibleForTesting
  static Future<void> Function(String key)? delete;

  /// Serialises the read-modify-write so two sends in the same frame cannot
  /// each overwrite the other's entry.
  ///
  /// Null means "nothing in flight". It is deliberately not seeded with a
  /// `Future.value()`: a future belongs to the zone that made it, and a widget
  /// test runs its body in a fake-async zone of its own. A chain seeded at
  /// class-init time — or in a `setUp` — would make every later `.then` wait
  /// on a zone that is no longer being pumped, and the call would simply never
  /// return. The first caller inside a zone starts the chain in that zone.
  static Future<void>? _chain;

  static String _key(String sessionKey) => '$kTaskOutboxPrefix$sessionKey';

  static Future<T> _locked<T>(Future<T> Function() action) {
    final Completer<T> done = Completer<T>();
    final Future<void> previous = _chain ?? Future<void>.value();
    _chain = previous.then((_) async {
      try {
        done.complete(await action());
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  static Future<List<OutboxTask>> _load(String sessionKey) async {
    try {
      final Future<String?> Function(String) get =
          read ?? LocalChatCacheService.kvGet;
      final String? raw = await get(_key(sessionKey));
      if (raw == null || raw.isEmpty) return <OutboxTask>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <OutboxTask>[];
      return <OutboxTask>[
        for (final Object? entry in decoded)
          if (OutboxTask.fromJson(entry) case final OutboxTask task) task,
      ];
    } catch (error) {
      // No SQLite (a widget test), or a row this version cannot read. An
      // unreadable queue is an empty queue, never a crash.
      if (kDebugMode) {
        debugPrint('[cowork-outbox] load failed for $sessionKey: $error');
      }
      return <OutboxTask>[];
    }
  }

  static Future<void> _save(String sessionKey, List<OutboxTask> tasks) async {
    try {
      if (tasks.isEmpty) {
        final Future<void> Function(String) remove =
            delete ?? LocalChatCacheService.kvDelete;
        await remove(_key(sessionKey));
        return;
      }
      final Future<void> Function(String, String) put =
          write ?? LocalChatCacheService.kvSet;
      await put(
        _key(sessionKey),
        jsonEncode(<Map<String, Object?>>[
          for (final OutboxTask task in tasks) task.toJson(),
        ]),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[cowork-outbox] save failed for $sessionKey: $error');
      }
    }
  }

  /// Puts [prompt] at the back of [sessionKey]'s queue and returns the entry.
  static Future<OutboxTask> enqueue({
    required String sessionKey,
    required String prompt,
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    String? localId,
    DateTime? createdAt,
  }) => _locked(() async {
    final DateTime created = (createdAt ?? now()).toUtc();
    final OutboxTask task = OutboxTask(
      localId: localId ?? 'q${created.microsecondsSinceEpoch}',
      sessionKey: sessionKey,
      prompt: prompt,
      createdAt: created,
      modelId: modelId,
      providerSlug: providerSlug,
      reasoningEffort: reasoningEffort,
    );
    final List<OutboxTask> tasks = await _load(sessionKey)
      ..add(task);
    await _save(sessionKey, tasks);
    return task;
  });

  /// What is still waiting for [sessionKey], oldest first.
  static Future<List<OutboxTask>> pendingFor(String sessionKey) =>
      _locked(() => _load(sessionKey));

  /// True when anything at all is waiting. Cheap enough for a rebuild.
  static Future<bool> hasPending(String sessionKey) async =>
      (await pendingFor(sessionKey)).isNotEmpty;

  static Future<void> remove(String sessionKey, String localId) =>
      _locked(() async {
        final List<OutboxTask> tasks = await _load(sessionKey)
          ..removeWhere((OutboxTask task) => task.localId == localId);
        await _save(sessionKey, tasks);
      });

  /// Records a failed flush. Returns true while the entry is still worth
  /// retrying; false once it has been given up on and removed.
  static Future<bool> markAttempt(
    String sessionKey,
    String localId,
    String error,
  ) => _locked(() async {
    final List<OutboxTask> tasks = await _load(sessionKey);
    final int index = tasks.indexWhere(
      (OutboxTask task) => task.localId == localId,
    );
    if (index < 0) return false;
    final int attempts = tasks[index].attempts + 1;
    final OutboxTask next = tasks[index].copyWith(
      attempts: attempts,
      lastError: error,
      // The next trigger may not take it before this: a failure earns a wait,
      // it does not earn a retry on every reconnect in the same second.
      nextAttemptAt: now().add(backoff.delayAfter(attempts)),
    );
    if (next.attempts >= maxAttempts) {
      tasks.removeAt(index);
      await _save(sessionKey, tasks);
      return false;
    }
    tasks[index] = next;
    await _save(sessionKey, tasks);
    return true;
  });

  /// Sends everything waiting for [sessionKey], oldest first, through [send].
  ///
  /// Call it AFTER the replay has been asked for: the host's transcript is the
  /// base every local row aligns against, and a prompt sent before the replay
  /// races its own echo back up the wire (bead cowork-4rpt).
  ///
  /// Stops at the first failure — the socket that just refused one prompt will
  /// refuse the next — and leaves the rest queued.
  ///
  /// It also stops at the first entry that is not due yet ([OutboxTask.isDue]).
  /// Stopping rather than skipping keeps the thread in order: the prompt the
  /// user typed second must not reach the host before the first one.
  static Future<int> flush(
    String sessionKey,
    Future<void> Function(OutboxTask task) send,
  ) async {
    final List<OutboxTask> tasks = await pendingFor(sessionKey);
    final DateTime at = now();
    int sent = 0;
    for (final OutboxTask task in tasks) {
      if (!task.isDue(at)) break;
      try {
        await send(task);
      } catch (error) {
        await markAttempt(sessionKey, task.localId, '$error');
        break;
      }
      await remove(sessionKey, task.localId);
      sent++;
    }
    return sent;
  }

  @visibleForTesting
  static Future<void> clearForTest(String sessionKey) =>
      _locked(() => _save(sessionKey, <OutboxTask>[]));

  /// Drops whatever is still queued on the serialiser.
  ///
  /// [_chain] is static and outlives one widget test. A read left in flight
  /// when a test ends — its store seam pulled out from under it, its fake
  /// clock gone — would never complete, and every later call would wait
  /// behind it forever. A test starts from a fresh chain instead.
  @visibleForTesting
  static void resetForTest() {
    _chain = null;
  }
}
