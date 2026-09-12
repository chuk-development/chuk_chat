// lib/platform_specific/chat/composer_queue.dart
//
// The composer's outbox and the one rule that says what its primary target
// does. Both are pure data/logic with no Flutter or chat-state dependency,
// so they live apart from the screen that uses them (bead cowork-bj88).

/// The composer's outbox.
///
/// The user may fire as many messages as they want while the coworker works.
/// Each one waits here, oldest first, and goes out in the next possible send
/// cycle. Nothing is dropped and nothing is overwritten — the single slot this
/// replaced lost the first of two messages (bead cowork-bj88).
class PendingMessageQueue {
  final List<String> _items = <String>[];

  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;

  /// What waits, oldest first. A copy, so a caller cannot reorder the queue.
  List<String> get items => List<String>.unmodifiable(_items);

  /// The message that goes out next, or null when nothing waits.
  String? get next => _items.isEmpty ? null : _items.first;

  /// Appends a message. Blank text is not a message, so it is ignored.
  void add(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _items.add(trimmed);
  }

  /// Removes and returns the oldest message, or null when nothing waits.
  String? takeNext() => _items.isEmpty ? null : _items.removeAt(0);

  /// Drops the whole queue and returns what was dropped, oldest first.
  List<String> clear() {
    final List<String> dropped = List<String>.of(_items);
    _items.clear();
    return dropped;
  }
}

/// What the composer's primary target does when it is tapped.
///
/// There is no `stop`. The coworker is never interrupted from here: a tap
/// while a run is open queues the message, and that a run is open is said by
/// the working dots, not by a red button (bead cowork-bj88).
enum ComposerAction { send, sendAudio, voiceMode }

/// The one place that decides what the composer's primary target does.
///
/// [isWorking] is taken and deliberately ignored: whether a run is open
/// changes the notice above the composer, never this target.
ComposerAction composerActionFor({
  required bool isRecording,
  required bool isWorking,
  required bool hasText,
  required bool voiceModeEnabled,
}) {
  if (isRecording) return ComposerAction.sendAudio;
  if (!hasText && voiceModeEnabled) return ComposerAction.voiceMode;
  return ComposerAction.send;
}
