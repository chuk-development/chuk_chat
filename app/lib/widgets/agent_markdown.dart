import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'package:cowork/utils/lenient_json.dart';
import 'package:cowork/widgets/chart_widget.dart';

/// One piece of an agent reply: prose, or a chart the agent asked for.
sealed class AgentSegment {
  const AgentSegment();
}

/// Markdown prose between the visual blocks.
class AgentTextSegment extends AgentSegment {
  const AgentTextSegment(this.text);
  final String text;
}

/// A parsed `<chart>` block, already decoded to its JSON map.
class AgentChartSegment extends AgentSegment {
  const AgentChartSegment(this.data);
  final Map<String, dynamic> data;
}

final RegExp _chartBlock = RegExp(
  r'<\s*chart\s*>([\s\S]*?)<\s*/\s*chart\s*>',
  caseSensitive: false,
);

/// The opening tag of a block whose end has not arrived yet.
final RegExp _chartStart = RegExp(r'<\s*chart\s*>', caseSensitive: false);

/// Decode a chart body, tolerating the two things a model gets wrong: a fenced
/// block around the JSON, and a trailing comma before `}` or `]`. Returns null
/// when the body is not a JSON object.
Map<String, dynamic>? decodeChartBody(String body) =>
    tryDecodeLenientJsonObject(body);

/// Split an agent reply into prose and `<chart>` blocks.
///
/// A block whose JSON does not decode stays in the prose verbatim — losing the
/// numbers silently is worse than showing them raw. A block that is still
/// streaming (opening tag, no closing tag yet) is held back: half a JSON body
/// is not something to show a reader, and the next delta completes it.
List<AgentSegment> splitAgentSegments(String data) {
  final segments = <AgentSegment>[];
  var cursor = 0;

  // Prose keeps its own whitespace: leading spaces carry indented code blocks
  // and two trailing spaces are a Markdown hard line break.
  void addText(String text) {
    if (text.trim().isEmpty) return;
    segments.add(AgentTextSegment(text));
  }

  for (final match in _chartBlock.allMatches(data)) {
    final chart = decodeChartBody(match.group(1) ?? '');
    // A block with no number in it is not a chart; leaving it in the prose
    // shows the reader what the agent sent instead of an empty frame.
    if (chart == null || !ChartRenderer.hasPlottableData(normalizeChartData(chart))) {
      continue;
    }
    addText(data.substring(cursor, match.start));
    segments.add(AgentChartSegment(chart));
    cursor = match.end;
  }

  var tail = data.substring(cursor);
  final open = _chartStart.firstMatch(tail);
  if (open != null && !_chartBlock.hasMatch(tail)) {
    tail = tail.substring(0, open.start); // still streaming — hold it back
  }
  addText(tail);
  return segments;
}

/// Renders an agent reply as Markdown, with `<chart>` blocks drawn as charts.
///
/// The agent is instructed to answer in Markdown — headings, lists, fenced code
/// with a language — so the thread must render it. A raw `#` and stray
/// backticks are what a chat UI looks like when it forgets to. The same is true
/// of a `<chart>` block: a markdown renderer drops it, so the reader sees the
/// numbers vanish instead of a chart.
///
/// It is a block, not a page: it brings no scroll view of its own, so it
/// composes inside the thread's [ListView]. The syntax theme follows the app
/// theme, and code keeps a monospace font at chat size.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final segments = splitAgentSegments(data);
    if (segments.length == 1 && segments.first is AgentTextSegment) {
      return _markdown(context, (segments.first as AgentTextSegment).text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in segments)
          switch (segment) {
            AgentTextSegment(:final text) => _markdown(context, text),
            AgentChartSegment(:final data) => ChartRenderer(data: data),
          },
      ],
    );
  }

  Widget _markdown(BuildContext context, String text) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = dark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
    final pre = dark ? PreConfig.darkConfig : const PreConfig();

    return MarkdownBlock(
      data: text,
      selectable: true,
      config: base.copy(
        configs: [
          PConfig(
            textStyle: theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14),
          ),
          pre.copy(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.symmetric(vertical: 6),
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          dark ? CodeConfig.darkConfig : const CodeConfig(),
        ],
      ),
    );
  }
}
