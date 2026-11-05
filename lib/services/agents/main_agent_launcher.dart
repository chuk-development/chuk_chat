import 'package:flutter/foundation.dart';

/// Opens the main agent's thread from outside the thread (Home widgets).
///
/// The messenger shell listens to [requests]. On a request it switches to the
/// Agents half, opens the main agent's thread (`resolveMainAgent`,
/// `roster_pins.dart`) and puts the text in that thread's composer, not
/// sent (`AgentsThreadComposer.prefill`). It sets [requests] back to null
/// once it has taken the text. A request made while there is no agent yet
/// (no computer, or the roster still empty) waits in the shell until an agent
/// is there, and a newer request replaces it.
class MainAgentLauncher {
  MainAgentLauncher._();

  static final MainAgentLauncher instance = MainAgentLauncher._();

  /// The latest request; the shell consumes it and sets it back to null.
  final ValueNotifier<String?> requests = ValueNotifier<String?>(null);

  /// Opens the main agent's thread with [text] in the composer (not sent).
  /// An empty [text] opens it with the composer focused and its draft kept
  /// (Home's `Ask <main agent>` pill).
  void openWithPrompt(String text) => requests.value = text;

  /// Takes the pending request: its text, and [requests] back to null.
  String? take() {
    final String? text = requests.value;
    if (text != null) requests.value = null;
    return text;
  }

  @visibleForTesting
  void reset() => requests.value = null;
}
