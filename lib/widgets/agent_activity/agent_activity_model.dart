// lib/widgets/agent_activity/agent_activity_model.dart
//
// Turns a round's tool calls into the lines an activity timeline shows:
// one line per step, consecutive steps of the same kind folded into a
// group ("Ran 4 searches"). Pure functions — the widget only renders what
// this produces, so the wording and grouping are testable on their own.

import 'package:chuk_chat/models/tool_call.dart';

/// What a timeline line represents. Drives the icon and the wording.
enum AgentActivityKind {
  /// A search: web, chats, files.
  search,

  /// Fetching or reading one page.
  page,

  /// A thought the model recorded before acting.
  thinking,

  /// Anything else the model called.
  other,
}

/// One line in the timeline.
class AgentActivityEntry {
  const AgentActivityEntry({
    required this.kind,
    required this.label,
    this.detail,
    this.children = const <AgentActivityEntry>[],
    this.hasError = false,
    this.toolCall,
  });

  final AgentActivityKind kind;

  /// Leading text, e.g. `Searched web for` or `Ran 4 searches`.
  final String label;

  /// The subject, rendered in a monospace face: a query or a URL.
  final String? detail;

  /// Steps folded under a group header.
  final List<AgentActivityEntry> children;

  /// Whether any step behind this line failed.
  final bool hasError;

  /// The call this line stands for, so a reader can open its arguments and
  /// result. Null on group headers and on thinking notes — those summarise
  /// several calls or none.
  final ToolCall? toolCall;

  bool get isGroup => children.isNotEmpty;
}

/// Argument keys that hold the thing a tool acted on, in priority order.
const List<String> _subjectKeys = <String>[
  'query',
  'q',
  'search_query',
  'searchQuery',
  'url',
  'link',
  'page',
  'path',
  'prompt',
];

/// Longest subject shown before it is cut with an ellipsis.
const int _maxDetailChars = 96;

/// Longest thinking line shown.
const int _maxThinkingChars = 120;

AgentActivityKind _kindOf(ToolCall call) {
  final name = call.name.toLowerCase();
  if (name.contains('search') || name.contains('find')) {
    return AgentActivityKind.search;
  }
  if (name.contains('fetch') ||
      name.contains('open') ||
      name.contains('browse') ||
      name.contains('scrape') ||
      name.contains('url') ||
      name.contains('page')) {
    return AgentActivityKind.page;
  }
  return AgentActivityKind.other;
}

String? _subjectOf(ToolCall call) {
  for (final key in _subjectKeys) {
    final value = call.arguments[key];
    if (value is String && value.trim().isNotEmpty) {
      return _clip(value.trim(), _maxDetailChars);
    }
  }
  return null;
}

String _clip(String value, int max) {
  if (value.length <= max) return value;
  return '${value.substring(0, max - 1).trimRight()}…';
}

/// Strip the scheme and any `www.` so a URL reads as a place, not a link.
String _shortenUrl(String url) {
  var short = url.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  short = short.replaceFirst(RegExp(r'^www\.'), '');
  return _clip(short, _maxDetailChars);
}

/// Human wording for a tool name: `generate_image` → `generate image`.
String _humanizeToolName(String name) {
  final spaced = name.replaceAll('_', ' ').replaceAll('.', ' ').trim();
  return spaced.isEmpty ? 'tool' : spaced;
}

AgentActivityEntry _entryFor(ToolCall call) {
  final kind = _kindOf(call);
  final subject = _subjectOf(call);
  final hasError = call.status == ToolCallStatus.error;

  switch (kind) {
    case AgentActivityKind.search:
      return AgentActivityEntry(
        kind: kind,
        label: 'Searched for',
        detail: subject,
        hasError: hasError,
        toolCall: call,
      );
    case AgentActivityKind.page:
      return AgentActivityEntry(
        kind: kind,
        label: 'Opened page',
        detail: subject == null ? null : _shortenUrl(subject),
        hasError: hasError,
        toolCall: call,
      );
    case AgentActivityKind.thinking:
    case AgentActivityKind.other:
      return AgentActivityEntry(
        kind: AgentActivityKind.other,
        label: 'Ran ${_humanizeToolName(call.name)}',
        detail: subject,
        hasError: hasError,
        toolCall: call,
      );
  }
}

/// Plural-aware header for a folded run of steps.
String _groupLabel(AgentActivityKind kind, int count) {
  switch (kind) {
    case AgentActivityKind.search:
      return count == 1 ? 'Ran 1 search' : 'Ran $count searches';
    case AgentActivityKind.page:
      return count == 1 ? 'Opened 1 page' : 'Opened $count pages';
    case AgentActivityKind.thinking:
      return 'Thought $count times';
    case AgentActivityKind.other:
      return count == 1 ? 'Ran 1 step' : 'Ran $count steps';
  }
}

/// One thing that happened in a round, in the order it happened: either a
/// tool call or a stretch of reasoning between calls.
class AgentActivityStep {
  const AgentActivityStep.reasoning(String text)
    : reasoning = text,
      toolCall = null;
  const AgentActivityStep.tool(ToolCall call)
    : toolCall = call,
      reasoning = null;

  final String? reasoning;
  final ToolCall? toolCall;
}

/// Build the timeline lines for an ordered mix of reasoning and calls.
///
/// This is the general form: reasoning recorded between two calls keeps
/// its place, and it breaks a run of same-kind calls so the note stays
/// next to the step it belongs to.
List<AgentActivityEntry> buildAgentActivityEntriesFromSteps(
  List<AgentActivityStep> steps,
) {
  final entries = <AgentActivityEntry>[];
  final pendingCalls = <ToolCall>[];

  void flushCalls() {
    if (pendingCalls.isEmpty) return;
    entries.addAll(buildAgentActivityEntries(List<ToolCall>.of(pendingCalls)));
    pendingCalls.clear();
  }

  for (final step in steps) {
    final reasoning = step.reasoning?.trim();
    if (reasoning != null && reasoning.isNotEmpty) {
      flushCalls();
      entries.add(
        AgentActivityEntry(
          kind: AgentActivityKind.thinking,
          label: _clip(_firstSentence(reasoning), _maxThinkingChars),
        ),
      );
      continue;
    }

    final call = step.toolCall;
    if (call != null) pendingCalls.add(call);
  }

  flushCalls();
  return entries;
}

/// Build the timeline lines for [calls].
///
/// A run of two or more consecutive calls of the same kind becomes one
/// group header with the individual steps as children — this is what keeps
/// a round of eight searches from filling the screen. A `roundThinking`
/// note is emitted as its own line before the call that carries it,
/// because that is when the model wrote it.
List<AgentActivityEntry> buildAgentActivityEntries(List<ToolCall> calls) {
  final entries = <AgentActivityEntry>[];

  int index = 0;
  while (index < calls.length) {
    final call = calls[index];

    final thinking = call.roundThinking?.trim();
    if (thinking != null && thinking.isNotEmpty) {
      entries.add(
        AgentActivityEntry(
          kind: AgentActivityKind.thinking,
          label: _clip(_firstSentence(thinking), _maxThinkingChars),
        ),
      );
    }

    // How far does this run of same-kind calls reach? A call carrying its
    // own thinking note starts a new run, so the note stays next to it.
    final kind = _kindOf(call);
    int end = index + 1;
    while (end < calls.length &&
        _kindOf(calls[end]) == kind &&
        (calls[end].roundThinking?.trim().isEmpty ?? true)) {
      end++;
    }

    final run = calls.sublist(index, end);
    if (run.length == 1) {
      entries.add(_entryFor(run.first));
    } else {
      final children = run.map(_entryFor).toList(growable: false);
      entries.add(
        AgentActivityEntry(
          kind: kind,
          label: _groupLabel(kind, run.length),
          children: children,
          hasError: children.any((child) => child.hasError),
        ),
      );
    }

    index = end;
  }

  return entries;
}

/// First sentence of [text], or the whole string when it has no break.
String _firstSentence(String text) {
  final match = RegExp(r'[.!?](\s|$)').firstMatch(text);
  if (match == null) return text.trim();
  return text.substring(0, match.start + 1).trim();
}

/// Total wall time of a round: first start to last completion.
///
/// While calls are still running the end is [now], so the label counts up.
/// Returns null when [calls] is empty.
Duration? agentActivityDuration(List<ToolCall> calls, {required DateTime now}) {
  if (calls.isEmpty) return null;

  DateTime? start;
  DateTime? end;
  var stillRunning = false;

  for (final call in calls) {
    if (start == null || call.startedAt.isBefore(start)) {
      start = call.startedAt;
    }
    final completed = call.completedAt;
    if (completed == null) {
      stillRunning = true;
    } else if (end == null || completed.isAfter(end)) {
      end = completed;
    }
  }

  if (start == null) return null;
  final stop = stillRunning || end == null ? now : end;
  final elapsed = stop.difference(start);
  return elapsed.isNegative ? Duration.zero : elapsed;
}

/// Compact duration wording: `4s`, `1m 3s`, `2h 5m`.
String formatAgentDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  if (totalSeconds < 60) return '${totalSeconds}s';

  if (duration.inMinutes < 60) {
    final seconds = totalSeconds % 60;
    return seconds == 0
        ? '${duration.inMinutes}m'
        : '${duration.inMinutes}m ${seconds}s';
  }

  final minutes = duration.inMinutes % 60;
  return minutes == 0
      ? '${duration.inHours}h'
      : '${duration.inHours}h ${minutes}m';
}
