// lib/widgets/agent_activity/agents_live_status.dart
//
// The Agents half of the status line above a running answer.
//
// The bubble is chuk_chat's and knows nothing about hosts. For an Agents
// thread it asks this file what to print: the phase the run ledger and the
// link report (`services/agents/agents_turn_phase.dart`), and a Retry target
// when the computer cannot be reached. A plain chat gets null and keeps the
// stream's own wording.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_turn_phase.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';

/// Whether the computer can be reached through [link] right now.
///
/// A link that is connecting or pairing counts as up: that is a reconnect on
/// its way, usually done within a second, and calling it "offline" for that
/// second would be the alarm the status line exists to avoid. Only no
/// transport at all, or one that failed or closed, is offline.
bool agentsLinkUp([AgentsRelayLink? link]) {
  final AgentsRelayController? controller =
      (link ?? AgentsRelayLink.instance).controller.value;
  if (controller == null) return false;
  final AgentsRelayPhase phase = controller.state.value.phase;
  return phase != AgentsRelayPhase.closed && phase != AgentsRelayPhase.error;
}

/// The live status of one Agents thread, for the bubble's header.
class AgentsLiveStatus {
  AgentsLiveStatus._(
    this.chatId, {
    this.turnStartedAt,
    AgentsRunLedger? ledger,
    AgentsRelayLink? link,
    StreamPhase? Function(String chatId)? streamPhase,
    Future<void> Function()? retry,
  }) : _ledger = ledger ?? AgentsRunLedger.instance,
       _link = link, // ignore: prefer_initializing_formals
       _streamPhase = streamPhase, // ignore: prefer_initializing_formals
       _retry = retry; // ignore: prefer_initializing_formals

  /// The status source for [chatId], or null when it is not an Agents thread
  /// (a plain chat keeps the stream's own wording).
  static AgentsLiveStatus? forChat(String? chatId, {DateTime? turnStartedAt}) {
    if (chatId == null || chatId.isEmpty) return null;
    if (!ChatOrigin.isAgentsThread(chatId)) return null;
    return AgentsLiveStatus._(chatId, turnStartedAt: turnStartedAt);
  }

  /// A source with every dependency injected. Test seam.
  @visibleForTesting
  static AgentsLiveStatus forTest(
    String chatId, {
    DateTime? turnStartedAt,
    required AgentsRunLedger ledger,
    AgentsRelayLink? link,
    StreamPhase? Function(String chatId)? streamPhase,
    Future<void> Function()? retry,
  }) => AgentsLiveStatus._(
    chatId,
    turnStartedAt: turnStartedAt,
    ledger: ledger,
    link: link,
    streamPhase: streamPhase,
    retry: retry,
  );

  final String chatId;

  /// When this bubble's request went out. A run the ledger still holds from
  /// an EARLIER turn is not this turn's status.
  final DateTime? turnStartedAt;

  final AgentsRunLedger _ledger;
  final AgentsRelayLink? _link;
  final StreamPhase? Function(String chatId)? _streamPhase;
  final Future<void> Function()? _retry;

  /// Fires whenever the run changes in a way the line can show. Stable: the
  /// ledger is one object for the whole process.
  Listenable get listenable => _ledger;

  /// This turn's run in the ledger, or null. A run the ledger still holds
  /// from an EARLIER turn is not this turn's.
  AgentsRun? _run() {
    final AgentsRun? run = _ledger.runFor(chatId);
    final DateTime? started = turnStartedAt;
    if (run != null &&
        !run.running &&
        started != null &&
        run.startedAt.isBefore(started.subtract(const Duration(seconds: 2)))) {
      return null;
    }
    return run;
  }

  /// Everything this turn did so far, for the open panel under the dots:
  /// the model's thinking, then every call the host reported, in order.
  ///
  /// The host reports its steps to the run ledger and nothing else; the
  /// message only receives them when the run is over. So the ledger is the
  /// source while the run is live, and [fallbackReasoning] /
  /// [fallbackCalls] (what the message itself holds) only stand in when the
  /// ledger has nothing for this turn.
  List<AgentActivityStep> steps({
    String fallbackReasoning = '',
    List<ToolCall> fallbackCalls = const <ToolCall>[],
  }) {
    final AgentsRun? run = _run();
    final String ledgerReasoning = run?.modelReasoning.trim() ?? '';
    final String reasoning = ledgerReasoning.isNotEmpty
        ? ledgerReasoning
        : fallbackReasoning.trim();
    final List<ToolCall> calls = (run != null && run.toolCalls.isNotEmpty)
        ? run.toolCalls
        : fallbackCalls;
    return <AgentActivityStep>[
      if (reasoning.isNotEmpty) AgentActivityStep.reasoning(reasoning),
      for (final ToolCall call in calls) AgentActivityStep.tool(call),
    ];
  }

  /// The status right now.
  AgentsTurnStatus? status() {
    final AgentsRun? run = _run();
    final StreamPhase? phase =
        (_streamPhase ?? (id) => StreamingManager().phaseOf(id))(chatId);
    return agentsTurnStatusFor(
      run: run,
      linkUp: agentsLinkUp(_link),
      streamPhase: phase,
    );
  }

  /// The words for the header, or null to keep the stream's wording.
  String? verb(BuildContext context) =>
      status()?.label(AppLocalizations.of(context));

  /// Retry, while the computer cannot be reached; null otherwise.
  Widget? trailing(BuildContext context) {
    final AgentsTurnStatus? current = status();
    if (current == null || !current.offersRetry) return null;
    return AgentsRetryButton(onRetry: _retry);
  }
}

/// The one action the status line can offer: go and get the computer.
///
/// It goes through [OfflineRetryManager.retryNow], the same path the Retry of
/// a failed bubble takes: with the computer paired it sends what is waiting,
/// otherwise the mounted thread view reconnects.
class AgentsRetryButton extends StatelessWidget {
  const AgentsRetryButton({super.key, this.onRetry});

  /// Test seam; production retries through [OfflineRetryManager].
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final String label =
        AppLocalizations.of(context)?.agentsPhaseRetry ?? 'Retry';
    return ExpressiveButton(
      key: const ValueKey<String>('agents-status-retry'),
      label: label,
      tonal: true,
      dense: true,
      onTap: () => unawaited(
        (onRetry ?? OfflineRetryManager.instance.retryNow)().catchError(
          (Object _) {},
        ),
      ),
    );
  }
}

/// A run this screen has no bubble for: a run the host was already working
/// on when the thread opened (the phone's typing pill).
///
/// Only the three typing dots, like any messenger: they say the agent is
/// still working. A tap opens what it is doing, in detail: the phase with
/// its clock ("Preparing · 41s"), then every step the host reported. Retry
/// stays next to the dots while the computer cannot be reached, because it
/// is an action, not a status.
class AgentsLiveStatusLine extends StatefulWidget {
  const AgentsLiveStatusLine({
    super.key,
    required this.sessionKey,
    this.ledger,
    this.link,
    this.clock,
  });

  final String sessionKey;

  /// Injectable for tests; default the process-wide ones.
  final AgentsRunLedger? ledger;
  final AgentsRelayLink? link;
  final DateTime Function()? clock;

  @override
  State<AgentsLiveStatusLine> createState() => _AgentsLiveStatusLineState();
}

class _AgentsLiveStatusLineState extends State<AgentsLiveStatusLine> {
  AgentsRunLedger get _ledger => widget.ledger ?? AgentsRunLedger.instance;

  @override
  void initState() {
    super.initState();
    _ledger.addListener(_repaint);
  }

  @override
  void didUpdateWidget(AgentsLiveStatusLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ledger != widget.ledger) {
      (oldWidget.ledger ?? AgentsRunLedger.instance).removeListener(_repaint);
      _ledger.addListener(_repaint);
    }
  }

  @override
  void dispose() {
    _ledger.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  AgentsTurnStatus? _status() => agentsTurnStatusFor(
    run: _ledger.runFor(widget.sessionKey),
    linkUp: agentsLinkUp(widget.link),
  );

  @override
  Widget build(BuildContext context) {
    final AgentsRun? run = _ledger.runFor(widget.sessionKey);
    // No run to tell about (it ended, or none was adopted): the plain dots,
    // with nothing behind them.
    if (run == null || _status() == null) {
      return const MessengerTypingIndicator();
    }
    return AgentActivityTimeline(
      key: const ValueKey<String>('agents-live-status-line'),
      toolCalls: const <ToolCall>[],
      isRunning: true,
      liveDots: true,
      showResultSummaries: true,
      clock: widget.clock,
      startedAt: run.startedAt,
      liveListenable: _ledger,
      liveSteps: () {
        final AgentsRun? current = _ledger.runFor(widget.sessionKey);
        if (current == null) return const <AgentActivityStep>[];
        final String reasoning = current.modelReasoning.trim();
        return <AgentActivityStep>[
          if (reasoning.isNotEmpty) AgentActivityStep.reasoning(reasoning),
          for (final ToolCall call in current.toolCalls)
            AgentActivityStep.tool(call),
        ];
      },
      liveVerb: (BuildContext context) =>
          _status()?.label(AppLocalizations.of(context)),
      liveTrailing: (BuildContext context) {
        final AgentsTurnStatus? status = _status();
        if (status == null || !status.offersRetry) return null;
        return const AgentsRetryButton();
      },
    );
  }
}
