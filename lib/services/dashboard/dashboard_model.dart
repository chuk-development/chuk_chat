// lib/services/dashboard/dashboard_model.dart
//
// The Home dashboard document (docs/DASHBOARD.md §2–§3): immutable types for
// the document and its eight widget types, a tolerant parser, and the tracker
// maths the host computes the same way.
//
// The parser never throws. A widget of an unknown type is skipped, a field of
// the wrong shape falls back to its default, and a document that is not a map
// is an empty dashboard. The host is the truth; the app draws what it can.

import 'package:flutter/foundation.dart';

/// The widget types of catalogue v1.
enum DashboardWidgetType {
  tracker,
  metric,
  checklist,
  note,
  chart,
  agenda,
  prompts,
  weather;

  static DashboardWidgetType? parse(Object? raw) {
    if (raw is! String) return null;
    for (final DashboardWidgetType t in values) {
      if (t.name == raw) return t;
    }
    return null;
  }

  /// `half` for tracker and metric, `full` for the others (§2).
  DashboardSize get defaultSize => this == tracker || this == metric
      ? DashboardSize.half
      : DashboardSize.full;
}

enum DashboardSize { half, full }

/// The tracker icons the contract allows (§3).
enum TrackerIcon { dumbbell, run, water, book, sleep, heart, check }

enum TrackerPeriod { day, week }

enum MetricTone { good, warn, bad, neutral }

/// The whole dashboard.
@immutable
class DashboardDocument {
  const DashboardDocument({required this.version, required this.widgets});

  static const DashboardDocument empty = DashboardDocument(
    version: 0,
    widgets: <DashboardWidget>[],
  );

  final int version;
  final List<DashboardWidget> widgets;

  bool get isEmpty => widgets.isEmpty;

  DashboardWidget? byId(String id) {
    for (final DashboardWidget w in widgets) {
      if (w.id == id) return w;
    }
    return null;
  }

  /// Parses a document. Never throws.
  factory DashboardDocument.fromJson(Object? json) {
    if (json is! Map) return empty;
    final List<DashboardWidget> out = <DashboardWidget>[];
    final Set<String> seen = <String>{};
    final Object? list = json['widgets'];
    if (list is List) {
      for (final Object? raw in list) {
        final DashboardWidget? w = DashboardWidget.tryParse(raw);
        if (w == null || !seen.add(w.id)) continue;
        out.add(w);
        if (out.length >= 40) break;
      }
    }
    return DashboardDocument(
      version: _asInt(json['version']) ?? 0,
      widgets: List<DashboardWidget>.unmodifiable(out),
    );
  }

  /// The document as JSON, every widget in the shape it came in.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'widgets': <Map<String, dynamic>>[
      for (final DashboardWidget w in widgets) w.toJson(),
    ],
  };
}

/// Fields every widget has (§2), plus its own fields in a subclass.
@immutable
sealed class DashboardWidget {
  const DashboardWidget({
    required this.id,
    required this.title,
    required this.size,
    required this.by,
    required this.updatedAt,
    required this.raw,
  });

  final String id;
  final String title;
  final DashboardSize size;

  /// Who changed it last ("You" for a tap in the app).
  final String by;
  final DateTime? updatedAt;

  /// The widget as it arrived, so an optimistic op can change one field and
  /// write the rest back unchanged.
  final Map<String, dynamic> raw;

  DashboardWidgetType get type;

  Map<String, dynamic> toJson() => Map<String, dynamic>.of(raw);

  static final RegExp _idPattern = RegExp(r'^[a-z0-9_-]{1,40}$');

  /// One widget, or null when it cannot be drawn (no id, unknown type).
  static DashboardWidget? tryParse(Object? input) {
    if (input is! Map) return null;
    final Map<String, dynamic> raw = <String, dynamic>{
      for (final MapEntry<Object?, Object?> e in input.entries)
        if (e.key is String) e.key! as String: e.value,
    };
    final DashboardWidgetType? type = DashboardWidgetType.parse(raw['type']);
    final Object? id = raw['id'];
    if (type == null || id is! String || !_idPattern.hasMatch(id)) return null;
    final String title = _asString(raw['title']) ?? '';
    final DashboardSize size = switch (raw['size']) {
      'half' => DashboardSize.half,
      'full' => DashboardSize.full,
      _ => type.defaultSize,
    };
    final String by = _asString(raw['by']) ?? '';
    final DateTime? updatedAt = _asDate(raw['updated_at']);
    switch (type) {
      case DashboardWidgetType.tracker:
        return TrackerWidget._parse(id, title, size, by, updatedAt, raw);
      case DashboardWidgetType.metric:
        return MetricWidget._parse(id, title, size, by, updatedAt, raw);
      case DashboardWidgetType.checklist:
        return ChecklistWidget._parse(id, title, size, by, updatedAt, raw);
      case DashboardWidgetType.note:
        return NoteWidget(
          id: id,
          title: title,
          size: size,
          by: by,
          updatedAt: updatedAt,
          raw: raw,
          text: _asString(raw['text']) ?? '',
        );
      case DashboardWidgetType.chart:
        final Object? spec = raw['spec'];
        return ChartWidget(
          id: id,
          title: title,
          size: size,
          by: by,
          updatedAt: updatedAt,
          raw: raw,
          spec: spec is Map
              ? Map<String, dynamic>.from(spec)
              : const <String, dynamic>{},
        );
      case DashboardWidgetType.agenda:
        return AgendaWidget._parse(id, title, size, by, updatedAt, raw);
      case DashboardWidgetType.prompts:
        return PromptsWidget._parse(id, title, size, by, updatedAt, raw);
      case DashboardWidgetType.weather:
        return WeatherWidget._parse(id, title, size, by, updatedAt, raw);
    }
  }
}

// ── tracker ────────────────────────────────────────────────────────────────

@immutable
class TrackerEntry {
  const TrackerEntry({required this.at, required this.value});

  final DateTime at;
  final double value;
}

// Not const: the per-period sums are computed once, lazily.
// ignore: must_be_immutable
class TrackerWidget extends DashboardWidget {
  TrackerWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.unit,
    required this.goal,
    required this.period,
    required this.steps,
    required this.icon,
    required this.entries,
  });

  static const List<double> defaultSteps = <double>[1, 10, 25];

  final String unit;

  /// Always > 0 (a bad goal falls back to 1).
  final double goal;
  final TrackerPeriod period;

  /// 1–3 positive numbers.
  final List<double> steps;
  final TrackerIcon icon;

  /// Oldest first, as stored.
  final List<TrackerEntry> entries;

  @override
  DashboardWidgetType get type => DashboardWidgetType.tracker;

  static TrackerWidget _parse(
    String id,
    String title,
    DashboardSize size,
    String by,
    DateTime? updatedAt,
    Map<String, dynamic> raw,
  ) {
    final double? goal = _asDouble(raw['goal']);
    final List<double> steps = <double>[
      if (raw['steps'] is List)
        for (final Object? s in raw['steps'] as List)
          if (_asDouble(s) case final double v when v > 0) v,
    ];
    final List<TrackerEntry> entries = <TrackerEntry>[
      if (raw['entries'] is List)
        for (final Object? e in raw['entries'] as List)
          if (e is Map)
            if ((_asDate(e['at']), _asDouble(e['value'])) case (
              final DateTime at,
              final double value,
            ))
              TrackerEntry(at: at, value: value),
    ];
    return TrackerWidget(
      id: id,
      title: title,
      size: size,
      by: by,
      updatedAt: updatedAt,
      raw: raw,
      unit: _asString(raw['unit']) ?? '',
      goal: goal != null && goal > 0 ? goal : 1,
      period: raw['period'] == 'week' ? TrackerPeriod.week : TrackerPeriod.day,
      steps: steps.isEmpty
          ? defaultSteps
          : List<double>.unmodifiable(steps.take(3)),
      icon: TrackerIcon.values.firstWhere(
        (TrackerIcon i) => i.name == raw['icon'],
        orElse: () => TrackerIcon.check,
      ),
      entries: List<TrackerEntry>.unmodifiable(entries),
    );
  }

  /// The sum of the current period (today, or this ISO week).
  double current(DateTime now) => sumOf(periodStart(now));

  /// The sum of the period that starts at [start] (a value of [periodStart]).
  double sumOf(DateTime start) => _sums[_keyOf(start)] ?? 0;

  /// Local midnight of the day, or of the Monday of the ISO week, of [t].
  DateTime periodStart(DateTime t) {
    final DateTime local = t.toLocal();
    final DateTime day = DateTime(local.year, local.month, local.day);
    if (period == TrackerPeriod.day) return day;
    return DateTime(day.year, day.month, day.day - (day.weekday - 1));
  }

  /// The start of the period [n] periods before [start].
  DateTime previousStart(DateTime start, [int n = 1]) =>
      period == TrackerPeriod.day
      ? DateTime(start.year, start.month, start.day - n)
      : DateTime(start.year, start.month, start.day - 7 * n);

  /// Whole periods in a row whose sum reached [goal], ending yesterday (or
  /// today when today already reaches it). §3.
  int streak(DateTime now) {
    DateTime start = periodStart(now);
    if (sumOf(start) < goal) start = previousStart(start);
    int n = 0;
    // An entry list holds at most 2000 entries, so no streak is longer.
    while (n <= entries.length && sumOf(start) >= goal) {
      n++;
      start = previousStart(start);
    }
    return n;
  }

  /// The sums of the last [count] periods, oldest first, ending with the
  /// current one.
  List<double> recent(DateTime now, {int count = 7}) {
    final DateTime start = periodStart(now);
    return <double>[
      for (int i = count - 1; i >= 0; i--) sumOf(previousStart(start, i)),
    ];
  }

  /// The newest entry that a correction has not cancelled yet, or null. The
  /// app's undo logs its negative value (§3 allows a negative correction).
  TrackerEntry? get undoable {
    final List<TrackerEntry> open = <TrackerEntry>[];
    for (final TrackerEntry e in entries) {
      if (e.value > 0) {
        open.add(e);
      } else if (e.value < 0) {
        final int i = open.lastIndexWhere(
          (TrackerEntry o) => o.value == -e.value,
        );
        if (i >= 0) open.removeAt(i);
      }
    }
    return open.isEmpty ? null : open.last;
  }

  static String _keyOf(DateTime start) =>
      '${start.year}-${start.month}-${start.day}';

  late final Map<String, double> _sums = () {
    final Map<String, double> out = <String, double>{};
    for (final TrackerEntry e in entries) {
      final String k = _keyOf(periodStart(e.at));
      out[k] = (out[k] ?? 0) + e.value;
    }
    return out;
  }();
}

// ── metric ─────────────────────────────────────────────────────────────────

class MetricWidget extends DashboardWidget {
  const MetricWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.value,
    required this.unit,
    required this.delta,
    required this.tone,
    required this.trend,
    required this.caption,
  });

  /// The value as text: a number is printed without a needless ".0".
  final String value;
  final String unit;
  final String delta;
  final MetricTone tone;
  final List<double> trend;
  final String caption;

  @override
  DashboardWidgetType get type => DashboardWidgetType.metric;

  static MetricWidget _parse(
    String id,
    String title,
    DashboardSize size,
    String by,
    DateTime? updatedAt,
    Map<String, dynamic> raw,
  ) {
    final Object? v = raw['value'];
    final List<double> trend = <double>[
      if (raw['trend'] is List)
        for (final Object? t in raw['trend'] as List)
          if (_asDouble(t) case final double d) d,
    ];
    return MetricWidget(
      id: id,
      title: title,
      size: size,
      by: by,
      updatedAt: updatedAt,
      raw: raw,
      value: v is num ? formatNumber(v.toDouble()) : (_asString(v) ?? '–'),
      unit: _asString(raw['unit']) ?? '',
      delta: _asString(raw['delta']) ?? '',
      tone: MetricTone.values.firstWhere(
        (MetricTone t) => t.name == raw['tone'],
        orElse: () => MetricTone.neutral,
      ),
      trend: List<double>.unmodifiable(
        trend.length > 60 ? trend.sublist(trend.length - 60) : trend,
      ),
      caption: _asString(raw['caption']) ?? '',
    );
  }
}

// ── checklist ──────────────────────────────────────────────────────────────

@immutable
class ChecklistItem {
  const ChecklistItem({
    required this.id,
    required this.text,
    required this.done,
  });

  final String id;
  final String text;
  final bool done;
}

class ChecklistWidget extends DashboardWidget {
  const ChecklistWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.items,
  });

  final List<ChecklistItem> items;

  int get doneCount => items.where((ChecklistItem i) => i.done).length;

  @override
  DashboardWidgetType get type => DashboardWidgetType.checklist;

  static ChecklistWidget _parse(
    String id,
    String title,
    DashboardSize size,
    String by,
    DateTime? updatedAt,
    Map<String, dynamic> raw,
  ) {
    final List<ChecklistItem> items = <ChecklistItem>[];
    if (raw['items'] is List) {
      for (final Object? i in raw['items'] as List) {
        if (i is! Map) continue;
        final String? itemId = _asString(i['id']);
        if (itemId == null || itemId.isEmpty) continue;
        items.add(
          ChecklistItem(
            id: itemId,
            text: _asString(i['text']) ?? '',
            done: i['done'] == true,
          ),
        );
        if (items.length >= 50) break;
      }
    }
    return ChecklistWidget(
      id: id,
      title: title,
      size: size,
      by: by,
      updatedAt: updatedAt,
      raw: raw,
      items: List<ChecklistItem>.unmodifiable(items),
    );
  }
}

// ── note / chart ───────────────────────────────────────────────────────────

class NoteWidget extends DashboardWidget {
  const NoteWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.text,
  });

  /// Markdown.
  final String text;

  @override
  DashboardWidgetType get type => DashboardWidgetType.note;
}

class ChartWidget extends DashboardWidget {
  const ChartWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.spec,
  });

  /// The `ChukChart` JSON, as a `<chart>` tag carries it.
  final Map<String, dynamic> spec;

  @override
  DashboardWidgetType get type => DashboardWidgetType.chart;
}

// ── agenda ─────────────────────────────────────────────────────────────────

@immutable
class AgendaItem {
  const AgendaItem({required this.time, required this.title, this.place = ''});

  /// `HH:MM`, or empty for an all-day item.
  final String time;
  final String title;
  final String place;

  /// Minutes after midnight, or null when [time] is not `HH:MM`.
  int? get minutes {
    final RegExpMatch? m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time);
    if (m == null) return null;
    final int h = int.parse(m.group(1)!);
    final int min = int.parse(m.group(2)!);
    if (h > 23 || min > 59) return null;
    return h * 60 + min;
  }
}

class AgendaWidget extends DashboardWidget {
  const AgendaWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.date,
    required this.items,
  });

  /// The day the agenda is for, local midnight; null means today.
  final DateTime? date;
  final List<AgendaItem> items;

  @override
  DashboardWidgetType get type => DashboardWidgetType.agenda;

  static AgendaWidget _parse(
    String id,
    String title,
    DashboardSize size,
    String by,
    DateTime? updatedAt,
    Map<String, dynamic> raw,
  ) {
    DateTime? date;
    final String? d = _asString(raw['date']);
    final RegExpMatch? m = d == null
        ? null
        : RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(d);
    if (m != null) {
      date = DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      );
    }
    final List<AgendaItem> items = <AgendaItem>[
      if (raw['items'] is List)
        for (final Object? i in raw['items'] as List)
          if (i is Map && (_asString(i['title']) ?? '').isNotEmpty)
            AgendaItem(
              time: _asString(i['time']) ?? '',
              title: _asString(i['title'])!,
              place: _asString(i['place']) ?? '',
            ),
    ];
    return AgendaWidget(
      id: id,
      title: title,
      size: size,
      by: by,
      updatedAt: updatedAt,
      raw: raw,
      date: date,
      items: List<AgendaItem>.unmodifiable(items.take(30)),
    );
  }
}

// ── prompts ────────────────────────────────────────────────────────────────

@immutable
class PromptItem {
  const PromptItem({required this.label, required this.prompt});

  final String label;
  final String prompt;
}

class PromptsWidget extends DashboardWidget {
  const PromptsWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.items,
  });

  final List<PromptItem> items;

  @override
  DashboardWidgetType get type => DashboardWidgetType.prompts;

  static PromptsWidget _parse(
    String id,
    String title,
    DashboardSize size,
    String by,
    DateTime? updatedAt,
    Map<String, dynamic> raw,
  ) {
    final List<PromptItem> items = <PromptItem>[];
    if (raw['items'] is List) {
      for (final Object? i in raw['items'] as List) {
        if (i is! Map) continue;
        final String label = _asString(i['label']) ?? '';
        final String prompt = _asString(i['prompt']) ?? label;
        if (label.isEmpty || prompt.isEmpty) continue;
        items.add(PromptItem(label: label, prompt: prompt));
        if (items.length >= 6) break;
      }
    }
    return PromptsWidget(
      id: id,
      title: title,
      size: size,
      by: by,
      updatedAt: updatedAt,
      raw: raw,
      items: List<PromptItem>.unmodifiable(items),
    );
  }
}

// ── weather ────────────────────────────────────────────────────────────────

@immutable
class WeatherDay {
  const WeatherDay({
    required this.date,
    required this.code,
    required this.max,
    required this.min,
  });

  final DateTime? date;
  final int code;
  final double? max;
  final double? min;
}

class WeatherWidget extends DashboardWidget {
  const WeatherWidget({
    required super.id,
    required super.title,
    required super.size,
    required super.by,
    required super.updatedAt,
    required super.raw,
    required this.place,
    required this.temp,
    required this.condition,
    required this.code,
    required this.daily,
    required this.unit,
  });

  final String place;
  final double? temp;
  final String condition;

  /// WMO weather code.
  final int code;
  final List<WeatherDay> daily;

  /// `C` or `F`.
  final String unit;

  @override
  DashboardWidgetType get type => DashboardWidgetType.weather;

  static WeatherWidget _parse(
    String id,
    String title,
    DashboardSize size,
    String by,
    DateTime? updatedAt,
    Map<String, dynamic> raw,
  ) {
    final Object? current = raw['current'];
    final Map<Object?, Object?> cur = current is Map
        ? current
        : const <Object?, Object?>{};
    final List<WeatherDay> daily = <WeatherDay>[
      if (raw['daily'] is List)
        for (final Object? d in raw['daily'] as List)
          if (d is Map)
            WeatherDay(
              date: _asDate(d['date']),
              code: _asInt(d['code']) ?? 0,
              max: _asDouble(d['max']),
              min: _asDouble(d['min']),
            ),
    ];
    return WeatherWidget(
      id: id,
      title: title,
      size: size,
      by: by,
      updatedAt: updatedAt,
      raw: raw,
      place: _asString(raw['place']) ?? '',
      temp: _asDouble(cur['temp']),
      condition: _asString(cur['condition']) ?? '',
      code: _asInt(cur['code']) ?? 0,
      daily: List<WeatherDay>.unmodifiable(daily.take(7)),
      unit: raw['unit'] == 'F' ? 'F' : 'C',
    );
  }
}

// ── helpers ────────────────────────────────────────────────────────────────

/// A number as a dashboard prints it: no ".0", at most two decimals.
String formatNumber(double v) {
  if (!v.isFinite) return '–';
  if (v == v.roundToDouble()) return v.toInt().toString();
  final String s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

String? _asString(Object? v) {
  if (v is String) return v;
  if (v is num) return formatNumber(v.toDouble());
  return null;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num && v.isFinite) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _asDouble(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final double? d = double.tryParse(v.trim());
    return d != null && d.isFinite ? d : null;
  }
  return null;
}

DateTime? _asDate(Object? v) =>
    v is String ? DateTime.tryParse(v.trim()) : null;

// ── optimistic ops ─────────────────────────────────────────────────────────

/// The actions the app sends in a `dashboard_op` (§5).
const Set<String> kDashboardOpActions = <String>{
  'log',
  'check',
  'remove',
  'move',
  'update',
};

/// ISO 8601 with the local offset, as the contract wants (`+01:00`).
String isoWithOffset(DateTime t) {
  final DateTime local = t.toLocal();
  final Duration off = local.timeZoneOffset;
  final String sign = off.isNegative ? '-' : '+';
  final int mins = off.inMinutes.abs();
  String two(int v) => v.toString().padLeft(2, '0');
  final String base = local.toIso8601String().split('.').first;
  return '$base$sign${two(mins ~/ 60)}:${two(mins % 60)}';
}

/// [doc] with [op] applied the way the host will apply it, with `by: "You"`.
/// An op that does not fit (unknown widget, wrong type) changes nothing.
DashboardDocument applyDashboardOp(
  DashboardDocument doc,
  Map<String, dynamic> op,
  DateTime now,
) {
  final String? action = op['action'] is String ? op['action'] as String : null;
  final String? id = op['id'] is String ? op['id'] as String : null;
  if (action == null || id == null) return doc;
  final List<Map<String, dynamic>> widgets = <Map<String, dynamic>>[
    for (final DashboardWidget w in doc.widgets) w.toJson(),
  ];
  final int index = widgets.indexWhere(
    (Map<String, dynamic> w) => w['id'] == id,
  );
  if (index < 0) return doc;
  final Map<String, dynamic> w = widgets[index];
  void touch() {
    w['by'] = 'You';
    w['updated_at'] = isoWithOffset(now);
  }

  switch (action) {
    case 'log':
      final double? value = _asDouble(op['value']);
      if (w['type'] != 'tracker' || value == null) return doc;
      final List<Object?> entries = <Object?>[
        if (w['entries'] is List) ...w['entries'] as List,
        <String, dynamic>{
          'at': op['at'] is String ? op['at'] : isoWithOffset(now),
          'value': value,
        },
      ];
      w['entries'] = entries.length > 2000
          ? entries.sublist(entries.length - 2000)
          : entries;
      touch();
    case 'check':
      if (w['type'] != 'checklist' || w['items'] is! List) return doc;
      bool hit = false;
      w['items'] = <Object?>[
        for (final Object? item in w['items'] as List)
          if (item is Map && item['id'] == op['item'])
            () {
              hit = true;
              return <String, dynamic>{
                ...Map<String, dynamic>.from(item),
                'done': op['done'] == true,
              };
            }()
          else
            item,
      ];
      if (!hit) return doc;
      touch();
    case 'remove':
      widgets.removeAt(index);
    case 'move':
      final int? to = _asInt(op['index']);
      if (to == null) return doc;
      widgets.removeAt(index);
      widgets.insert(to.clamp(0, widgets.length), w);
    case 'update':
      final Object? patch = op['patch'];
      if (patch is! Map) return doc;
      for (final MapEntry<Object?, Object?> e in patch.entries) {
        if (e.key is! String) continue;
        if (e.key == 'type' || e.key == 'id') continue;
        w[e.key! as String] = e.value;
      }
      touch();
    default:
      return doc;
  }
  return DashboardDocument.fromJson(<String, dynamic>{
    'version': doc.version,
    'widgets': widgets,
  });
}
