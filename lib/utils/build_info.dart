// lib/utils/build_info.dart
//
// Build-time metadata injected via --dart-define at build time.
//
// `BUILD_TIMESTAMP` is expected to be an ISO 8601 UTC string
// (e.g. `2026-05-03T14:32:18Z`). It is set by `run.sh`, the GitHub
// build workflows, and `Dockerfile.web`. When the value is missing
// or malformed (e.g. running `flutter run` directly without the
// helper script), `formatted()` returns null and the UI hides the
// build-date line.

class BuildInfo {
  BuildInfo._();

  /// Raw value from --dart-define=BUILD_TIMESTAMP=...
  static const String buildTimestampRaw =
      String.fromEnvironment('BUILD_TIMESTAMP');

  /// Parsed UTC build timestamp, or null if not provided / invalid.
  static DateTime? get buildTimestamp {
    final raw = buildTimestampRaw.trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toUtc();
  }

  /// Formatted display string `yyyy-MM-dd HH:mm UTC`, or null when
  /// no build timestamp is available.
  ///
  /// `now` is accepted purely for test injection (currently unused but
  /// kept as a deterministic seam for future relative formatting).
  static String? formatted({DateTime? now}) {
    final ts = buildTimestamp;
    if (ts == null) return null;
    final y = ts.year.toString().padLeft(4, '0');
    final mo = ts.month.toString().padLeft(2, '0');
    final d = ts.day.toString().padLeft(2, '0');
    final h = ts.hour.toString().padLeft(2, '0');
    final mi = ts.minute.toString().padLeft(2, '0');
    return '$y-$mo-$d $h:$mi UTC';
  }
}
