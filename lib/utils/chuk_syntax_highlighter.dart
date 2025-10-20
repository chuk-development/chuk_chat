// lib/utils/chuk_syntax_highlighter.dart

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlight/highlight.dart' as hl;

/// Provides lightweight syntax highlighting for Markdown code blocks.
class ChukSyntaxHighlighter extends SyntaxHighlighter {
  ChukSyntaxHighlighter(this.context, this.textColor);

  final BuildContext context;
  final Color textColor;

  @override
  TextSpan format(String source, {String? language}) {
    final ThemeData theme = Theme.of(context);
    final Brightness brightness = theme.colorScheme.brightness;
    final TextStyle baseStyle =
        theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
          color: textColor,
        ) ??
        const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4);

    final hl.Result result = hl.highlight.parse(
      source,
      language: (language != null && language.trim().isNotEmpty)
          ? language.trim()
          : null,
      autoDetection: language == null || language.trim().isEmpty,
    );
    final Map<String, TextStyle> themeStyles = _tokenStyles(brightness);

    final List<InlineSpan> spans = <InlineSpan>[];
    for (final hl.Node node in result.nodes ?? <hl.Node>[]) {
      spans.add(_buildTextSpan(node, themeStyles));
    }

    if (spans.isEmpty) {
      return TextSpan(text: source, style: baseStyle);
    }

    return TextSpan(style: baseStyle, children: spans);
  }

  TextSpan _buildTextSpan(hl.Node node, Map<String, TextStyle> themeStyles) {
    final TextStyle? style = _styleFor(node.className, themeStyles);

    if (node.value != null) {
      return TextSpan(text: node.value, style: style);
    }

    final List<InlineSpan> children = <InlineSpan>[];
    if (node.children != null) {
      for (final hl.Node child in node.children!) {
        children.add(_buildTextSpan(child, themeStyles));
      }
    }
    return TextSpan(style: style, children: children);
  }

  TextStyle? _styleFor(String? className, Map<String, TextStyle> themeStyles) {
    if (className == null || className.isEmpty) {
      return null;
    }

    TextStyle? result;
    for (final String part in className.split(' ')) {
      final TextStyle? candidate = themeStyles[part];
      if (candidate != null) {
        result = result == null ? candidate : result.merge(candidate);
      }
    }
    return result;
  }

  Map<String, TextStyle> _tokenStyles(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return <String, TextStyle>{
        'keyword': const TextStyle(color: Color(0xFF82AAFF)),
        'built_in': const TextStyle(color: Color(0xFF82AAFF)),
        'type': const TextStyle(color: Color(0xFFC792EA)),
        'literal': const TextStyle(color: Color(0xFFF78C6C)),
        'number': const TextStyle(color: Color(0xFFF78C6C)),
        'string': const TextStyle(color: Color(0xFFC3E88D)),
        'subst': const TextStyle(color: Color(0xFFEEFFFF)),
        'symbol': const TextStyle(color: Color(0xFFEAB676)),
        'class': const TextStyle(color: Color(0xFFFFCB6B)),
        'function': const TextStyle(color: Color(0xFF82AAFF)),
        'title': const TextStyle(color: Color(0xFF82AAFF)),
        'params': const TextStyle(color: Color(0xFFEEFFFF)),
        'operator': const TextStyle(color: Color(0xFF89DDFF)),
        'punctuation': const TextStyle(color: Color(0xFF89DDFF)),
        'comment': const TextStyle(
          color: Color(0xFF676E95),
          fontStyle: FontStyle.italic,
        ),
        'meta': const TextStyle(color: Color(0xFF75A7F0)),
        'attr': const TextStyle(color: Color(0xFFADD7FF)),
        'attribute': const TextStyle(color: Color(0xFFADD7FF)),
        'property': const TextStyle(color: Color(0xFFADD7FF)),
        'variable': const TextStyle(color: Color(0xFFEEFFFF)),
      };
    }

    return <String, TextStyle>{
      'keyword': const TextStyle(color: Color(0xFF7C4DFF)),
      'built_in': const TextStyle(color: Color(0xFF7C4DFF)),
      'type': const TextStyle(color: Color(0xFF5E35B1)),
      'literal': const TextStyle(color: Color(0xFFD81B60)),
      'number': const TextStyle(color: Color(0xFF1E88E5)),
      'string': const TextStyle(color: Color(0xFF2E7D32)),
      'subst': const TextStyle(color: Color(0xFF3E2723)),
      'symbol': const TextStyle(color: Color(0xFFF57C00)),
      'class': const TextStyle(color: Color(0xFF6D4C41)),
      'function': const TextStyle(color: Color(0xFF0D47A1)),
      'title': const TextStyle(color: Color(0xFF0D47A1)),
      'params': const TextStyle(color: Color(0xFF283593)),
      'operator': const TextStyle(color: Color(0xFF3949AB)),
      'punctuation': const TextStyle(color: Color(0xFF3949AB)),
      'comment': const TextStyle(
        color: Color(0xFF757575),
        fontStyle: FontStyle.italic,
      ),
      'meta': const TextStyle(color: Color(0xFF00897B)),
      'attr': const TextStyle(color: Color(0xFFAF3D00)),
      'attribute': const TextStyle(color: Color(0xFFAF3D00)),
      'property': const TextStyle(color: Color(0xFFAF3D00)),
      'variable': const TextStyle(color: Color(0xFF1A237E)),
    };
  }
}
