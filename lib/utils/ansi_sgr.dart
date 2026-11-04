// lib/utils/ansi_sgr.dart
//
// Terminal output to styled runs. Only SGR (`ESC [ … m`: colour, bold, dim,
// italic, underline) is kept; every other escape (cursor moves, clears, OSC
// titles and links, charset selection) is removed, so it never reaches the
// screen as literal characters. Blink is dropped on purpose.

import 'package:flutter/painting.dart';

/// One run of text with one style. [text] holds no newline.
class AnsiSpan {
  const AnsiSpan(
    this.text, {
    this.foreground,
    this.background,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
  });

  final String text;
  final AnsiColor? foreground;
  final AnsiColor? background;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;

  bool get plain =>
      foreground == null &&
      background == null &&
      !bold &&
      !dim &&
      !italic &&
      !underline;
}

/// A terminal colour: one of the 16 named ones (index 0-15), or a direct
/// RGB value from the 256 palette or a truecolor code.
class AnsiColor {
  const AnsiColor.named(int this.index) : rgb = null;
  const AnsiColor.rgb(Color this.rgb) : index = null;

  final int? index;
  final Color? rgb;

  @override
  bool operator ==(Object other) =>
      other is AnsiColor && other.index == index && other.rgb == rgb;

  @override
  int get hashCode => Object.hash(index, rgb);
}

final RegExp _osc = RegExp('\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)?');
final RegExp _csi = RegExp('\x1b\\[([0-9;:?<=>!]*)([ -/]*)([@-~])');
final RegExp _otherEsc = RegExp('\x1b(?:[()*+][0-9A-Za-z]|[ -/]*[0-~])?');
final RegExp _controls = RegExp('[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f\x7f]');

/// Remove every escape sequence that is not SGR, and stray control
/// characters. Keeps `\n` and `\t`. A `\r` inside a line keeps what the
/// terminal would show: the text after the last carriage return.
String stripNonSgr(String input) {
  String text = input.replaceAll(_osc, '');
  text = text.replaceAllMapped(
    _csi,
    (m) => m.group(3) == 'm' ? m.group(0)! : '',
  );
  // Mark the kept SGR codes so the generic ESC rule below cannot eat them.
  text = text.replaceAllMapped(_csi, (m) => '\u0000SGR${m.group(1)}\u0000');
  text = text.replaceAll(_otherEsc, '');
  text = text.replaceAllMapped(
    RegExp('\u0000SGR([0-9;:]*)\u0000'),
    (m) => '\x1b[${m.group(1)}m',
  );
  final List<String> lines = text.split('\n');
  for (int i = 0; i < lines.length; i++) {
    String line = lines[i];
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    final int cr = line.lastIndexOf('\r');
    if (cr >= 0) line = line.substring(cr + 1);
    lines[i] = line.replaceAll(_controls, '');
  }
  return lines.join('\n');
}

/// Parse [input] into lines of styled runs.
List<List<AnsiSpan>> parseAnsi(String input) {
  final String text = stripNonSgr(input);
  final List<List<AnsiSpan>> lines = <List<AnsiSpan>>[<AnsiSpan>[]];
  final _State state = _State();
  final RegExp sgr = RegExp('\x1b\\[([0-9;:]*)m');
  int pos = 0;

  void emit(String chunk) {
    final List<String> parts = chunk.split('\n');
    for (int i = 0; i < parts.length; i++) {
      if (i > 0) lines.add(<AnsiSpan>[]);
      if (parts[i].isNotEmpty) lines.last.add(state.span(parts[i]));
    }
  }

  for (final RegExpMatch m in sgr.allMatches(text)) {
    if (m.start > pos) emit(text.substring(pos, m.start));
    state.apply(m.group(1)!);
    pos = m.end;
  }
  if (pos < text.length) emit(text.substring(pos));
  return lines;
}

class _State {
  AnsiColor? fg;
  AnsiColor? bg;
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;

  AnsiSpan span(String text) => AnsiSpan(
    text,
    foreground: fg,
    background: bg,
    bold: bold,
    dim: dim,
    italic: italic,
    underline: underline,
  );

  void apply(String params) {
    final List<int> codes = params.isEmpty
        ? <int>[0]
        : params
              .split(RegExp('[;:]'))
              .map((p) => int.tryParse(p) ?? 0)
              .toList();
    for (int i = 0; i < codes.length; i++) {
      final int c = codes[i];
      if (c == 0) {
        fg = null;
        bg = null;
        bold = dim = italic = underline = false;
      } else if (c == 1) {
        bold = true;
      } else if (c == 2) {
        dim = true;
      } else if (c == 3) {
        italic = true;
      } else if (c == 4) {
        underline = true;
      } else if (c == 22) {
        bold = dim = false;
      } else if (c == 23) {
        italic = false;
      } else if (c == 24) {
        underline = false;
      } else if (c >= 30 && c <= 37) {
        fg = AnsiColor.named(c - 30);
      } else if (c >= 90 && c <= 97) {
        fg = AnsiColor.named(c - 90 + 8);
      } else if (c == 39) {
        fg = null;
      } else if (c >= 40 && c <= 47) {
        bg = AnsiColor.named(c - 40);
      } else if (c >= 100 && c <= 107) {
        bg = AnsiColor.named(c - 100 + 8);
      } else if (c == 49) {
        bg = null;
      } else if (c == 38 || c == 48) {
        AnsiColor? color;
        if (i + 2 < codes.length && codes[i + 1] == 5) {
          color = _palette256(codes[i + 2]);
          i += 2;
        } else if (i + 4 < codes.length && codes[i + 1] == 2) {
          color = AnsiColor.rgb(
            Color.fromARGB(
              255,
              codes[i + 2].clamp(0, 255),
              codes[i + 3].clamp(0, 255),
              codes[i + 4].clamp(0, 255),
            ),
          );
          i += 4;
        }
        if (c == 38) {
          fg = color;
        } else {
          bg = color;
        }
      }
    }
  }
}

AnsiColor _palette256(int n) {
  if (n < 16) return AnsiColor.named(n);
  if (n >= 232) {
    final int v = 8 + (n - 232) * 10;
    return AnsiColor.rgb(Color.fromARGB(255, v, v, v));
  }
  final int i = n - 16;
  int level(int x) => x == 0 ? 0 : 55 + x * 40;
  return AnsiColor.rgb(
    Color.fromARGB(255, level(i ~/ 36), level((i ~/ 6) % 6), level(i % 6)),
  );
}
