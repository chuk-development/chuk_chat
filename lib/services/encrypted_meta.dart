// lib/services/encrypted_meta.dart
//
// Row metadata that must not sit in the database as plaintext (artifact
// handle and title, project name and system prompt, project file name and
// text) travels in one E2E-encrypted JSON envelope per row, the
// `encrypted_meta` column. The plaintext columns keep a placeholder, because
// some of them carry NOT NULL / non-empty CHECK constraints and older app
// builds still read them.
//
// Old builds keep writing plaintext. A row is therefore read with one rule:
// a real plaintext value (not empty, not [kEncryptedPlaceholder]) was
// written after the seal by an old build and wins; otherwise the sealed
// value is used. The owning service re-seals such a row on the next load.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:chuk_chat/services/encryption_service.dart';

/// Stands in the plaintext column of a sealed row. Old builds show it as the
/// name; the non-empty CHECK constraints accept it.
const String kEncryptedPlaceholder = '🔒';

/// Version of the JSON inside the envelope (not of the cipher envelope).
const int kEncryptedMetaVersion = 1;

class EncryptedMeta {
  const EncryptedMeta._();

  /// Envelopes above this many characters are opened off the UI isolate.
  /// A project file's envelope carries the whole file text (~160k chars).
  static const int _backgroundOpenMinChars = 16 * 1024;

  /// Seals a plaintext string. Swappable so tests run without a signed-in
  /// user and a derived key.
  @visibleForTesting
  static Future<String> Function(String plaintext) seal = _defaultSeal;

  /// Opens an envelope produced by [seal].
  @visibleForTesting
  static Future<String> Function(String envelope) open = _defaultOpen;

  /// Restores the real cipher. Call from `tearDown` after overriding.
  @visibleForTesting
  static void resetCipher() {
    seal = _defaultSeal;
    open = _defaultOpen;
  }

  // encryptInBackground seals short strings on the calling isolate itself.
  static Future<String> _defaultSeal(String plaintext) =>
      EncryptionService.encryptInBackground(plaintext);

  static Future<String> _defaultOpen(String envelope) =>
      envelope.length < _backgroundOpenMinChars
      ? EncryptionService.decrypt(envelope)
      : EncryptionService.decryptInBackground(envelope);

  /// Encrypts [fields] into one envelope for the `encrypted_meta` column of
  /// row [rowId] in [table]. Null values are dropped.
  ///
  /// The envelope names its row: [decode] refuses it anywhere else, so the
  /// server cannot move sealed metadata to another row of the same user
  /// (a system prompt to another project, a handle to another artifact).
  /// A row id must therefore be known before the insert, and a re-keyed row
  /// gets a new envelope in the same write.
  static Future<String> encode(
    Map<String, Object?> fields, {
    required String table,
    required String rowId,
  }) {
    final body = <String, Object?>{
      'v': kEncryptedMetaVersion,
      'tbl': table,
      'row': rowId,
    };
    fields.forEach((key, value) {
      if (value != null) body[key] = value;
    });
    return seal(jsonEncode(body));
  }

  /// Decrypts the `encrypted_meta` value of row [rowId] in [table]. Returns
  /// null when the column is empty (a legacy row). Throws when the envelope
  /// cannot be opened (sealed with another key) or belongs to another row,
  /// so the caller treats the row as unreadable and never re-seals it.
  static Future<Map<String, dynamic>?> decode(
    String? envelope, {
    required String table,
    required String rowId,
  }) async {
    if (envelope == null || envelope.trim().isEmpty) return null;
    final decoded = jsonDecode(await open(envelope));
    if (decoded is! Map) {
      throw const FormatException('encrypted_meta is not a JSON object');
    }
    if (decoded['tbl'] != table || decoded['row'] != rowId) {
      throw const FormatException('encrypted_meta belongs to another row');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// True when [error] says the `encrypted_meta` column is not there yet
  /// (migration not applied, or the PostgREST schema cache not reloaded).
  /// Other errors that merely name the column (a CHECK or trigger error)
  /// do not count.
  static bool isMissingColumnError(PostgrestException error) {
    final text = '${error.message} ${error.details ?? ''} ${error.hint ?? ''}'
        .toLowerCase();
    if (!text.contains('encrypted_meta')) return false;
    final code = (error.code ?? '').toUpperCase();
    return code == 'PGRST204' ||
        code == '42703' ||
        text.contains('schema cache') ||
        text.contains('does not exist');
  }

  /// True when [value] is a real plaintext value, not a gap or the
  /// placeholder of a sealed row.
  static bool isRealPlaintext(Object? value) {
    if (value is! String) return false;
    final trimmed = value.trim();
    return trimmed.isNotEmpty && trimmed != kEncryptedPlaceholder;
  }

  /// Reads one field: real plaintext (legacy row, or an old build wrote after
  /// the seal) wins; otherwise the sealed value; otherwise null.
  static String? pick(Object? plaintext, Map<String, dynamic>? meta, String key) {
    if (isRealPlaintext(plaintext)) return plaintext as String;
    final sealed = meta?[key];
    return sealed is String ? sealed : null;
  }
}
