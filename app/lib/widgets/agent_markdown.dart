import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// Renders an agent reply as Markdown.
///
/// The agent is instructed to answer in Markdown — headings, lists, fenced code
/// with a language — so the thread must render it. A raw `#` and stray
/// backticks are what a chat UI looks like when it forgets to.
///
/// It is a block, not a page: it brings no scroll view of its own, so it
/// composes inside the thread's [ListView]. The syntax theme follows the app
/// theme, and code keeps a monospace font at chat size.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = dark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
    final pre = dark ? PreConfig.darkConfig : const PreConfig();

    return MarkdownBlock(
      data: data,
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
