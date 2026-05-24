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

      final positions = _findOccurrences(current, edit.oldStr);
      if (positions.length != 1) {
        throw StateError(_buildMatchError(current, edit.oldStr, positions));
      }

      current = current.replaceFirst(edit.oldStr, edit.newStr);
    }

    return current;
  }

  static List<int> _findOccurrences(String text, String needle) {
    if (needle.isEmpty) return const <int>[];

    final positions = <int>[];
    var index = 0;
    while (true) {
      final found = text.indexOf(needle, index);
      if (found < 0) break;
      positions.add(found);
      index = found + needle.length;
    }
    return positions;
  }

  /// Builds a verbose error message when the AI's `old_str` matches the
  /// wrong number of times. Includes up to the first 3 hits with ~80
  /// chars of context on either side so the AI can either widen its
  /// context or switch to `action: "rewrite"`.
  static String _buildMatchError(
    String text,
    String needle,
    List<int> positions,
  ) {
    final preview = _trimPreview(needle, 60);

    if (positions.isEmpty) {
      return 'Edit rejected: old_str "$preview" was not found in the '
          'artifact. Re-read the current content and copy the exact text '
          'to replace (whitespace, newlines, and quoting all count). Or '
          'use action="rewrite" to replace the whole document.';
    }

    final buffer = StringBuffer()
      ..write('Edit rejected: old_str "')
      ..write(preview)
      ..write('" matches ')
      ..write(positions.length)
      ..writeln(' places in the artifact.')
      ..writeln(
        'Add more surrounding text to make it unique, or use '
        'action="rewrite" to replace the whole document.',
      );

    final shown = positions.length > 3 ? 3 : positions.length;
    for (var i = 0; i < shown; i++) {
      final pos = positions[i];
      final context = _extractContext(text, pos, needle.length, 80);
      buffer
        ..writeln()
        ..write('Match ')
        ..write(i + 1)
        ..write(' (around char ')
        ..write(pos)
        ..writeln('):')
        ..write('  …')
        ..write(context)
        ..writeln('…');
    }
    if (positions.length > shown) {
      buffer
        ..writeln()
        ..write('(+')
        ..write(positions.length - shown)
        ..writeln(' more match(es) not shown)');
    }
    return buffer.toString().trimRight();
  }

  static String _trimPreview(String value, int max) {
    if (value.length <= max) return _escapeForMessage(value);
    return '${_escapeForMessage(value.substring(0, max))}…';
  }

  static String _escapeForMessage(String value) {
    // Collapse newlines/tabs so the error stays single-line readable.
    return value.replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll(
          '\t',
          r'\t',
        );
  }

  static String _extractContext(
    String text,
    int pos,
    int matchLen,
    int radius,
  ) {
    final start = (pos - radius).clamp(0, text.length);
    final end = (pos + matchLen + radius).clamp(0, text.length);
    return _escapeForMessage(text.substring(start, end));
  }
}
