// lib/platform_specific/chat/chat_debug_snapshot.dart

import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/chat_sync_service.dart';

/// What the "copy debug chat" action reads out of a running chat screen.
///
/// The desktop and the mobile chat state both expose exactly this, so the
/// debug dump is built once instead of once per platform.
abstract class ChatDebugSnapshot {
  List<Map<String, String>> get debugMessages;
  String get debugModelId;
  String? get debugProviderSlug;
  String? get debugWorkspaceId;
  String get debugReasoningEffort;
  String? get debugActiveChatId;
}

/// The context block that rides along with a copied debug chat.
///
/// Everything a bug report needs and the message text does not carry: which
/// model answered, which chat it was, whether that chat was saved, and where
/// the sync stood.
Map<String, String> chatDebugContext(
  ChatDebugSnapshot? state, {
  required String platform,
}) {
  if (state == null) return const {};
  final chatId = state.debugActiveChatId;
  final chat = chatId == null ? null : ChatStorageState.chatsById[chatId];
  final lastSync = ChatSyncService.lastSyncAt;
  return {
    'Model': state.debugModelId,
    'Provider': state.debugProviderSlug ?? '',
    'Workspace': state.debugWorkspaceId ?? '',
    'Reasoning': state.debugReasoningEffort,
    'Platform': platform,
    'Chat ID': chatId ?? '',
    'Chat UpdatedAt (local)': chat?.updatedAt?.toIso8601String() ?? '',
    'Chat Fully Loaded': (chat?.isFullyLoaded ?? false).toString(),
    'Chat Pending Save':
        chatId != null && ChatStorageState.pendingSaves.containsKey(chatId)
        ? 'true'
        : 'false',
    'Chat Saving':
        chatId != null && ChatStorageState.savingChats.contains(chatId)
        ? 'true'
        : 'false',
    'Sync Enabled': ChatSyncService.isEnabled.toString(),
    'Sync In Progress': ChatSyncService.isSyncing.toString(),
    'Sync First Done': ChatSyncService.hasCompletedFirstSync.toString(),
    'Sync Last At': lastSync?.toIso8601String() ?? 'never',
    'Sync Last Result': ChatSyncService.lastSyncOutcome ?? '',
  };
}
