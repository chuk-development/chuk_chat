// AGENTS STUB. Upstream: chuk_chat/lib/services/workspace_message_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — workspaces (projects) are a chuk_chat feature backed by
// Supabase. Agents has agents, not workspaces; the host owns the system prompt.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:chuk_chat/models/workspace_model.dart';

class WorkspaceMessageService {
  static const int maxTotalContentLength = 500000;
  static const int maxChatHistoryContentLength = 100000;

  static Future<String> buildProjectSystemMessage(String workspaceId) async =>
      '';

  static Future<List<Map<String, dynamic>>> injectProjectContext(
    List<Map<String, dynamic>> history,
    String? workspaceId,
  ) async => history;

  static String getProjectContextSummary(Workspace workspace) => '';

  static bool hasContext(Workspace workspace) => false;

  static int estimateTotalFileTokens(Workspace workspace) => 0;

  static int estimateProjectContextTokens(Workspace workspace) => 0;

  static int? getModelContextWindow(String? modelId) => null;

  static double? contextUsageRatio(Workspace workspace, String? modelId) =>
      null;

  static double? fileContextRatio(WorkspaceFile file, String? modelId) => null;

  static int remainingFileTokenBudget(Workspace workspace, String? modelId) =>
      0;
}
