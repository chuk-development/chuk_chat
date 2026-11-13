/// Prompts the app accepted but could not hand to the host yet.
///
/// A send goes out over the relay socket. When that socket is down — the host
/// asleep, the phone on a dead train, the app just launched — the send used to
/// end in `Not connected to your Agents host.` and the prompt was gone: not
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
///
/// ## The second store: tasks that WERE sent
///
/// [AgentsTaskOutbox] only ever held what the socket REFUSED. A send the socket
/// accepted was left to fate, and a fire-and-forget `send()` on a half-open
/// socket reports success for a frame nobody will ever read. The host had a
/// matching hole: a `task` that arrived before the controller session was
/// provisioned fell off the end of its handler with no run, no log and no error
/// frame, so the app saw exactly what it sees for a frame that never left the
/// phone — nothing. A message sent at 04:49 was simply gone, and the thread
/// kept the typing dots.
///
/// [AgentsPendingTasks] is the other half of the fix. It records a task from
/// the moment it is handed to the socket until the host's `task_ack` says the
/// host holds it. Anything still recorded when the socket comes back is re-sent
/// with its ORIGINAL `task_id`, which the host dedupes — so a task that did
/// arrive is answered `duplicate` and never runs twice.
///
/// The id belongs to ONE send, not to the user's message: a tool-loop pass, a
/// regenerate and a continue are each a real send the host must run, and the
/// host's dedupe is strict enough that sharing an id across them would leave
/// the second one quietly undone.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_backoff.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';

/// Prefix of the per-thread outbox key in the SQLite `kv_cache` table.
const String kTaskOutboxPrefix = 'agents.task_outbox.';

/// One prompt waiting for a socket.
@immutable
class OutboxTask {
  const OutboxTask({
    required this.localId,
    required this.sessionKey,
    required this.prompt,
    required this.createdAt,
    this._taskId,
    this.modelId,
    this.providerSlug,
    this.reasoningEffort,
    this.attempts = 0,
    this.lastError,
    this.nextAttemptAt,
    this.failed = false,
    this.attachments = const <String>[],
    this.blobIds = const <String>[],
  });

  /// The local copies of the files this prompt carries: store refs and
  /// image paths, all sealed on this device (docs/OFFLINE_SEND.md, "Agents").
  /// They are uploaded right before the task goes out.
  final List<String> attachments;

  /// Files the host already holds for this prompt (a task that was sent and
  /// never confirmed). Sent as they are when [attachments] is empty.
  final List<String> blobIds;

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

  /// The `task_id` this prompt goes out under, minted ONCE when it is queued
  /// and stored with it. Every flush of the entry sends the same id, so a
  /// second flush of a prompt that did arrive is answered `duplicate` by the
  /// host instead of running twice. A row stored before the id was kept falls
  /// back to the id the old flush derived from [localId], so it stays the
  /// same task too.
  String get taskId => _taskId ?? legacyTaskId(localId);
  final String? _taskId;

  /// The id older builds derived at flush time. The wire contract caps
  /// `task_id` at 64 characters.
  static String legacyTaskId(String localId) {
    final String id = 'o-$localId';
    return id.length <= 64 ? id : id.substring(0, 64);
  }

  /// How often a flush has tried and failed. At [AgentsTaskOutbox.maxAttempts]
  /// the entry is marked [failed]: it stays stored, but automatic flushes
  /// leave it alone until the user asks for it again.
  final int attempts;
  final String? lastError;

  /// Not before this instant. A trigger that arrives earlier leaves the entry
  /// alone, so a reconnect, a resume and a watchdog tick in the same second
  /// are one attempt, not three.
  final DateTime? nextAttemptAt;

  /// True once the entry used up its automatic attempts. It is never deleted
  /// for that: only the user (Retry or Discard) or a sign-out removes it.
  final bool failed;

  /// True when [now] is at or past [nextAttemptAt] (or nothing is set), and
  /// the entry has not [failed].
  bool isDue(DateTime now) =>
      !failed && (nextAttemptAt == null || !now.isBefore(nextAttemptAt!));

  OutboxTask copyWith({
    int? attempts,
    String? lastError,
    DateTime? nextAttemptAt,
    bool? failed,
    bool clearRetryState = false,
  }) => OutboxTask(
    localId: localId,
    sessionKey: sessionKey,
    prompt: prompt,
    createdAt: createdAt,
    taskId: taskId,
    modelId: modelId,
    providerSlug: providerSlug,
    reasoningEffort: reasoningEffort,
    attachments: attachments,
    blobIds: blobIds,
    attempts: attempts ?? this.attempts,
    lastError: clearRetryState ? lastError : (lastError ?? this.lastError),
    nextAttemptAt: clearRetryState
        ? nextAttemptAt
        : (nextAttemptAt ?? this.nextAttemptAt),
    failed: failed ?? this.failed,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'localId': localId,
    'sessionKey': sessionKey,
    'prompt': prompt,
    'createdAt': createdAt.toIso8601String(),
    'taskId': taskId,
    if (modelId != null) 'modelId': modelId,
    if (providerSlug != null) 'providerSlug': providerSlug,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    if (attachments.isNotEmpty) 'attachments': attachments,
    if (blobIds.isNotEmpty) 'blobIds': blobIds,
    if (attempts > 0) 'attempts': attempts,
    if (lastError != null) 'lastError': lastError,
    if (nextAttemptAt != null)
      'nextAttemptAt': nextAttemptAt!.toIso8601String(),
    if (failed) 'failed': true,
  };

  /// Null for a row this version cannot read: a queue entry is a convenience,
  /// never a reason to fail a launch. Rows written before `taskId` and
  /// `failed` existed load with the derived id and as not failed.
  static OutboxTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['localId'];
    final Object? session = raw['sessionKey'];
    final Object? prompt = raw['prompt'];
    if (id is! String || id.isEmpty) return null;
    if (session is! String || session.isEmpty) return null;
    if (prompt is! String || prompt.isEmpty) return null;
    final Object? taskId = raw['taskId'];
    return OutboxTask(
      localId: id,
      sessionKey: session,
      prompt: prompt,
      createdAt:
          DateTime.tryParse('${raw['createdAt']}') ?? DateTime.now().toUtc(),
      taskId: taskId is String && taskId.isNotEmpty ? taskId : null,
      modelId: raw['modelId'] as String?,
      providerSlug: raw['providerSlug'] as String?,
      reasoningEffort: raw['reasoningEffort'] as String?,
      attachments: _strings(raw['attachments']),
      blobIds: _strings(raw['blobIds']),
      attempts: raw['attempts'] is int ? raw['attempts'] as int : 0,
      lastError: raw['lastError'] as String?,
      nextAttemptAt: raw['nextAttemptAt'] is String
          ? DateTime.tryParse(raw['nextAttemptAt'] as String)
          : null,
      failed: raw['failed'] == true,
    );
  }
}

/// Thrown by a flush sender that has no link to send on. [AgentsTaskOutbox.flush]
/// stops on it like on any failure, but does NOT count an attempt: only a
/// send the paired socket refused moves an entry towards
/// [OutboxTask.failed].
class OutboxSendDeferred implements Exception {
  const OutboxSendDeferred([this.reason = 'not paired']);

  final String reason;

  @override
  String toString() => 'OutboxSendDeferred: $reason';
}

/// Thrown by a flush sender when the entry itself cannot go out as it is
/// (its files are too large, too many, empty or gone). Sending again will
/// not help, so [AgentsTaskOutbox.flush] marks the entry
/// [OutboxTask.failed] at once, with [reason], instead of counting attempts.
class OutboxSendRefused implements Exception {
  const OutboxSendRefused(this.reason);

  final String reason;

  @override
  String toString() => 'OutboxSendRefused: $reason';
}

/// What one `kv_cache` row of either store holds once it is read.
///
/// [rows] are the entries this install can read. [locked] are sealed blobs it
/// cannot open right now (no key yet, or a key that does not fit): they are
/// carried along VERBATIM on every write, never dropped, and tried again on
/// every read. A thread with anything [locked] is not flushed, so a prompt the
/// app cannot read never gets overtaken by a newer one.
class _StoredRows {
  const _StoredRows(this.rows, this.locked);

  static const _StoredRows empty = _StoredRows(<Object?>[], <String>[]);

  final List<Object?> rows;
  final List<String> locked;
}

/// Encryption at rest for both stores in this file.
///
/// A row is written as `{"sealed": "<blob>"}`, the blob being the JSON list of
/// entries sealed by [OutboxCipher.seal] (the user's chat key, AES-GCM). When
/// no key is loaded the list is written as plain JSON, exactly the format
/// older builds wrote, and the next write with a key seals it. Blobs that
/// cannot be opened ride in `"locked"`; plain entries next to locked blobs
/// ride in `"tasks"`.
abstract final class _RowCodec {
  static Future<_StoredRows> decode(String? raw) async {
    if (raw == null || raw.isEmpty) return _StoredRows.empty;
    final Object? decoded = jsonDecode(raw);
    if (decoded is List) return _StoredRows(decoded, const <String>[]);
    if (decoded is! Map) return _StoredRows.empty;
    final List<Object?> rows = <Object?>[];
    final List<String> locked = <String>[];
    // Blobs that could not be opened before are OLDER than anything written
    // next to them, so whatever opens now goes first.
    final Object? oldLocked = decoded['locked'];
    if (oldLocked is List) {
      for (final Object? blob in oldLocked) {
        if (blob is! String || blob.isEmpty) continue;
        final List<Object?>? opened = await _open(blob);
        if (opened == null) {
          locked.add(blob);
        } else {
          rows.addAll(opened);
        }
      }
    }
    final Object? sealed = decoded['sealed'];
    if (sealed is String && sealed.isNotEmpty) {
      final List<Object?>? opened = await _open(sealed);
      if (opened == null) {
        locked.add(sealed);
      } else {
        rows.addAll(opened);
      }
    }
    final Object? plain = decoded['tasks'];
    if (plain is List) rows.addAll(plain);
    return _StoredRows(rows, locked);
  }

  /// Null when [blob] cannot be opened now. Never throws.
  static Future<List<Object?>?> _open(String blob) async {
    try {
      if (!OutboxCipher.canOpen()) return null;
      final Object? list = jsonDecode(await OutboxCipher.open(blob));
      return list is List ? list : null;
    } catch (_) {
      return null;
    }
  }

  /// Null means "nothing left": the caller deletes the row.
  static Future<String?> encode(
    List<Map<String, Object?>> rows,
    List<String> locked,
  ) async {
    if (rows.isEmpty && locked.isEmpty) return null;
    if (rows.isEmpty) return jsonEncode(<String, Object?>{'locked': locked});
    final String plain = jsonEncode(rows);
    String? sealed;
    try {
      sealed = await OutboxCipher.seal(plain);
    } catch (error) {
      if (kDebugMode) debugPrint('[agents-outbox] seal failed: $error');
      sealed = null;
    }
    if (sealed == null) {
      // No key yet. A prompt typed before the key is ready must not be lost,
      // so it is kept readable and sealed on the next write that has a key.
      if (locked.isEmpty) return plain;
      return jsonEncode(<String, Object?>{'tasks': rows, 'locked': locked});
    }
    return jsonEncode(<String, Object?>{
      'sealed': sealed,
      if (locked.isNotEmpty) 'locked': locked,
    });
  }
}

/// The typed view of one outbox row.
class _OutboxRow {
  _OutboxRow(this.tasks, this.locked, {this.readFailed = false});

  final List<OutboxTask> tasks;
  final List<String> locked;

  /// The store could not be read at all. A write based on this row would
  /// replace rows nobody has seen, so only [AgentsTaskOutbox.enqueue] (which
  /// would otherwise lose the new prompt) writes after a failed read.
  final bool readFailed;
}

/// Reads and writes the per-thread queue. Static because there is one queue
/// per install, like the chat cache it sits next to.
///
/// Nothing in here ever deletes a prompt on its own. An entry leaves the queue
/// only when its send came back, when the user discards it, or when the user
/// signs out ([wipeAll]). An entry that keeps failing is marked
/// [OutboxTask.failed] and kept: the owner's rule is that nothing typed may be
/// lost.
class AgentsTaskOutbox {
  AgentsTaskOutbox._();

  /// After this many failed flushes an entry is marked failed: it stays in
  /// the queue, but automatic flushes skip it, so one poison prompt cannot
  /// loop forever or hold the prompts behind it.
  static const int maxAttempts = 5;

  /// How long a failed entry waits before the next trigger may take it.
  /// `chat`: 500 ms, doubling, capped at 10 s (bead cowork-i7sd follow-up).
  static const AgentsBackoff backoff = AgentsBackoff.chat;

  /// Bumped after every write to either store, so a widget that shows an
  /// entry's state can rebuild without polling.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

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

  /// Makes two enqueues in the same microsecond two different entries.
  static int _seq = 0;

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

  /// Reads a raw row through the seam or SQLite. Throws when there is no
  /// store; the callers decide what that means.
  static Future<String?> _readRaw(String key) =>
      (read ?? LocalChatCacheService.kvGet)(key);

  /// Writes [encoded] under [key], or deletes the row when it is null.
  static Future<void> _writeRaw(String key, String? encoded) async {
    if (encoded == null) {
      await (delete ?? LocalChatCacheService.kvDelete)(key);
    } else {
      await (write ?? LocalChatCacheService.kvSet)(key, encoded);
    }
    changes.value++;
  }

  static Future<List<String>> _listKeys(String prefix) =>
      (readKeys ?? LocalChatCacheService.kvKeys)(prefix);

  static Future<_OutboxRow> _loadRow(String sessionKey) async {
    try {
      final _StoredRows stored = await _RowCodec.decode(
        await _readRaw(_key(sessionKey)),
      );
      return _OutboxRow(<OutboxTask>[
        for (final Object? entry in stored.rows)
          if (OutboxTask.fromJson(entry) case final OutboxTask task) task,
      ], stored.locked);
    } catch (error) {
      // No SQLite (a widget test), or a row this version cannot read. An
      // unreadable queue is an empty queue, never a crash.
      if (kDebugMode) {
        debugPrint('[agents-outbox] load failed for $sessionKey: $error');
      }
      return _OutboxRow(<OutboxTask>[], <String>[], readFailed: true);
    }
  }

  static Future<List<OutboxTask>> _load(String sessionKey) async =>
      (await _loadRow(sessionKey)).tasks;

  static Future<void> _saveRow(String sessionKey, _OutboxRow row) async {
    try {
      await _writeRaw(
        _key(sessionKey),
        await _RowCodec.encode(<Map<String, Object?>>[
          for (final OutboxTask task in row.tasks) task.toJson(),
        ], row.locked),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-outbox] save failed for $sessionKey: $error');
      }
    }
  }

  /// Reads [sessionKey]'s row, lets [edit] change its entries, and writes it
  /// back with any locked blobs untouched. Inside the serialiser.
  static Future<T> _edit<T>(
    String sessionKey,
    Future<T> Function(List<OutboxTask> tasks) edit, {
    bool writeAfterFailedRead = false,
  }) => _locked(() async {
    final _OutboxRow row = await _loadRow(sessionKey);
    final T result = await edit(row.tasks);
    if (!row.readFailed || writeAfterFailedRead) {
      await _saveRow(sessionKey, row);
    }
    return result;
  });

  /// Puts [prompt] at the back of [sessionKey]'s queue and returns the entry.
  ///
  /// [taskId] is the `task_id` the prompt will go out under. A caller that
  /// already minted one for a send the socket refused passes it, so a frame
  /// that did slip out is still the same task to the host. Left null, the
  /// entry mints its own here, once, and every flush reuses it.
  static Future<OutboxTask> enqueue({
    required String sessionKey,
    required String prompt,
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    String? localId,
    String? taskId,
    DateTime? createdAt,
    bool failed = false,
    String? lastError,
    List<String> attachments = const <String>[],
    List<String> blobIds = const <String>[],
  }) {
    final DateTime created = (createdAt ?? now()).toUtc();
    _seq = (_seq + 1) & 0xffffff;
    final String id =
        localId ??
        'q${created.microsecondsSinceEpoch}-${_seq.toRadixString(36)}';
    final OutboxTask task = OutboxTask(
      localId: id,
      sessionKey: sessionKey,
      prompt: prompt,
      createdAt: created,
      taskId: (taskId != null && taskId.isNotEmpty)
          ? taskId
          : OutboxTask.legacyTaskId(id),
      modelId: modelId,
      providerSlug: providerSlug,
      reasoningEffort: reasoningEffort,
      failed: failed,
      lastError: lastError,
      attachments: List<String>.unmodifiable(attachments),
      blobIds: List<String>.unmodifiable(blobIds),
    );
    return _edit(sessionKey, (List<OutboxTask> tasks) async {
      tasks.add(task);
      return task;
    }, writeAfterFailedRead: true);
  }

  /// What is still waiting for [sessionKey], oldest first. Failed entries are
  /// included; check [OutboxTask.failed].
  static Future<List<OutboxTask>> pendingFor(String sessionKey) =>
      _locked(() => _load(sessionKey));

  /// True when anything at all is waiting. Cheap enough for a rebuild.
  static Future<bool> hasPending(String sessionKey) async =>
      (await pendingFor(sessionKey)).isNotEmpty;

  static Future<void> remove(String sessionKey, String localId) =>
      _edit(sessionKey, (List<OutboxTask> tasks) async {
        tasks.removeWhere((OutboxTask task) => task.localId == localId);
      });

  /// Records a failed flush. Returns true while the entry is still retried
  /// automatically; false once it is [OutboxTask.failed] (it is KEPT, with
  /// its last error) or gone.
  static Future<bool> markAttempt(
    String sessionKey,
    String localId,
    String error,
  ) => _edit(sessionKey, (List<OutboxTask> tasks) async {
    final int index = tasks.indexWhere(
      (OutboxTask task) => task.localId == localId,
    );
    if (index < 0) return false;
    final int attempts = tasks[index].attempts + 1;
    final bool failed = attempts >= maxAttempts;
    tasks[index] = tasks[index].copyWith(
      attempts: attempts,
      lastError: error,
      failed: failed,
      // The next trigger may not take it before this: a failure earns a wait,
      // it does not earn a retry on every reconnect in the same second.
      nextAttemptAt: now().add(backoff.delayAfter(attempts)),
    );
    return !failed;
  });

  /// Marks [localId] [OutboxTask.failed] now, with [error]: it is kept and
  /// waits for the user. Returns whether the entry was found.
  static Future<bool> markFailed(
    String sessionKey,
    String localId,
    String error,
  ) => _edit(sessionKey, (List<OutboxTask> tasks) async {
    final int index = tasks.indexWhere(
      (OutboxTask task) => task.localId == localId,
    );
    if (index < 0) return false;
    tasks[index] = tasks[index].copyWith(
      attempts: tasks[index].attempts + 1,
      lastError: error,
      failed: true,
    );
    return true;
  });

  /// The session keys that have a queue row, from the store itself.
  static Future<List<String>> _sessionKeys() async {
    final List<String> rows = await _listKeys(kTaskOutboxPrefix);
    return <String>[
      for (final String row in rows)
        if (row.length > kTaskOutboxPrefix.length)
          row.substring(kTaskOutboxPrefix.length),
    ];
  }

  /// The entry named [localId] in any thread, or null. Reads every thread's
  /// row, so call it on a user action, not per frame.
  static Future<OutboxTask?> findByLocalId(String localId) async {
    final List<String> sessions;
    try {
      sessions = await _sessionKeys();
    } catch (_) {
      return null;
    }
    for (final String sessionKey in sessions) {
      for (final OutboxTask task in await pendingFor(sessionKey)) {
        if (task.localId == localId) return task;
      }
    }
    return null;
  }

  /// The user asked for [localId] again: a failed entry goes back to
  /// pending with a clean attempt count and is due at once. Searches every
  /// thread. Returns whether the entry was found.
  static Future<bool> requeueByLocalId(String localId) async {
    final OutboxTask? found = await findByLocalId(localId);
    if (found == null) return false;
    return _edit(found.sessionKey, (List<OutboxTask> tasks) async {
      final int index = tasks.indexWhere(
        (OutboxTask t) => t.localId == localId,
      );
      if (index < 0) return false;
      tasks[index] = tasks[index].copyWith(
        attempts: 0,
        failed: false,
        clearRetryState: true,
      );
      return true;
    });
  }

  /// Every failed entry of [sessionKey] back to pending, as
  /// [requeueByLocalId] does for one. The Retry button of a thread runs it
  /// before it flushes. Returns how many were requeued.
  static Future<int> requeueFailed(String sessionKey) =>
      _edit(sessionKey, (List<OutboxTask> tasks) async {
        int count = 0;
        for (int i = 0; i < tasks.length; i++) {
          if (!tasks[i].failed) continue;
          tasks[i] = tasks[i].copyWith(
            attempts: 0,
            failed: false,
            clearRetryState: true,
          );
          count++;
        }
        return count;
      });

  /// The user threw [localId] away. Searches every thread. Returns whether
  /// the entry was found.
  static Future<bool> discardByLocalId(String localId) async {
    final OutboxTask? found = await findByLocalId(localId);
    if (found == null) return false;
    return _edit(found.sessionKey, (List<OutboxTask> tasks) async {
      final int before = tasks.length;
      tasks.removeWhere((OutboxTask t) => t.localId == localId);
      return tasks.length != before;
    });
  }

  /// Sign-out: deletes every queued prompt AND every unacknowledged-task
  /// record of every thread. The next account on this device must never send
  /// the last one's words to its own host.
  static Future<void> wipeAll() => _locked(() async {
    for (final String prefix in <String>[
      kTaskOutboxPrefix,
      kPendingTaskPrefix,
    ]) {
      List<String> keys;
      try {
        keys = await _listKeys(prefix);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[agents-outbox] wipe: key listing failed: $error');
        }
        continue;
      }
      for (final String key in keys) {
        if (!key.startsWith(prefix)) continue;
        try {
          await _writeRaw(key, null);
        } catch (error) {
          if (kDebugMode) debugPrint('[agents-outbox] wipe failed: $error');
        }
      }
    }
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
  /// user typed second must not reach the host before the first one. A
  /// [OutboxTask.failed] entry is the one exception: it is skipped, because it
  /// waits for the user and must not hold everything behind it for ever.
  ///
  /// A thread whose row holds a sealed blob this install cannot open (no key
  /// yet) is not flushed at all: what is readable might be newer than what is
  /// not.
  ///
  /// One flush per thread at a time. A flush reads the queue, then removes
  /// each entry only after its send came back — so two flushes overlapping in
  /// that window would both see the same prompt. The guard below stops that,
  /// and the entry's stored [OutboxTask.taskId] makes any copy that still
  /// slips through a `duplicate` to the host rather than a second run.
  static Future<int> flush(
    String sessionKey,
    Future<void> Function(OutboxTask task) send,
  ) async {
    if (!_flushing.add(sessionKey)) return 0;
    try {
      final _OutboxRow row = await _locked(() => _loadRow(sessionKey));
      if (row.locked.isNotEmpty) return 0;
      final DateTime at = now();
      int sent = 0;
      for (final OutboxTask task in row.tasks) {
        if (task.failed) continue;
        if (!task.isDue(at)) break;
        try {
          await send(task);
        } on OutboxSendDeferred {
          // No link: not the prompt's fault, so no attempt is counted. A
          // flapping network must never push a prompt into `failed`.
          break;
        } on OutboxSendRefused catch (refused) {
          // The entry itself is the problem (its files): no retry can fix
          // it. It fails now and waits for the user; the link is fine, so
          // the entries behind it still go.
          await markFailed(sessionKey, task.localId, refused.reason);
          continue;
        } catch (error) {
          await markAttempt(sessionKey, task.localId, '$error');
          break;
        }
        await remove(sessionKey, task.localId);
        sent++;
      }
      return sent;
    } finally {
      _flushing.remove(sessionKey);
    }
  }

  /// Session keys with a flush in flight. See [flush] for why one per thread
  /// is one too many.
  static final Set<String> _flushing = <String>{};

  /// Sends EVERY thread's queued prompts, oldest first within a thread,
  /// through [send]. [send] must route by [OutboxTask.sessionKey], not by a
  /// captured thread key.
  ///
  /// The per-thread [flush] is what the open thread's Retry button runs. This
  /// is the whole-queue counterpart: prompts typed while the host was down
  /// are typed INTO a thread, but the user expects them all to go out when
  /// the link returns — not only those of the thread that happens to be on
  /// screen when the socket comes back.
  ///
  /// The session keys come from the store itself (every `kv_cache` key under
  /// [kTaskOutboxPrefix]), so a thread whose view was never mounted flushes
  /// too. One failed thread does not stop the others.
  static Future<int> flushAll(
    Future<void> Function(OutboxTask task) send,
  ) async {
    List<String> sessions;
    try {
      sessions = await _sessionKeys();
    } catch (error) {
      // No store (a widget test, web without prefs yet): nothing to flush.
      if (kDebugMode) {
        debugPrint('[agents-outbox] key listing failed: $error');
      }
      return 0;
    }
    int sent = 0;
    for (final String sessionKey in sessions) {
      sent += await flush(sessionKey, send);
    }
    return sent;
  }

  /// Test seam for the key listing. Production leaves it null and reads the
  /// SQLite `kv_cache` table.
  @visibleForTesting
  static Future<List<String>> Function(String prefix)? readKeys;

  /// Whether ANY thread's queue holds an entry that may go out right now.
  /// Failed entries never count: they wait for the user.
  ///
  /// The paired transition and the Retry button flush immediately, but a send
  /// that failed earns a wait ([markAttempt]) — and during that wait nothing
  /// else would look at the queue again. This is the poll the watchdog calls,
  /// so a backed-off prompt goes out when it becomes due.
  static Future<bool> anyDue() async {
    final List<String> sessions;
    try {
      sessions = await _sessionKeys();
    } catch (_) {
      return false;
    }
    final DateTime at = now();
    for (final String sessionKey in sessions) {
      final _OutboxRow row = await _locked(() => _loadRow(sessionKey));
      if (row.locked.isNotEmpty) continue;
      for (final OutboxTask task in row.tasks) {
        if (task.isDue(at)) return true;
      }
    }
    return false;
  }

  /// Every local attachment path a queued prompt still names, so the file
  /// sweeper keeps those files.
  ///
  /// [complete] is false when some row could not be read (no key yet, a
  /// sealed blob of another key, a store error): the paths of that row are
  /// not known. The readable rows still count, so one bad row does not hide
  /// what the others name. The caller decides how careful to be with files
  /// no known row names ([OfflineFileSweeper] waits much longer then).
  static Future<({Set<String> paths, bool complete})> attachmentPaths() async {
    final Set<String> out = <String>{};
    bool complete = true;
    final List<String> sessions;
    try {
      sessions = await _sessionKeys();
    } catch (_) {
      return (paths: out, complete: false);
    }
    for (final String sessionKey in sessions) {
      try {
        final _OutboxRow row = await _locked(() => _loadRow(sessionKey));
        if (row.locked.isNotEmpty || row.readFailed) complete = false;
        for (final OutboxTask task in row.tasks) {
          out.addAll(task.attachments);
        }
      } catch (_) {
        complete = false;
      }
    }
    return (paths: out, complete: complete);
  }

  @visibleForTesting
  static Future<void> clearForTest(String sessionKey) => _locked(
    () => _saveRow(sessionKey, _OutboxRow(<OutboxTask>[], <String>[])),
  );

  /// Drops whatever is still queued on the serialiser.
  ///
  /// [_chain] is static and outlives one widget test. A read left in flight
  /// when a test ends — its store seam pulled out from under it, its fake
  /// clock gone — would never complete, and every later call would wait
  /// behind it forever. A test starts from a fresh chain instead.
  @visibleForTesting
  static void resetForTest() {
    _chain = null;
    _flushing.clear();
  }
}

/// Prefix of the per-thread unacknowledged-task key in the SQLite `kv_cache`
/// table. Deliberately its own namespace: what is here has ALREADY gone out,
/// so a flush of [kTaskOutboxPrefix] must never pick it up and send it twice.
const String kPendingTaskPrefix = 'agents.task_pending_ack.';

/// One task the socket took, still waiting for the host's `task_ack`.
@immutable
class PendingTask {
  const PendingTask({
    required this.taskId,
    required this.sessionKey,
    required this.prompt,
    required this.sentAt,
    this.modelId,
    this.providerSlug,
    this.reasoningEffort,
    this.attempts = 1,
    this.blobIds = const <String>[],
  });

  /// The `blob_id`s the task named. A re-send names the same files: the host
  /// keeps an uploaded file in the workspace.
  final List<String> blobIds;

  /// The id on the wire, minted once per SEND. Every re-send of that send
  /// carries this same string, which is the only reason a blind re-send is
  /// safe: the host dedupes on it and answers `duplicate` rather than running
  /// the task again. A different send — the next pass, a regenerate — is a
  /// different id, or the host would call it a duplicate and never run it.
  final String taskId;
  final String sessionKey;

  /// Exactly the string that went out, so a re-send is byte-identical.
  final String prompt;

  /// When the newest attempt went to the socket.
  final DateTime sentAt;
  final String? modelId;
  final String? providerSlug;
  final String? reasoningEffort;

  /// How often this task has been handed to a socket, the first send included.
  /// At [AgentsPendingTasks.maxAttempts] the app stops trying and tells the
  /// user the message did not arrive, rather than spinning for ever.
  final int attempts;

  PendingTask copyWith({int? attempts, DateTime? sentAt}) => PendingTask(
    taskId: taskId,
    sessionKey: sessionKey,
    prompt: prompt,
    sentAt: sentAt ?? this.sentAt,
    modelId: modelId,
    providerSlug: providerSlug,
    reasoningEffort: reasoningEffort,
    attempts: attempts ?? this.attempts,
    blobIds: blobIds,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'taskId': taskId,
    'sessionKey': sessionKey,
    'prompt': prompt,
    'sentAt': sentAt.toIso8601String(),
    if (modelId != null) 'modelId': modelId,
    if (providerSlug != null) 'providerSlug': providerSlug,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
    'attempts': attempts,
    if (blobIds.isNotEmpty) 'blobIds': blobIds,
  };

  /// Null for a row this version cannot read — the same rule as [OutboxTask]:
  /// a delivery record is a safety net, never a reason to fail a launch.
  static PendingTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['taskId'];
    final Object? session = raw['sessionKey'];
    final Object? prompt = raw['prompt'];
    if (id is! String || id.isEmpty) return null;
    if (session is! String || session.isEmpty) return null;
    if (prompt is! String) return null;
    return PendingTask(
      taskId: id,
      sessionKey: session,
      prompt: prompt,
      sentAt: DateTime.tryParse('${raw['sentAt']}') ?? DateTime.now().toUtc(),
      modelId: raw['modelId'] as String?,
      providerSlug: raw['providerSlug'] as String?,
      reasoningEffort: raw['reasoningEffort'] as String?,
      attempts: raw['attempts'] is int ? raw['attempts'] as int : 1,
      blobIds: _strings(raw['blobIds']),
    );
  }
}

/// Tasks the socket accepted but the host has not acknowledged.
///
/// It shares [AgentsTaskOutbox]'s store seams and clock on purpose: the two
/// halves of "did this prompt arrive?" are one concern, and a test that fakes
/// the disk for one has faked it for both.
class AgentsPendingTasks {
  AgentsPendingTasks._();

  /// How often one task may be handed to a socket before the app gives up and
  /// tells the user the message did not arrive. Three is the first send plus
  /// two reconnects; more than that and the host is not coming back in time
  /// for this message to still be what the user meant.
  static const int maxAttempts = 3;

  static String _key(String sessionKey) => '$kPendingTaskPrefix$sessionKey';

  /// The entries this install can read, and the sealed blobs it cannot open
  /// yet ([_StoredRows.locked]), which every write carries along unchanged.
  static Future<(List<PendingTask>, List<String>, bool)> _loadRow(
    String sessionKey,
  ) async {
    try {
      final _StoredRows stored = await _RowCodec.decode(
        await AgentsTaskOutbox._readRaw(_key(sessionKey)),
      );
      return (
        <PendingTask>[
          for (final Object? entry in stored.rows)
            if (PendingTask.fromJson(entry) case final PendingTask task) task,
        ],
        stored.locked,
        false,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-pending] load failed for $sessionKey: $error');
      }
      return (<PendingTask>[], <String>[], true);
    }
  }

  static Future<List<PendingTask>> _load(String sessionKey) async =>
      (await _loadRow(sessionKey)).$1;

  static Future<void> _save(
    String sessionKey,
    List<PendingTask> tasks,
    List<String> locked,
  ) async {
    try {
      await AgentsTaskOutbox._writeRaw(
        _key(sessionKey),
        await _RowCodec.encode(<Map<String, Object?>>[
          for (final PendingTask task in tasks) task.toJson(),
        ], locked),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-pending] save failed for $sessionKey: $error');
      }
    }
  }

  /// Records that [taskId] has just been handed to the socket.
  ///
  /// Called BEFORE the frame is sealed, not after: a send that throws halfway
  /// through still has to leave a record behind, because the half-open socket
  /// case is exactly the one where the send reports success and the frame is
  /// gone. Recording the same id twice bumps the attempt count instead of
  /// adding a second row, so a re-send stays one task.
  static Future<PendingTask> record({
    required String sessionKey,
    required String taskId,
    required String prompt,
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    List<String> blobIds = const <String>[],
  }) => AgentsTaskOutbox._locked(() async {
    final DateTime at = AgentsTaskOutbox.now();
    final (List<PendingTask> tasks, List<String> locked, _) = await _loadRow(
      sessionKey,
    );
    final int index = tasks.indexWhere((PendingTask t) => t.taskId == taskId);
    final PendingTask task;
    if (index >= 0) {
      task = tasks[index].copyWith(
        attempts: tasks[index].attempts + 1,
        sentAt: at,
      );
      tasks[index] = task;
    } else {
      task = PendingTask(
        taskId: taskId,
        sessionKey: sessionKey,
        prompt: prompt,
        sentAt: at,
        modelId: modelId,
        providerSlug: providerSlug,
        reasoningEffort: reasoningEffort,
        blobIds: List<String>.unmodifiable(blobIds),
      );
      tasks.add(task);
    }
    await _save(sessionKey, tasks, locked);
    return task;
  });

  /// What [sessionKey] still has no `task_ack` for, oldest first.
  static Future<List<PendingTask>> pendingFor(String sessionKey) =>
      AgentsTaskOutbox._locked(() => _load(sessionKey));

  /// The host holds it (`accepted` or `duplicate`), or its run produced its
  /// first real output. Either way there is nothing left to re-send.
  /// Idempotent: clearing an id that is not there is a no-op.
  static Future<void> clear(String sessionKey, String taskId) =>
      AgentsTaskOutbox._locked(() async {
        final (List<PendingTask> tasks, List<String> locked, bool failed) =
            await _loadRow(sessionKey);
        if (failed) return;
        final int before = tasks.length;
        tasks.removeWhere((PendingTask t) => t.taskId == taskId);
        if (tasks.length == before) return;
        await _save(sessionKey, tasks, locked);
      });

  /// Sends everything [sessionKey] has no `task_ack` for again, oldest first.
  ///
  /// The mirror of [AgentsTaskOutbox.flush], for the other half of the
  /// problem: these went out and vanished, rather than never going out at all.
  /// Each one is re-sent with its ORIGINAL `task_id`, which is what makes a
  /// blind re-send safe — the host dedupes on it and answers `duplicate` for a
  /// task it already took, so the same message is never run twice.
  ///
  /// The attempt is counted and the record rewritten BEFORE [send] is called,
  /// because a send that is lost is exactly the case this exists for: it
  /// reports success and the frame is gone. A task that is out of attempts is
  /// skipped and kept as a failed outbox entry with Retry ([mayRetry]).
  ///
  /// Stops at the first failure — the socket that just refused one frame will
  /// refuse the next — and leaves the rest recorded. Returns how many went out.
  static Future<int> resend(
    String sessionKey,
    Future<void> Function(PendingTask task) send,
  ) async {
    final List<PendingTask> tasks = await pendingFor(sessionKey);
    int sent = 0;
    for (final PendingTask task in tasks) {
      if (!await mayRetry(sessionKey, task.taskId)) continue;
      final PendingTask attempt = await record(
        sessionKey: sessionKey,
        taskId: task.taskId,
        prompt: task.prompt,
        modelId: task.modelId,
        providerSlug: task.providerSlug,
        reasoningEffort: task.reasoningEffort,
        blobIds: task.blobIds,
      );
      try {
        await send(attempt);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[agents-pending] resend failed for $sessionKey: $error');
        }
        break;
      }
      sent++;
    }
    return sent;
  }

  /// True when [taskId] may go out once more, and false once it has used up
  /// [maxAttempts] (or is not recorded). A task that is out of attempts is
  /// taken off this record and KEPT as a failed outbox entry under the same
  /// `task_id` ([keepAsFailed]): the bubble offers Retry and Delete, and a
  /// Retry is still the same task to the host, which dedupes it. Nothing the
  /// user typed is dropped (bead chuk_chat-9hgx).
  static Future<bool> mayRetry(String sessionKey, String taskId) async {
    final (
      bool may,
      PendingTask? exhausted,
    ) = await AgentsTaskOutbox._locked(() async {
      final (List<PendingTask> tasks, List<String> locked, bool failed) =
          await _loadRow(sessionKey);
      if (failed) return (false, null);
      final int index = tasks.indexWhere((PendingTask t) => t.taskId == taskId);
      if (index < 0) return (false, null);
      if (tasks[index].attempts >= maxAttempts) {
        final PendingTask gone = tasks.removeAt(index);
        await _save(sessionKey, tasks, locked);
        return (false, gone);
      }
      return (true, null);
    });
    if (exhausted != null) await keepAsFailed(exhausted);
    return may;
  }

  /// The error a task that was sent but never confirmed shows.
  static const String notConfirmedError =
      'Not sent yet. The app sends it again on its own.';

  /// [task] went out [maxAttempts] times and the host never confirmed it: it
  /// becomes a failed outbox entry under its own `task_id`, and its bubble
  /// is marked so it offers Retry. Never throws.
  static Future<void> keepAsFailed(PendingTask task) async {
    try {
      final OutboxTask entry = await AgentsTaskOutbox.enqueue(
        sessionKey: task.sessionKey,
        prompt: task.prompt,
        modelId: task.modelId,
        providerSlug: task.providerSlug,
        reasoningEffort: task.reasoningEffort,
        taskId: task.taskId,
        failed: true,
        lastError: notConfirmedError,
        blobIds: task.blobIds,
      );
      await AgentsQueuedMarks.markQueued(
        sessionKey: task.sessionKey,
        prompt: task.prompt,
        queueId: entry.localId,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-pending] could not keep the task: $error');
      }
    }
  }

  /// Clears [taskId] in whatever thread records it (a `task_ack` from a host
  /// that leaves the session key off).
  static Future<void> clearAnywhere(String taskId) async {
    for (final String key in await sessionKeys()) {
      await clear(key, taskId);
    }
  }

  /// The threads that have tasks with no `task_ack`.
  static Future<List<String>> sessionKeys() async {
    try {
      return <String>[
        for (final String key in await AgentsTaskOutbox._listKeys(
          kPendingTaskPrefix,
        ))
          key.substring(kPendingTaskPrefix.length),
      ];
    } catch (_) {
      return const <String>[];
    }
  }
}

/// The string entries of a stored list; anything else is dropped.
List<String> _strings(Object? raw) => raw is List
    ? List<String>.unmodifiable(<String>[
        for (final Object? e in raw)
          if (e is String && e.isNotEmpty) e,
      ])
    : const <String>[];
