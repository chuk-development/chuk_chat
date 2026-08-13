/// Where a file the agent produced lands when the user saves it.
///
/// The agent pushes files into the thread as `file` events (§9,
/// `send_file_to_user`). Rendering one is the UI's job; putting it on disk is
/// this seam's job, so a widget test can prove the Save action without touching
/// a real filesystem.
library;

import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// Writes a received file somewhere the user can find it.
abstract interface class AgentFileSaver {
  /// Saves [file] and returns a short, human-readable location to show the
  /// user. Throws on failure — the caller reports it in the card.
  Future<String> save(CoworkRelayFile file);
}

/// Reduces a name from the wire to a plain, single-segment file name.
///
/// The name comes from the executor, so it is untrusted input: a `..` or a path
/// separator in it must never let a save escape the target directory.
String sanitizeAgentFileName(String raw) {
  final base = raw.split(RegExp(r'[/\\]')).last.trim();
  final cleaned = base.replaceAll(RegExp(r'[\x00-\x1f]'), '');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'agent-file';
  // Keep it short enough for every filesystem we ship on.
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}
