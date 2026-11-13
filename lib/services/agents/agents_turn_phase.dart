// lib/services/agents/agents_turn_phase.dart
//
// What an agent is doing with the message the user just sent, in one word
// the status line above the answer can print.
//
// The plain chat reads its phase from the stream (`StreamPhase`). An Agents
// turn knows more than its stream does: the run ledger hears the host's
// `task_ack`, its heartbeats, every tool line and every token, and the link
// knows whether the computer is reachable at all. A turn that only said
// "Connecting for 40s" while the host was busy preparing its context read as
// frozen — the top complaint about every agent product (research item 4,
// docs/research/AGENT_COMPETITORS_2026-10.md). This file turns what the app
// already observes into an honest phase. It invents nothing: every phase is
// backed by a frame that arrived, or by one that did not.

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart'
    show AgentsHostRetry;
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/ui/expressive/agent_status.dart' show humanToolLabel;
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart'
    show knownToolActivityLabel, runningActivityLabel, toolActivityLabel;

/// The phases of one Agents turn, roughly in the order they occur.
enum AgentsTurnPhase {
  /// The task left the app; the host has not said it has it yet.
  sending,

  /// The host has not answered the first send within the ack window. The app
  /// is sending it again; the computer may be asleep or offline.
  noAnswer,

  /// The link to the computer is down while the turn waits.
  offline,

  /// The host holds the task (`task_ack`) and nothing else came yet.
  received,

  /// The host says the task waits behind another one (`heartbeat.phase`).
  queued,

  /// The host is working on it but no output came yet: it is building the
  /// context and the model is reading the prompt.
  preparing,

  /// Model reasoning is arriving.
  thinking,

  /// A tool is running ([AgentsTurnStatus.toolLabel] names it).
  tool,

  /// Between steps: a tool finished and the next step has not shown yet.
  working,

  /// Answer tokens are arriving.
  writing,

  /// The model service did not answer; the host asks again by itself after
  /// a wait (`heartbeat.retry`). [AgentsTurnStatus.retryInSeconds] says when.
  retrying,

  /// The run is blocked on the user: an approval, keys or a takeover.
  waitingForYou,

  /// The app gave up: the task never reached the computer.
  notDelivered,
}

/// One status, as the line prints it.
class AgentsTurnStatus {
  const AgentsTurnStatus(
    this.phase, {
    this.toolLabel,
    this.toolName,
    this.toolFromHost = false,
    this.retryInSeconds,
  });

  final AgentsTurnPhase phase;

  /// For [AgentsTurnPhase.retrying]: whole seconds until the host asks the
  /// model again. Null when the host gave no wait.
  final int? retryInSeconds;

  /// Present-tense name of the running tool, for [AgentsTurnPhase.tool], in
  /// English.
  final String? toolLabel;

  /// The raw name of the running tool (`web_search`). With it, [label]
  /// prints the tool's phrase in the reader's language.
  final String? toolName;

  /// Whether [toolName] came from the host's phase frame rather than from a
  /// tool line in the ledger. A host tool this app has no phrase for keeps
  /// its own name ("Browser click"); a ledger tool reads "Running …".
  final bool toolFromHost;

  /// Whether the line offers Retry: only where the user can do something
  /// about it — the computer is not reachable.
  bool get offersRetry =>
      phase == AgentsTurnPhase.offline || phase == AgentsTurnPhase.noAnswer;

  /// Whether the words stand next to the typing dots, not only in the panel
  /// a tap opens: every phase in which the turn is not simply working. A
  /// provider that fails and is asked again in 60 s, a computer that does
  /// not answer, a card that waits for the reader. Dots alone would say
  /// "working" while nothing moves (CHAT-76).
  bool get showsBesideDots => switch (phase) {
    AgentsTurnPhase.retrying ||
    AgentsTurnPhase.offline ||
    AgentsTurnPhase.noAnswer ||
    AgentsTurnPhase.waitingForYou ||
    AgentsTurnPhase.notDelivered => true,
    _ => false,
  };

  /// The words for the line, localised when [l10n] is given.
  String label([AppLocalizations? l10n]) => agentsTurnPhaseLabel(
    phase,
    l10n: l10n,
    toolLabel: _localToolLabel(l10n) ?? toolLabel,
    retryInSeconds: retryInSeconds,
  );

  String? _localToolLabel(AppLocalizations? l10n) {
    final String? name = toolName;
    if (name == null || name.isEmpty || l10n == null) return null;
    return toolFromHost
        ? knownToolActivityLabel(name, l10n)
        : toolActivityLabel(name, l10n);
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsTurnStatus &&
      other.phase == phase &&
      other.toolLabel == toolLabel &&
      other.toolName == toolName &&
      other.toolFromHost == toolFromHost &&
      other.retryInSeconds == retryInSeconds;

  @override
  int get hashCode =>
      Object.hash(phase, toolLabel, toolName, toolFromHost, retryInSeconds);

  @override
  String toString() => 'AgentsTurnStatus($phase, $toolLabel)';
}

/// The status of the turn on [run], or null when there is nothing to say.
///
/// [linkUp] is whether the computer is reachable right now. [streamPhase] is
/// the phase of this client's own stream for the thread, when one is open; it
/// is the fallback for a run the ledger knows little about.
AgentsTurnStatus? agentsTurnStatusFor({
  required AgentsRun? run,
  required bool linkUp,
  StreamPhase? streamPhase,
}) {
  if (run != null && !run.running) {
    // A run that is over speaks for itself, except the one end that left the
    // reader with nothing: the message never arrived.
    if (run.outcome == AgentsRunOutcome.notDelivered) {
      return const AgentsTurnStatus(AgentsTurnPhase.notDelivered);
    }
    return null;
  }
  if (run == null) {
    if (streamPhase == null) return null;
    if (!linkUp) return const AgentsTurnStatus(AgentsTurnPhase.offline);
    return switch (streamPhase) {
      StreamPhase.connecting => const AgentsTurnStatus(AgentsTurnPhase.sending),
      StreamPhase.processing => const AgentsTurnStatus(
        AgentsTurnPhase.preparing,
      ),
      StreamPhase.thinking => const AgentsTurnStatus(AgentsTurnPhase.thinking),
      StreamPhase.working => const AgentsTurnStatus(AgentsTurnPhase.working),
      StreamPhase.writing => const AgentsTurnStatus(AgentsTurnPhase.writing),
    };
  }

  // The user is what the run waits on: that outranks everything else.
  if (run.waitingForUser) {
    return const AgentsTurnStatus(AgentsTurnPhase.waitingForYou);
  }
  if (!linkUp) return const AgentsTurnStatus(AgentsTurnPhase.offline);

  // A tool that is open right now is the most precise true statement.
  final String? running = runningActivityLabel(run.toolCalls);
  if (running != null) {
    return AgentsTurnStatus(
      AgentsTurnPhase.tool,
      toolLabel: running,
      toolName: _runningToolName(run),
    );
  }

  // The host's own word, when it sends one and it is newer than the last
  // frame of output (a heartbeat every ten seconds can lag a token).
  final AgentsTurnStatus? host = _hostStatus(run);

  if (!run.producedOutput) {
    if (host != null) return host;
    if (run.sawHeartbeat) {
      return const AgentsTurnStatus(AgentsTurnPhase.preparing);
    }
    // Adopted from a `run_state` header: the host is on it, nothing more is
    // known.
    if (run.hostObserved) {
      return const AgentsTurnStatus(AgentsTurnPhase.working);
    }
    if (run.taskAcknowledged) {
      return const AgentsTurnStatus(AgentsTurnPhase.received);
    }
    if (run.taskWaits >= 1) {
      return const AgentsTurnStatus(AgentsTurnPhase.noAnswer);
    }
    return const AgentsTurnStatus(AgentsTurnPhase.sending);
  }

  final DateTime? signalAt = run.lastSignalAt;
  final DateTime? hostAt = run.hostPhaseAt;
  if (host != null &&
      hostAt != null &&
      (signalAt == null || hostAt.isAfter(signalAt))) {
    return host;
  }
  return switch (run.lastSignal) {
    AgentsRunSignal.writing => const AgentsTurnStatus(AgentsTurnPhase.writing),
    AgentsRunSignal.thinking => const AgentsTurnStatus(
      AgentsTurnPhase.thinking,
    ),
    AgentsRunSignal.tool => const AgentsTurnStatus(AgentsTurnPhase.working),
    AgentsRunSignal.none => switch (streamPhase) {
      StreamPhase.writing => const AgentsTurnStatus(AgentsTurnPhase.writing),
      StreamPhase.thinking => const AgentsTurnStatus(AgentsTurnPhase.thinking),
      _ => const AgentsTurnStatus(AgentsTurnPhase.working),
    },
  };
}

/// The host's `heartbeat.phase`, mapped. Null for a phase this app does not
/// know — a newer host may grow more, and an unknown word is not a status.
AgentsTurnStatus? _hostStatus(AgentsRun run) {
  switch (run.hostPhase) {
    case 'queued':
      return const AgentsTurnStatus(AgentsTurnPhase.queued);
    case 'preparing':
      return const AgentsTurnStatus(AgentsTurnPhase.preparing);
    case 'model':
      return const AgentsTurnStatus(AgentsTurnPhase.thinking);
    case 'tool':
      final String? tool = run.hostPhaseTool;
      if (tool == null || tool.isEmpty) {
        return const AgentsTurnStatus(AgentsTurnPhase.working);
      }
      return AgentsTurnStatus(
        AgentsTurnPhase.tool,
        toolLabel: knownToolActivityLabel(tool) ?? humanToolLabel(tool),
        toolName: tool,
        toolFromHost: true,
      );
    case 'waiting_user':
      return const AgentsTurnStatus(AgentsTurnPhase.waitingForYou);
    case 'retrying':
      // The wait as of the beat, less the time since: the line counts down
      // between beats too, and never below zero.
      final AgentsHostRetry? retry = run.hostRetry;
      final DateTime? at = run.hostPhaseAt;
      int? left;
      if (retry != null) {
        final double since = at == null
            ? 0
            : DateTime.now().difference(at).inMilliseconds / 1000;
        left = (retry.inSeconds - since).ceil().clamp(0, 1 << 30);
      }
      return AgentsTurnStatus(AgentsTurnPhase.retrying, retryInSeconds: left);
    default:
      return null;
  }
}

/// The words for [phase]. English when no [l10n] is at hand (tests, a widget
/// outside the app's localisations).
String agentsTurnPhaseLabel(
  AgentsTurnPhase phase, {
  AppLocalizations? l10n,
  String? toolLabel,
  int? retryInSeconds,
}) {
  final AppLocalizations? l = l10n;
  return switch (phase) {
    AgentsTurnPhase.sending => l?.agentsPhaseSending ?? 'Sending',
    AgentsTurnPhase.noAnswer => l?.agentsPhaseNoAnswer ?? 'Connecting…',
    AgentsTurnPhase.offline => l?.agentsPhaseOffline ?? 'Connecting…',
    AgentsTurnPhase.received => l?.agentsPhaseReceived ?? 'Got it',
    AgentsTurnPhase.queued => l?.agentsPhaseQueued ?? 'Queued',
    AgentsTurnPhase.preparing => l?.agentsPhasePreparing ?? 'Preparing',
    AgentsTurnPhase.thinking => l?.agentsPhaseThinking ?? 'Thinking',
    AgentsTurnPhase.tool =>
      (toolLabel != null && toolLabel.isNotEmpty)
          ? toolLabel
          : (l?.agentsPhaseWorking ?? 'Working'),
    AgentsTurnPhase.working => l?.agentsPhaseWorking ?? 'Working',
    AgentsTurnPhase.writing => l?.agentsPhaseWriting ?? 'Writing',
    AgentsTurnPhase.retrying =>
      retryInSeconds == null || retryInSeconds <= 0
          ? (l?.agentsPhaseRetryingNow ??
                'Provider not answering, trying again')
          : (l?.agentsPhaseRetryingIn('$retryInSeconds') ??
                'Provider not answering, trying again in $retryInSeconds s'),
    AgentsTurnPhase.waitingForYou =>
      l?.agentsPhaseWaitingForYou ?? 'Waiting for you',
    AgentsTurnPhase.notDelivered =>
      l?.agentsPhaseNotDelivered ?? 'Not sent yet, trying again',
  };
}

/// The name of the most recent tool that is still open on [run].
String? _runningToolName(AgentsRun run) {
  String? name;
  for (final ToolCall call in run.toolCalls) {
    if (call.status == ToolCallStatus.running ||
        call.status == ToolCallStatus.pending) {
      name = call.name;
    }
  }
  return name;
}
