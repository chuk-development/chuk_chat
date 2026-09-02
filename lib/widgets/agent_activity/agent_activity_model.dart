// lib/widgets/agent_activity/agent_activity_model.dart
//
// Turns a round's tool calls into the lines an activity timeline shows:
// one line per step, in the order they happened, each carrying the pages
// it pulled in. Pure functions — the widget only renders what this
// produces, so the wording and the source extraction are testable on
// their own.

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

/// A page a step pulled in, shown as a chip under that step.
class AgentActivitySource {
  const AgentActivitySource({
    required this.url,
    required this.host,
    required this.title,
  });

  final String url;
  final String host;
  final String title;
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
    this.sources = const <AgentActivitySource>[],
    this.body,
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

  /// Pages this step brought in. Rendered as chips under the line, the
  /// way a reader checks where an answer came from without opening the
  /// raw result.
  final List<AgentActivitySource> sources;

  /// The whole of what the model wrote, when the line is only its first
  /// sentence. A reader can open it; the line stays short either way.
  final String? body;

  bool get isGroup => children.isNotEmpty;

  bool get hasBody => (body?.trim().isNotEmpty ?? false);
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
        label: 'Searched',
        detail: subject,
        hasError: hasError,
        toolCall: call,
        sources: extractSourcesFor(call),
      );
    case AgentActivityKind.page:
      return AgentActivityEntry(
        kind: kind,
        label: 'Opened page',
        detail: subject == null ? null : _shortenUrl(subject),
        hasError: hasError,
        toolCall: call,
        sources: extractSourcesFor(call),
      );
    case AgentActivityKind.thinking:
    case AgentActivityKind.other:
      return AgentActivityEntry(
        kind: AgentActivityKind.other,
        label: 'Ran ${_humanizeToolName(call.name)}',
        detail: subject,
        hasError: hasError,
        toolCall: call,
        sources: extractSourcesFor(call),
      );
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
    // The steps already carry the round's thinking as its own entry. Left
    // on, the calls would repeat it and every note would appear twice.
    entries.addAll(
      buildAgentActivityEntries(
        List<ToolCall>.of(pendingCalls),
        includeRoundThinking: false,
      ),
    );
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
          body: reasoning,
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
/// One line per call, in the order the model made them — a run of eight
/// searches reads as eight searches, each with its own query and its own
/// sources. A `roundThinking` note is emitted as its own line before the
/// call that carries it, because that is when the model wrote it.
List<AgentActivityEntry> buildAgentActivityEntries(
  List<ToolCall> calls, {
  bool includeRoundThinking = true,
}) {
  final entries = <AgentActivityEntry>[];

  for (final call in calls) {
    final thinking = includeRoundThinking ? call.roundThinking?.trim() : null;
    if (thinking != null && thinking.isNotEmpty) {
      entries.add(
        AgentActivityEntry(
          kind: AgentActivityKind.thinking,
          label: _clip(_firstSentence(thinking), _maxThinkingChars),
          body: thinking,
        ),
      );
    }
    entries.add(_entryFor(call));
  }

  return entries;
}

/// Most source chips shown under one step.
const int maxSourcesPerStep = 8;

/// The pages a call pulled in.
///
/// `web_search` results list numbered titles with an indented URL under
/// each; `web_crawl` fetches the one URL it was given. Anything else falls
/// back to the URLs in the result text, which is how a new tool still gets
/// chips without this having to know about it.
List<AgentActivitySource> extractSourcesFor(ToolCall call) {
  final result = call.result;
  if (result == null || result.isEmpty) return const <AgentActivitySource>[];

  final sources = <AgentActivitySource>[];
  final seen = <String>{};

  void add(String url, String? title) {
    final trimmed = url.trim().replaceAll(RegExp(r'[),.]+$'), '');
    if (trimmed.isEmpty || !seen.add(trimmed)) return;
    if (sources.length >= maxSourcesPerStep) return;
    final host = Uri.tryParse(trimmed)?.host ?? trimmed;
    sources.add(
      AgentActivitySource(
        url: trimmed,
        host: host.replaceFirst(RegExp(r'^www\.'), ''),
        title: (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : host,
      ),
    );
  }

  if (call.name == 'web_crawl') {
    final url = call.arguments['url'];
    if (url is String && url.isNotEmpty) {
      add(url, result.split('\n').first.replaceFirst(
        RegExp(r'^Content from\s+'),
        '',
      ));
    }
    return List<AgentActivitySource>.unmodifiable(sources);
  }

  final titles = RegExp(r'^\d+\.\s+(.+)$', multiLine: true)
      .allMatches(result)
      .map((m) => m.group(1)!)
      .toList(growable: false);
  final urls = RegExp(r'^\s+(https?://\S+)', multiLine: true)
      .allMatches(result)
      .map((m) => m.group(1)!)
      .toList(growable: false);

  if (urls.isNotEmpty) {
    for (int i = 0; i < urls.length; i++) {
      add(urls[i], i < titles.length ? titles[i] : null);
    }
    return List<AgentActivitySource>.unmodifiable(sources);
  }

  for (final match in RegExp(r'https?://\S+').allMatches(result)) {
    add(match.group(0)!, null);
  }
  return List<AgentActivitySource>.unmodifiable(sources);
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
Duration? agentActivityDuration(
  List<ToolCall> calls, {
  required DateTime now,
  bool running = false,
}) {
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
  // While the round runs the clock runs with it, even between calls: the
  // model thinking after its last tool is still time the reader waits.
  final stop = running || stillRunning || end == null ? now : end;
  final elapsed = stop.difference(start);
  return elapsed.isNegative ? Duration.zero : elapsed;
}

/// Compact duration wording: `4s`, `1m 3s`, `2h 5m`.
/// Live elapsed label for a RUNNING turn: one decimal below a minute, so the
/// counter visibly climbs several times a second instead of jumping once per
/// whole second. Above a minute it reads the same as the settled label — a
/// tenth of a second there is noise. The settled value keeps whole seconds.
String formatAgentDurationLive(Duration duration) {
  if (duration.inSeconds < 60) {
    final seconds = duration.inMilliseconds / 1000.0;
    return '${seconds.toStringAsFixed(1)}s';
  }
  return formatAgentDuration(duration);
}

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
