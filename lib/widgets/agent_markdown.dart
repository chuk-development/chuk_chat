import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/lenient_json.dart';
import 'package:chuk_chat/widgets/chart_widget.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

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

/// Its closing tag.
final RegExp _chartEnd = RegExp(r'<\s*/\s*chart\s*>', caseSensitive: false);

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
    if (chart == null ||
        !ChartRenderer.hasPlottableData(normalizeChartData(chart))) {
      continue;
    }
    addText(data.substring(cursor, match.start));
    segments.add(AgentChartSegment(chart));
    cursor = match.end;
  }

  // The tail may hold an unreadable block that already closed plus a block
  // that is still arriving. Only the last opening tag decides: if nothing
  // closes it, the reply is mid-stream and the partial JSON is held back.
  var tail = data.substring(cursor);
  final opens = _chartStart.allMatches(tail).toList();
  if (opens.isNotEmpty) {
    final last = opens.last;
    final closes = _chartEnd.hasMatch(tail.substring(last.end));
    if (!closes) tail = tail.substring(0, last.start);
  }
  addText(tail);
  return segments;
}

/// Renders an agent reply as Markdown, with `<chart>` blocks drawn as charts.
///
/// This widget exists for one thing the plain markdown renderer cannot do: a
/// `<chart>` block. A markdown renderer drops the tag, so the reader watches
/// the numbers vanish instead of seeing a chart. Splitting the reply into prose
/// and charts is therefore the whole job here — the prose itself is handed to
/// [MarkdownMessage], the app's one markdown renderer, so a document gets the
/// same inline code chips, underlined accent links, monotonic heading sizes,
/// list markers, horizontally scrolling code blocks and [ChukTable] tables that
/// the chat gets. A second, simpler markdown path only means a second set of
/// bugs.
///
/// It is a block, not a page: it brings no scroll view of its own, so it
/// composes inside the thread's [ListView] or a document's scroll view.
///
/// [fontSize] and [height] set the reading size of the prose. A document passes
/// a larger size and a looser line height than a chat bubble; leaving them null
/// keeps the chat defaults.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(
    this.data, {
    super.key,
    this.fontSize,
    this.height,
    this.selectable = true,
  });

  final String data;
  final double? fontSize;
  final double? height;

  /// One [SelectionArea] around the whole reply, so a drag selects across a
  /// heading, a list and the paragraph after it. Turn it off when the caller
  /// already provides one — a nested selection area swallows the outer drag.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final segments = splitAgentSegments(data);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in segments)
          switch (segment) {
            AgentTextSegment(:final text) => _markdown(context, text),
            AgentChartSegment(:final data) => ChartRenderer(data: data),
          },
      ],
    );
    if (!selectable) return body;
    return SelectionArea(child: body);
  }

  Widget _markdown(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return MarkdownMessage(
      text: text,
      textColor: scheme.onSurface,
      backgroundColor: scheme.surface,
      // The one selection area is put up by [build]; a second one here would
      // cut every selection at a segment boundary.
      wrapWithSelectionArea: false,
      paragraphFontSize: fontSize,
      paragraphHeight: height,
    );
  }
}
