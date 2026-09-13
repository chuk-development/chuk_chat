// lib/utils/automation_message.dart
//
// Recognises the user turn the host submits when an automation fires.
//
// A watcher or a schedule wakes the agent by submitting a run whose prompt
// text carries the marker header, then the operator's own prompt, then the
// observed payload as data. That text lands in the thread as a user turn
// (`AgentsRelayUser`), which is exactly wrong on screen: nobody typed it, and
// the payload is a JSON blob the reader never wants to see.
//
// The recognition has to work from the text alone. The wake reaches the app as
// a plain row, is written to the cache through a whitelist of keys, and comes
// back on the next replay — a marker key added next to the text would be
// dropped on the way through, so the header IS the marker.

/// A user turn that a fired automation produced, not a person.
class AutomationWake {
  const AutomationWake({required this.id, required this.name});

  /// The automation's id, as the host printed it in the header.
  final String id;

  /// The automation's display name. Empty when the host had none.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is AutomationWake && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// The header the host writes first in a fired task's prompt, mirroring
/// `fired_prompt()` in `agent/src/agents_agent/automations.py`. The name runs
/// to the last `]` on the line, so a name that itself contains a bracket
/// still parses.
final RegExp _headerPattern = RegExp(
  r'^\[automation ([A-Za-z0-9_-]+) fired:[ \t]*(.*)\]$',
);

/// Reads the automation header off [text], or returns null when this is an
/// ordinary message. Only the first line is inspected: a person quoting a
/// wake further down their own message is still a person talking.
AutomationWake? parseAutomationWake(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('[automation ')) return null;
  final int lineEnd = trimmed.indexOf('\n');
  final String header = (lineEnd < 0 ? trimmed : trimmed.substring(0, lineEnd))
      .trimRight();
  final match = _headerPattern.firstMatch(header);
  if (match == null) return null;
  return AutomationWake(id: match.group(1)!, name: match.group(2)!.trim());
}
