// COWORK STUB. Upstream: chuk_chat/lib/services/title_generation_service.dart.
// Reason: auto-generated chat titles are a hosted-API feature. CoWork's sidebar
// lists agents (coworkers), not chats, so there is no title to generate. The
// plan hides the auto-title rows in Customization (WS-2). Only the settings-sync
// entry point is kept so `SettingsSyncService` imports verbatim.
library;

/// No-op stand-in for chuk_chat's title-generation settings sync.
class TitleGenerationService {
  const TitleGenerationService._();

  /// CoWork has no auto-title setting to pull from Supabase.
  static Future<void> syncSettingsFromSupabase({
    bool forceRefresh = false,
  }) async {}

  /// Called fire-and-forget by the imported send logic on the first message of
  /// a chat. CoWork renames nothing: the sidebar row is the agent, and the
  /// agent's name is the user's.
  static Future<void> generateAndApplyTitle(
    String chatId,
    String firstMessage,
  ) async {}
}
