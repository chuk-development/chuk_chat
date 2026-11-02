import 'entities.dart';
import 'rrule.dart';
import 'time_utils.dart';

/// One drawn occurrence of an event (a recurring event yields many).
class EventOccurrence {
  final CalendarEvent event;
  final DateTime start;
  final DateTime end;

  const EventOccurrence(this.event, this.start, this.end);

  bool get isRecurringInstance => event.isRecurring && !event.isException;
}

/// Port of the app's `calendarItemsProvider` event logic: expands recurring
/// events inside [rangeStart, rangeEnd), drops occurrences replaced by an
/// exception (matched by the exception's original date), hides deleted
/// occurrences, and keeps plain events overlapping the range.
List<EventOccurrence> expandEvents(
  Iterable<CalendarEvent> events,
  DateTime rangeStart,
  DateTime rangeEnd,
) {
  final exceptionsByParent = <String, Set<String>>{};
  for (final e in events) {
    if (e.isException && e.originalStartTime != null) {
      final date = DateTime.tryParse(e.originalStartTime!);
      if (date != null) {
        exceptionsByParent.putIfAbsent(e.recurrenceId!, () => {}).add(dateKey(date));
      }
    }
  }

  final out = <EventOccurrence>[];
  for (final e in events) {
    if (e.isDeletedOccurrence) continue;
    if (e.isRecurring && !e.isException) {
      final starts = RRuleHelper.expandOccurrences(
        e.startTime,
        e.recurrenceRule!,
        rangeStart,
        rangeEnd,
        excludedDates: exceptionsByParent[e.id],
      );
      for (final s in starts) {
        // The app's expander may return the series start for an unparsable
        // rule; keep only what really falls into the range.
        if (s.isBefore(rangeEnd) && s.add(e.duration).isAfter(rangeStart)) {
          out.add(EventOccurrence(e, s, s.add(e.duration)));
        }
      }
    } else if (e.startTime.isBefore(rangeEnd) && e.endTime.isAfter(rangeStart)) {
      out.add(EventOccurrence(e, e.startTime, e.endTime));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}
