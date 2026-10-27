// lib/services/agents/agents_draft_history.dart
//
// The drafts an agent asked to send, per thread, so a revised draft can show
// what changed (bead chuk_chat-gkt9).
//
// A mail or a Slack message waits on an approval card. When the user says
// "shorter" or "move it to Tuesday", the run ends and the next run asks
// again with the new text. The host does not say which approval revised
// which, so the app keeps the last drafts it saw per thread: a mail compares
// with the previous mail, a connector call with the previous call of the
// same tool on the same server.
//
// Replayed approvals are recorded too (a reload replays the thread), so the
// history comes back after a restart as long as the host still replays the
// earlier request. It lives in memory only; it holds draft text.

import 'dart:convert';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// One draft as the approval card showed it.
class AgentsDraft {
  const AgentsDraft({
    required this.approvalId,
    required this.kind,
    required this.body,
    this.subject,
  });

  final String approvalId;

  /// What it can be compared with: `mail`, or `mcp:<server>/<tool>`.
  final String kind;

  /// The text that is diffed: the mail preview, or the connector arguments.
  final String body;

  /// The mail subject, when there is one.
  final String? subject;
}

class AgentsDraftHistory {
  AgentsDraftHistory();

  static final AgentsDraftHistory instance = AgentsDraftHistory();

  /// Drafts kept per thread. A revision compares with the latest one, so a
  /// short list is enough.
  static const int keepPerThread = 6;

  final Map<String, List<AgentsDraft>> _byThread =
      <String, List<AgentsDraft>>{};

  /// The draft behind [request], or null when it is not a draft (a browser
  /// step, a publish, a takeover) or carries no text.
  static AgentsDraft? draftOf(AgentsRelayApprovalRequest request) {
    final Map<String, dynamic>? d = request.details;
    if (d == null) return null;
    switch (request.actionClass) {
      case 'send_external':
        final Object? preview = d['preview'];
        if (preview is! String || preview.trim().isEmpty) return null;
        final Object? subject = d['subject'];
        return AgentsDraft(
          approvalId: request.approvalId,
          kind: 'mail',
          body: preview,
          subject: subject is String && subject.trim().isNotEmpty
              ? subject
              : null,
        );
      case 'mcp_destructive':
        final Object? args = d['arguments'];
        String body;
        if (args is String) {
          body = args;
        } else {
          try {
            body = args == null ? '' : jsonEncode(args);
          } catch (_) {
            body = '$args';
          }
        }
        if (body.trim().isEmpty) return null;
        return AgentsDraft(
          approvalId: request.approvalId,
          kind: 'mcp:${d['server'] ?? ''}/${d['remote_tool'] ?? ''}',
          body: body,
        );
      default:
        return null;
    }
  }

  /// Keeps the draft behind [request]. The same approval seen twice (a
  /// replay of the card on screen) is stored once.
  void record(String threadKey, AgentsRelayApprovalRequest request) {
    if (threadKey.isEmpty) return;
    final AgentsDraft? draft = draftOf(request);
    if (draft == null) return;
    final List<AgentsDraft> list = _byThread.putIfAbsent(
      threadKey,
      () => <AgentsDraft>[],
    );
    list.removeWhere((AgentsDraft d) => d.approvalId == draft.approvalId);
    list.add(draft);
    if (list.length > keepPerThread) {
      list.removeRange(0, list.length - keepPerThread);
    }
  }

  /// The latest earlier draft of the same kind as [request], or null.
  AgentsDraft? previousFor(
    String threadKey,
    AgentsRelayApprovalRequest request,
  ) {
    final AgentsDraft? draft = draftOf(request);
    if (draft == null) return null;
    final List<AgentsDraft>? list = _byThread[threadKey];
    if (list == null) return null;
    for (int i = list.length - 1; i >= 0; i--) {
      final AgentsDraft d = list[i];
      if (d.approvalId == draft.approvalId) continue;
      if (d.kind == draft.kind) return d;
    }
    return null;
  }

  /// Forgets everything (tests, sign-out).
  void clear() => _byThread.clear();
}
