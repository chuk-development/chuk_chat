// lib/widgets/terminal_block.dart
//
// A shell result as a terminal: the command, then its output in monospace,
// never wrapped (a long line scrolls sideways, so columns stay in place).
// Over 16 lines the middle folds: the first 8 and the last 8 stay, and a
// row "N lines hidden" opens the rest. ANSI colours (SGR) are drawn; every
// other escape is removed. An exit code shows only when it is not 0.
//
// Harness reference: `ui-primitives/TerminalBlock`, `ui-tool/ExitCodeBadge`.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/utils/ansi_sgr.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Lines kept at the head and at the tail of a folded output.
const int kTerminalHeadLines = 8;
const int kTerminalTailLines = 8;

/// What a shell call produced, read from its arguments and result.
class ShellResult {
  const ShellResult({this.command, required this.output, this.exitCode});

  final String? command;
  final String output;

  /// Null when the result did not say.
  final int? exitCode;
}

final RegExp _exitMarker = RegExp(
  r'\[exit(?: code)?:?\s*(-?\d+)\]|exit code[: ]\s*(-?\d+)',
  caseSensitive: false,
);

/// Read a shell call: the command from its arguments, the output and exit
/// code from its result. Handles the JSON form (`output`, `error`,
/// `stdout`, `stderr`, `exit_code`), the `--- stdout --- / --- stderr ---`
/// form, `[exit code: N]` markers, and plain text. Null without a result.
ShellResult? shellResultOf(ToolCall call) {
  final String? result = call.result;
  if (result == null || result.trim().isEmpty) return null;
  final Object? rawCommand = call.arguments['command'] ?? call.arguments['cmd'];
  final String? command = rawCommand is String && rawCommand.trim().isNotEmpty
      ? rawCommand.trim()
      : null;
  int? exitCode = _intOf(call.arguments['exit_code']);

  String output = result;
  final String trimmed = result.trim();
  if (trimmed.startsWith('{')) {
    try {
      final Object? decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        exitCode ??= _intOf(decoded['exit_code'] ?? decoded['exitCode']);
        final List<String> parts = <String>[
          for (final String key in const <String>['stdout', 'output'])
            if (decoded[key] is String && (decoded[key] as String).isNotEmpty)
              decoded[key] as String,
          for (final String key in const <String>['stderr', 'error'])
            if (decoded[key] is String && (decoded[key] as String).isNotEmpty)
              decoded[key] as String,
        ];
        if (parts.isNotEmpty) output = parts.join('\n');
      }
    } catch (_) {}
  } else {
    final RegExp stdoutMarker = RegExp(r'^--- stdout ---\s*$', multiLine: true);
    final RegExp stderrMarker = RegExp(r'^--- stderr ---\s*$', multiLine: true);
    final RegExpMatch? out = stdoutMarker.firstMatch(result);
    if (out != null) {
      final RegExpMatch? err = stderrMarker.firstMatch(result);
      final String stdout = result
          .substring(out.end, err?.start ?? result.length)
          .trim();
      final String stderr = err == null ? '' : result.substring(err.end).trim();
      output = <String>[
        if (stdout.isNotEmpty) stdout,
        if (stderr.isNotEmpty) stderr,
      ].join('\n');
    }
  }
  if (exitCode == null) {
    final RegExpMatch? marker = _exitMarker.firstMatch(result);
    if (marker != null) {
      exitCode = int.tryParse(marker.group(1) ?? marker.group(2) ?? '');
    }
  }
  return ShellResult(
    command: command,
    output: output.trimRight(),
    exitCode: exitCode,
  );
}

int? _intOf(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

class TerminalBlock extends StatefulWidget {
  const TerminalBlock({
    super.key,
    required this.output,
    this.command,
    this.exitCode,
  });

  final String output;
  final String? command;
  final int? exitCode;

  @override
  State<TerminalBlock> createState() => _TerminalBlockState();
}

class _TerminalBlockState extends State<TerminalBlock> {
  bool _expanded = false;
  late List<List<AnsiSpan>> _lines = parseAnsi(widget.output);

  @override
  void didUpdateWidget(TerminalBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.output != widget.output) _lines = parseAnsi(widget.output);
  }

  String _t(String key, String english) {
    final String? text = AppLocalizations.of(context)?.toolActivityText(key);
    return text == null || text.startsWith('toolActivity_') ? english : text;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final Color fg = scheme.onSurface.withValues(alpha: 0.88);
    final Color muted = scheme.onSurface.withValues(alpha: 0.55);
    final TextStyle mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.4,
      color: fg,
    );

    final List<List<AnsiSpan>> lines =
        _lines.length == 1 && _lines.first.isEmpty ? const [] : _lines;
    final int total = lines.length;
    final bool foldable = total > kTerminalHeadLines + kTerminalTailLines;
    final bool folded = foldable && !_expanded;
    final int hidden = total - kTerminalHeadLines - kTerminalTailLines;

    Widget lineOf(List<AnsiSpan> spans) => Text.rich(
      TextSpan(
        children: <InlineSpan>[
          if (spans.isEmpty) const TextSpan(text: ' '),
          for (final AnsiSpan span in spans)
            TextSpan(
              text: span.text,
              style: _styleOf(span, mono, scheme, dark),
            ),
        ],
      ),
      style: mono,
      softWrap: false,
      maxLines: 1,
    );

    final List<Widget> outputRows = <Widget>[
      if (total == 0)
        Text(_t('noOutput', '(no output)'), style: mono.copyWith(color: muted))
      else if (!folded)
        for (final List<AnsiSpan> line in lines) lineOf(line)
      else ...<Widget>[
        for (final List<AnsiSpan> line in lines.take(kTerminalHeadLines))
          lineOf(line),
        const SizedBox(height: 2),
        _foldRow(
          _t('linesHidden', '{n} lines hidden').replaceAll('{n}', '$hidden'),
          muted,
          open: false,
        ),
        const SizedBox(height: 2),
        for (final List<AnsiSpan> line in lines.skip(
          total - kTerminalTailLines,
        ))
          lineOf(line),
      ],
    ];

    return Container(
      key: const ValueKey<String>('terminal-block'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.command != null || _failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: <Widget>[
                    if (widget.command != null)
                      Expanded(
                        child: Text(
                          '\$ ${widget.command}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono.copyWith(
                            color: muted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    if (_failed) ...<Widget>[
                      const SizedBox(width: 8),
                      _ExitCapsule(
                        label: _t(
                          'exitCode',
                          'exit {n}',
                        ).replaceAll('{n}', '${widget.exitCode}'),
                      ),
                    ],
                  ],
                ),
              ),
            // No wrap: columns stay where the program put them, and a long
            // line scrolls sideways inside the block, never the page.
            SingleChildScrollView(
              key: const ValueKey<String>('terminal-hscroll'),
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: outputRows,
              ),
            ),
            if (foldable && _expanded)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _foldRow(_t('showLess', 'Show less'), muted, open: true),
              ),
          ],
        ),
      ),
    );
  }

  bool get _failed => widget.exitCode != null && widget.exitCode != 0;

  Widget _foldRow(String label, Color color, {required bool open}) {
    return InkWell(
      key: ValueKey<String>(open ? 'terminal-collapse' : 'terminal-expand'),
      onTap: () => setState(() => _expanded = !open),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppIcon(
              open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static TextStyle? _styleOf(
    AnsiSpan span,
    TextStyle base,
    ColorScheme scheme,
    bool dark,
  ) {
    if (span.plain) return null;
    return TextStyle(
      color: span.foreground == null
          ? null
          : _colorOf(span.foreground!, scheme, dark),
      backgroundColor: span.background == null
          ? null
          : _colorOf(span.background!, scheme, dark).withValues(alpha: 0.3),
      fontWeight: span.bold ? FontWeight.w700 : null,
      fontStyle: span.italic ? FontStyle.italic : null,
      decoration: span.underline ? TextDecoration.underline : null,
    ).merge(
      span.dim
          ? TextStyle(
              color: (base.color ?? scheme.onSurface).withValues(alpha: 0.6),
            )
          : null,
    );
  }

  /// The 16 named colours on the app theme: black and white take the text
  /// colour, so output stays readable on both themes.
  static Color _colorOf(AnsiColor color, ColorScheme scheme, bool dark) {
    final Color? rgb = color.rgb;
    if (rgb != null) return rgb;
    switch (color.index!) {
      case 0:
      case 7:
      case 15:
        return scheme.onSurface;
      case 8:
        return scheme.onSurface.withValues(alpha: 0.55);
      case 1:
      case 9:
        return scheme.error;
      case 2:
      case 10:
        return dark ? const Color(0xFF7EE787) : const Color(0xFF1A7F37);
      case 3:
      case 11:
        return dark ? const Color(0xFFD29922) : const Color(0xFF9A6700);
      case 4:
      case 12:
        return dark ? const Color(0xFF58A6FF) : const Color(0xFF0969DA);
      case 5:
      case 13:
        return dark ? const Color(0xFFBC8CFF) : const Color(0xFF8250DF);
      default:
        return dark ? const Color(0xFF39C5CF) : const Color(0xFF1B7C83);
    }
  }
}

/// A neutral capsule with a red dot: "● exit 2". Only for a failed command.
class _ExitCapsule extends StatelessWidget {
  const _ExitCapsule({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('terminal-exit-code'),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: scheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(alpha: 0.75),
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
