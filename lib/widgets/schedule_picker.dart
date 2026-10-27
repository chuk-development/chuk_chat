// lib/widgets/schedule_picker.dart
//
// The schedule of a routine, picked instead of typed (bead chuk_chat-4p90):
// every day at a time, on chosen weekdays at a time, every N hours, or a
// custom line for anything else. The picker writes the host's spec into
// [SchedulePicker.controller] on every change, so the editor sends what it
// always sent (`lib/services/automations/simple_schedule.dart`).
//
// One choice control (the `ConnectedGroup` pill), the Material time picker,
// and the app's own icon buttons; no glow (docs/DESIGN.md).

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/schedule_spec.dart';
import 'package:chuk_chat/services/automations/simple_schedule.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

const List<SimpleScheduleMode> _modes = <SimpleScheduleMode>[
  SimpleScheduleMode.daily,
  SimpleScheduleMode.weekdays,
  SimpleScheduleMode.everyHours,
  SimpleScheduleMode.custom,
];

class SchedulePicker extends StatefulWidget {
  const SchedulePicker({
    super.key,
    required this.controller,
    required this.customField,
    this.onChanged,
    this.errorText,
    this.now,
  });

  /// The editor's refusal of the schedule (no day picked). The custom field
  /// shows its own.
  final String? errorText;

  /// Holds the spec. Read once for the start state, written on every change.
  final TextEditingController controller;

  /// The text field for a custom schedule (the editor's own field, with its
  /// error line). It edits [controller] directly.
  final Widget customField;

  /// Called after every change the picker made.
  final VoidCallback? onChanged;

  /// "Now" for the next-run line; tests pin it.
  final DateTime Function()? now;

  @override
  State<SchedulePicker> createState() => _SchedulePickerState();
}

class _SchedulePickerState extends State<SchedulePicker> {
  late SimpleSchedule _value;

  /// The shape the picker had before custom, so a switch back keeps it.
  SimpleSchedule _lastPicked = SimpleSchedule.initial;

  @override
  void initState() {
    super.initState();
    final String text = widget.controller.text;
    _value = SimpleSchedule.fromSpec(text);
    if (_value.mode != SimpleScheduleMode.custom) _lastPicked = _value;
    // A new routine starts as "every day at 09:00", written out at once so
    // the editor's empty check and the save see the same spec.
    if (text.trim().isEmpty) _write(_value, notify: false);
  }

  void _write(SimpleSchedule next, {bool notify = true}) {
    _value = next;
    if (next.mode != SimpleScheduleMode.custom) {
      _lastPicked = next;
      final String spec = next.toSpec();
      if (widget.controller.text != spec) widget.controller.text = spec;
    }
    if (notify) {
      setState(() {});
      widget.onChanged?.call();
    }
  }

  void _selectMode(int index) {
    final SimpleScheduleMode mode = _modes[index];
    if (mode == _value.mode) return;
    if (mode == SimpleScheduleMode.custom) {
      // The custom field starts from the spec the picker made, so the user
      // edits from there instead of from nothing.
      _write(
        SimpleSchedule(
          mode: SimpleScheduleMode.custom,
          custom: widget.controller.text,
        ),
      );
      return;
    }
    // The last picked time and days survive a switch of shape.
    _write(_lastPicked.copyWith(mode: mode));
  }

  Future<void> _pickTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _value.hour, minute: _value.minute),
      initialEntryMode: TimePickerEntryMode.dial,
    );
    if (picked == null || !mounted) return;
    _write(_value.copyWith(hour: picked.hour, minute: picked.minute));
  }

  void _toggleDay(int day) {
    final Set<int> days = <int>{..._value.weekdays};
    if (!days.remove(day)) days.add(day);
    _write(_value.copyWith(weekdays: days));
  }

  void _stepHours(int delta) {
    final int next = (_value.everyHours + delta).clamp(
      kMinEveryHours,
      kMaxEveryHours,
    );
    _write(_value.copyWith(everyHours: next));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final List<Widget> body = switch (_value.mode) {
      SimpleScheduleMode.daily => <Widget>[_timeRow(context, l)],
      SimpleScheduleMode.weekdays => <Widget>[
        _dayRow(context, l),
        const SizedBox(height: 10),
        _timeRow(context, l),
      ],
      SimpleScheduleMode.everyHours => <Widget>[_hoursRow(context, l)],
      SimpleScheduleMode.custom => <Widget>[widget.customField],
    };
    final String? next = _value.mode == SimpleScheduleMode.custom
        ? null
        : _nextRun(context, l);
    return Column(
      key: const ValueKey<String>('schedule-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ConnectedGroup(
          key: const ValueKey<String>('schedule-mode'),
          margin: EdgeInsets.zero,
          labels: <String>[
            l.scheduleModeDaily,
            l.scheduleModeWeekdays,
            l.scheduleModeHours,
            l.scheduleModeCustom,
          ],
          selected: _modes.indexOf(_value.mode),
          onSelected: _selectMode,
        ),
        const SizedBox(height: 12),
        ...body,
        if (widget.errorText != null &&
            _value.mode != SimpleScheduleMode.custom)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              widget.errorText!,
              key: const ValueKey<String>('schedule-error'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          )
        else if (next != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              next,
              key: const ValueKey<String>('schedule-next-run'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 10),
      ],
    );
  }

  /// "Next: Tue, Oct 21, 09:00", from the app's own schedule maths.
  String? _nextRun(BuildContext context, AppLocalizations l) {
    final ScheduleSpec? spec = ScheduleSpec.tryParse(widget.controller.text);
    if (spec == null) return null;
    final DateTime now = (widget.now ?? DateTime.now)();
    final List<DateTime> runs = spec.nextRuns(now, count: 1);
    if (runs.isEmpty) return null;
    final DateTime at = runs.first;
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    final String when =
        '${m.formatMediumDate(at)}, '
        '${m.formatTimeOfDay(TimeOfDay.fromDateTime(at), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    return l.scheduleNextRun(when);
  }

  Widget _timeRow(BuildContext context, AppLocalizations l) {
    final ThemeData theme = Theme.of(context);
    final String time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: _value.hour, minute: _value.minute),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return MorphTap(
      key: const ValueKey<String>('schedule-time'),
      onTap: _pickTime,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          HugeIcon(
            HugeIcons.clock01,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l.scheduleAtTime,
              style: theme.textTheme.bodyLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            time,
            key: const ValueKey<String>('schedule-time-value'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayRow(BuildContext context, AppLocalizations l) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    // narrowWeekdays starts on Sunday, like cron; the row starts on the
    // locale's first day.
    final int first = m.firstDayOfWeekIndex;
    final List<int> order = <int>[for (int i = 0; i < 7; i++) (first + i) % 7];
    return Semantics(
      label: l.scheduleDaysLabel,
      child: Row(
        key: const ValueKey<String>('schedule-days'),
        children: <Widget>[
          for (final int day in order)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _DayToggle(
                    key: ValueKey<String>('schedule-day-$day'),
                    label: m.narrowWeekdays[day],
                    selected: _value.weekdays.contains(day),
                    scheme: scheme,
                    onTap: () => _toggleDay(day),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _hoursRow(BuildContext context, AppLocalizations l) {
    final ThemeData theme = Theme.of(context);
    final int n = _value.everyHours;
    return ExpressiveField(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              l.scheduleEveryHours(n),
              key: const ValueKey<String>('schedule-hours-value'),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ExpressiveIconButton(
            key: const ValueKey<String>('schedule-hours-minus'),
            hugeIcon: HugeIcons.minusSign,
            size: 44,
            tooltip: l.scheduleFewerHours,
            onTap: n > kMinEveryHours ? () => _stepHours(-1) : null,
          ),
          const SizedBox(width: 6),
          ExpressiveIconButton(
            key: const ValueKey<String>('schedule-hours-plus'),
            hugeIcon: HugeIcons.plusSign,
            size: 44,
            tooltip: l.scheduleMoreHours,
            onTap: n < kMaxEveryHours ? () => _stepHours(1) : null,
          ),
        ],
      ),
    );
  }
}

/// One weekday: a round toggle, filled with the accent when on.
class _DayToggle extends StatelessWidget {
  const _DayToggle({
    super.key,
    required this.label,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: MorphTap(
        onTap: onTap,
        color: selected ? scheme.primary : scheme.surfaceContainerLow,
        shape: const CircleBorder(),
        child: Center(
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
