// lib/widgets/markdown_message.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' as hi;
import 'package:chuk_chat/utils/highlight_registry.dart' as highlight_registry;
import 'package:markdown_widget/markdown_widget.dart';
import 'package:url_launcher/url_launcher.dart';

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
  Brightness? _lastBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ThemeData theme = Theme.of(context);
    final Brightness currentBrightness = theme.brightness;
    if (_lastBrightness != currentBrightness) {
      _rebuildCache();
    }
  }

  @override
  void didUpdateWidget(covariant MarkdownMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        widget.textColor != oldWidget.textColor ||
        widget.backgroundColor != oldWidget.backgroundColor) {
      _rebuildCache();
    }
  }

  Future<void> _onTapLink(String href) async {
    final bool? shouldOpen = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open Link'),
        content: Text('Do you really want to leave the app and open $href?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open'),
          ),
        ],
      ),
    );

    if (shouldOpen == true) {
      final Uri uri = Uri.parse(href);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedContent == null) {
      _rebuildCache();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _cachedContent!,
    );
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
    final Color accentColor = theme.colorScheme.primary;

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
          style: codeTextStyle.copyWith(backgroundColor: codeBackground),
        ),
        PreConfig(
          padding: EdgeInsets.zero,
          margin: EdgeInsets.zero,
          textStyle: codeTextStyle,
          styleNotMatched: codeTextStyle,
          theme: syntaxTheme,
          builder: (code, language) => _AsyncCodeBlock(
            code: code,
            language: language,
            textStyle: codeTextStyle,
            backgroundColor: codeBackground,
            borderColor: codeBorderColor,
            theme: syntaxTheme,
            textColor: widget.textColor,
          ),
        ),
        LinkConfig(
          style:
              (theme.textTheme.bodyMedium?.copyWith(
                color: accentColor,
                decoration: TextDecoration.underline,
              )) ??
              TextStyle(
                color: accentColor,
                decoration: TextDecoration.underline,
              ),
          onTap: (url) {
            _onTapLink(url);
          },
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
              TextStyle(color: widget.textColor, fontWeight: FontWeight.w600),
          bodyStyle:
              (theme.textTheme.bodyMedium?.copyWith(color: widget.textColor)) ??
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
        return Text.rich(textSpan, textAlign: TextAlign.left);
      },
    );

    List<Widget> builtWidgets;
    try {
      builtWidgets = generator.buildWidgets(widget.text, config: config);
    } catch (error, stackTrace) {
      debugPrint('Markdown parsing error: $error');
      debugPrint('Stack trace: $stackTrace');
      builtWidgets = <Widget>[
        Text(
          widget.text,
          style:
              (theme.textTheme.bodyMedium?.copyWith(
                color: widget.textColor,
                height: 1.45,
                fontSize: 14,
              )) ??
              TextStyle(color: widget.textColor, height: 1.45, fontSize: 14),
        ),
      ];
    }

    _cachedContent = builtWidgets.isEmpty
        ? <Widget>[
            Text(
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

    _lastBrightness = theme.brightness;
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

/// Widget that handles async code highlighting to prevent UI jank
class _AsyncCodeBlock extends StatefulWidget {
  final String code;
  final String? language;
  final TextStyle textStyle;
  final Color backgroundColor;
  final Color borderColor;
  final Map<String, TextStyle> theme;
  final Color textColor;

  const _AsyncCodeBlock({
    required this.code,
    this.language,
    required this.textStyle,
    required this.backgroundColor,
    required this.borderColor,
    required this.theme,
    required this.textColor,
  });

  @override
  State<_AsyncCodeBlock> createState() => _AsyncCodeBlockState();
}

class _AsyncCodeBlockState extends State<_AsyncCodeBlock> {
  List<InlineSpan>? _highlightedSpans;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHighlight();
  }

  @override
  void didUpdateWidget(covariant _AsyncCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.code != oldWidget.code ||
        widget.language != oldWidget.language ||
        widget.theme != oldWidget.theme) {
      _scheduleHighlight();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _scheduleHighlight() {
    _debounceTimer?.cancel();
    // Use a short delay to debounce rapid updates (e.g. streaming)
    // This prevents spawning too many isolates for every single character
    _debounceTimer = Timer(const Duration(milliseconds: 150), () {
      _highlightCode();
    });
  }

  Future<void> _highlightCode() async {
    if (!mounted) return;

    final String code = widget.code;
    final String? language = widget.language;

    // Skip highlighting for empty code
    if (code.trim().isEmpty) {
      setState(() {
        _highlightedSpans = [TextSpan(text: code, style: widget.textStyle)];
      });
      return;
    }

    // Skip highlighting for text that's mostly non-ASCII (CJK, Arabic, etc.)
    // These cause errors in the highlight package and aren't code anyway
    if (_isMostlyNonAscii(code)) {
      setState(() {
        _highlightedSpans = [TextSpan(text: code, style: widget.textStyle)];
      });
      return;
    }

    // Normalize and validate language
    final String normalizedLanguage = (language ?? '').trim().toLowerCase();
    final bool shouldAutoDetect = normalizedLanguage.isEmpty;

    // Pass only necessary data to the isolate
    try {
      // Run heavy parsing in an isolate
      final List<hi.Node> nodes = await compute(_parseCode, {
        'code': code,
        'language': normalizedLanguage,
        'autoDetect': shouldAutoDetect,
      }).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('Highlight timeout for language: ${normalizedLanguage.isEmpty ? '(auto-detect)' : normalizedLanguage}');
          return <hi.Node>[];
        },
      );

      if (!mounted) return;

      // Convert nodes to TextSpans on the main thread (fast)
      final List<InlineSpan> spans = _convertNodesSafely(
        nodes,
        widget.theme,
        widget.textStyle,
      );

      if (mounted) {
        setState(() {
          _highlightedSpans = spans.isEmpty
              ? [TextSpan(text: code, style: widget.textStyle)]
              : spans;
        });
      }
    } catch (e, stackTrace) {
      final String langDesc = normalizedLanguage.isEmpty ? '(auto-detect)' : normalizedLanguage;
      debugPrint('Highlight error for language "$langDesc": $e');
      if (e is! TimeoutException) {
        debugPrint('Stack trace: $stackTrace');
      }
      // Fallback to plain text
      if (mounted) {
        setState(() {
          _highlightedSpans = [TextSpan(text: code, style: widget.textStyle)];
        });
      }
    }
  }

  /// Check if text is mostly non-ASCII characters (CJK, Arabic, Cyrillic, etc.)
  /// These cause parsing errors in the highlight package and are unlikely to be code
  bool _isMostlyNonAscii(String text) {
    if (text.isEmpty) return false;

    int nonAsciiCount = 0;
    int totalChars = 0;

    for (final int codeUnit in text.runes) {
      // Skip whitespace and common punctuation
      if (codeUnit <= 32 || (codeUnit >= 33 && codeUnit <= 47) ||
          (codeUnit >= 58 && codeUnit <= 64) || (codeUnit >= 91 && codeUnit <= 96) ||
          (codeUnit >= 123 && codeUnit <= 126)) {
        continue;
      }
      totalChars++;
      // Non-ASCII is anything above 127
      if (codeUnit > 127) {
        nonAsciiCount++;
      }
    }

    // If more than 50% of meaningful characters are non-ASCII, skip highlighting
    return totalChars > 0 && (nonAsciiCount / totalChars) > 0.5;
  }

  @override
  Widget build(BuildContext context) {
    final List<InlineSpan> content =
        _highlightedSpans ??
        [TextSpan(text: widget.code, style: widget.textStyle)];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with language and copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: widget.textColor.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(7),
                topRight: Radius.circular(7),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  (widget.language?.isEmpty ?? true) ? 'code' : widget.language!,
                  style: TextStyle(
                    color: widget.textColor.withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _CopyButton(code: widget.code, textColor: widget.textColor),
              ],
            ),
          ),
          // Code content
          Padding(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text.rich(
                TextSpan(children: content),
                style: widget.textStyle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

  // Top-level function for compute
List<hi.Node> _parseCode(Map<String, dynamic> args) {
  try {
    final String code = args['code'] as String? ?? '';
    final String? language = args['language'] as String?;
    final bool autoDetect = args['autoDetect'] as bool? ?? false;

    if (code.isEmpty) {
      return [];
    }

    // Skip highlighting for text that's mostly non-ASCII (CJK, Arabic, etc.)
    // These cause errors in the highlight package and aren't code anyway
    if (_isMostlyNonAsciiCode(code)) {
      return [];
    }

    // Register all languages to ensure syntax highlighting works for any language
    // inside the isolate.
    try {
      hi.highlight.registerLanguages(highlight_registry.allLanguages);
    } catch (e) {
      // Language registration failed, return empty to fall back to plain text
      // Silently fail - this is expected in some environments
      return [];
    }

    // Replace Windows line endings for consistency
    final String normalizedCode = code.replaceAll('\r\n', '\n');

    // Safely validate and normalize language
    String? validatedLanguage;
    if (language != null && language.isNotEmpty) {
      final String langLower = language.toLowerCase();
      if (highlight_registry.allLanguages.containsKey(langLower)) {
        validatedLanguage = langLower;
      }
      // Silently fall back to auto-detection for unknown languages
    }

    try {
      final hi.Result result = hi.highlight.parse(
        normalizedCode,
        language: autoDetect || validatedLanguage == null ? null : validatedLanguage,
        autoDetection: autoDetect || validatedLanguage == null,
      );
      return result.nodes ?? [];
    } on FormatException catch (_) {
      // FormatException can occur when the highlighter encounters unexpected syntax
      // Fall back to plain text rendering
      return [];
    } catch (e) {
      // If the highlighter fails (e.g. parsing error, null check operator used on null),
      // return an empty list which will be handled gracefully by the UI
      // falling back to plain text.
      return [];
    }
  } on FormatException catch (_) {
    // Handle FormatException at the top level too
    return [];
  } catch (e) {
    // Catch any unexpected errors in the isolate, including null check errors
    // Silently return empty to fall back to plain text
    return [];
  }
}

/// Top-level helper for checking if text is mostly non-ASCII (for isolate use)
bool _isMostlyNonAsciiCode(String text) {
  if (text.isEmpty) return false;

  int nonAsciiCount = 0;
  int totalChars = 0;

  for (final int codeUnit in text.runes) {
    // Skip whitespace and common punctuation
    if (codeUnit <= 32 || (codeUnit >= 33 && codeUnit <= 47) ||
        (codeUnit >= 58 && codeUnit <= 64) || (codeUnit >= 91 && codeUnit <= 96) ||
        (codeUnit >= 123 && codeUnit <= 126)) {
      continue;
    }
    totalChars++;
    // Non-ASCII is anything above 127
    if (codeUnit > 127) {
      nonAsciiCount++;
    }
  }

  // If more than 50% of meaningful characters are non-ASCII, skip highlighting
  return totalChars > 0 && (nonAsciiCount / totalChars) > 0.5;
}

// Helper to convert nodes to spans (Main thread)
List<TextSpan> _convertNodesSafely(
  List<hi.Node>? nodes,
  Map<String, TextStyle> theme,
  TextStyle baseStyle,
) {
  if (nodes == null || nodes.isEmpty) {
    return <TextSpan>[];
  }

  final List<TextSpan> spans = <TextSpan>[];
  try {
    for (final hi.Node node in nodes) {
      try {
        spans.addAll(_collectSpans(node, theme, baseStyle, null));
      } catch (e) {
        debugPrint('Error converting node: $e');
        // Skip problematic nodes
        continue;
      }
    }
  } catch (e) {
    debugPrint('Error in _convertNodesSafely: $e');
    return <TextSpan>[];
  }
  return spans;
}

List<TextSpan> _collectSpans(
  hi.Node? node,
  Map<String, TextStyle> theme,
  TextStyle baseStyle,
  TextStyle? parentThemeStyle,
) {
  if (node == null) {
    return <TextSpan>[];
  }

  try {
    final String className = node.className ?? '';
    final TextStyle? themeStyle = className.isNotEmpty
        ? theme[className]
        : parentThemeStyle;
    final TextStyle effectiveStyle = (themeStyle != null
        ? themeStyle.merge(baseStyle)
        : baseStyle);

    if (node.value != null && node.value!.isNotEmpty) {
      return <TextSpan>[TextSpan(text: node.value, style: effectiveStyle)];
    }

    final List<hi.Node>? children = node.children;
    if (children == null || children.isEmpty) {
      return <TextSpan>[];
    }

    final List<TextSpan> childSpans = <TextSpan>[];
    for (final hi.Node child in children) {
      try {
        childSpans.addAll(
          _collectSpans(child, theme, baseStyle, themeStyle ?? parentThemeStyle),
        );
      } catch (e) {
        debugPrint('Error collecting child spans: $e');
        // Skip problematic child nodes
        continue;
      }
    }

    if (childSpans.isEmpty) {
      return <TextSpan>[];
    }

    return <TextSpan>[TextSpan(children: childSpans, style: effectiveStyle)];
  } catch (error) {
    debugPrint('Error in _collectSpans: $error');
    // Return a safe fallback span
    final String fallbackText = node.value ?? '';
    return fallbackText.isNotEmpty
        ? <TextSpan>[TextSpan(text: fallbackText, style: baseStyle)]
        : <TextSpan>[];
  }
}

/// Copy button widget for code blocks
class _CopyButton extends StatefulWidget {
  final String code;
  final Color textColor;

  const _CopyButton({required this.code, required this.textColor});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    setState(() {
      _copied = true;
    });

    // Reset after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _copied = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _copyToClipboard,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: widget.textColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? Icons.check : Icons.content_copy,
              size: 14,
              color: widget.textColor.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? 'Copied!' : 'Copy',
              style: TextStyle(
                color: widget.textColor.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
