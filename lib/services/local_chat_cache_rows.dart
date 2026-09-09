// lib/services/local_chat_cache_rows.dart
//
// Row shapes shared by both local-cache backends. SQLite (native) and
// SharedPreferences (web) store the same rows; only the storage differs, so
// building and validating a row does not belong in either backend.

/// Builds a plaintext cache row.
///
/// The local cache holds plaintext on purpose — the encryption key sits on the
/// same device, so encrypting it again would be theatre. The field names differ
/// from the Supabase ones (`payload`, not `encrypted_payload`) precisely so a
/// plaintext row can never be sent to the server by mistake.
Map<String, dynamic> buildPlaintextCacheRow({
  required String id,
  required String payload,
  required String createdAt,
  required bool isStarred,
  String? updatedAt,
  String? title,
}) {
  return <String, dynamic>{
    'id': id,
    'payload': payload,
    'created_at': createdAt,
    'is_starred': isStarred,
    'updated_at': ?updatedAt,
    'title': ?title,
  };
}

/// Normalises a row read back from storage, or returns null when it is not
/// usable.
///
/// Rows arrive with the types their backend happens to use: SQLite gives
/// `is_starred` as 0/1 and a `created_at` string, an older row may carry a
/// `DateTime`. A row without an id or a payload is dropped rather than
/// repaired — there is nothing left to show.
Map<String, dynamic>? sanitizeCacheRow(Map<String, dynamic> row) {
  final id = row['id'];
  final payload = row['payload'];
  if (id is! String || payload is! String) return null;

  String? createdAt;
  final raw = row['created_at'];
  if (raw is String) {
    createdAt = raw;
  } else if (raw is DateTime) {
    createdAt = raw.toUtc().toIso8601String();
  }
  createdAt ??= DateTime.now().toUtc().toIso8601String();

  final starred = row['is_starred'];
  final isStarred = starred is bool
      ? starred
      : (starred is num ? starred != 0 : false);

  return <String, dynamic>{
    'id': id,
    'payload': payload,
    'created_at': createdAt,
    'is_starred': isStarred,
    if (row['updated_at'] is String) 'updated_at': row['updated_at'],
    if (row['title'] is String) 'title': row['title'],
  };
}
