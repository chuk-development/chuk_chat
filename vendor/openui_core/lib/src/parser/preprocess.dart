// chuk_chat addition: source preprocessing before the parser runs.
//
// Mirrors `stripFences` and `stripComments` in the upstream TypeScript
// parser (thesysdev/openui, `packages/lang-core/src/parser/parser.ts`).
// Unlike upstream, the result is not trimmed: the streaming parser uses
// the trailing newline to decide that a statement is complete.

import 'package:meta/meta.dart';

/// Returns [input] with Markdown fences and line comments removed.
///
/// This is `stripComments(stripFences(input))`. The streaming parser
/// and the one-shot `parse` both call it before they tokenize.
@experimental
String preprocessSource(String input) => stripComments(stripFences(input));

/// Extracts the code from Markdown code fences in [input].
///
/// - When [input] contains one or more fences, the bodies of all
///   fences are joined with a newline. Text outside the fences (prose)
///   is dropped. This is the upstream "inline mode".
/// - An opening fence without a closing fence (the model is still
///   streaming) yields everything after the fence line.
/// - An opening fence without a newline yet yields an empty body.
/// - Without any fence, [input] is returned unchanged.
///
/// The scan is string-aware: a "```" inside a double-quoted string
/// does not open or close a fence.
@experimental
String stripFences(String input) {
  final blocks = <String>[];
  var i = 0;
  while (i < input.length) {
    var fenceStart = -1;
    while (i < input.length) {
      final next = _skipString(input, i);
      if (next > i) {
        i = next;
        continue;
      }
      if (_isFenceAt(input, i)) {
        fenceStart = i;
        break;
      }
      i++;
    }
    if (fenceStart == -1) break;

    // Skip the language tag up to the end of the line.
    var j = fenceStart + 3;
    while (j < input.length && input.codeUnitAt(j) != _newline) {
      j++;
    }
    if (j >= input.length) {
      // The fence line is still streaming: there is no body yet.
      blocks.add('');
      i = input.length;
      break;
    }
    j++; // Skip the newline after the language tag.

    var closePos = -1;
    var k = j;
    while (k < input.length) {
      final next = _skipString(input, k);
      if (next > k) {
        k = next;
        continue;
      }
      if (_isFenceAt(input, k)) {
        closePos = k;
        break;
      }
      k++;
    }
    if (closePos != -1) {
      blocks.add(input.substring(j, closePos));
      i = closePos + 3;
    } else {
      // No closing fence yet (streaming): take the rest.
      blocks.add(input.substring(j));
      i = input.length;
    }
  }
  if (blocks.isEmpty) return input;
  return blocks.join('\n');
}

/// Removes `//` and `#` line comments that are outside of strings.
///
/// Both `"` and `'` open a string region, as in upstream. A string
/// region can continue over a line end.
@experimental
String stripComments(String input) {
  if (!input.contains('//') && !input.contains('#')) return input;
  int? inString;
  final lines = input.split('\n');
  for (var l = 0; l < lines.length; l++) {
    final line = lines[l];
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (inString != null) {
        if (c == _backslash && i + 1 < line.length) {
          i++;
          continue;
        }
        if (c == inString) inString = null;
        continue;
      }
      if (c == _doubleQuote || c == _singleQuote) {
        inString = c;
        continue;
      }
      final isSlashComment =
          c == _slash &&
          i + 1 < line.length &&
          line.codeUnitAt(i + 1) == _slash;
      if (isSlashComment || c == _hash) {
        lines[l] = line.substring(0, i).trimRight();
        break;
      }
    }
  }
  return lines.join('\n');
}

bool _isFenceAt(String s, int i) =>
    i + 2 < s.length &&
    s.codeUnitAt(i) == _backtick &&
    s.codeUnitAt(i + 1) == _backtick &&
    s.codeUnitAt(i + 2) == _backtick;

/// When [start] is a `"`, returns the index after the closing quote
/// (or the input length for an open string). Otherwise returns [start].
int _skipString(String input, int start) {
  if (input.codeUnitAt(start) != _doubleQuote) return start;
  var i = start + 1;
  while (i < input.length) {
    final c = input.codeUnitAt(i);
    if (c == _backslash) {
      i += 2;
    } else if (c == _doubleQuote) {
      return i + 1;
    } else {
      i++;
    }
  }
  return input.length;
}

const int _backslash = 0x5C;
const int _doubleQuote = 0x22;
const int _singleQuote = 0x27;
const int _newline = 0x0A;
const int _backtick = 0x60;
const int _slash = 0x2F;
const int _hash = 0x23;
