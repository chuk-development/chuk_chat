// lib/utils/json_helpers.dart
//
// Decoding helpers for JSON that arrives from somewhere that may not send
// JSON at all: an HTTP error body, a model's answer, an encrypted column.
// Every one of them answers "is this the shape I want?" without throwing.

import 'dart:convert';

/// Decodes [body] into a JSON object, or returns null when it is not one.
///
/// Server error bodies are the main caller: a 500 may carry
/// `{"error": "..."}` or an HTML page, and the caller wants the detail when
/// there is one and a status-code fallback when there is not.
Map<String, dynamic>? tryDecodeJsonObject(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // Not JSON, or not an object — the caller's fallback path handles it.
  }
  return null;
}

/// Lenient JSON parse for model output, which makes two mistakes often
/// enough to be worth repairing: a stray `]` closing an object, and a
/// trailing comma before `}` or `]`.
///
/// Strict [jsonDecode] runs first, so well-formed input is untouched. When
/// every repair fails, the original input is decoded once more so the caller
/// sees the real [FormatException] and not one from a patched-up string.
dynamic tryParseLenientJson(String raw) {
  final trimmed = raw.trim();
  try {
    return jsonDecode(trimmed);
  } catch (_) {}

  // `{...}]` — an object the model closed with the wrong bracket.
  if (trimmed.startsWith('{') && trimmed.endsWith(']')) {
    final withoutBracket = trimmed.substring(0, trimmed.length - 1).trim();
    if (withoutBracket.endsWith('}')) {
      try {
        return jsonDecode(withoutBracket);
      } catch (_) {}
    }
  }

  // Trailing commas: `[1, 2, ]` / `{"a": 1, }`.
  try {
    return jsonDecode(trimmed.replaceAll(RegExp(r',\s*([}\]])'), r'$1'));
  } catch (_) {}

  return jsonDecode(trimmed);
}

/// True when [raw] is one of our AES-GCM envelopes rather than plaintext.
///
/// Used wherever a column can hold either, so a payload that was never
/// decrypted is not shown to the reader as if it were text.
bool looksLikeEncryptedPayload(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return false;
    return decoded['v'] != null &&
        decoded['nonce'] != null &&
        decoded['ciphertext'] != null &&
        decoded['mac'] != null;
  } catch (_) {
    return false;
  }
}
