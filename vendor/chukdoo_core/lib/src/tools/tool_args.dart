import '../models/time_utils.dart';

/// A tool call failed in a way the model should see and correct.
class ChukdooToolError implements Exception {
  final String message;
  const ChukdooToolError(this.message);
  @override
  String toString() => message;
}

/// Typed, forgiving access to tool arguments.
class ToolArgs {
  final Map<String, dynamic> raw;
  final DateTime now;

  ToolArgs(Map<String, dynamic>? raw, this.now) : raw = raw ?? const {};

  bool has(String key) => raw.containsKey(key);
  bool isNull(String key) => raw.containsKey(key) && raw[key] == null;

  String? string(String key) {
    final v = raw[key];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  String requireString(String key) =>
      string(key) ?? (throw ChukdooToolError('Missing required argument "$key".'));

  /// Raw text (keeps whitespace; for note content).
  String? text(String key) => raw[key]?.toString();

  int? integer(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is num) return v.toInt();
    final parsed = int.tryParse(v.toString().trim());
    if (parsed == null) throw ChukdooToolError('"$key" must be an integer.');
    return parsed;
  }

  bool? boolean(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is bool) return v;
    final s = v.toString().toLowerCase().trim();
    if (s == 'true' || s == 'yes' || s == '1') return true;
    if (s == 'false' || s == 'no' || s == '0') return false;
    throw ChukdooToolError('"$key" must be true or false.');
  }

  List<String>? stringList(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is List) {
      return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    }
    return v.toString().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  List<int>? intList(String key) {
    final v = raw[key];
    if (v == null) return null;
    final items = v is List ? v : v.toString().split(',');
    return items.map((e) {
      final n = e is num ? e.toInt() : int.tryParse(e.toString().trim());
      if (n == null) throw ChukdooToolError('"$key" must be a list of integers.');
      return n;
    }).toList();
  }

  /// A calendar date: `YYYY-MM-DD`, a full ISO timestamp (date part used),
  /// or `today` / `tomorrow` / `yesterday`.
  DateTime? date(String key) {
    final s = string(key);
    if (s == null) return null;
    return parseDateInput(s, now) ??
        (throw ChukdooToolError(
            '"$key" must be a date like 2026-10-17 (or today/tomorrow), got "$s".'));
  }

  /// A local date-time: `YYYY-MM-DDTHH:mm[:ss]` (local wall clock). A value
  /// with `Z` or an offset is converted to local time. A bare date means
  /// midnight.
  DateTime? dateTime(String key) {
    final s = string(key);
    if (s == null) return null;
    return parseDateTimeInput(s, now) ??
        (throw ChukdooToolError(
            '"$key" must be a local date-time like 2026-10-17T14:30, got "$s".'));
  }

  LocalTime? time(String key) {
    final s = string(key);
    if (s == null) return null;
    return LocalTime.tryParse(s) ??
        (throw ChukdooToolError('"$key" must be a time like 14:30, got "$s".'));
  }
}

/// `today`/`tomorrow`/`yesterday` (and the German words) as a date.
DateTime? _relativeDay(String s, DateTime now) {
  final offset = switch (s.toLowerCase()) {
    'today' || 'heute' => 0,
    'tomorrow' || 'morgen' => 1,
    'yesterday' || 'gestern' => -1,
    _ => null,
  };
  return offset == null ? null : DateTime(now.year, now.month, now.day + offset);
}

DateTime? parseDateInput(String s, DateTime now) {
  final dt = parseDateTimeInput(s, now);
  return dt == null ? null : DateTime(dt.year, dt.month, dt.day);
}

DateTime? parseDateTimeInput(String s, DateTime now) {
  final relative = _relativeDay(s, now);
  if (relative != null) return relative;
  try {
    final normalized = s.contains(' ') && !s.contains('T') ? s.replaceFirst(' ', 'T') : s;
    final parsed = DateTime.parse(normalized);
    return parsed.isUtc ? parsed.toLocal() : parsed;
  } on FormatException {
    return null;
  }
}

/// `YYYY-MM-DDTHH:mm` for output.
String fmtDateTime(DateTime d) =>
    '${dateKey(d)}T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
String weekdayName(DateTime d) => _weekdays[d.weekday - 1];
