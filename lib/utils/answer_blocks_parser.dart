// lib/utils/answer_blocks_parser.dart
//
// The parse half of the static answer blocks: `::: steps`, `::: timeline`,
// `::: scale` and the GitHub alerts (`> [!NOTE]`). Pure Dart, no Flutter, so
// every rule here is unit-tested without a widget tree. The widgets live in
// `lib/widgets/answer_blocks.dart`; `MarkdownMessage` calls
// [splitAnswerBlocks] before it splits out tables, so the blocks ride the same
// segment pipeline as the native tables.
//
// Rules (from docs/answer_formats/index.html, "Die Syntax"):
// - `::: name arg` opens a block, a line `:::` closes it. A new `::: name`
//   line also closes the open block. A block that is still streaming (no
//   close yet) renders with the lines that are already there.
// - Blocks do not nest. A `:::` line inside a fenced code block is code.
// - An unknown name falls back to plain Markdown: the marker lines go, the
//   argument and the body stay as text.

/// The block kinds the renderer draws natively.
enum AnswerBlockKind { steps, timeline, scale, alert }

/// One slice of a message: Markdown text or a parsed block.
sealed class AnswerSegment {
  const AnswerSegment();
}

/// Markdown between the blocks, verbatim.
class AnswerTextSegment extends AnswerSegment {
  const AnswerTextSegment(this.text);
  final String text;
}

/// A block with its raw body lines.
class AnswerBlockSegment extends AnswerSegment {
  const AnswerBlockSegment({
    required this.kind,
    required this.arg,
    required this.lines,
    required this.closed,
  });

  final AnswerBlockKind kind;

  /// Everything after the block name on the opening line. For an alert, the
  /// alert type in upper case (`NOTE`, `WARNING`, ...).
  final String arg;

  /// The body lines, without the marker lines.
  final List<String> lines;

  /// False while the block is still streaming.
  final bool closed;
}

const Map<String, AnswerBlockKind> _kBlockNames = <String, AnswerBlockKind>{
  'steps': AnswerBlockKind.steps,
  'timeline': AnswerBlockKind.timeline,
  'scale': AnswerBlockKind.scale,
};

final RegExp _openRe = RegExp(r'^ {0,3}:::\s*([A-Za-z][\w-]*)[ \t]*(.*)$');
final RegExp _closeRe = RegExp(r'^ {0,3}:::\s*$');

/// A closing marker that is still being typed (`:` or `::`).
final RegExp _partialCloseRe = RegExp(r'^ {0,3}:{1,2}\s*$');

final RegExp _alertRe = RegExp(
  r'^ {0,3}>[ \t]?\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*(.*)$',
  caseSensitive: false,
);

bool _isFence(String line) {
  final String t = line.trimLeft();
  return t.startsWith('```') || t.startsWith('~~~');
}

/// Splits [text] into Markdown and block segments.
///
/// Never throws. A text with no block keeps its exact characters.
List<AnswerSegment> splitAnswerBlocks(String text) {
  if (!text.contains(':::') && !text.contains('[!')) {
    return <AnswerSegment>[AnswerTextSegment(text)];
  }

  final List<String> lines = text.split('\n');
  final List<AnswerSegment> out = <AnswerSegment>[];
  final StringBuffer buf = StringBuffer();
  bool inFence = false;
  bool sawBlock = false;

  void flush() {
    if (buf.isEmpty) return;
    out.add(AnswerTextSegment(buf.toString()));
    buf.clear();
  }

  int i = 0;
  while (i < lines.length) {
    final String line = lines[i];
    if (_isFence(line)) {
      inFence = !inFence;
      buf.writeln(line);
      i++;
      continue;
    }
    if (inFence) {
      buf.writeln(line);
      i++;
      continue;
    }

    final RegExpMatch? open = _openRe.firstMatch(line);
    if (open != null) {
      sawBlock = true;
      // The opening line has no newline yet: its name may still be growing
      // (`::: ste`). Show nothing for it until the line is complete.
      if (i == lines.length - 1) {
        i++;
        continue;
      }
      final String name = open.group(1)!.toLowerCase();
      final String arg = open.group(2)!.trim();
      final List<String> body = <String>[];
      bool closed = false;
      bool bodyFence = false;
      int j = i + 1;
      while (j < lines.length) {
        final String l = lines[j];
        if (_isFence(l)) {
          bodyFence = !bodyFence;
          body.add(l);
          j++;
          continue;
        }
        if (!bodyFence) {
          if (_closeRe.hasMatch(l)) {
            closed = true;
            j++;
            break;
          }
          if (_openRe.hasMatch(l)) {
            // The next block closes this one.
            closed = true;
            break;
          }
        }
        body.add(l);
        j++;
      }
      if (!closed && body.isNotEmpty && _partialCloseRe.hasMatch(body.last)) {
        body.removeLast();
      }

      final AnswerBlockKind? kind = _kBlockNames[name];
      if (kind == null) {
        // Unknown block: plain Markdown, without the marker lines.
        if (arg.isNotEmpty) {
          buf.writeln(arg);
          buf.writeln();
        }
        for (final String l in body) {
          buf.writeln(l);
        }
        buf.writeln();
      } else {
        flush();
        out.add(
          AnswerBlockSegment(
            kind: kind,
            arg: arg,
            lines: List<String>.unmodifiable(body),
            closed: closed,
          ),
        );
      }
      i = j;
      continue;
    }

    final RegExpMatch? alert = _alertRe.firstMatch(line);
    if (alert != null) {
      sawBlock = true;
      final List<String> body = <String>[
        if (alert.group(2)!.trim().isNotEmpty) alert.group(2)!.trim(),
      ];
      int j = i + 1;
      while (j < lines.length && lines[j].trimLeft().startsWith('>')) {
        String l = lines[j].trimLeft().substring(1);
        if (l.startsWith(' ')) l = l.substring(1);
        body.add(l);
        j++;
      }
      flush();
      out.add(
        AnswerBlockSegment(
          kind: AnswerBlockKind.alert,
          arg: alert.group(1)!.toUpperCase(),
          lines: List<String>.unmodifiable(body),
          closed: j < lines.length,
        ),
      );
      i = j;
      continue;
    }

    buf.writeln(line);
    i++;
  }
  flush();

  if (!sawBlock) return <AnswerSegment>[AnswerTextSegment(text)];
  return out;
}

// ---------------------------------------------------------------------------
// steps

enum StepPartKind { text, command, warning }

/// One piece of a step body. A [StepPartKind.command] part holds one or more
/// command lines joined by `\n`; consecutive text lines are joined too, so a
/// Markdown list inside a step stays one list.
class StepPart {
  const StepPart(this.kind, this.text);
  final StepPartKind kind;
  final String text;
}

class StepItem {
  const StepItem({
    required this.label,
    required this.title,
    required this.parts,
  });

  /// `1`, `2`, ... or `A`, `B`, ... for `::: steps abc`.
  final String label;
  final String title;
  final List<StepPart> parts;
}

class StepsSpec {
  const StepsSpec({required this.title, required this.steps});
  final String title;
  final List<StepItem> steps;
}

final RegExp _stepNumRe = RegExp(r'^\s{0,3}(\d{1,3})[.)]\s+(.*)$');
final RegExp _stepLetterRe = RegExp(r'^\s{0,3}([A-Za-z])[.)]\s+(.*)$');
final RegExp _lettersArgRe = RegExp(r'^abc\b\s*', caseSensitive: false);

String _letter(int index) =>
    index < 26 ? String.fromCharCode(65 + index) : '${index + 1}';

StepsSpec parseSteps(String arg, List<String> lines) {
  final bool letters = _lettersArgRe.hasMatch(arg);
  final String title = arg.replaceFirst(_lettersArgRe, '').trim();

  final List<String> labels = <String>[];
  final List<String> titles = <String>[];
  final List<List<StepPart>> parts = <List<StepPart>>[];

  void newStep(String label, String stepTitle) {
    labels.add(label);
    titles.add(stepTitle);
    parts.add(<StepPart>[]);
  }

  void addPart(StepPartKind kind, String text) {
    if (parts.isEmpty) newStep('', '');
    final List<StepPart> cur = parts.last;
    if (cur.isNotEmpty &&
        cur.last.kind == kind &&
        kind != StepPartKind.warning) {
      cur[cur.length - 1] = StepPart(kind, '${cur.last.text}\n$text');
    } else {
      cur.add(StepPart(kind, text));
    }
  }

  for (final String raw in lines) {
    if (raw.trim().isEmpty) continue;
    final RegExpMatch? m = letters
        ? (_stepLetterRe.firstMatch(raw) ?? _stepNumRe.firstMatch(raw))
        : _stepNumRe.firstMatch(raw);
    if (m != null) {
      newStep(letters ? '' : m.group(1)!, m.group(2)!.trim());
      continue;
    }
    final String line = raw.trimLeft();
    if (line.startsWith(r'$ ') || line == r'$') {
      addPart(StepPartKind.command, line.substring(1).trimLeft());
    } else if (line.startsWith('! ')) {
      addPart(StepPartKind.warning, line.substring(2).trim());
    } else {
      addPart(StepPartKind.text, raw);
    }
  }

  final List<StepItem> steps = <StepItem>[
    for (int k = 0; k < titles.length; k++)
      StepItem(
        label: letters
            ? _letter(k)
            : (labels[k].isEmpty ? '${k + 1}' : labels[k]),
        title: titles[k],
        parts: List<StepPart>.unmodifiable(parts[k]),
      ),
  ];
  return StepsSpec(title: title, steps: steps);
}

// ---------------------------------------------------------------------------
// timeline

class TimelineEntry {
  const TimelineEntry({
    required this.label,
    required this.text,
    required this.highlight,
  });

  /// The date or label before the first `: `. Empty when the line has none.
  final String label;
  final String text;

  /// The line started with `*`: the key entry.
  final bool highlight;
}

/// Splits at the first `: ` (colon and space), so `12:30: Lunch` keeps its
/// time. Returns `('', line)` when there is no separator.
(String, String) splitKeyValue(String line) {
  final int at = line.indexOf(': ');
  if (at < 0) return ('', line.trim());
  return (line.substring(0, at).trim(), line.substring(at + 2).trim());
}

List<TimelineEntry> parseTimeline(List<String> lines) {
  final List<TimelineEntry> out = <TimelineEntry>[];
  for (final String raw in lines) {
    String line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('- ')) line = line.substring(2).trimLeft();
    bool hi = false;
    if (line.startsWith('*') && !line.startsWith('**')) {
      hi = true;
      line = line.substring(1).trimLeft();
    }
    final (String label, String text) = splitKeyValue(line);
    out.add(TimelineEntry(label: label, text: text, highlight: hi));
  }
  return out;
}

// ---------------------------------------------------------------------------
// scale (experimental)

class ScalePoint {
  const ScalePoint({required this.value, required this.raw, this.label = ''});
  final double value;

  /// The number as the model wrote it, shown unchanged.
  final String raw;
  final String label;
}

class ScaleSpec {
  const ScaleSpec({
    required this.min,
    required this.max,
    required this.unit,
    required this.ticks,
    required this.markers,
  });

  final double min;
  final double max;
  final String unit;
  final List<ScalePoint> ticks;
  final List<ScalePoint> markers;

  bool get isKelvin =>
      RegExp(r'^(k|kelvin)$', caseSensitive: false).hasMatch(unit.trim());

  /// Where [value] sits on the band, 0..1.
  double fraction(double value) {
    if (max <= min) return 0.5;
    return ((value - min) / (max - min)).clamp(0.0, 1.0).toDouble();
  }
}

final RegExp _numRe = RegExp(r"-?\d[\d.,']*");

/// Reads the first number in [s]. Accepts `2700`, `2.700` and `2,700`
/// (thousands), `2,5` and `2.5` (decimals). Returns null when there is none.
double? parseLooseNumber(String s) {
  final RegExpMatch? m = _numRe.firstMatch(s);
  if (m == null) return null;
  String n = m.group(0)!.replaceAll("'", '');
  n = n.replaceAll(RegExp(r'[.,]+$'), '');
  final bool hasDot = n.contains('.');
  final bool hasComma = n.contains(',');
  if (hasDot && hasComma) {
    // The last separator is the decimal one.
    if (n.lastIndexOf(',') > n.lastIndexOf('.')) {
      n = n.replaceAll('.', '').replaceAll(',', '.');
    } else {
      n = n.replaceAll(',', '');
    }
  } else if (hasDot || hasComma) {
    final String sep = hasDot ? '.' : ',';
    final bool thousands = RegExp('^-?\\d{1,3}(\\$sep\\d{3})+\$').hasMatch(n);
    n = thousands ? n.replaceAll(sep, '') : n.replaceAll(',', '.');
  }
  return double.tryParse(n);
}

final RegExp _rangeRe = RegExp(
  r"^\s*(-?\d[\d.,']*)\s*(?:–|—|-|\.\.|to|bis)\s*(-?\d[\d.,']*)\s*(.*)$",
  caseSensitive: false,
);

/// Returns null when the block cannot be drawn (no range and fewer than two
/// distinct values). The caller then shows the lines as text.
ScaleSpec? parseScale(String arg, List<String> lines) {
  final List<ScalePoint> ticks = <ScalePoint>[];
  final List<ScalePoint> markers = <ScalePoint>[];
  for (final String raw in lines) {
    String line = raw.trim();
    if (line.isEmpty) continue;
    final bool marker = line.startsWith('@');
    if (marker) line = line.substring(1).trim();
    final (String key, String label) = splitKeyValue(line);
    final String numText = key.isEmpty ? label : key;
    final double? v = parseLooseNumber(numText);
    if (v == null) continue;
    final String rawNum = _numRe.firstMatch(numText)!.group(0)!;
    final ScalePoint p = ScalePoint(
      value: v,
      raw: rawNum,
      label: key.isEmpty ? '' : label,
    );
    (marker ? markers : ticks).add(p);
  }

  double? lo;
  double? hi;
  String unit = '';
  final RegExpMatch? range = _rangeRe.firstMatch(arg);
  if (range != null) {
    lo = parseLooseNumber(range.group(1)!);
    hi = parseLooseNumber(range.group(2)!);
    unit = range.group(3)!.trim();
  }
  if (lo == null || hi == null || lo == hi) {
    final List<double> all = <double>[
      for (final ScalePoint p in ticks) p.value,
      for (final ScalePoint p in markers) p.value,
    ];
    if (all.length < 2) return null;
    all.sort();
    lo = all.first;
    hi = all.last;
    if (lo == hi) return null;
  }
  if (lo > hi) {
    final double t = lo;
    lo = hi;
    hi = t;
  }
  if (ticks.isEmpty && markers.isEmpty) return null;
  return ScaleSpec(
    min: lo,
    max: hi,
    unit: unit,
    ticks: List<ScalePoint>.unmodifiable(ticks),
    markers: List<ScalePoint>.unmodifiable(markers),
  );
}
