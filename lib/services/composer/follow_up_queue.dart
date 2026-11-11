// lib/services/composer/follow_up_queue.dart
//
// Messages the user sends while a reply still runs (deepseek-harness idea 67,
// docs/research/DEEPSEEK_HARNESS_IDEAS.md).
//
// Two ways to send while busy:
//
// * Queue: the message waits and goes out as a new turn after the reply.
// * Steer: the message goes into the running turn. The tool loop adds it as
//   a user message at its next pass ([SteerInbox], read by
//   `ToolCallHandler`). When the turn has no further pass, the screen sends
//   the steer after the reply, the same as a queued message.
//
// Enter sends with the mode of the setting ("While busy: Queue / Steer"),
// Ctrl/Cmd+Enter with the other mode. Agents threads have no steer on the
// wire yet, so they always queue.
//
// The screen owns one [FollowUpQueue] per open chat. The queue dock above the
// composer draws it (lib/widgets/composer/queue_dock.dart).
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What Enter does while a reply runs.
enum BusySendMode { queue, steer }

/// How one waiting message goes out.
enum FollowUpKind {
  /// A new turn after the reply.
  queued,

  /// Into the running turn, at its next tool-loop pass.
  steer,
}

/// The persisted "While busy" setting.
abstract final class ComposerBusySetting {
  static const String prefsKey = 'composer_busy_send_mode';

  /// The current mode. Starts at [BusySendMode.queue] (the default) until
  /// [load] reads the stored value.
  static final ValueNotifier<BusySendMode> mode = ValueNotifier<BusySendMode>(
    BusySendMode.queue,
  );

  static bool _loaded = false;

  /// Reads the stored mode once. Safe to call more than once.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(prefsKey);
      mode.value = raw == BusySendMode.steer.name
          ? BusySendMode.steer
          : BusySendMode.queue;
    } catch (_) {
      // No store (tests, a broken prefs file): keep the default.
    }
  }

  static Future<void> set(BusySendMode value) async {
    mode.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, value.name);
    } catch (_) {
      // The value still applies to this run.
    }
  }

  @visibleForTesting
  static void debugReset() {
    _loaded = false;
    mode.value = BusySendMode.queue;
  }
}

/// The kind a busy send takes. [alternate] is Ctrl/Cmd+Enter: the other mode.
/// Without [steerAvailable] (an Agents thread) every busy send queues.
FollowUpKind busySendKind(
  BusySendMode setting, {
  required bool alternate,
  required bool steerAvailable,
}) {
  if (!steerAvailable) return FollowUpKind.queued;
  final bool steer = (setting == BusySendMode.steer) != alternate;
  return steer ? FollowUpKind.steer : FollowUpKind.queued;
}

/// One waiting message.
@immutable
class QueuedFollowUp {
  const QueuedFollowUp({
    required this.id,
    required this.text,
    this.kind = FollowUpKind.queued,
  });

  final String id;
  final String text;
  final FollowUpKind kind;

  QueuedFollowUp copyWith({String? text, FollowUpKind? kind}) =>
      QueuedFollowUp(id: id, text: text ?? this.text, kind: kind ?? this.kind);
}

/// The waiting messages of one chat, oldest first.
class FollowUpQueue extends ChangeNotifier {
  final List<QueuedFollowUp> _items = <QueuedFollowUp>[];
  int _seq = 0;

  List<QueuedFollowUp> get items => List<QueuedFollowUp>.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;

  /// The texts in order, for the parking store.
  List<String> get texts => <String>[for (final i in _items) i.text];

  /// True when a message waits to go out as a new turn after the reply.
  bool get hasQueued => _items.any((i) => i.kind == FollowUpKind.queued);

  String _nextId() => 'fu${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  QueuedFollowUp add(String text, {FollowUpKind kind = FollowUpKind.queued}) {
    final QueuedFollowUp item = QueuedFollowUp(
      id: _nextId(),
      text: text,
      kind: kind,
    );
    _items.add(item);
    notifyListeners();
    return item;
  }

  /// Puts [texts] at the front, in order (undelivered steers after a turn).
  void prependQueued(List<String> texts) {
    if (texts.isEmpty) return;
    _items.insertAll(0, <QueuedFollowUp>[
      for (final t in texts) QueuedFollowUp(id: _nextId(), text: t),
    ]);
    notifyListeners();
  }

  QueuedFollowUp? byId(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  void update(String id, {String? text, FollowUpKind? kind}) {
    final int at = _items.indexWhere((i) => i.id == id);
    if (at < 0) return;
    _items[at] = _items[at].copyWith(text: text, kind: kind);
    notifyListeners();
  }

  QueuedFollowUp? remove(String id) {
    final int at = _items.indexWhere((i) => i.id == id);
    if (at < 0) return null;
    final QueuedFollowUp gone = _items.removeAt(at);
    notifyListeners();
    return gone;
  }

  /// Removes the given ids at once (steers the tool loop delivered).
  void removeAll(Iterable<String> ids) {
    final Set<String> set = ids.toSet();
    final int before = _items.length;
    _items.removeWhere((i) => set.contains(i.id));
    if (_items.length != before) notifyListeners();
  }

  /// Takes the oldest message that waits for a new turn.
  QueuedFollowUp? takeNextQueued() {
    final int at = _items.indexWhere((i) => i.kind == FollowUpKind.queued);
    if (at < 0) return null;
    final QueuedFollowUp item = _items.removeAt(at);
    notifyListeners();
    return item;
  }

  /// Replaces everything with [texts] as queued messages (restore from the
  /// parking store).
  void replaceWith(List<String> texts) {
    _items
      ..clear()
      ..addAll(<QueuedFollowUp>[
        for (final t in texts) QueuedFollowUp(id: _nextId(), text: t),
      ]);
    notifyListeners();
  }

  /// Empties the queue and returns what was in it.
  List<QueuedFollowUp> drain() {
    if (_items.isEmpty) return const <QueuedFollowUp>[];
    final List<QueuedFollowUp> all = List<QueuedFollowUp>.of(_items);
    _items.clear();
    notifyListeners();
    return all;
  }
}

/// One steer that waits for the next pass of a running turn.
@immutable
class SteerEntry {
  const SteerEntry({required this.id, required this.text});
  final String id;
  final String text;
}

/// Steers per chat, between the screen (writer) and the tool loop (reader).
///
/// Static because the tool loop of a chat runs in `ToolCallHandler`, which
/// knows the chat by its id (`ToolLoopSession.discoveryContextKey`) and not
/// the screen. The screen listens to [revision] to drop delivered steers from
/// its dock.
abstract final class SteerInbox {
  static final Map<String, List<SteerEntry>> _pending =
      <String, List<SteerEntry>>{};

  /// Bumped on every post and every take.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// The user turn the model reads. The line in front tells it that the
  /// message came while it was working, so it can change course.
  static String messageFor(String text) =>
      '[Message from the user while you were working]\n$text';

  static void post(String chatId, SteerEntry entry) {
    (_pending[chatId] ??= <SteerEntry>[]).add(entry);
    revision.value++;
  }

  /// Takes all steers of [chatId], for the next pass. Empty when none wait.
  static List<SteerEntry> take(String? chatId) {
    if (chatId == null) return const <SteerEntry>[];
    final List<SteerEntry>? list = _pending.remove(chatId);
    if (list == null || list.isEmpty) return const <SteerEntry>[];
    revision.value++;
    return list;
  }

  /// Whether the steer [id] of [chatId] still waits.
  static bool isPending(String chatId, String id) =>
      _pending[chatId]?.any((e) => e.id == id) ?? false;

  /// Drops one steer (the user removed it or sends it as a queued message).
  static bool remove(String chatId, String id) {
    final List<SteerEntry>? list = _pending[chatId];
    if (list == null) return false;
    final int before = list.length;
    list.removeWhere((e) => e.id == id);
    if (list.isEmpty) _pending.remove(chatId);
    final bool removed = list.length != before;
    if (removed) revision.value++;
    return removed;
  }

  /// Changes the text of a waiting steer.
  static void update(String chatId, String id, String text) {
    final List<SteerEntry>? list = _pending[chatId];
    if (list == null) return;
    final int at = list.indexWhere((e) => e.id == id);
    if (at < 0) return;
    list[at] = SteerEntry(id: id, text: text);
  }

  @visibleForTesting
  static void debugClear() {
    _pending.clear();
    revision.value = 0;
  }
}

/// The double-Esc stop: two Esc presses within [window] stop the reply.
class DoubleEscapeDetector {
  DoubleEscapeDetector({
    this.window = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration window;
  final DateTime Function() _clock;
  DateTime? _last;

  /// Registers one Esc. True when it is the second within [window]; the
  /// detector then starts over.
  bool press() {
    final DateTime now = _clock();
    final DateTime? last = _last;
    if (last != null && now.difference(last) <= window) {
      _last = null;
      return true;
    }
    _last = now;
    return false;
  }

  void reset() => _last = null;
}
