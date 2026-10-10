// OpenUI Select, DatePicker and Slider.
//
// Select opens the app's one dropdown surface (`showAnchoredMenu` with
// `MenuActionRow` tiles). DatePicker opens the Material date pickers in
// the app theme. Slider is the Material slider (a range slider when the
// value has two numbers).
//
// Stored values: Select a `String`; DatePicker `"YYYY-MM-DD"` (single)
// or `{from: "YYYY-MM-DD", to: "YYYY-MM-DD"}` (range); Slider a list of
// numbers (`[2500]` or `[20, 80]`), as upstream.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/openui/components/forms_buttons/field.dart';
import 'package:chuk_chat/openui/components/forms_buttons/form.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

// ---------------------------------------------------------------------
// The tappable field box (Select, DatePicker)
// ---------------------------------------------------------------------

/// A field-shaped button: the filled field look, a text or a
/// placeholder, an optional leading icon, and a trailing icon.
class OpenUiFieldButton extends StatefulWidget {
  /// Creates a field button.
  const OpenUiFieldButton({
    required this.text,
    required this.placeholder,
    required this.trailing,
    required this.onTap,
    this.leading,
    this.hasError = false,
    this.open = false,
    this.verticalPadding = 13,
    this.semanticsLabel,
    super.key,
  });

  /// The value text, or `null` to show [placeholder].
  final String? text;

  /// Shown when [text] is `null`.
  final String placeholder;

  /// The icon at the end.
  final HugeIconData trailing;

  /// The icon at the start, or `null`.
  final HugeIconData? leading;

  /// Called with the context of the box. `null` disables the box.
  final ValueChanged<BuildContext>? onTap;

  /// Whether to draw the error border.
  final bool hasError;

  /// Whether the menu or picker of the box is open (focus border).
  final bool open;

  /// The vertical padding of the text (the size of a `Select`).
  final double verticalPadding;

  /// The accessible label, when the text does not say enough.
  final String? semanticsLabel;

  @override
  State<OpenUiFieldButton> createState() => _OpenUiFieldButtonState();
}

class _OpenUiFieldButtonState extends State<OpenUiFieldButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final enabled = widget.onTap != null;
    final value = widget.text;
    final iconColor = enabled
        ? t.mutedColor
        : t.mutedColor.withValues(alpha: 0.5);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticsLabel,
      value: value ?? widget.placeholder,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: Builder(
          builder: (boxContext) => InkWell(
            borderRadius: kBorderRadiusField,
            onTap: enabled ? () => widget.onTap!(boxContext) : null,
            onFocusChange: (v) => setState(() => _focused = v),
            child: InputDecorator(
              isEmpty: value == null,
              isFocused: _focused || widget.open,
              decoration: openUiFieldDecoration(
                context,
                hint: widget.placeholder,
                hasError: widget.hasError,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: widget.verticalPadding,
                ),
                prefixIcon: widget.leading == null
                    ? null
                    : HugeIcon(widget.leading!, size: 18, color: iconColor),
                suffixIcon: HugeIcon(
                  widget.trailing,
                  size: 18,
                  color: iconColor,
                ),
              ).copyWith(enabled: enabled),
              child: Text(
                value ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodyStyle.copyWith(
                  fontSize: 15,
                  height: 1.35,
                  color: enabled
                      ? t.textColor
                      : t.textColor.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Select
// ---------------------------------------------------------------------

/// Builds `Select(name, items, placeholder?, rules?, value?, size?)`.
Widget buildOpenUiSelect(BuildContext context, OpenUiProps props) =>
    OpenUiSelectView(props: props);

/// The `Select` field.
class OpenUiSelectView extends StatefulWidget {
  /// Creates a select from its props.
  const OpenUiSelectView({required this.props, super.key});

  /// The component props.
  final OpenUiProps props;

  @override
  State<OpenUiSelectView> createState() => _OpenUiSelectViewState();
}

class _OpenUiSelectViewState extends State<OpenUiSelectView>
    with OpenUiFieldStateMixin<OpenUiSelectView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final field = resolveField(
      context,
      props,
      validationValue: (v) => _asValue(v),
    );
    final items = <({String value, String label})>[
      for (final item in props.data('items', type: 'SelectItem'))
        if (item.string('value').isNotEmpty)
          (
            value: item.string('value'),
            label: item.string('label').trim().isEmpty
                ? item.string('value')
                : item.string('label'),
          ),
    ];
    final current = _asValue(field.stored);
    String? text;
    if (current != null) {
      text = current;
      for (final item in items) {
        if (item.value == current) text = item.label;
      }
    }
    final placeholder = props.string('placeholder').trim();
    final padding = switch (props.choice('size', fallback: 'medium')) {
      'small' => 9.0,
      'large' => 17.0,
      _ => 13.0,
    };
    return OpenUiFieldButton(
      text: text,
      placeholder: placeholder.isEmpty
          ? openUiStrings(context).openUiSelectPlaceholder
          : placeholder,
      trailing: HugeIcons.arrowDown01,
      hasError: field.error != null,
      open: _open,
      verticalPadding: padding,
      onTap: field.enabled && items.isNotEmpty
          ? (box) => _openMenu(box, field, items, current)
          : null,
    );
  }

  static String? _asValue(Object? v) {
    if (v is String) return v.isEmpty ? null : v;
    if (v is num) return '$v';
    return null;
  }

  Future<void> _openMenu(
    BuildContext box,
    OpenUiField field,
    List<({String value, String label})> items,
    String? current,
  ) async {
    final scheme = Theme.of(box).colorScheme;
    final width = box.size?.width ?? 240;
    setState(() => _open = true);
    final choice = await showAnchoredMenu<String>(
      box,
      color: scheme.surfaceContainerHigh,
      minWidth: math.max(width, 180),
      maxWidth: math.max(width, 360),
      outlined: true,
      items: <Widget>[
        for (final item in items)
          PopupMenuItem<String>(
            value: item.value,
            padding: EdgeInsets.zero,
            child: MenuActionRow(
              label: item.label,
              selected: item.value == current,
              maxLines: 2,
            ),
          ),
      ],
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (choice == null) return;
    field.write(context, choice);
    field.validate(choice);
  }
}

// ---------------------------------------------------------------------
// DatePicker
// ---------------------------------------------------------------------

/// Builds `DatePicker(name, mode?, rules?, value?)`.
Widget buildOpenUiDatePicker(BuildContext context, OpenUiProps props) =>
    OpenUiDatePickerView(props: props);

/// The `DatePicker` field.
class OpenUiDatePickerView extends StatefulWidget {
  /// Creates a date picker from its props.
  const OpenUiDatePickerView({required this.props, super.key});

  /// The component props.
  final OpenUiProps props;

  @override
  State<OpenUiDatePickerView> createState() => _OpenUiDatePickerViewState();
}

class _OpenUiDatePickerViewState extends State<OpenUiDatePickerView>
    with OpenUiFieldStateMixin<OpenUiDatePickerView> {
  static final DateTime _first = DateTime(1900);
  static final DateTime _last = DateTime(2100, 12, 31);
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final range = props.choice('mode', fallback: 'single') == 'range';
    final field = resolveField(
      context,
      props,
      validationValue: (v) =>
          range ? _readRange(v)?.toStored() : _readDay(v)?.toStored(),
    );
    String fmt(DateTime d) => _formatDay(context, d);
    String? text;
    if (range) {
      final r = _readRange(field.stored);
      if (r != null) {
        text = '${fmt(r.start)} – ${fmt(r.end)}';
      }
    } else {
      final d = _readDay(field.stored);
      if (d != null) text = fmt(d.date);
    }
    return OpenUiFieldButton(
      text: text,
      placeholder: range
          ? openUiStrings(context).openUiPickDateRange
          : openUiStrings(context).openUiPickDate,
      leading: HugeIcons.calendar01,
      trailing: HugeIcons.arrowDown01,
      hasError: field.error != null,
      open: _open,
      onTap: field.enabled ? (_) => _pick(field, range) : null,
    );
  }

  Future<void> _pick(OpenUiField field, bool range) async {
    setState(() => _open = true);
    Object? stored;
    try {
      if (range) {
        final current = _readRange(field.stored);
        final picked = await showDateRangePicker(
          context: context,
          firstDate: _first,
          lastDate: _last,
          initialDateRange: current == null
              ? null
              : DateTimeRange(start: current.start, end: current.end),
          builder: _themed,
        );
        if (picked != null) {
          stored = _Range(picked.start, picked.end).toStored();
        }
      } else {
        final current = _readDay(field.stored)?.date;
        final now = DateUtils.dateOnly(DateTime.now());
        final picked = await showDatePicker(
          context: context,
          firstDate: _first,
          lastDate: _last,
          initialDate: current ?? now,
          builder: _themed,
        );
        if (picked != null) stored = _Day(picked).toStored();
      }
    } finally {
      if (mounted) setState(() => _open = false);
    }
    if (!mounted || stored == null) return;
    field.write(context, stored);
    field.validate(stored);
  }

  /// The pickers in the app look: the dialog surface and radius, no
  /// tint, no shadow.
  Widget _themed(BuildContext context, Widget? child) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kRadiusDialog),
    );
    return Theme(
      data: theme.copyWith(
        datePickerTheme: theme.datePickerTheme.copyWith(
          backgroundColor: scheme.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: shape,
          headerBackgroundColor: scheme.surfaceContainerHigh,
          headerForegroundColor: scheme.onSurface,
          rangePickerBackgroundColor: scheme.surface,
          rangePickerSurfaceTintColor: Colors.transparent,
          rangePickerShadowColor: Colors.transparent,
          rangePickerHeaderBackgroundColor: scheme.surface,
          rangePickerHeaderForegroundColor: scheme.onSurface,
          rangeSelectionBackgroundColor: scheme.primary.withValues(alpha: 0.18),
          dividerColor: OpenUiTheme.of(context).hairline,
        ),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }

  /// `Mar 2, 2026` in the locale of the app. Falls back to the
  /// Material short date when intl has no data for the locale.
  static String _formatDay(BuildContext context, DateTime d) {
    try {
      final locale = Localizations.maybeLocaleOf(context)?.toLanguageTag();
      return DateFormat.yMMMd(locale).format(d);
    } on Object {
      return MaterialLocalizations.of(context).formatShortDate(d);
    }
  }

  static _Day? _readDay(Object? v) {
    if (v is String) {
      final d = DateTime.tryParse(v.trim());
      return d == null ? null : _Day(d);
    }
    if (v is Map) return _readDay(v['from'] ?? v['start'] ?? v['date']);
    if (v is List && v.isNotEmpty) return _readDay(v.first);
    return null;
  }

  static _Range? _readRange(Object? v) {
    Object? a;
    Object? b;
    if (v is Map) {
      a = v['from'] ?? v['start'];
      b = v['to'] ?? v['end'];
    } else if (v is List && v.isNotEmpty) {
      a = v.first;
      b = v.length > 1 ? v[1] : null;
    } else {
      a = v;
    }
    final start = _readDay(a)?.date;
    if (start == null) return null;
    final end = _readDay(b)?.date ?? start;
    return end.isBefore(start) ? _Range(end, start) : _Range(start, end);
  }
}

class _Day {
  _Day(DateTime d) : date = DateUtils.dateOnly(d);

  final DateTime date;

  String toStored() => _iso(date);
}

class _Range {
  _Range(DateTime a, DateTime b)
    : start = DateUtils.dateOnly(a),
      end = DateUtils.dateOnly(b);

  final DateTime start;
  final DateTime end;

  Map<String, Object?> toStored() => <String, Object?>{
    'from': _iso(start),
    'to': _iso(end),
  };
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------------
// Slider
// ---------------------------------------------------------------------

/// Builds `Slider(name, variant, min, max, step?, defaultValue?, label?,
/// rules?, value?)`.
Widget buildOpenUiSlider(BuildContext context, OpenUiProps props) =>
    OpenUiSliderView(props: props);

/// The `Slider` field.
class OpenUiSliderView extends StatefulWidget {
  /// Creates a slider from its props.
  const OpenUiSliderView({required this.props, super.key});

  /// The component props.
  final OpenUiProps props;

  @override
  State<OpenUiSliderView> createState() => _OpenUiSliderViewState();
}

class _OpenUiSliderViewState extends State<OpenUiSliderView>
    with OpenUiFieldStateMixin<OpenUiSliderView> {
  /// The values while a thumb moves; `null` when idle.
  List<double>? _drag;

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final t = OpenUiTheme.of(context);
    final min = props.number('min');
    var max = props.number('max', fallback: min + 100);
    if (!(max > min)) max = min + 1;
    var step = props.numberOrNull('step');
    if (step != null && step <= 0) step = null;
    final discrete =
        props.choice('variant', fallback: 'continuous') == 'discrete';
    if (discrete && step == null) step = (max - min) <= 100 ? 1 : null;
    int? divisions;
    if (step != null) {
      final d = ((max - min) / step).round();
      if (d >= 1 && d <= 1000) divisions = d;
    }

    final defaults = _numbers(props.raw('defaultValue'));
    final field = resolveField(
      context,
      props,
      startValue: defaults.isEmpty ? null : _clean(defaults, min, max),
    );
    final stored = _numbers(field.stored);
    final base = stored.isNotEmpty
        ? stored
        : defaults.isNotEmpty
        ? defaults
        : <double>[min];
    final values = _drag ?? _clamp(base, min, max);
    final isRange = values.length >= 2;
    final label = props.string('label').trim();
    final fractionDigits = _digits(step ?? ((max - min) <= 10 ? 0.1 : 1));
    String fmt(double v) => _format(v, fractionDigits);
    final valueText = isRange
        ? '${fmt(values[0])} – ${fmt(values[1])}'
        : fmt(values[0]);

    void commit(List<double> next) {
      final out = _clean(next, min, max, fractionDigits);
      setState(() => _drag = null);
      field.write(context, out);
      field.validate(out);
    }

    final slider = isRange
        ? RangeSlider(
            values: RangeValues(values[0], math.max(values[0], values[1])),
            min: min,
            max: max,
            divisions: divisions,
            labels: RangeLabels(fmt(values[0]), fmt(values[1])),
            onChanged: field.enabled
                ? (r) => setState(() => _drag = <double>[r.start, r.end])
                : null,
            onChangeEnd: field.enabled
                ? (r) => commit(<double>[r.start, r.end])
                : null,
          )
        : Slider(
            value: values[0],
            min: min,
            max: max,
            divisions: divisions,
            label: fmt(values[0]),
            semanticFormatterCallback: fmt,
            onChanged: field.enabled
                ? (v) => setState(() => _drag = <double>[v])
                : null,
            onChangeEnd: field.enabled ? (v) => commit(<double>[v]) : null,
          );

    final caption = t.captionStyle.copyWith(fontSize: 12);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Expanded(
              child: label.isEmpty
                  ? const SizedBox.shrink()
                  : Text(
                      label,
                      style: t.bodyStyle.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
            Text(
              valueText,
              style: t.bodyStyle.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            showValueIndicator: ShowValueIndicator.onlyForDiscrete,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: slider,
          ),
        ),
        Row(
          children: <Widget>[
            Text(fmt(min), style: caption),
            const Spacer(),
            Text(fmt(max), style: caption),
          ],
        ),
      ],
    );
  }

  static List<double> _numbers(Object? v) {
    if (v is num) return v.isFinite ? <double>[v.toDouble()] : <double>[];
    if (v is String) {
      final n = double.tryParse(v.trim());
      return n == null || !n.isFinite ? <double>[] : <double>[n];
    }
    if (v is List) {
      return <double>[for (final e in v.take(2)) ..._numbers(e)];
    }
    return <double>[];
  }

  static List<double> _clamp(List<double> v, double min, double max) =>
      <double>[for (final e in v.take(2)) e.clamp(min, max)];

  /// The values as stored: clamped, rounded, whole numbers as `int`.
  static List<num> _clean(
    List<double> v,
    double min,
    double max, [
    int digits = 2,
  ]) {
    return <num>[for (final e in _clamp(v, min, max)) _round(e, digits)];
  }

  static num _round(double v, int digits) {
    final f = math.pow(10, digits).toDouble();
    final r = (v * f).roundToDouble() / f;
    return r == r.roundToDouble() && r.abs() < 1e15 ? r.toInt() : r;
  }

  static int _digits(double step) {
    if (step == step.roundToDouble()) return 0;
    final text = step.toString();
    final dot = text.indexOf('.');
    if (dot < 0 || text.contains('e')) return 2;
    return math.min(text.length - dot - 1, 4);
  }

  static String _format(double v, int digits) {
    final r = _round(v, digits);
    if (r is int) {
      return _group(r);
    }
    return (r as double).toStringAsFixed(digits);
  }

  static String _group(int v) {
    final s = v.abs().toString();
    if (s.length <= 4) return v.toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
      out.write(s[i]);
    }
    return v < 0 ? '-$out' : out.toString();
  }
}
