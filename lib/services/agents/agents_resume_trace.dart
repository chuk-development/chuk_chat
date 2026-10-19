/// Debug timing for the way back into the app (bead chuk_chat-kl8x).
///
/// The app comes back from the background and the thread must paint at once.
/// This records the moment of the resume and prints, for each later step of
/// the reattach (socket kept or replaced, relay handshake, replay, repaint),
/// how many milliseconds after the resume it happened. Debug builds only, and
/// never any content: stage names, counts and durations.
library;

import 'package:flutter/foundation.dart';

class AgentsResumeTrace {
  AgentsResumeTrace._();

  static final Stopwatch _clock = Stopwatch();
  static bool _armed = false;

  /// True between [start] and the window's end: a stage logged then is a
  /// stage of the reattach.
  static bool get active => _armed && _clock.elapsed < _window;

  /// Stages later than this are not part of the resume any more.
  static const Duration _window = Duration(seconds: 30);

  /// Logging on: debug builds only.
  static bool get enabled => kDebugMode;

  /// The app came back to the foreground.
  static void start() {
    if (!enabled) return;
    _clock
      ..reset()
      ..start();
    _armed = true;
    debugPrint('[agents-resume] +0 ms resumed');
  }

  /// One step of the reattach. No content: [stage] is a fixed name.
  static void mark(String stage) {
    if (!enabled || !active) return;
    debugPrint('[agents-resume] +${_clock.elapsedMilliseconds} ms $stage');
  }

  /// Milliseconds since the resume, or null outside the window.
  static int? get elapsedMs => active ? _clock.elapsedMilliseconds : null;

  @visibleForTesting
  static void reset() {
    _clock
      ..stop()
      ..reset();
    _armed = false;
  }
}
