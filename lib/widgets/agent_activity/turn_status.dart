// lib/widgets/agent_activity/turn_status.dart
//
// One source of truth for the status line above an answer: what the turn is
// doing right now, and how long it has been doing it.
//
// Mobile and desktop have their own send pipelines, and the wording used to
// be decided inside each layout branch of the bubble. The result was a header
// that said "Thinking" while the request was still travelling, a second
// branch that printed no time at all, and two places to fix whenever the
// wording changed. Every header now goes through this file.

import 'package:chuk_chat/models/stream_phase.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';

/// The status of one assistant turn, as the header above it reports it.
class TurnStatus {
  const TurnStatus({
    required this.isRunning,
    required this.hasToolCalls,
    this.hasSteps = false,
    this.phase,
    this.runningToolLabel,
    this.elapsed,
  });

  /// Whether the turn is still going.
  final bool isRunning;

  /// Whether the turn made any tool call — it decides between the thinking
  /// wording and the working wording once the turn has settled.
  final bool hasToolCalls;

  /// Whether anything has arrived yet — a stretch of reasoning or a call.
  /// Only used for the fallback wording, when the live phase is unknown.
  final bool hasSteps;

  /// What the stream is doing right now. Null when nothing is running, and
  /// null on a turn whose live phase could not be read.
  final StreamPhase? phase;

  /// Present-tense name of the tool the turn is waiting on, e.g.
  /// "Searching the web". Outranks [phase]: the model is blocked on the
  /// tool, whatever token it last sent.
  final String? runningToolLabel;

  /// How long the turn has taken so far, or took in total.
  final Duration? elapsed;

  /// The verb in front of the duration: what the turn is doing, or did.
  ///
  /// While it runs, a running tool wins over the stream phase, because the
  /// model is waiting on that tool. Without either, the fallback names the
  /// shape of the turn rather than claiming a phase that was never read.
  String get verb {
    if (isRunning) {
      final tool = runningToolLabel;
      if (tool != null && tool.isNotEmpty) return tool;
      final p = phase;
      if (p != null) return p.label;
      // No live phase to read — the request is in flight but the stream has
      // not been registered yet. Nothing has arrived, so the honest word is
      // the first phase, not a claim that the model is thinking.
      if (hasToolCalls) return StreamPhase.working.label;
      return hasSteps ? StreamPhase.thinking.label : StreamPhase.connecting.label;
    }
    return hasToolCalls ? 'Worked' : 'Thought';
  }

  /// Whether a duration is printed next to [verb].
  ///
  /// A settled turn always prints one when it is known, a turn under a
  /// second included — it shows as a tenth of a second, because the header's
  /// job is to say how long the reader waited. A running turn waits for its
  /// first whole second: "Connecting for 0s" says nothing the verb does not.
  bool get showsDuration {
    final value = elapsed;
    if (value == null) return false;
    return isRunning ? value.inSeconds >= 1 : true;
  }

  /// The whole header line, e.g. `Prompt processing for 3s`.
  String get label {
    if (!showsDuration) return verb;
    final text = isRunning
        ? formatAgentDurationLive(elapsed!)
        : formatAgentDuration(elapsed!);
    return '$verb for $text';
  }
}

/// True while any call in [calls] is still pending or running.
bool hasRunningToolCall(List<ToolCall> calls) => calls.any(
  (call) =>
      call.status == ToolCallStatus.running ||
      call.status == ToolCallStatus.pending,
);

/// How long the turn has taken, from the most trustworthy source available.
///
/// In order: the number measured when the turn ended, the clock running from
/// the moment the request went out, the last value the live counter showed
/// (so a turn that ends without a recorded number does not drop back to no
/// time at all), and finally the old guess from the tool-call stamps, which
/// is all a message written before the turn clock existed can offer.
Duration? resolveTurnElapsed({
  Duration? finalDuration,
  DateTime? startedAt,
  required DateTime now,
  required bool isRunning,
  Duration? lastLiveDuration,
  List<ToolCall> toolCalls = const <ToolCall>[],
}) {
  if (finalDuration != null) return finalDuration;
  // The settled number comes before the running clock: a turn that is over
  // must not keep growing because its start stamp is still around.
  if (!isRunning && lastLiveDuration != null) return lastLiveDuration;
  if (startedAt != null) {
    final elapsed = now.difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }
  return agentActivityDuration(toolCalls, now: now, running: isRunning);
}
