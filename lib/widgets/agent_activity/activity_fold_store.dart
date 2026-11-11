// lib/widgets/agent_activity/activity_fold_store.dart
//
// The open/closed state of every "Worked for …" block, kept outside the
// widget. A lazy message list throws a row's State away when the row leaves
// the cache (a scroll, a jump from the minimap) and builds a fresh one when
// it comes back. State kept in the widget was lost on that trip, and the
// block came back in its default state: a block the reader had folded
// opened again. T3 Code keeps the same thing in a set at the timeline level
// (`expandedWorkGroupIds`), for the same reason.

import 'dart:collection';

/// What the reader chose for one block.
class ActivityFold {
  /// The reader's choice for the whole block; null = follow the turn
  /// (open while it runs, folded once it is done).
  bool? expanded;

  /// Whether [expanded] was chosen while the turn was still running. Such a
  /// choice ends with the turn: a finished turn folds, as in T3 Code.
  bool chosenWhileRunning = false;

  /// Groups the reader opened or closed by hand, by their position.
  final Map<int, bool> groups = <int, bool>{};

  /// Thinking notes the reader opened, by their position.
  final Set<int> bodies = <int>{};

  /// Back to the default: follow the turn.
  void reset() {
    expanded = null;
    chosenWhileRunning = false;
    groups.clear();
    bodies.clear();
  }
}

/// One [ActivityFold] per block, keyed by message id and the block's slot.
class ActivityFoldStore {
  ActivityFoldStore._();

  static final ActivityFoldStore instance = ActivityFoldStore._();

  /// Oldest entries go first once there are more than this. A fold is a
  /// few bytes; the cap only stops a session that never ends from growing.
  static const int maxEntries = 4000;

  final LinkedHashMap<String, ActivityFold> _folds =
      LinkedHashMap<String, ActivityFold>();

  /// The fold for [key], made on first use.
  ActivityFold of(String key) {
    final ActivityFold? hit = _folds.remove(key);
    final ActivityFold fold = hit ?? ActivityFold();
    // Re-insert so the most recently used entry is the last one evicted.
    _folds[key] = fold;
    while (_folds.length > maxEntries) {
      _folds.remove(_folds.keys.first);
    }
    return fold;
  }

  /// Whether [key] has a fold yet (tests).
  bool contains(String key) => _folds.containsKey(key);

  /// Forget everything (sign-out, tests).
  void clear() => _folds.clear();
}
