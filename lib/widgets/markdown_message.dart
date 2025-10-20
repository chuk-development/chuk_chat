// lib/widgets/markdown_message.dart

import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' as hi;
import 'package:markdown_widget/markdown_widget.dart';

class MarkdownMessage extends StatefulWidget {
  const MarkdownMessage({
    super.key,
    required this.text,
    required this.textColor,
    required this.backgroundColor,
  });

  final String text;
  final Color textColor;
  final Color backgroundColor;

  @override
  State<MarkdownMessage> createState() => _MarkdownMessageState();
}

class _MarkdownMessageState extends State<MarkdownMessage> {
  List<Widget>? _cachedContent;
  String? _lastText;
  Color? _lastTextColor;
  Color? _lastBackgroundColor;
  Brightness? _lastBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureCache();
  }

  @override
  void didUpdateWidget(covariant MarkdownMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != _lastText ||
        widget.textColor != _lastTextColor ||
        widget.backgroundColor != _lastBackgroundColor) {
      _rebuildCache();
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> renderedContent = _ensureCache();

    return SelectionArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: renderedContent,
      ),
    );
  }

  List<Widget> _ensureCache() {
    final ThemeData theme = Theme.of(context);
    final Brightness currentBrightness = theme.brightness;
    final bool themeChanged = _lastBrightness != currentBrightness;

    if (_cachedContent == null || themeChanged) {
      _rebuildCache();
    }

    return _cachedContent!;
  }

  void _rebuildCache() {
    final ThemeData theme = Theme.of(context);
    final Color codeBackground = _codeBackground();
    final Map<String, TextStyle> syntaxTheme = _getSyntaxTheme(context);
    final TextStyle codeTextStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.4,
      color: widget.textColor,
    );
    final Color codeBorderColor = widget.textColor.withValues(alpha: 0.2);

    final MarkdownConfig config = MarkdownConfig(
      configs: [
        PConfig(
          textStyle:
              (theme.textTheme.bodyMedium?.copyWith(
                color: widget.textColor,
                height: 1.45,
                fontSize: 14,
              )) ??
              TextStyle(color: widget.textColor, height: 1.45, fontSize: 14),
        ),
        H1Config(
          style:
              (theme.textTheme.headlineSmall?.copyWith(
                color: widget.textColor,
                height: 1.3,
                fontWeight: FontWeight.w700,
              )) ??
              TextStyle(
                color: widget.textColor,
                height: 1.3,
                fontWeight: FontWeight.w700,
              ),
        ),
        H2Config(
          style:
              (theme.textTheme.titleLarge?.copyWith(
                color: widget.textColor,
                height: 1.3,
                fontWeight: FontWeight.w700,
              )) ??
              TextStyle(
                color: widget.textColor,
                height: 1.3,
                fontWeight: FontWeight.w700,
              ),
        ),
        H3Config(
          style:
              (theme.textTheme.titleMedium?.copyWith(
                color: widget.textColor,
                height: 1.3,
                fontWeight: FontWeight.w700,
              )) ??
              TextStyle(
                color: widget.textColor,
                height: 1.3,
                fontWeight: FontWeight.w700,
              ),
        ),
        H4Config(
          style:
              (theme.textTheme.titleSmall?.copyWith(
                color: widget.textColor,
                height: 1.35,
                fontWeight: FontWeight.w600,
              )) ??
              TextStyle(
                color: widget.textColor,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
        ),
        H5Config(
          style:
              (theme.textTheme.bodyLarge?.copyWith(
                color: widget.textColor,
                height: 1.35,
                fontWeight: FontWeight.w600,
              )) ??
              TextStyle(
                color: widget.textColor,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
        ),
        H6Config(
          style:
              (theme.textTheme.bodyMedium?.copyWith(
                color: widget.textColor,
                height: 1.35,
                fontWeight: FontWeight.w600,
              )) ??
              TextStyle(
                color: widget.textColor,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
        ),
        CodeConfig(
          style:
              codeTextStyle.copyWith(backgroundColor: codeBackground),
        ),
        PreConfig(
          padding: EdgeInsets.zero,
          margin: EdgeInsets.zero,
          textStyle: codeTextStyle,
          styleNotMatched: codeTextStyle,
          theme: syntaxTheme,
          builder: (code, language) => _buildCodeBlock(
            code: code,
            language: language,
            textStyle: codeTextStyle,
            backgroundColor: codeBackground,
            borderColor: codeBorderColor,
            theme: syntaxTheme,
          ),
        ),
        BlockquoteConfig(
          textColor: widget.textColor,
          sideColor: widget.textColor.withValues(alpha: 0.35),
          sideWith: 3.0,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        ),
        TableConfig(
          columnWidths: const <int, TableColumnWidth>{0: FlexColumnWidth()},
          border: TableBorder.all(
            color: widget.textColor.withValues(alpha: 0.2),
            width: 1,
          ),
          defaultColumnWidth: const FlexColumnWidth(),
          headerStyle:
              (theme.textTheme.bodyMedium?.copyWith(
                color: widget.textColor,
                fontWeight: FontWeight.w600,
              )) ??
              TextStyle(
                color: widget.textColor,
                fontWeight: FontWeight.w600,
              ),
          bodyStyle:
              (theme.textTheme.bodyMedium?.copyWith(
                color: widget.textColor,
              )) ??
              TextStyle(color: widget.textColor),
        ),
        ListConfig(),
        HrConfig(color: widget.textColor.withValues(alpha: 0.2), height: 1),
      ],
    );

    final MarkdownGenerator generator = MarkdownGenerator(
      linesMargin: const EdgeInsets.symmetric(vertical: 4),
      richTextBuilder: (span) {
        final TextSpan textSpan = span is TextSpan
            ? span
            : TextSpan(children: <InlineSpan>[span]);
        return SelectableText.rich(textSpan, textAlign: TextAlign.left);
      },
    );

    final List<Widget> builtWidgets = generator.buildWidgets(
      widget.text,
      config: config,
    );

    _cachedContent = builtWidgets.isEmpty
        ? <Widget>[
            SelectableText(
              widget.text,
              style:
                  (theme.textTheme.bodyMedium?.copyWith(
                    color: widget.textColor,
                    height: 1.45,
                    fontSize: 14,
                  )) ??
                  TextStyle(
                    color: widget.textColor,
                    height: 1.45,
                    fontSize: 14,
                  ),
            ),
          ]
        : builtWidgets;

    _lastText = widget.text;
    _lastTextColor = widget.textColor;
    _lastBackgroundColor = widget.backgroundColor;
    _lastBrightness = theme.brightness;
  }

  Widget _buildCodeBlock({
    required String code,
    required String language,
    required TextStyle textStyle,
    required Color backgroundColor,
    required Color borderColor,
    required Map<String, TextStyle> theme,
  }) {
    final List<InlineSpan> spans = _highlightSafely(
      code.replaceAll('\r\n', '\n'),
      language,
      theme,
      textStyle,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      padding: const EdgeInsets.all(12),
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText.rich(TextSpan(children: spans), style: textStyle),
      ),
    );
  }

  List<InlineSpan> _highlightSafely(
    String code,
    String language,
    Map<String, TextStyle> theme,
    TextStyle baseStyle,
  ) {
    final String normalizedLanguage = language.trim();
    final bool autoDetect = normalizedLanguage.isEmpty;

    try {
      final hi.Result result = hi.highlight.parse(
        code,
        language: autoDetect ? null : normalizedLanguage,
        autoDetection: autoDetect,
      );
      final List<hi.Node>? nodes = result.nodes;
      if (nodes == null || nodes.isEmpty) {
        return <InlineSpan>[TextSpan(text: code, style: baseStyle)];
      }
      return _convertNodesSafely(nodes, theme, baseStyle);
    } catch (error, stackTrace) {
      debugPrint(
        'Code highlight failed for language "$normalizedLanguage": $error',
      );
      debugPrint('$stackTrace');
      return <InlineSpan>[TextSpan(text: code, style: baseStyle)];
    }
  }

  List<TextSpan> _convertNodesSafely(
    List<hi.Node> nodes,
    Map<String, TextStyle> theme,
    TextStyle baseStyle,
  ) {
    final List<TextSpan> spans = <TextSpan>[];
    for (final hi.Node node in nodes) {
      spans.addAll(_collectSpans(node, theme, baseStyle, null));
    }
    return spans;
  }

  List<TextSpan> _collectSpans(
    hi.Node node,
    Map<String, TextStyle> theme,
    TextStyle baseStyle,
    TextStyle? parentThemeStyle,
  ) {
    final String className = node.className ?? '';
    final TextStyle? themeStyle = className.isNotEmpty
        ? theme[className]
        : parentThemeStyle;
    final TextStyle effectiveStyle = (themeStyle != null
        ? themeStyle.merge(baseStyle)
        : baseStyle);

    if (node.value != null) {
      return <TextSpan>[TextSpan(text: node.value, style: effectiveStyle)];
    }

    final List<hi.Node>? children = node.children;
    if (children == null || children.isEmpty) {
      return <TextSpan>[];
    }

    final List<TextSpan> childSpans = <TextSpan>[];
    for (final hi.Node child in children) {
      childSpans.addAll(
        _collectSpans(child, theme, baseStyle, themeStyle ?? parentThemeStyle),
      );
    }
    return <TextSpan>[TextSpan(children: childSpans, style: effectiveStyle)];
  }

  Color _codeBackground() {
    final HSLColor hsl = HSLColor.fromColor(widget.backgroundColor);
    final double luminance = widget.backgroundColor.computeLuminance();
    if (luminance > 0.6) {
      return hsl
          .withLightness((hsl.lightness - 0.1).clamp(0.0, 1.0))
          .toColor()
          .withValues(alpha: 0.6);
    }
    return hsl
        .withLightness((hsl.lightness + 0.2).clamp(0.0, 1.0))
        .toColor()
        .withValues(alpha: 0.6);
  }

  Map<String, TextStyle> _getSyntaxTheme(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
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
