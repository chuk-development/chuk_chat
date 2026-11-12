/// The time column of a roster row, like a messenger: a clock time today,
/// "Yesterday", the weekday inside a week, a short date after that. Empty
/// when there is no time. The phone inbox and the desktop roster both use it,
/// so one agent shows the same label on both.
String rosterTimeLabel(
  DateTime? when, {
  required DateTime now,
  bool alwaysUse24HourFormat = false,
}) {
  if (when == null) return '';
  final DateTime day = DateTime(when.year, when.month, when.day);
  final DateTime today = DateTime(now.year, now.month, now.day);
  final int days = today.difference(day).inDays;
  if (days <= 0) {
    final String mm = when.minute.toString().padLeft(2, '0');
    if (alwaysUse24HourFormat) {
      return '${when.hour.toString().padLeft(2, '0')}:$mm';
    }
    final int h12 = when.hour % 12 == 0 ? 12 : when.hour % 12;
    return '$h12:$mm ${when.hour < 12 ? 'AM' : 'PM'}';
  }
  if (days == 1) return 'Yesterday';
  if (days < 7) {
    const List<String> names = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    return names[when.weekday - 1];
  }
  return '${when.day}.${when.month}.';
}
