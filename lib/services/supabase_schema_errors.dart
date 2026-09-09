// lib/services/supabase_schema_errors.dart

import 'package:supabase_flutter/supabase_flutter.dart';

/// True when [error] says the `preferences` JSONB column is not there.
///
/// Not every deployment has the legacy `user_preferences.preferences` column.
/// Callers that hit this keep working locally instead of failing the whole
/// operation, so the check has to be exact: Postgres reports a missing column
/// as 42703, and the message names the column.
bool isMissingPreferencesColumn(PostgrestException error) {
  const column = 'preferences';
  final code = error.code?.toLowerCase() ?? '';
  final message = error.message.toLowerCase();
  // 42P01 is a missing *table*. That is a schema outage, not a deployment
  // without the optional column, and swallowing it would hide the failure
  // behind a silent "local only" fallback.
  if (code == '42P01' || message.contains('relation')) return false;
  return (code == '42703' || message.contains('does not exist')) &&
      message.contains(column);
}
