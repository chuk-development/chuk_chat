// lib/widgets/agent_activity/min_duration_hold.dart
//
// A running title stays on screen for at least [minimum] (150 ms). A burst of
// fast tool calls would otherwise flash four titles in one second and the
// reader could read none. Only the newest waiting title is kept.

/// Holds a value for at least [minimum] after it was first shown.
class MinDurationHold<T> {
  MinDurationHold({this.minimum = const Duration(milliseconds: 150)});

  final Duration minimum;

  T? _shown;
  DateTime? _shownAt;
  T? _pending;
  bool _hasPending = false;

  /// The value to draw now for a wanted [value] at time [now].
  T show(T value, DateTime now) {
    if (_shownAt == null) {
      _shown = value;
      _shownAt = now;
      return value;
    }
    if (value == _shown) {
      _hasPending = false;
      return value;
    }
    if (now.difference(_shownAt!) >= minimum) {
      _shown = value;
      _shownAt = now;
      _hasPending = false;
      return value;
    }
    _pending = value;
    _hasPending = true;
    return _shown as T;
  }

  /// How long until the waiting value may show, or null when none waits.
  Duration? waitFor(DateTime now) {
    if (!_hasPending || _shownAt == null) return null;
    final Duration left = minimum - now.difference(_shownAt!);
    return left.isNegative ? Duration.zero : left;
  }

  /// The waiting value, if any.
  T? get pending => _hasPending ? _pending : null;

  /// Forget everything: the next value shows at once. Used when the turn
  /// closes, because a closed title must never wait.
  void reset() {
    _shown = null;
    _shownAt = null;
    _pending = null;
    _hasPending = false;
  }
}
