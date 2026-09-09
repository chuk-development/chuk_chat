/// Safely parse a coordinate value that may be num or String.
double toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}

/// Format milliseconds duration as mm:ss string.
String formatDuration(int ms) {
  final duration = Duration(milliseconds: ms);
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Truncate text with ellipsis if it exceeds maxLength.
String truncate(String text, int maxLength) {
  if (text.length <= maxLength) return text;
  return '${text.substring(0, maxLength)}...';
}
