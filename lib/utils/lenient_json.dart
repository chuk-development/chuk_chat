/// Decoding JSON that a language model wrote.
///
/// Model output is close to JSON but not always JSON: a trailing comma before
/// `}` or `]`, a markdown fence around the body. Both are safe to repair. What
/// is never safe is editing the text inside a string — `{"caption": "A,}"}` is
/// valid JSON, and a regex that deletes "a comma before a brace" silently
/// rewrites the caption. So the repair walks the text and skips strings.
library;

import 'dart:convert';

/// Remove commas that sit directly before `}` or `]`, outside of any string.
String stripTrailingCommas(String source) {
  final out = StringBuffer();
  var inString = false;
  var escaped = false;

  for (var i = 0; i < source.length; i++) {
    final char = source[i];

    if (inString) {
      out.write(char);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }

    if (char == '"') {
      inString = true;
      out.write(char);
      continue;
    }

    if (char == ',') {
      // Look ahead past whitespace: a comma before a closing brace is the one
      // thing to drop; every other comma is structure.
      var j = i + 1;
      while (j < source.length && source[j].trim().isEmpty) {
        j++;
      }
      if (j < source.length && (source[j] == '}' || source[j] == ']')) continue;
    }

    out.write(char);
  }

  return out.toString();
}

/// Strip a markdown fence (```json … ```) around a JSON body.
String stripCodeFence(String source) {
  var text = source.trim();
  if (!text.startsWith('```')) return text;
  text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*[ \t]*\r?\n?'), '');
  if (text.endsWith('```')) text = text.substring(0, text.length - 3);
  return text.trim();
}

/// Decode a JSON value a model wrote, repairing only a fence and a trailing
/// comma. Returns null when the text is not JSON — an unreadable block is
/// better shown raw than guessed at.
Object? tryDecodeLenientJson(String source) {
  final text = stripCodeFence(source);
  for (final candidate in [text, stripTrailingCommas(text)]) {
    try {
      return jsonDecode(candidate);
    } on FormatException {
      // Try the repaired candidate; if that fails too, the caller keeps the raw text.
    }
  }
  return null;
}

/// The same, narrowed to a JSON object.
Map<String, dynamic>? tryDecodeLenientJsonObject(String source) {
  final decoded = tryDecodeLenientJson(source);
  return decoded is Map<String, dynamic> ? decoded : null;
}
