// lib/platform_specific/chat/voice/voice_record_placement.dart
//
// Where the call records of a chat go in its message list. Display only: the
// records never enter the message list itself, so they are never written into
// the encrypted chat payload and never sent to a host.

/// The records of a chat, placed against its message rows.
///
/// A record is drawn above the message at its key in [beforeIndex], or under
/// the last message when it is in [trailing]. The message rows keep their
/// indices, so every per-row action (edit, retry, day divider, run grouping)
/// reads the list exactly as before.
class VoiceRecordPlacement<T> {
  const VoiceRecordPlacement({required this.beforeIndex, required this.trailing});

  static VoiceRecordPlacement<T> empty<T>() =>
      VoiceRecordPlacement<T>(beforeIndex: <int, List<T>>{}, trailing: <T>[]);

  /// Records to draw above message `i`, in time order.
  final Map<int, List<T>> beforeIndex;

  /// Records that come after every dated message, in time order.
  final List<T> trailing;

  bool get isEmpty => beforeIndex.isEmpty && trailing.isEmpty;

  /// The records above message [index].
  List<T> before(int index) => beforeIndex[index] ?? const <Never>[];
}

/// Merges [records] into a message list by time.
///
/// [messageTimes] holds the time of each message row, in list order; null
/// for a row without a stamp. A record goes above the first row that is
/// strictly later than the record's own time ([timeOf]).
///
/// An undated row counts as written with the next dated row after it: the
/// list is in time order, and the usual undated row is a question whose
/// answer (stamped when its turn started) follows at once. So a call never
/// lands between a question and its answer. Undated rows after the last
/// dated one stay undated, and a record later than every dated row goes to
/// [VoiceRecordPlacement.trailing].
VoiceRecordPlacement<T> placeRecordsByTime<T>({
  required List<DateTime?> messageTimes,
  required List<T> records,
  required DateTime Function(T record) timeOf,
}) {
  if (records.isEmpty) return VoiceRecordPlacement.empty<T>();
  final List<T> sorted = List<T>.of(records)
    ..sort((T a, T b) => timeOf(a).compareTo(timeOf(b)));
  // Each undated row takes the time of the next dated row after it.
  final List<DateTime?> times = List<DateTime?>.of(messageTimes);
  DateTime? following;
  for (int i = times.length - 1; i >= 0; i--) {
    times[i] ??= following;
    following = times[i];
  }
  final Map<int, List<T>> before = <int, List<T>>{};
  int next = 0;
  for (int i = 0; i < times.length && next < sorted.length; i++) {
    final DateTime? at = times[i];
    if (at == null) continue;
    while (next < sorted.length && timeOf(sorted[next]).isBefore(at)) {
      (before[i] ??= <T>[]).add(sorted[next]);
      next++;
    }
  }
  return VoiceRecordPlacement<T>(
    beforeIndex: before,
    trailing: sorted.sublist(next),
  );
}

/// One entry of the merged timeline: a message index or a record. Used by
/// tests and by any caller that wants a flat view of [placement].
List<Object> flattenPlacement<T extends Object>(
  int messageCount,
  VoiceRecordPlacement<T> placement,
) {
  final List<Object> out = <Object>[];
  for (int i = 0; i < messageCount; i++) {
    out.addAll(placement.before(i));
    out.add(i);
  }
  out.addAll(placement.trailing);
  return out;
}
