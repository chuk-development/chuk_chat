// lib/models/stream_phase.dart
//
// What a running turn is doing right now.
//
// The header above a streaming answer used to say "Thinking" from the moment
// the message was sent until the first word appeared, which covered three
// very different waits: the request still travelling, the server reading a
// long prompt, and the model actually reasoning. They fail differently — a
// stall in the first is a network problem, in the second a queue — so the
// reader is told which one they are in.

/// The phases of one assistant turn, in the order they occur.
enum StreamPhase {
  /// The request is out, nothing has come back yet.
  connecting,

  /// The server answered, but no token has arrived — it is reading the
  /// prompt.
  processing,

  /// Reasoning tokens are arriving.
  thinking,

  /// A tool is running.
  working,

  /// Answer tokens are arriving.
  writing;

  /// The present-tense wording shown while the phase lasts.
  String get label => switch (this) {
    StreamPhase.connecting => 'Connecting',
    StreamPhase.processing => 'Prompt processing',
    StreamPhase.thinking => 'Thinking',
    StreamPhase.working => 'Working',
    StreamPhase.writing => 'Writing',
  };
}
