// lib/utils/format_bytes.dart

/// Formats a byte count for a reader: `842 B`, `1.5 KB`, `12 MB`.
///
/// One decimal below 10 of a unit, none above — `1.5 MB` carries information,
/// `12.3 MB` is noise at a glance. Bytes themselves never get a decimal.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final formatted =
      value < 10 ? value.toStringAsFixed(1) : value.round().toString();
  return '$formatted ${units[unitIndex]}';
}
