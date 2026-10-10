// OpenUI choice fields: CheckBoxGroup, RadioGroup, SwitchGroup, Chips
// and OptionCards. Their items are data-only components that the group
// reads with `props.data`.
//
// Stored values (as upstream):
// - CheckBoxGroup, SwitchGroup: a map of item name to bool.
// - RadioGroup: the value of the chosen item.
// - Chips, OptionCards: a `String` (type single) or a list of strings
//   (type multiple).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/openui/components/forms_buttons/field.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// The height of the first text line of an option row. The control
/// (checkbox, radio) sits in a box this high, so it centres on it.
const double _kRowLine = 24;

TextStyle _optionLabelStyle(OpenUiTheme t, {bool enabled = true}) =>
    t.bodyStyle.copyWith(
      fontSize: 14.5,
      height: _kRowLine / 14.5,
      fontWeight: FontWeight.w500,
      color: enabled ? t.textColor : t.textColor.withValues(alpha: 0.5),
    );

TextStyle _optionDescriptionStyle(OpenUiTheme t) =>
    t.captionStyle.copyWith(fontSize: 12.5, height: 1.4);

/// One row of a check box or radio group: the control, then the label
/// and the description. The whole row is the tap target.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.control,
    required this.label,
    required this.description,
    required this.onTap,
    required this.enabled,
  });

  final Widget control;
  final String label;
  final String description;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(OpenUiTokens.radiusInner),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: _kRowLine,
              height: _kRowLine,
              child: Center(child: control),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(label, style: _optionLabelStyle(t, enabled: enabled)),
                  if (description.trim().isNotEmpty)
                    Text(description, style: _optionDescriptionStyle(t)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const VisualDensity _kDense = VisualDensity(horizontal: -4, vertical: -4);

/// Reads a stored map of name to bool. Anything else gives an empty map.
Map<String, bool> _boolMap(Object? v) {
  if (v is! Map) return const <String, bool>{};
  return <String, bool>{
    for (final e in v.entries)
      if (e.value is bool) e.key.toString(): e.value as bool,
  };
}

// ---------------------------------------------------------------------
// CheckBoxGroup and SwitchGroup
// ---------------------------------------------------------------------

/// Builds `CheckBoxGroup(name, items, rules?, value?)`.
Widget buildOpenUiCheckBoxGroup(BuildContext context, OpenUiProps props) =>
    OpenUiToggleGroupView(props: props, switches: false);

/// Builds `SwitchGroup(name, items, variant?, value?)`.
Widget buildOpenUiSwitchGroup(BuildContext context, OpenUiProps props) =>
    OpenUiToggleGroupView(props: props, switches: true);

/// A group of on/off items: check boxes or switches.
class OpenUiToggleGroupView extends StatefulWidget {
  /// Creates the group from its props.
  const OpenUiToggleGroupView({
    required this.props,
    required this.switches,
    super.key,
  });

  /// The component props.
  final OpenUiProps props;

  /// `SwitchGroup` when true, else `CheckBoxGroup`.
  final bool switches;

  @override
  State<OpenUiToggleGroupView> createState() => _OpenUiToggleGroupViewState();
}

class _OpenUiToggleGroupViewState extends State<OpenUiToggleGroupView>
    with OpenUiFieldStateMixin<OpenUiToggleGroupView> {
  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final itemType = widget.switches ? 'SwitchItem' : 'CheckBoxItem';
    final items = <({String name, String label, String description, bool on})>[
      for (final item in props.data('items', type: itemType))
        if (item.string('name').trim().isNotEmpty)
          (
            name: item.string('name').trim(),
            label: item.string('label').trim().isEmpty
                ? item.string('name').trim()
                : item.string('label'),
            description: item.string('description'),
            on: item.boolean('defaultChecked'),
          ),
    ];
    final defaults = <String, bool>{for (final i in items) i.name: i.on};
    final field = resolveField(
      context,
      props,
      startValue: items.isEmpty ? null : defaults,
    );
    if (items.isEmpty) return const SizedBox.shrink();
    Map<String, bool> aggregate(Object? raw) {
      final stored = _boolMap(raw);
      return <String, bool>{
        for (final i in items) i.name: stored[i.name] ?? i.on,
      };
    }

    void toggle(String name, bool value) {
      final next = aggregate(field.latest(context))..[name] = value;
      field.write(context, next);
      field.validate(next);
    }

    final t = OpenUiTheme.of(context);
    final current = aggregate(field.stored);
    final rows = <Widget>[
      for (final item in items)
        widget.switches
            ? _SwitchRow(
                label: item.label,
                description: item.description,
                value: current[item.name] ?? false,
                enabled: field.enabled,
                onChanged: (v) => toggle(item.name, v),
              )
            : _OptionRow(
                enabled: field.enabled,
                label: item.label,
                description: item.description,
                onTap: () => toggle(
                  item.name,
                  !(aggregate(field.latest(context))[item.name] ?? false),
                ),
                control: Checkbox(
                  value: current[item.name] ?? false,
                  visualDensity: _kDense,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: BorderSide(
                    color: field.error != null ? t.danger : t.mutedColor,
                    width: 1.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                  semanticLabel: item.label,
                  onChanged: field.enabled
                      ? (v) => toggle(item.name, v ?? false)
                      : null,
                ),
              ),
    ];
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
    if (!widget.switches) return column;
    final variant = props.choice('variant', fallback: 'clear');
    if (variant == 'clear') return column;
    return DecoratedBox(
      decoration: t.cardDecoration(
        variant: variant,
        radius: OpenUiTokens.radiusCard,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: column,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.description,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(OpenUiTokens.radiusInner),
        onTap: enabled ? () => onChanged(!value) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (label.trim().isNotEmpty)
                      Text(
                        label,
                        style: _optionLabelStyle(t, enabled: enabled),
                      ),
                    if (description.trim().isNotEmpty)
                      Text(description, style: _optionDescriptionStyle(t)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: value,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: enabled ? onChanged : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// RadioGroup
// ---------------------------------------------------------------------

/// Builds `RadioGroup(name, items, defaultValue?, rules?, value?)`.
Widget buildOpenUiRadioGroup(BuildContext context, OpenUiProps props) =>
    OpenUiRadioGroupView(props: props);

/// The `RadioGroup` field.
class OpenUiRadioGroupView extends StatefulWidget {
  /// Creates a radio group from its props.
  const OpenUiRadioGroupView({required this.props, super.key});

  /// The component props.
  final OpenUiProps props;

  @override
  State<OpenUiRadioGroupView> createState() => _OpenUiRadioGroupViewState();
}

class _OpenUiRadioGroupViewState extends State<OpenUiRadioGroupView>
    with OpenUiFieldStateMixin<OpenUiRadioGroupView> {
  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final items = <({String value, String label, String description})>[
      for (final item in props.data('items', type: 'RadioItem'))
        if (item.string('value').isNotEmpty)
          (
            value: item.string('value'),
            label: item.string('label').trim().isEmpty
                ? item.string('value')
                : item.string('label'),
            description: item.string('description'),
          ),
    ];
    final fallback = props.stringOrNull('defaultValue');
    final field = resolveField(
      context,
      props,
      startValue: fallback == null || fallback.isEmpty ? null : fallback,
    );
    if (items.isEmpty) return const SizedBox.shrink();
    final stored = field.stored;
    final current = stored is String && stored.isNotEmpty
        ? stored
        : stored is num
        ? '$stored'
        : fallback;

    void choose(String? value) {
      if (value == null || !field.enabled) return;
      field.write(context, value);
      field.validate(value);
    }

    final t = OpenUiTheme.of(context);
    return RadioGroup<String>(
      groupValue: current,
      onChanged: choose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final item in items)
            _OptionRow(
              enabled: field.enabled,
              label: item.label,
              description: item.description,
              onTap: () => choose(item.value),
              control: Radio<String>(
                value: item.value,
                enabled: field.enabled,
                visualDensity: _kDense,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                fillColor: field.error != null && current == null
                    ? WidgetStatePropertyAll<Color>(t.danger)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Chips and OptionCards (shared selection logic)
// ---------------------------------------------------------------------

/// The selection as a list, from the stored value or else the default
/// (upstream `normalizeSelection`).
List<String> _selection(bool multiple, Object? stored, Object? fallback) {
  List<String> strings(Object? v) => <String>[
    if (v is String && v.isNotEmpty) v,
    if (v is List)
      for (final e in v)
        if (e is String && e.isNotEmpty) e,
  ];
  final fromStored = stored == null ? null : strings(stored);
  final picked = fromStored ?? strings(fallback);
  if (!multiple) return picked.isEmpty ? <String>[] : <String>[picked.first];
  return picked;
}

/// The value to store for a selection. An empty single selection is
/// `""`, not `null`, so the default does not come back.
Object? _storedSelection(bool multiple, List<String> selection) => multiple
    ? List<String>.unmodifiable(selection)
    : (selection.isEmpty ? '' : selection.first);

List<String> _toggle(bool multiple, List<String> selection, String value) {
  if (!multiple) {
    return selection.isNotEmpty && selection.first == value
        ? <String>[]
        : <String>[value];
  }
  return selection.contains(value)
      ? <String>[
          for (final s in selection)
            if (s != value) s,
        ]
      : <String>[...selection, value];
}

/// Shared state of `Chips` and `OptionCards`.
mixin _SelectionField<W extends StatefulWidget>
    on State<W>, OpenUiFieldStateMixin<W> {
  ({OpenUiField field, bool multiple, List<String> selection}) resolveSelection(
    BuildContext context,
    OpenUiProps props,
  ) {
    final multiple = props.choice('type', fallback: 'single') == 'multiple';
    final fallback = props.raw('defaultValue');
    final start = _selection(multiple, null, fallback);
    final field = resolveField(
      context,
      props,
      startValue: fallback == null ? null : _storedSelection(multiple, start),
      validationValue: (v) {
        final s = _selection(multiple, v, fallback);
        return s.isEmpty ? null : _storedSelection(multiple, s);
      },
    );
    return (
      field: field,
      multiple: multiple,
      selection: _selection(multiple, field.stored, fallback),
    );
  }

  void toggleSelection(
    OpenUiField field,
    bool multiple,
    Object? fallback,
    String value,
  ) {
    if (!field.enabled) return;
    final selection = _selection(multiple, field.latest(context), fallback);
    final next = _toggle(multiple, selection, value);
    field.write(context, _storedSelection(multiple, next));
    field.validate(next.isEmpty ? null : _storedSelection(multiple, next));
  }
}

// ---------------------------------------------------------------------
// Chips
// ---------------------------------------------------------------------

/// Builds `Chips(name, type?, items?, rules?, defaultValue?)`.
Widget buildOpenUiChips(BuildContext context, OpenUiProps props) =>
    OpenUiChipsView(props: props);

/// The `Chips` field: a wrap of selectable pills.
class OpenUiChipsView extends StatefulWidget {
  /// Creates the chips from their props.
  const OpenUiChipsView({required this.props, super.key});

  /// The component props.
  final OpenUiProps props;

  @override
  State<OpenUiChipsView> createState() => _OpenUiChipsViewState();
}

class _OpenUiChipsViewState extends State<OpenUiChipsView>
    with
        OpenUiFieldStateMixin<OpenUiChipsView>,
        _SelectionField<OpenUiChipsView> {
  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final s = resolveSelection(context, props);
    final items = props
        .data('items', type: 'ChipItem')
        .where((i) => i.string('value').isNotEmpty)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final item in items)
          _Chip(
            label: item.string('label').trim().isEmpty
                ? item.string('value')
                : item.string('label'),
            icon: item.child('icon'),
            selected: s.selection.contains(item.string('value')),
            multiple: s.multiple,
            hasError: s.field.error != null,
            enabled: s.field.enabled && !item.boolean('disabled'),
            onTap: () => toggleSelection(
              s.field,
              s.multiple,
              props.raw('defaultValue'),
              item.string('value'),
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.multiple,
    required this.hasError,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final Widget? icon;
  final bool selected;
  final bool multiple;
  final bool hasError;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final scheme = t.scheme;
    final fill = selected
        ? scheme.primary
        : hasError
        ? t.statusFill('error')
        : t.sunkColor;
    final fg = selected ? scheme.onPrimary : t.textColor;
    final leading = icon != null
        ? icon!
        : (selected && multiple)
        ? HugeIcon(HugeIcons.tick02, size: 16, color: fg)
        : null;
    final chip = MorphTap(
      onTap: enabled ? onTap : null,
      color: fill,
      pressedColor: selected ? null : scheme.secondaryContainer,
      padding: EdgeInsets.fromLTRB(leading == null ? 14 : 10, 8, 14, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            IconTheme.merge(
              data: IconThemeData(color: fg, size: 16),
              child: SizedBox(
                height: 18,
                child: Center(widthFactor: 1, child: leading),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 13.5,
                height: 18 / 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Opacity(opacity: enabled ? 1 : 0.45, child: chip),
    );
  }
}

// ---------------------------------------------------------------------
// OptionCards
// ---------------------------------------------------------------------

/// Builds `OptionCards(name, type?, items?, rules?, defaultValue?)`.
Widget buildOpenUiOptionCards(BuildContext context, OpenUiProps props) =>
    OpenUiOptionCardsView(props: props);

/// The `OptionCards` field: selectable cards in a responsive grid.
class OpenUiOptionCardsView extends StatefulWidget {
  /// Creates the cards from their props.
  const OpenUiOptionCardsView({required this.props, super.key});

  /// The component props.
  final OpenUiProps props;

  @override
  State<OpenUiOptionCardsView> createState() => _OpenUiOptionCardsViewState();
}

class _OpenUiOptionCardsViewState extends State<OpenUiOptionCardsView>
    with
        OpenUiFieldStateMixin<OpenUiOptionCardsView>,
        _SelectionField<OpenUiOptionCardsView> {
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final s = resolveSelection(context, props);
    final items = props
        .data('items', type: 'OptionCard')
        .where((i) => i.string('value').isNotEmpty)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 360.0;
        var columns = width >= 600
            ? 3
            : width >= 300
            ? 2
            : 1;
        columns = math.max(1, math.min(columns, items.length));
        final cellWidth = ((width - _gap * (columns - 1)) / columns)
            .floorToDouble();
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: <Widget>[
            for (final item in items)
              SizedBox(
                width: cellWidth,
                child: _OptionCard(
                  title: item.string('title').trim().isEmpty
                      ? item.string('value')
                      : item.string('title'),
                  subtitle: item.string('subtitle'),
                  top: item.child('topContent'),
                  selected: s.selection.contains(item.string('value')),
                  multiple: s.multiple,
                  hasError: s.field.error != null,
                  enabled: s.field.enabled && !item.boolean('disabled'),
                  onTap: () => toggleSelection(
                    s.field,
                    s.multiple,
                    props.raw('defaultValue'),
                    item.string('value'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.title,
    required this.subtitle,
    required this.top,
    required this.selected,
    required this.multiple,
    required this.hasError,
    required this.enabled,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget? top;
  final bool selected;
  final bool multiple;
  final bool hasError;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final scheme = t.scheme;
    final radius = BorderRadius.circular(OpenUiTokens.radiusCard);
    final accentText = Theme.of(context).accentForegroundOn(t.cardColor);
    final borderColor = selected
        ? scheme.primary
        : hasError
        ? t.danger
        : t.borderColor;
    final fill = selected
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: t.isDark ? 0.16 : 0.10),
            t.cardColor,
          )
        : t.cardColor;

    final indicator = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : Colors.transparent,
        shape: multiple ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: multiple ? BorderRadius.circular(7) : null,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outline,
          width: 1.5,
        ),
      ),
      child: selected
          ? Center(
              child: HugeIcon(
                HugeIcons.tick02,
                size: 14,
                color: scheme.onPrimary,
              ),
            )
          : null,
    );

    final titleText = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: t.bodyStyle.copyWith(
        fontSize: 14.5,
        height: 1.3,
        fontWeight: FontWeight.w700,
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: top == null
                  ? titleText
                  : Align(
                      alignment: AlignmentDirectional.topStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            OpenUiTokens.radiusInner,
                          ),
                          child: IconTheme.merge(
                            data: IconThemeData(color: accentText, size: 24),
                            child: top!,
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            indicator,
          ],
        ),
        if (top != null) ...<Widget>[const SizedBox(height: 10), titleText],
        if (subtitle.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: t.captionStyle.copyWith(fontSize: 12.5, height: 1.35),
          ),
        ],
      ],
    );

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: subtitle.trim().isEmpty ? title : '$title, $subtitle',
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: radius,
            border: Border.all(
              color: borderColor,
              width: selected ? 1.5 : OpenUiTokens.borderWidth,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: enabled ? onTap : null,
              child: Padding(padding: const EdgeInsets.all(12), child: body),
            ),
          ),
        ),
      ),
    );
  }
}
