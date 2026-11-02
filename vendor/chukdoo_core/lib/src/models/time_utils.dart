/// Time conventions of the app, in one place.
///
/// The app stores times as LOCAL wall-clock ISO strings without an offset
/// (`DateTime.toIso8601String()` of a local DateTime, e.g.
/// `2026-10-17T14:30:00.000`). Postgres reads such a string into a
/// `timestamptz` column as UTC, so a clear column comes back as
/// `2026-10-17T14:30:00+00:00`. The wall clock survives that round trip, so
/// every reader here takes the wall-clock components and ignores the offset.
library;

/// Local wall-clock ISO string without offset, exactly like the app.
String localIso(DateTime value) {
  final local = value.isUtc
      ? DateTime(value.year, value.month, value.day, value.hour, value.minute,
          value.second, value.millisecond, value.microsecond)
      : value;
  return local.toIso8601String();
}

/// Parses an app or column timestamp as a local wall-clock DateTime.
DateTime parseWall(String value) {
  final parsed = DateTime.parse(value);
  if (!parsed.isUtc) return parsed;
  return DateTime(parsed.year, parsed.month, parsed.day, parsed.hour,
      parsed.minute, parsed.second, parsed.millisecond, parsed.microsecond);
}

DateTime? tryParseWall(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    return parseWall(value);
  } on FormatException {
    return null;
  }
}

/// `yyyy-MM-dd` of a date.
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// A time of day (the app's `TimeOfDay`, stored as unpadded `H:m`).
class LocalTime implements Comparable<LocalTime> {
  final int hour;
  final int minute;

  const LocalTime(this.hour, this.minute);

  /// Parses `H:m`, `HH:mm` or `HH:mm:ss`. Returns null if malformed.
  static LocalTime? tryParse(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return LocalTime(h, m);
  }

  /// The app's storage form: unpadded `H:m` (e.g. `9:5`).
  String toAppString() => '$hour:$minute';

  /// Human form `HH:mm`.
  String toDisplay() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  int get minutesOfDay => hour * 60 + minute;

  @override
  int compareTo(LocalTime other) => minutesOfDay.compareTo(other.minutesOfDay);

  @override
  bool operator ==(Object other) =>
      other is LocalTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => toDisplay();
}

/// `#RRGGBB` (calendars) from an ARGB int.
String colorToRgbHex(int argb) =>
    '#${argb.toRadixString(16).padLeft(8, '0').substring(2)}';

/// `#AARRGGBB` (habits, notes, folders) from an ARGB int.
String colorToArgbHex(int argb) => '#${argb.toRadixString(16).padLeft(8, '0')}';

/// Parses `#RGB`-less forms the app writes: `#RRGGBB` -> opaque, `#AARRGGBB`.
int? parseHexColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final clean = hex.replaceAll('#', '');
  if (clean.length == 6) return int.tryParse('FF$clean', radix: 16);
  if (clean.length == 8) return int.tryParse(clean, radix: 16);
  return null;
}

/// Accepts `#RRGGBB`, `#AARRGGBB` or an int and returns an opaque-or-given ARGB.
int? colorFromInput(Object? input) {
  if (input == null) return null;
  if (input is int) return input <= 0xFFFFFF ? (0xFF000000 | input) : input;
  if (input is String) return parseHexColor(input.trim());
  return null;
}
