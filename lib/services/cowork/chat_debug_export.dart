/// The full-chat debug export (bd cowork-338).
///
/// One tap has to put EVERYTHING a bug report needs on the clipboard: the whole
/// transcript, every tool call and command, every artifact the agent handed
/// over, and the raw model context the executor echoed back — as one structured
/// JSON blob. It is deliberately independent of the verbose view: a quiet
/// transcript still exports the hidden process detail, because the person
/// filing the bug is not the person who set the toggle.
///
/// It lives in a service, not in a widget, so both the thread view and the
/// shell's top-right action can call the same code.
///
/// The two sources it reads are the two that survive a rebuild:
///
///  * [ChatStorageService] — the local instant-paint cache, whose rows are the
///    same ones the imported renderer draws (text, reasoning, tool calls,
///    content blocks).
///  * [CoworkRunLedger] — the live run for the thread, for the raw
///    `debug_context` payload and the run's own totals.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:cowork/models/content_block.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/settings/verbose_service.dart';

/// Builds and copies the structured debug export for one thread.
abstract final class ChatDebugExport {
  /// The `kind` marker every export carries, so a pasted blob is recognisable.
  static const String kind = 'cowork_full_chat_debug';

  /// The whole export for [threadKey] as a map: header, stats, transcript and
  /// every collected `debug_context`.
  ///
  /// Async because the transcript comes from the local cache, which may still
  /// be on disk. Never throws: a thread with no rows exports an empty
  /// transcript rather than failing the copy.
  static Future<Map<String, dynamic>> build({required String threadKey}) async {
    final rows = await _rowsFor(threadKey);
    final run = CoworkRunLedger.instance.runFor(threadKey);

    final transcript = <Map<String, dynamic>>[];
    var userMessages = 0;
    var assistantMessages = 0;
    var toolCalls = 0;
    var failedToolCalls = 0;
    var files = 0;
    var tokensSpent = run?.tokensSpent ?? 0;

    for (final row in rows) {
      final role = row['role'] == 'user' ? 'user' : 'assistant';
      if (role == 'user') {
        userMessages++;
      } else if ((row['text'] as String? ?? '').isNotEmpty) {
        assistantMessages++;
      }

      final calls = _decodeToolCalls(row['toolCalls']);
      final blocks = _decodeBlocks(row['contentBlocks']);
      toolCalls += calls.length;
      failedToolCalls += calls
          .where((c) => c.status == ToolCallStatus.error)
          .length;
      files += blocks
          .where((b) => b.type == ContentBlockType.sandboxArtifact)
          .length;

      transcript.add(<String, dynamic>{
        'role': role,
        'text': row['text'] ?? '',
        if ((row['reasoning'] as String? ?? '').isNotEmpty)
          'reasoning': row['reasoning'],
        if (calls.isNotEmpty)
          'tool_calls': [for (final call in calls) call.toJson()],
        if (blocks.isNotEmpty)
          'content_blocks': [for (final block in blocks) block.toJson()],
        if (row['modelId'] != null) 'model_id': row['modelId'],
        if (row['provider'] != null) 'provider': row['provider'],
      });
    }

    // The run in flight (or the last one, until the fold takes it) adds what
    // the transcript cannot carry: the tool lines that are still open and the
    // raw context the executor echoed back.
    if (run != null) {
      toolCalls += run.toolCalls.length;
      failedToolCalls += run.toolCalls
          .where((c) => c.status == ToolCallStatus.error)
          .length;
      files += run.blocks
          .where((b) => b.type == ContentBlockType.sandboxArtifact)
          .length;
      if (run.toolCalls.isNotEmpty || run.blocks.isNotEmpty) {
        transcript.add(<String, dynamic>{
          'role': 'run_in_flight',
          if (run.modelReasoning.isNotEmpty) 'reasoning': run.modelReasoning,
          if (run.finalAnswer != null) 'final_answer': run.finalAnswer,
          'tool_calls': [for (final call in run.toolCalls) call.toJson()],
          'content_blocks': [for (final block in run.blocks) block.toJson()],
        });
      }
      tokensSpent = run.tokensSpent ?? tokensSpent;
    }

    final debugContexts = <String, dynamic>{};
    final context = run?.debugContext;
    if (context != null) debugContexts[threadKey] = context;

    return <String, dynamic>{
      'kind': kind,
      'thread_key': threadKey,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'verbose_view': VerboseService.instance.enabled,
      'stats': <String, dynamic>{
        'entries': transcript.length,
        'user_messages': userMessages,
        'assistant_messages': assistantMessages,
        'tool_calls': toolCalls,
        'failed_tool_calls': failedToolCalls,
        'files': files,
        'tokens_spent': tokensSpent,
        if (run != null) 'run_state': run.running ? 'running' : 'idle',
        if (run?.runId != null) 'run_id': run!.runId,
      },
      'transcript': transcript,
      'debug_contexts': debugContexts,
    };
  }

  /// [build], pretty-printed. Falls back to a plain-text transcript if the blob
  /// cannot be encoded, so the caller always has something to hand over.
  static Future<String> buildJson({required String threadKey}) async {
    try {
      return const JsonEncoder.withIndent(
        '  ',
      ).convert(await build(threadKey: threadKey));
    } catch (error) {
      if (kDebugMode) debugPrint('[cowork-export] encode failed: $error');
      return plainTranscript(await _rowsFor(threadKey));
    }
  }

  /// Copies the export for [threadKey] to the clipboard and returns the short
  /// note to show the user (`'debug chat copied'`, or the fallback wording).
  static Future<String> copyToClipboard({required String threadKey}) async {
    String text;
    String note;
    try {
      text = const JsonEncoder.withIndent(
        '  ',
      ).convert(await build(threadKey: threadKey));
      note = 'debug chat copied';
    } catch (_) {
      text = plainTranscript(await _rowsFor(threadKey));
      note = 'copied the transcript';
    }
    await Clipboard.setData(ClipboardData(text: text));
    return note;
  }

  /// A plain-text dump of [rows], used as the copy fallback.
  static String plainTranscript(List<Map<String, dynamic>> rows) {
    final buffer = StringBuffer();
    for (final row in rows) {
      final text = row['text'] as String? ?? '';
      if (text.isEmpty) continue;
      buffer.writeln(row['role'] == 'user' ? 'You: $text' : 'Agent: $text');
    }
    return buffer.toString().trimRight();
  }

  /// The thread's cached rows, in the imported renderer's own shape.
  static Future<List<Map<String, dynamic>>> _rowsFor(String threadKey) async {
    try {
      final chat = await ChatStorageService.loadFullChat(threadKey);
      final messages = chat?.messagesOrNull;
      if (messages == null) return const <Map<String, dynamic>>[];
      return [for (final message in messages) message.toJson()];
    } catch (error) {
      if (kDebugMode) debugPrint('[cowork-export] cache read failed: $error');
      return const <Map<String, dynamic>>[];
    }
  }

  static List<ToolCall> _decodeToolCalls(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <ToolCall>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ToolCall>[];
      return [
        for (final item in decoded)
          if (item is Map) ToolCall.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return const <ToolCall>[];
    }
  }

  static List<ContentBlock> _decodeBlocks(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <ContentBlock>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ContentBlock>[];
      return [
        for (final item in decoded)
          if (item is Map)
            ContentBlock.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return const <ContentBlock>[];
    }
  }
}
