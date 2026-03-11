// lib/services/artifact_diff_engine.dart

import 'package:chuk_chat/models/artifact.dart';

class ArtifactDiffEngine {
  const ArtifactDiffEngine._();

  static const int maxEditsPerUpdate = 5;

  /// Apply [edits] sequentially using exact old_str -> new_str replacement.
  ///
  /// Each old_str must match exactly once in the current working content.
  /// If match count is 0 or >1, throws [StateError].
  static String applyEdits(String original, List<ArtifactEdit> edits) {
    if (edits.isEmpty) {
      throw StateError('No edits provided.');
    }
    if (edits.length > maxEditsPerUpdate) {
      throw StateError(
        'Too many edits (${edits.length}). Maximum is '
        '$maxEditsPerUpdate per update. Use rewrite instead.',
      );
    }

    var current = original;
    for (final edit in edits) {
      if (edit.oldStr.isEmpty) {
        throw StateError('old_str cannot be empty.');
      }

      final matches = _countOccurrences(current, edit.oldStr);
      if (matches != 1) {
        throw StateError(
          'Edit rejected: old_str must appear exactly once. '
          'Found $matches occurrence(s).',
        );
      }

      current = current.replaceFirst(edit.oldStr, edit.newStr);
    }

    return current;
  }

  static int _countOccurrences(String text, String needle) {
    if (needle.isEmpty) return 0;

    var count = 0;
    var index = 0;
    while (true) {
      final found = text.indexOf(needle, index);
      if (found < 0) break;
      count += 1;
      index = found + needle.length;
    }
    return count;
  }
}
