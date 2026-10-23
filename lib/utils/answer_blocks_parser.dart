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
enum AnswerBlockKind {
  steps,
  timeline,
  scale,
  alert,
  bars,
  kpi,
  tiles,
  cards,
  ask,
  source,
  status,
}

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
  'bars': AnswerBlockKind.bars,
  'kpi': AnswerBlockKind.kpi,
  'tiles': AnswerBlockKind.tiles,
  'cards': AnswerBlockKind.cards,
  'ask': AnswerBlockKind.ask,
  'source': AnswerBlockKind.source,
  'status': AnswerBlockKind.status,
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

/// A label the model wrapped in bold: `**Goethe:** Faust` or
/// `**Goethe**: Faust`. The colon is required, inside the markers (group 1)
/// or right after them (group 2); group 3 is the text after it. A bold start
/// with no colon (`**Big news** on 2021: launch`) is not a label: the line
/// splits at its `: ` instead.
final RegExp _boldLabelRe = RegExp(
  r'^(?:\*\*|__)(?:(.+?:)(?:\*\*|__)|(.+?)(?:\*\*|__)\s*:)\s+(.*)$',
);

/// Drops a wrapping `**…**` / `__…__` and a trailing colon from a label.
/// The label is drawn as plain text, so a marker left in it shows literally.
String stripLabelEmphasis(String label) {
  String l = label.trim();
  final RegExpMatch? m = RegExp(r'^(\*\*|__)(.+)\1$').firstMatch(l);
  if (m != null) l = m.group(2)!.trim();
  if (l.endsWith(':')) l = l.substring(0, l.length - 1).trimRight();
  return l;
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
    final RegExpMatch? bold = _boldLabelRe.firstMatch(line);
    final String? boldLabel = bold == null
        ? null
        : (bold.group(1) ?? bold.group(2));
    final String label;
    final String text;
    if (boldLabel != null && !boldLabel.contains('*')) {
      // A bold label ends at its closing marker, not at the first `: ` of
      // the sentence after it.
      label = stripLabelEmphasis(boldLabel);
      text = bold!.group(3)!.trim();
    } else {
      final (String k, String v) = splitKeyValue(line);
      label = stripLabelEmphasis(k);
      text = v;
    }
    out.add(TimelineEntry(label: label, text: text, highlight: hi));
  }
  return out;
}

final RegExp _digitRe = RegExp(r'\d');

/// The longest label the timeline's date column draws, in characters
/// (`2021-01-15`, `12:30 Uhr`, `um 1800`).
const int kTimelineLabelMaxChars = 14;

/// True when [entries] is a real timeline: most entries carry a short,
/// date-like label (it holds a digit). A bullet list with bold names
/// (`- **Goethe:** Faust`) is not one; it is drawn as plain Markdown, so the
/// names do not end up in the narrow date column.
bool timelineIsDated(List<TimelineEntry> entries) {
  if (entries.isEmpty) return false;
  int dated = 0;
  for (final TimelineEntry e in entries) {
    if (e.label.isNotEmpty &&
        e.label.length <= kTimelineLabelMaxChars &&
        _digitRe.hasMatch(e.label)) {
      dated++;
    }
  }
  return dated * 2 >= entries.length;
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

// ---------------------------------------------------------------------------
// bars — labelled horizontal bar comparison
//
// ::: bars Optional title
// Step 5 | ~1.200 GB | 600B Gesamtparameter
// GLM Flash | ~640 GB | 320B Gesamtparameter
// ! Parameter × 2 Byte — zusätzlicher Laufzeitspeicher nötig
// :::
//
// The bar length comes from the first number in the value; the value text is
// shown unchanged. A line starting with `! ` is the note under the bars.

class BarRow {
  const BarRow({
    required this.label,
    required this.valueText,
    required this.sub,
    required this.value,
  });

  final String label;
  final String valueText;
  final String sub;

  /// First number in [valueText], or null (row draws at full length then).
  final double? value;
}

class BarsSpec {
  const BarsSpec({
    required this.title,
    required this.rows,
    this.note = '',
    this.tag = '',
  });
  final String title;
  final List<BarRow> rows;
  final String note;

  /// Optional small label chip above the title (`tag: BF16 · nur Gewichte`).
  final String tag;
}

BarsSpec parseBars(String arg, List<String> lines) {
  final List<BarRow> rows = <BarRow>[];
  String note = '';
  String tag = '';
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('! ')) {
      note = line.substring(2).trim();
      continue;
    }
    if (line.startsWith('tag:')) {
      tag = line.substring(4).trim();
      continue;
    }
    final List<String> parts = line.split('|').map((p) => p.trim()).toList();
    final String label = parts.isNotEmpty ? parts[0] : '';
    final String valueText = parts.length > 1 ? parts[1] : '';
    final String sub = parts.length > 2 ? parts.sublist(2).join(' · ') : '';
    if (label.isEmpty && valueText.isEmpty) continue;
    rows.add(
      BarRow(
        label: label,
        valueText: valueText,
        sub: sub,
        value: parseLooseNumber(valueText),
      ),
    );
  }
  return BarsSpec(
    title: arg.trim(),
    rows: List<BarRow>.unmodifiable(rows),
    note: note,
    tag: tag,
  );
}

// ---------------------------------------------------------------------------
// kpi — stat tiles (value first)
//
// ::: kpi Optional title
// 82 % | Luftfeuchtigkeit | droplet
// 7 km/h S | Wind aus Süden | wind
// :::

class KpiTile {
  const KpiTile({required this.value, required this.label, this.icon = ''});
  final String value;
  final String label;
  final String icon;
}

class KpiSpec {
  const KpiSpec({required this.title, required this.tiles, this.tag = ''});
  final String title;
  final List<KpiTile> tiles;
  final String tag;
}

KpiSpec parseKpi(String arg, List<String> lines) {
  final List<KpiTile> tiles = <KpiTile>[];
  String tag = '';
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('tag:')) {
      tag = line.substring(4).trim();
      continue;
    }
    final List<String> parts = line.split('|').map((p) => p.trim()).toList();
    final String value = parts.isNotEmpty ? parts[0] : '';
    if (value.isEmpty) continue;
    tiles.add(
      KpiTile(
        value: value,
        label: parts.length > 1 ? parts[1] : '',
        icon: parts.length > 2 ? parts[2] : '',
      ),
    );
  }
  return KpiSpec(
    title: arg.trim(),
    tiles: List<KpiTile>.unmodifiable(tiles),
    tag: tag,
  );
}

// ---------------------------------------------------------------------------
// tiles — icon tiles (label first)
//
// ::: tiles Optional title
// Chatbot | chat
// Such-Crawler | search
// Spiele-Bot | game
// :::

class IconTile {
  const IconTile({required this.label, this.icon = '', this.sub = ''});
  final String label;
  final String icon;
  final String sub;
}

class TilesSpec {
  const TilesSpec({required this.title, required this.tiles, this.tag = ''});
  final String title;
  final List<IconTile> tiles;
  final String tag;
}

TilesSpec parseTiles(String arg, List<String> lines) {
  final List<IconTile> tiles = <IconTile>[];
  String tag = '';
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('tag:')) {
      tag = line.substring(4).trim();
      continue;
    }
    String body = line.startsWith('- ') ? line.substring(2).trim() : line;
    final List<String> parts = body.split('|').map((p) => p.trim()).toList();
    final String label = parts.isNotEmpty ? parts[0] : '';
    if (label.isEmpty) continue;
    tiles.add(
      IconTile(
        label: label,
        icon: parts.length > 1 ? parts[1] : '',
        sub: parts.length > 2 ? parts.sublist(2).join(' · ') : '',
      ),
    );
  }
  return TilesSpec(
    title: arg.trim(),
    tiles: List<IconTile>.unmodifiable(tiles),
    tag: tag,
  );
}

// ---------------------------------------------------------------------------
// cards — card carousel (hotel / product / item cards)
//
// ::: cards Hotels
// Alpenruhe Panorama
// image: https://example.com/alpenruhe.jpg
// badge: Für deinen Bergmoment
// subtitle: Grindelwald, Schweiz
// meta: 4,8 · 128 Bewertungen
// chips: Panoramabalkon, Berg-Spa
// price: 248 CHF / Nacht
// url: https://example.com/alpenruhe
// --
// Auralis Quiet One
// ...
// :::
//
// The first line of a record is the title, the rest are `key: value` pairs.
// `meta` and `chips` may repeat; chips split on commas. `--` on its own line
// (or a blank line) starts the next card.

class AnswerCard {
  const AnswerCard({
    required this.title,
    this.subtitle = '',
    this.image = '',
    this.badge = '',
    this.price = '',
    this.url = '',
    this.action = '',
    this.metas = const <String>[],
    this.chips = const <String>[],
  });
  final String title;
  final String subtitle;
  final String image;
  final String badge;
  final String price;
  final String url;

  /// Label of the action button (default "Open" in the widget).
  final String action;
  final List<String> metas;
  final List<String> chips;
}

class CardsSpec {
  const CardsSpec({required this.label, required this.cards});
  final String label;
  final List<AnswerCard> cards;
}

const List<String> _kCardKeys = <String>[
  'image',
  'badge',
  'subtitle',
  'price',
  'url',
  'link',
  'action',
];

AnswerCard _parseCardRecord(List<String> record) {
  String title = '';
  String subtitle = '';
  String image = '';
  String badge = '';
  String price = '';
  String url = '';
  String action = '';
  final List<String> metas = <String>[];
  final List<String> chips = <String>[];

  for (final String raw in record) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    final int colon = line.indexOf(':');
    final String key = colon > 0
        ? line.substring(0, colon).trim().toLowerCase()
        : '';
    final String value = colon > 0 ? line.substring(colon + 1).trim() : '';
    // A known key with an empty value (`image:` from a tool that returned
    // nothing) is not content: drop it instead of letting it become the
    // title or a meta line.
    if (value.isEmpty &&
        (_kCardKeys.contains(key) || key == 'chips' || key == 'meta')) {
      continue;
    }
    if (value.isNotEmpty && _kCardKeys.contains(key)) {
      switch (key) {
        case 'image':
          image = value;
          continue;
        case 'badge':
          badge = value;
          continue;
        case 'subtitle':
          subtitle = value;
          continue;
        case 'price':
          price = value;
          continue;
        case 'action':
          action = value;
          continue;
        case 'url':
        case 'link':
          url = value;
          continue;
      }
    }
    if (key == 'chips' && value.isNotEmpty) {
      chips.addAll(
        value.split(',').map((c) => c.trim()).where((c) => c.isNotEmpty),
      );
      continue;
    }
    if (key == 'meta' && value.isNotEmpty) {
      metas.add(value);
      continue;
    }
    if (title.isEmpty) {
      title = line.startsWith('- ') ? line.substring(2).trim() : line;
    } else {
      // An extra plain line: read it as a fact line.
      metas.add(line);
    }
  }
  return AnswerCard(
    title: title,
    subtitle: subtitle,
    image: image,
    badge: badge,
    price: price,
    url: url,
    action: action,
    metas: List<String>.unmodifiable(metas),
    chips: List<String>.unmodifiable(chips),
  );
}

CardsSpec parseCards(String arg, List<String> lines) {
  final List<List<String>> records = <List<String>>[];
  List<String> current = <String>[];

  void flushRecord() {
    if (current.any((l) => l.trim().isNotEmpty)) {
      records.add(current);
    }
    current = <String>[];
  }

  for (final String line in lines) {
    final String t = line.trim();
    if (t == '--' || t == '---' || t.isEmpty) {
      flushRecord();
      continue;
    }
    current.add(line);
  }
  flushRecord();

  final List<AnswerCard> cards = <AnswerCard>[
    for (final List<String> record in records) _parseCardRecord(record),
  ].where((AnswerCard c) => c.title.isNotEmpty).toList();

  return CardsSpec(
    label: arg.trim(),
    cards: List<AnswerCard>.unmodifiable(cards),
  );
}

// ---------------------------------------------------------------------------
// ask — follow-up chips the reader can tap to send as the next question
//
// ::: ask Welche Rechenbasis möchtest du verstehen?
// Aktive Parameter
// BF16 & FP8
// :::

class AskSpec {
  const AskSpec({required this.question, required this.chips});
  final String question;
  final List<String> chips;
}

AskSpec parseAsk(String arg, List<String> lines) {
  final List<String> chips = <String>[];
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    chips.add(line.startsWith('- ') ? line.substring(2).trim() : line);
  }
  return AskSpec(
    question: arg.trim(),
    chips: List<String>.unmodifiable(chips.where((c) => c.isNotEmpty)),
  );
}

// ---------------------------------------------------------------------------
// status — a list of items with amount, status and date (open payments,
// invoices, orders, deliveries, tasks with a deadline)
//
// ::: status 4 offene Zahlungen · 122,20 € + 50 $
// Hetzner | Kartenzahlung fehlgeschlagen | 102,20 € | failed | 16.10. | hetzner.com | Bezahlen https://…
// Mobbin | Zahlungsmethode aktualisieren | | due Letzte Chance | 18.10. | mobbin.com
// more: Ältere Erinnerungen (Tailscale, Lebara …)
// Tailscale | Zahlungserinnerung | | ok | 02.09. | tailscale.com
// :::
//
// One row per line, positional fields: title | detail | amount | status |
// date | domain | action. Every field after the title may be empty. The
// status is a kind word, optionally followed by the chip label in the
// reader's language (`due Letzte Chance`); without a label the word itself
// is the label. The action is an http(s) URL, optionally with a label in
// front. A `more:` line starts the collapsed footer; the rows after it are
// shown only when the reader opens it.

/// The colour family of a status chip.
enum StatusKind { failed, overdue, due, ok, neutral }

const Map<String, StatusKind> _kStatusWords = <String, StatusKind>{
  'failed': StatusKind.failed,
  'fail': StatusKind.failed,
  'error': StatusKind.failed,
  'declined': StatusKind.failed,
  'fehlgeschlagen': StatusKind.failed,
  'abgelehnt': StatusKind.failed,
  'overdue': StatusKind.overdue,
  'late': StatusKind.overdue,
  'delayed': StatusKind.overdue,
  'überfällig': StatusKind.overdue,
  'ueberfaellig': StatusKind.overdue,
  'verspätet': StatusKind.overdue,
  'due': StatusKind.due,
  'pending': StatusKind.due,
  'open': StatusKind.due,
  'offen': StatusKind.due,
  'fällig': StatusKind.due,
  'soon': StatusKind.due,
  'warning': StatusKind.due,
  'ok': StatusKind.ok,
  'paid': StatusKind.ok,
  'done': StatusKind.ok,
  'delivered': StatusKind.ok,
  'bezahlt': StatusKind.ok,
  'erledigt': StatusKind.ok,
  'geliefert': StatusKind.ok,
};

class StatusItem {
  const StatusItem({
    required this.title,
    this.detail = '',
    this.amount = '',
    this.kind = StatusKind.neutral,
    this.statusLabel = '',
    this.date = '',
    this.domain = '',
    this.actionLabel = '',
    this.actionUrl = '',
  });

  final String title;
  final String detail;
  final String amount;
  final StatusKind kind;

  /// The chip text; empty means no chip.
  final String statusLabel;
  final String date;

  /// Bare host for the logo (`hetzner.com`), empty when none is usable.
  final String domain;
  final String actionLabel;

  /// An http(s) URL, empty when the row has no action.
  final String actionUrl;
}

class StatusSpec {
  const StatusSpec({
    required this.title,
    required this.summary,
    required this.items,
    this.moreLabel = '',
    this.moreItems = const <StatusItem>[],
  });

  /// The bold header line (`4 offene Zahlungen`).
  final String title;

  /// The muted line under it (`122,20 € + 50 $`).
  final String summary;
  final List<StatusItem> items;

  /// The collapsed footer row; empty means no footer.
  final String moreLabel;
  final List<StatusItem> moreItems;
}

final RegExp _hostRe = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$',
);
final RegExp _urlTokenRe = RegExp(r'https?://\S+', caseSensitive: false);

/// A host fit for the favicon services, or ''. Accepts `hetzner.com`,
/// `www.hetzner.com` and a full URL; refuses IPs, `localhost` and anything
/// that is not a plain public-looking name.
String statusDomain(String raw) {
  String h = raw.trim().toLowerCase();
  if (h.isEmpty) return '';
  if (h.contains('://')) h = Uri.tryParse(h)?.host ?? '';
  h = h.split('/').first;
  if (h.startsWith('www.')) h = h.substring(4);
  if (!_hostRe.hasMatch(h)) return '';
  if (h.endsWith('.local') || h.endsWith('.localhost')) return '';
  return h;
}

(StatusKind, String) _parseStatus(String raw) {
  final String s = raw.trim();
  if (s.isEmpty) return (StatusKind.neutral, '');
  // `due Letzte Chance`, `due: Letzte Chance`, `status:due`.
  String body = s;
  if (body.toLowerCase().startsWith('status:')) body = body.substring(7).trim();
  final Match? m = RegExp(r'^([^\s:]+)\s*:?\s*(.*)$').firstMatch(body);
  final String word = (m?.group(1) ?? body).toLowerCase();
  final String rest = (m?.group(2) ?? '').trim();
  final StatusKind? kind = _kStatusWords[word];
  if (kind == null) return (StatusKind.neutral, body);
  if (rest.isNotEmpty) return (kind, rest);
  final String w = m?.group(1) ?? body;
  return (kind, w[0].toUpperCase() + w.substring(1));
}

StatusItem? _parseStatusRow(String line) {
  String body = line.startsWith('- ') ? line.substring(2).trim() : line;
  final List<String> p = body.split('|').map((String x) => x.trim()).toList();
  String at(int i) => i < p.length ? p[i] : '';
  final String title = stripLabelEmphasis(at(0));
  if (title.isEmpty) return null;
  final (StatusKind kind, String label) = _parseStatus(at(3));
  final String actionRaw = p.length > 6 ? p.sublist(6).join(' | ') : '';
  final Match? url = _urlTokenRe.firstMatch(actionRaw);
  String actionUrl = '';
  String actionLabel = '';
  if (url != null) {
    actionUrl = url.group(0)!;
    actionLabel = actionRaw.substring(0, url.start).trim();
    if (actionLabel.endsWith(':')) {
      actionLabel = actionLabel.substring(0, actionLabel.length - 1).trim();
    }
  }
  String domain = statusDomain(at(5));
  if (domain.isEmpty && actionUrl.isNotEmpty) domain = statusDomain(actionUrl);
  return StatusItem(
    title: title,
    detail: at(1),
    amount: at(2),
    kind: kind,
    statusLabel: label,
    date: at(4),
    domain: domain,
    actionLabel: actionLabel,
    actionUrl: actionUrl,
  );
}

StatusSpec parseStatus(String arg, List<String> lines) {
  final List<StatusItem> items = <StatusItem>[];
  final List<StatusItem> more = <StatusItem>[];
  String moreLabel = '';
  bool inMore = false;
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    final String lower = line.toLowerCase();
    if (lower.startsWith('more:') || lower.startsWith('mehr:')) {
      moreLabel = line.substring(5).trim();
      inMore = true;
      continue;
    }
    final StatusItem? item = _parseStatusRow(line);
    if (item == null) continue;
    (inMore ? more : items).add(item);
  }
  String title = arg.trim();
  String summary = '';
  for (final String sep in const <String>[' · ', ' | ', ' — ', ' - ']) {
    final int at = title.indexOf(sep);
    if (at > 0) {
      summary = title.substring(at + sep.length).trim();
      title = title.substring(0, at).trim();
      break;
    }
  }
  if (moreLabel.isEmpty && more.isNotEmpty) moreLabel = '+${more.length}';
  return StatusSpec(
    title: title,
    summary: summary,
    items: List<StatusItem>.unmodifiable(items),
    moreLabel: moreLabel,
    moreItems: List<StatusItem>.unmodifiable(more),
  );
}
