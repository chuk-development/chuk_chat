/// What a collapsed tool row says about one host tool call
/// (docs/WIRE_CONTRACT.md, "Tool events and timestamps" and "File tools").
///
///  * `description` (`run_command` / `python`): the model's own 5-10 word
///    label ("Run the unit tests"). It is the row title when present.
///  * `ui.diff` (`edit_file`) and `ui.diffs` (`apply_patch`), live only: the
///    unified diff the model never saw. The collapsed row shows `+a -r`.
///
/// The frame's `ui` block is not stored on the host, so the counts are kept
/// on the call's arguments ([kToolDiffAddedKey], [kToolDiffRemovedKey]) and
/// survive in the local transcript. A replayed call has no `ui` and shows no
/// counts.
library;

import 'package:chuk_chat/models/tool_call.dart';

/// Lines added, on the call's arguments.
const String kToolDiffAddedKey = '_ui_diff_added';

/// Lines removed, on the call's arguments.
const String kToolDiffRemovedKey = '_ui_diff_removed';

/// Added and removed lines of one unified diff. The `+++` / `---` file
/// headers are not lines of the change.
({int added, int removed}) unifiedDiffStat(String diff) {
  int added = 0;
  int removed = 0;
  for (final String line in diff.split('\n')) {
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (line.startsWith('+')) {
      added++;
    } else if (line.startsWith('-')) {
      removed++;
    }
  }
  return (added: added, removed: removed);
}

/// The counts of a `tool` frame's `ui` block (`diff` or `diffs`), or null
/// when it carries no diff.
({int added, int removed})? toolUiDiffStat(Object? ui) {
  if (ui is! Map) return null;
  final List<String> diffs = <String>[
    if (ui['diff'] is String) ui['diff'] as String,
    if (ui['diffs'] is List)
      for (final Object? d in ui['diffs'] as List)
        if (d is Map && d['diff'] is String) d['diff'] as String,
  ];
  if (diffs.isEmpty) return null;
  int added = 0;
  int removed = 0;
  for (final String diff in diffs) {
    final stat = unifiedDiffStat(diff);
    added += stat.added;
    removed += stat.removed;
  }
  return (added: added, removed: removed);
}

/// The model's label for [call] (`description`), or null.
String? toolCallDescription(ToolCall call) {
  final Object? value = call.arguments['description'];
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The `+a -r` counts kept on [call], or null.
({int added, int removed})? toolCallDiffStat(ToolCall call) {
  final Object? added = call.arguments[kToolDiffAddedKey];
  final Object? removed = call.arguments[kToolDiffRemovedKey];
  if (added is! int || removed is! int) return null;
  return (added: added, removed: removed);
}

/// `+12 -3`, the collapsed row's diff label, or null.
String? toolCallDiffLabel(ToolCall call) {
  final stat = toolCallDiffStat(call);
  if (stat == null) return null;
  return '+${stat.added} -${stat.removed}';
}
