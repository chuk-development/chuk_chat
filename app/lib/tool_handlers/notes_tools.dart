// COWORK STUB. Upstream: chuk_chat/lib/tool_handlers/notes_tools.dart.
// Reason: the upstream file is a 700-line client-side notes/identity tool
// handler (Soul / User info / Memory) that runs tools on the device. In CoWork
// every tool runs on the Python host, so only the settings-sync entry point is
// needed. `SettingsSyncService` calls `syncIdentityFromSupabase`; nothing else
// in the imported surface touches this file.
library;

/// No-op stand-in for chuk_chat's identity sync.
///
/// CoWork keeps the system prompt on the host (see `user_preferences_service`),
/// so there is no device-local identity cache to refresh.
Future<void> syncIdentityFromSupabase({bool forceRefresh = false}) async {}
