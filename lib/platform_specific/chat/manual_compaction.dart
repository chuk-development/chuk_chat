// lib/platform_specific/chat/manual_compaction.dart
//
// The `/compact` command of both chat screens. It builds the same request
// a send of this chat would build (system prompt of the turn, `tools[]`,
// history), so the summary request is a continuation of the chat's own
// prefix (docs/GOTCHAS.md, "Chat compaction"), and then hands it to
// [ChatCompactionRunner.compactNow].

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/chat_compaction.dart';
import 'package:chuk_chat/services/chat_compaction_runner.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';

/// What one screen sends with: its settings at the time of the command.
class ManualCompactionRequest {
  const ManualCompactionRequest({
    required this.messages,
    required this.chatId,
    required this.modelId,
    required this.providerSlug,
    required this.baseSystemPrompt,
    required this.workspace,
    required this.toolCallingEnabled,
    required this.discoveryMode,
    this.skipIdentity = false,
    this.includeRecentImages = true,
    this.includeAllImages = false,
    this.includeReasoning = false,
    this.includeToolResults = true,
  });

  /// The chat's rows at the time of the command. Copied at once and only
  /// read: the caller writes the summary back with
  /// [CompactionOutcome.writeInto] after checking the chat is still the
  /// one on screen.
  final List<Map<String, String>> messages;
  final String chatId;
  final String modelId;
  final String providerSlug;
  final String? baseSystemPrompt;
  final Workspace? workspace;
  final bool toolCallingEnabled;
  final bool discoveryMode;
  final bool skipIdentity;
  final bool includeRecentImages;
  final bool includeAllImages;
  final bool includeReasoning;
  final bool includeToolResults;
}

/// Runs `/compact` for [request]. One summary per chat at a time (shared
/// with the send paths, [ChatCompactionRunner.isRunning]); a second call
/// while one runs returns [CompactionStatus.notNeeded] with reason `busy`.
Future<CompactionOutcome> runManualCompaction(
  ManualCompactionRequest request,
) async {
  final String chatId = request.chatId;
  if (_starting.contains(chatId) || ChatCompactionRunner.isRunning(chatId)) {
    return const CompactionOutcome(CompactionStatus.notNeeded, reason: 'busy');
  }
  _starting.add(chatId);
  // A copy, taken now: the screen's list may hold another chat when the
  // summary comes back.
  final List<Map<String, String>> rows = <Map<String, String>>[
    for (final m in request.messages) Map<String, String>.from(m),
  ];
  try {
    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    final String accessToken = session?.accessToken ?? '';
    if (accessToken.isEmpty) {
      return const CompactionOutcome(
        CompactionStatus.failed,
        reason: 'no session',
      );
    }
    Future<List<Map<String, dynamic>>> buildHistory(
      List<Map<String, String>> messages,
      List<int> starts,
    ) => ChatHistoryBuilder.build(
          messages: messages,
          pendingUserText: '',
          includeRecentImages: request.includeRecentImages,
          includeAllImages: request.includeAllImages,
          includeReasoning: request.includeReasoning,
          includeToolResults: request.includeToolResults,
          messageStarts: starts,
        );
    final ToolCallHandler handler = ToolCallHandler.forChat(chatId);
    final ToolLoopSession toolSession = handler.createSession(
      initialUserMessage: '',
      history: await buildHistory(rows, <int>[]),
      accessToken: accessToken,
      discoveryContextKey: chatId,
      baseSystemPrompt: request.baseSystemPrompt,
      modelId: request.modelId,
      toolCallingEnabled: request.toolCallingEnabled,
      discoveryMode: request.discoveryMode,
      skipIdentity: request.skipIdentity,
      nativeToolCalling: !kIsWeb,
    );
    toolSession.applyWorkspace(request.workspace);
    final String systemPrompt = await handler.buildInitialSystemPrompt(
      toolSession,
    );
    return await ChatCompactionRunner.compactNow(
      messages: rows,
      chatId: chatId,
      modelId: request.modelId,
      providerSlug: request.providerSlug,
      accessToken: accessToken,
      systemPrompt: systemPrompt,
      tools: handler.nativeToolDefinitions(toolSession),
      buildHistory: buildHistory,
    );
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[Compaction] /compact failed: ${error.runtimeType}');
    }
    return CompactionOutcome(CompactionStatus.failed, reason: '$error');
  } finally {
    _starting.remove(chatId);
  }
}

/// Chats whose `/compact` is being set up (session, system prompt) before
/// the runner takes over.
final Set<String> _starting = <String>{};
