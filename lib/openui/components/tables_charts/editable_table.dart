// EditableTable: a table whose cells the user edits inline.
//
// Column types: text, number, url (edited in place), date-single (the
// date picker) and select (the app's anchored menu). Every edit writes
// the whole table to the form state, under the table name, as
// `[{id, values: [...]}, ...]` (the upstream shape). Outside a `Form`
// the table is its own form with that name. "Save changes" sends
// "Save Changes" to the assistant with the form values, as upstream.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:openui_core/openui_core.dart'
    show implicitContinueConversationPlan;

import 'package:chuk_chat/openui/components/tables_charts/chart_common.dart';
import 'package:chuk_chat/openui/components/tables_charts/data_table.dart';
import 'package:chuk_chat/openui/openui_actions.dart';
import 'package:chuk_chat/openui/openui_props.dart';
import 'package:chuk_chat/openui/openui_strings.dart';
import 'package:chuk_chat/openui/openui_theme.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

/// The message a save sends, as upstream.
const String kEditableTableSaveMessage = 'Save Changes';

/// The column types upstream allows.
const List<String> _kTypes = <String>[
  'text',
  'number',
  'date-single',
  'select',
  'url',
];

@immutable
class _EColumn {
  const _EColumn({
    required this.type,
    required this.key,
    required this.header,
    required this.width,
    required this.options,
  });

  final String type;
  final String key;
  final String header;
  final double? width;
  final List<({String value, String label})> options;

  String labelOf(Object? v) {
    final s = tableCellText(v);
    for (final o in options) {
      if (o.value == s) return o.label;
    }
    return s;
  }
}

@immutable
class _ERow {
  const _ERow(this.id, this.values);

  final String id;
  final List<Object?> values;

  _ERow copyWith(int index, Object? value) {
    final v = List<Object?>.of(values);
    while (v.length <= index) {
      v.add(null);
    }
    v[index] = value;
    return _ERow(id, List<Object?>.unmodifiable(v));
  }

  Object? at(int i) => i < values.length ? values[i] : null;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'values': List<Object?>.of(values),
  };
}

List<_EColumn> _readColumns(OpenUiProps p) => <_EColumn>[
  for (final m in p.mapList('columns'))
    _EColumn(
      type: _kTypes.contains(m['type']) ? m['type']! as String : 'text',
      key: m['key'] is String ? m['key']! as String : 'default',
      header: tableCellText(m['header']),
      width: chartNumber(m['width']),
      options: <({String value, String label})>[
        if (m['options'] case final List<Object?> opts)
          for (final o in opts)
            if (o is Map && o['value'] != null)
              (
                value: tableCellText(o['value']),
                label: tableCellText(o['label'] ?? o['value']),
              ),
      ],
    ),
];

List<_ERow> _readRows(List<Object?> raw) {
  final out = <_ERow>[];
  for (var i = 0; i < raw.length; i++) {
    final m = raw[i];
    if (m is! Map) continue;
    final values = m['values'];
    final id = m['id'];
    out.add(
      _ERow(
        id == null ? 'row-${i + 1}' : tableCellText(id),
        List<Object?>.unmodifiable(<Object?>[
          if (values is List)
            for (final v in values)
              if (v is String || v is num || v is bool) v else null,
        ]),
      ),
    );
  }
  return out;
}

/// Builds `EditableTable(name?, columns?, data?)`.
Widget buildEditableTable(BuildContext context, OpenUiProps p) {
  final name = p.string('name').trim().isEmpty
      ? 'table'
      : p.string('name').trim();
  var columns = _readColumns(p);
  final rows = _readRows(p.list('data'));
  if (columns.isEmpty) {
    // Columns still streaming: show the values as text columns.
    var width = 0;
    for (final r in rows) {
      width = math.max(width, r.values.length);
    }
    columns = <_EColumn>[
      for (var c = 0; c < width; c++)
        _EColumn(
          type: 'text',
          key: 'col$c',
          header: '',
          width: null,
          options: const <({String value, String label})>[],
        ),
    ];
  }
  if (columns.isEmpty) return chartPlaceholder(context, p, 80);
  final table = _EditableTable(
    name: name,
    columns: columns,
    rows: rows,
    locked: chartIsStreaming(context, p),
  );
  if (OpenUiFormScope.maybeNameOf(context) != null) return table;
  return OpenUiFormScope(formName: name, child: table);
}

class _EditableTable extends StatefulWidget {
  const _EditableTable({
    required this.name,
    required this.columns,
    required this.rows,
    required this.locked,
  });

  final String name;
  final List<_EColumn> columns;
  final List<_ERow> rows;

  /// While the statement streams, the cells do not take edits.
  final bool locked;

  @override
  State<_EditableTable> createState() => _EditableTableState();
}

class _EditableTableState extends State<_EditableTable> {
  late List<_ERow> _rows = List<_ERow>.of(widget.rows);
  Map<String, _ERow>? _baseline;
  bool _readForm = false;

  // The cell being edited in place, or null.
  int? _editRow;
  int? _editCol;
  final TextEditingController _edit = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editRow != null) _commitText();
    });
    if (!widget.locked) _setBaseline(widget.rows);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_readForm) return;
    _readForm = true;
    // A value already in the form (the view was rebuilt) wins over the
    // program data, as upstream.
    final stored = OpenUiFormScope.formOf(context)?.value(widget.name);
    if (stored is List) {
      final rows = _readRows(stored);
      if (rows.isNotEmpty) _rows = rows;
    }
  }

  @override
  void didUpdateWidget(_EditableTable old) {
    super.didUpdateWidget(old);
    if (_changedCount == 0 && _editRow == null) {
      _rows = List<_ERow>.of(widget.rows);
    }
    if (!widget.locked && _baseline == null) _setBaseline(widget.rows);
  }

  @override
  void dispose() {
    _edit.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _setBaseline(List<_ERow> rows) {
    _baseline = <String, _ERow>{for (final r in rows) r.id: r};
  }

  int get _changedCount {
    final base = _baseline;
    if (base == null) return 0;
    var n = 0;
    for (final r in _rows) {
      final b = base[r.id];
      if (b == null) continue;
      for (var c = 0; c < widget.columns.length; c++) {
        if (!_same(r.at(c), b.at(c))) n++;
      }
    }
    return n;
  }

  bool _changed(int row, int col) {
    final b = _baseline?[_rows[row].id];
    return b != null && !_same(_rows[row].at(col), b.at(col));
  }

  static bool _same(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return tableCellText(a) == tableCellText(b);
  }

  List<Map<String, Object?>> get _value => [for (final r in _rows) r.toJson()];

  void _writeForm() {
    OpenUiFormScope.formOf(context)?.setValue(widget.name, _value);
  }

  void _set(int row, int col, Object? value) {
    if (row >= _rows.length) return;
    setState(() => _rows[row] = _rows[row].copyWith(col, value));
    _writeForm();
  }

  // ------------------------------------------------------------- edits

  void _startText(int row, int col) {
    if (_editRow != null) _commitText();
    final v = _rows[row].at(col);
    final type = widget.columns[col].type;
    _edit.text = type == 'number' && v is num
        ? (v == v.roundToDouble() ? v.toInt().toString() : v.toString())
        : tableCellText(v);
    _edit.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _edit.text.length,
    );
    setState(() {
      _editRow = row;
      _editCol = col;
    });
    _focus.requestFocus();
  }

  void _commitText() {
    final row = _editRow;
    final col = _editCol;
    if (row == null || col == null) return;
    _editRow = null;
    _editCol = null;
    final text = _edit.text.trim();
    Object? value = text;
    if (widget.columns[col].type == 'number') {
      if (text.isEmpty) {
        value = '';
      } else {
        final n = chartNumber(text);
        if (n == null) {
          // Not a number: keep the old value.
          if (mounted) setState(() {});
          return;
        }
        value = n == n.roundToDouble() && n.abs() < 1e15 ? n.toInt() : n;
      }
    }
    if (!mounted) return;
    if (_same(_rows[row].at(col), value) &&
        _rows[row].at(col).runtimeType == value.runtimeType) {
      setState(() {});
      return;
    }
    _set(row, col, value);
  }

  Future<void> _pickDate(int row, int col) async {
    if (_editRow != null) _commitText();
    final current = DateTime.tryParse(tableCellText(_rows[row].at(col)));
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (picked == null || !mounted) return;
    _set(row, col, DateFormat('yyyy-MM-dd').format(picked));
  }

  Future<void> _pickOption(BuildContext anchor, int row, int col) async {
    if (_editRow != null) _commitText();
    final column = widget.columns[col];
    if (column.options.isEmpty) {
      _startText(row, col);
      return;
    }
    final current = tableCellText(_rows[row].at(col));
    final scheme = Theme.of(anchor).colorScheme;
    final choice = await showAnchoredMenu<String>(
      anchor,
      color: scheme.surfaceContainerHigh,
      minWidth: 180,
      maxWidth: 320,
      items: <PopupMenuEntry<String>>[
        for (final o in column.options)
          PopupMenuItem<String>(
            value: o.value,
            padding: EdgeInsets.zero,
            child: MenuActionRow(
              label: o.label,
              selected: o.value == current,
              maxLines: 2,
            ),
          ),
      ],
    );
    if (choice == null || !mounted) return;
    _set(row, col, choice);
  }

  void _reset() {
    final base = _baseline;
    if (base == null) return;
    setState(() {
      _editRow = null;
      _editCol = null;
      _rows = [for (final r in _rows) base[r.id] ?? r];
    });
    _writeForm();
  }

  Future<void> _save(BuildContext context) async {
    if (_editRow != null) _commitText();
    _writeForm();
    setState(() => _setBaseline(_rows));
    await OpenUiAction(
      implicitContinueConversationPlan(kEditableTableSaveMessage),
    ).run(context, label: kEditableTableSaveMessage);
  }

  // ------------------------------------------------------------ layout

  String _display(_EColumn col, Object? v) {
    switch (col.type) {
      case 'select':
        return col.labelOf(v);
      case 'date-single':
        final d = DateTime.tryParse(tableCellText(v));
        return d == null ? tableCellText(v) : DateFormat.yMMMd().format(d);
      default:
        return tableCellText(v);
    }
  }

  List<double> _naturalWidths(BuildContext context, OpenUiTableStyles s) {
    final scaler = MediaQuery.textScalerOf(context);
    final cols = widget.columns;
    return <double>[
      for (var c = 0; c < cols.length; c++)
        () {
          final col = cols[c];
          final pads = tableCellPadLeft(c) + tableCellPadRight(c, cols.length);
          if (col.width != null && col.width! > 0) {
            return col.width!.clamp(64.0, 480.0) + pads;
          }
          final icon = col.type == 'text' || col.type == 'number' ? 0 : 22;
          var w = measureTableText(col.header, s.header, scaler);
          for (final r in _rows.take(kTableRowsSampled)) {
            w = math.max(
              w,
              measureTableText(_display(col, r.at(c)), s.body, scaler) + icon,
            );
          }
          if (col.type == 'select') {
            for (final o in col.options) {
              w = math.max(w, measureTableText(o.label, s.body, scaler) + icon);
            }
          }
          if (col.type == 'date-single') {
            w = math.max(
              w,
              measureTableText('Sep 30, 2026', s.body, scaler) + icon,
            );
          }
          return w.clamp(64.0, kTableMaxText) + pads + 2;
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final styles = OpenUiTableStyles.of(context);
    final changes = _changedCount;
    return OpenUiTableShell(
      builder: (context, available) {
        final plan = planTableColumns(
          _naturalWidths(context, styles),
          available,
        );
        return (
          table: _table(context, styles, plan.widths),
          width: plan.widths.fold<double>(0, (a, w) => a + w),
          scrolls: plan.scrolls,
        );
      },
      footer: changes > 0
          ? _ChangesBar(count: changes, onReset: _reset, onSave: _save)
          : null,
    );
  }

  Widget _table(
    BuildContext context,
    OpenUiTableStyles s,
    List<double> widths,
  ) {
    final t = OpenUiTheme.of(context);
    final cols = widget.columns;
    final n = cols.length;
    EdgeInsets pad(int c) => EdgeInsets.fromLTRB(
      tableCellPadLeft(c) - 4,
      3,
      tableCellPadRight(c, n) - 4,
      3,
    );
    return Table(
      columnWidths: <int, TableColumnWidth>{
        for (var c = 0; c < n; c++) c: FixedColumnWidth(widths[c]),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: <TableRow>[
        TableRow(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: t.headerRule,
              ),
            ),
          ),
          children: <Widget>[
            for (var c = 0; c < n; c++)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tableCellPadLeft(c),
                  kTableRowPadY,
                  tableCellPadRight(c, n),
                  kTableRowPadY,
                ),
                child: Text(
                  cols[c].header,
                  style: s.header,
                  textAlign: cols[c].type == 'number'
                      ? TextAlign.right
                      : TextAlign.left,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        for (var r = 0; r < _rows.length; r++)
          TableRow(
            decoration: r < _rows.length - 1
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: t.hairline)),
                  )
                : null,
            children: <Widget>[
              for (var c = 0; c < n; c++)
                Padding(padding: pad(c), child: _cell(context, s, r, c)),
            ],
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, OpenUiTableStyles s, int r, int c) {
    final t = OpenUiTheme.of(context);
    final col = widget.columns[c];
    final value = _rows[r].at(c);
    final editing = _editRow == r && _editCol == c;
    final changed = _changed(r, c);
    final number = col.type == 'number';
    final style = number ? s.number : s.body;

    Widget content;
    if (editing) {
      content = TextField(
        key: ValueKey<String>('openui-edit-$r-$c'),
        controller: _edit,
        focusNode: _focus,
        style: style.copyWith(color: t.textColor),
        textAlign: number ? TextAlign.right : TextAlign.left,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : (col.type == 'url' ? TextInputType.url : TextInputType.text),
        textInputAction: TextInputAction.done,
        cursorColor: t.accent,
        decoration: const InputDecoration(
          isDense: true,
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (_) => _commitText(),
        onTapOutside: (_) => _focus.unfocus(),
      );
    } else {
      final text = _display(col, value);
      final url = col.type == 'url' ? tableCellUrl(value) : null;
      final HugeIconData? trailing = switch (col.type) {
        'select' => HugeIcons.arrowDown01,
        'date-single' => HugeIcons.calendar01,
        _ => null,
      };
      content = Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: url != null ? s.link : style,
              textAlign: number ? TextAlign.right : TextAlign.left,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 4),
            HugeIcon(trailing, size: 16, color: t.mutedColor),
          ],
          if (url != null) ...<Widget>[
            const SizedBox(width: 2),
            Semantics(
              link: true,
              label: openUiStrings(context).openUiOpenLink,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => openTableUrl(context, url.toString()),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: HugeIcon(
                    HugeIcons.arrowUpRight01,
                    size: 16,
                    color: s.link.color,
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    }

    final fill = editing
        ? t.accent.withValues(alpha: t.isDark ? 0.16 : 0.10)
        : (changed
              ? t.accent.withValues(alpha: t.isDark ? 0.12 : 0.08)
              : Colors.transparent);
    final box = AnimatedContainer(
      duration: kExpressiveShort,
      constraints: const BoxConstraints(minHeight: 34),
      alignment: number ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(OpenUiTokens.radiusChip),
        border: editing
            ? Border.all(color: t.accent.withValues(alpha: 0.7))
            : null,
      ),
      child: content,
    );
    if (editing || widget.locked) return box;
    return Builder(
      builder: (cellContext) => Semantics(
        button: true,
        label: col.header.isEmpty
            ? openUiStrings(context).openUiEditCell
            : openUiStrings(context).openUiEditColumn(col.header),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            switch (col.type) {
              case 'date-single':
                _pickDate(r, c);
              case 'select':
                _pickOption(cellContext, r, c);
              default:
                _startText(r, c);
            }
          },
          child: box,
        ),
      ),
    );
  }
}

/// The bar under an edited table: the change count, Reset, Save.
class _ChangesBar extends StatelessWidget {
  const _ChangesBar({
    required this.count,
    required this.onReset,
    required this.onSave,
  });

  final int count;
  final VoidCallback onReset;
  final Future<void> Function(BuildContext context) onSave;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final scheme = t.scheme;
    Widget pill(String label, Color fill, Color fg, VoidCallback onTap) =>
        Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: MorphTap(
            onTap: onTap,
            color: fill,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              count == 1
                  ? openUiStrings(context).openUiOneChange
                  : openUiStrings(context).openUiChanges('$count'),
              style: t.captionStyle,
            ),
          ),
          pill(
            openUiStrings(context).openUiReset,
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
            onReset,
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (ctx) => pill(
              openUiStrings(context).openUiSaveChanges,
              scheme.primary,
              scheme.onPrimary,
              () => onSave(ctx),
            ),
          ),
        ],
      ),
    );
  }
}
