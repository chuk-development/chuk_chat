// Typed, safe readers for the props of one OpenUI component.
//
// Every reader falls back on a missing or bad value. None throws.
// See docs/OPENUI.md, "Props helper".

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter/widgets.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/openui_actions.dart';
import 'package:chuk_chat/openui/openui_component.dart';

/// Looks up a component definition by name (used for data children).
typedef OpenUiDefLookup = OpenUiComponentDef? Function(String name);

/// The props of one component call, with typed readers.
///
/// The renderer resolves each positional argument to a value:
/// - a primitive (`String`, `num`, `bool`), a `List`, a `Map` or `null`,
/// - a rendered child `Widget` (a component call or a reference to one),
/// - a [DataNode] for a data-only component (`Series(...)`),
/// - an `ActionPlan` for an action slot,
/// - a `ReactiveAssign` for a `$binding` slot that got a `$variable`.
@immutable
class OpenUiProps {
  /// Creates props for [component]. [def] gives the enum values for
  /// [choice]; [lookup] resolves the definitions of data children.
  const OpenUiProps({
    required this.component,
    required this.values,
    this.def,
    this.statementId = '',
    this.lookup,
  });

  /// The component name (`Button`).
  final String component;

  /// The raw resolved values, keyed by parameter name.
  final Map<String, Object?> values;

  /// The definition of [component], when known.
  final OpenUiComponentDef? def;

  /// The OpenUI statement that holds this call (for keys and errors).
  final String statementId;

  /// Resolves the definitions of data children (see [data]).
  final OpenUiDefLookup? lookup;

  /// The raw value of [name], or `null`.
  Object? raw(String name) => values[name];

  /// Whether [name] has a non-null value.
  bool has(String name) => values[name] != null;

  /// A string. Numbers and booleans are converted. Anything else
  /// (including `null`, a widget or a list) gives [fallback].
  String string(String name, {String fallback = ''}) =>
      stringOrNull(name) ?? fallback;

  /// A string, or `null` when the value is missing or not text-like.
  String? stringOrNull(String name) {
    final v = values[name];
    if (v is String) return v;
    if (v is num) return _formatNumber(v);
    if (v is bool) return v.toString();
    return null;
  }

  /// A number. Numeric strings are parsed. Anything else gives
  /// [fallback].
  double number(String name, {double fallback = 0}) =>
      numberOrNull(name) ?? fallback;

  /// A number, or `null` when the value is missing or not numeric.
  double? numberOrNull(String name) => _toDouble(values[name]);

  /// A whole number (rounded). Anything else gives [fallback].
  int integer(String name, {int fallback = 0}) =>
      numberOrNull(name)?.round() ?? fallback;

  /// A boolean. `"true"`/`"false"` strings are read too. Anything else
  /// gives [fallback].
  bool boolean(String name, {bool fallback = false}) {
    final v = values[name];
    if (v is bool) return v;
    if (v == 'true') return true;
    if (v == 'false') return false;
    return fallback;
  }

  /// An enum value. The result is always one of the allowed values of
  /// the parameter (from its upstream type text) or [fallback].
  String choice(String name, {required String fallback}) {
    final v = stringOrNull(name);
    if (v == null) return fallback;
    final allowed = def?.param(name)?.enumValues ?? const <String>[];
    if (allowed.isEmpty || allowed.contains(v)) return v;
    return fallback;
  }

  /// A list. `null` gives an empty list; a single non-list value gives
  /// a one-element list.
  List<Object?> list(String name) {
    final v = values[name];
    if (v == null) return const <Object?>[];
    if (v is List) return List<Object?>.unmodifiable(v);
    return List<Object?>.unmodifiable(<Object?>[v]);
  }

  /// The text-like items of [list] (numbers are converted). Other items
  /// are skipped.
  List<String> stringList(String name) => [
    for (final v in list(name))
      if (v is String)
        v
      else if (v is num)
        _formatNumber(v)
      else if (v is bool)
        v.toString(),
  ];

  /// The items of [list] as numbers. An item that is not numeric is
  /// `0`, so the positions still line up with a label list.
  List<double> numberList(String name) => [
    for (final v in list(name)) _toDouble(v) ?? 0,
  ];

  /// A map (an OpenUI object literal). Anything else gives an empty map.
  Map<String, Object?> map(String name) {
    final v = values[name];
    if (v is Map) {
      return Map<String, Object?>.unmodifiable(<String, Object?>{
        for (final e in v.entries) e.key.toString(): e.value,
      });
    }
    return const <String, Object?>{};
  }

  /// The map items of [list]. Other items are skipped.
  List<Map<String, Object?>> mapList(String name) => [
    for (final v in list(name))
      if (v is Map)
        Map<String, Object?>.unmodifiable(<String, Object?>{
          for (final e in v.entries) e.key.toString(): e.value,
        }),
  ];

  /// The rendered child widgets of [name], flattened. Text and numbers
  /// become a plain [Text]. Data-only nodes and `null` are skipped.
  List<Widget> children(String name) {
    final out = <Widget>[];
    void add(Object? v) {
      if (v == null || v is DataNode) return;
      if (v is Widget) {
        out.add(v);
      } else if (v is List) {
        v.forEach(add);
      } else if (v is String || v is num) {
        out.add(Text(v is num ? _formatNumber(v) : v as String));
      }
    }

    add(values[name]);
    return out;
  }

  /// The first child widget of [name], or `null`.
  Widget? child(String name) {
    final c = children(name);
    return c.isEmpty ? null : c.first;
  }

  /// The data-only children of [name] (for example the `Series` items
  /// of a chart), flattened, as props. With [type], only that component.
  List<OpenUiProps> data(String name, {String? type}) {
    final out = <OpenUiProps>[];
    void add(Object? v) {
      if (v is DataNode) {
        if (type != null && v.typeName != type) return;
        out.add(
          OpenUiProps(
            component: v.typeName,
            values: v.props,
            def: lookup?.call(v.typeName),
            statementId: v.statementId,
            lookup: lookup,
          ),
        );
      } else if (v is List) {
        v.forEach(add);
      }
    }

    add(values[name]);
    return out;
  }

  /// The first data-only child of [name], or `null`.
  OpenUiProps? dataOne(String name, {String? type}) {
    final d = data(name, type: type);
    return d.isEmpty ? null : d.first;
  }

  /// The action of an action slot, or `null`. It is `null` when the
  /// slot is empty, malformed, or its statement is still streaming.
  OpenUiAction? action(String name) {
    final v = values[name];
    if (v is ActionPlan && v.steps.isNotEmpty) return OpenUiAction(v);
    return null;
  }

  /// The two-way binding of a `$binding` slot, or `null` when the
  /// argument was not a `$variable`.
  OpenUiBinding? binding(String name) {
    final v = values[name];
    if (v is ReactiveAssign) return OpenUiBinding(v.target, v.value);
    return null;
  }

  static double? _toDouble(Object? v) {
    if (v is num) return v.isFinite ? v.toDouble() : null;
    if (v is String) {
      final n = double.tryParse(v.trim());
      return n != null && n.isFinite ? n : null;
    }
    return null;
  }

  static String _formatNumber(num v) {
    if (v is int) return v.toString();
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    return v.toString();
  }

  @override
  String toString() => 'OpenUiProps($component, $values)';
}

/// The action of an action slot (`Action([...])`, a bare step such as
/// `@ToAssistant("x")`, or `{type: "continue_conversation", ...}`).
@immutable
class OpenUiAction {
  /// Wraps an action plan from the renderer.
  const OpenUiAction(this.plan);

  /// The steps, in order.
  final ActionPlan plan;

  /// Runs the action. [label] is the label of the component that fired
  /// it: an object-literal `continue_conversation` sends it as the
  /// message. When the component sits inside a `Form`, the form values
  /// travel with any message to the assistant.
  Future<void> run(BuildContext context, {required String label}) async {
    final renderer = RendererScope.maybeFind(context);
    if (renderer == null) return;
    final scope = OpenUiScope.maybeOf(context);
    final formName = OpenUiFormScope.maybeNameOf(context);
    await (scope?.runWithForm(
          formName,
          () => renderer.triggerAction(label, action: plan),
        ) ??
        renderer.triggerAction(label, action: plan));
  }
}

/// A two-way binding to a `$variable` of the OpenUI program.
@immutable
class OpenUiBinding {
  /// Creates a binding to [target] (with the `$`) holding [value].
  const OpenUiBinding(this.target, this.value);

  /// The state variable, with the leading `$`.
  final String target;

  /// The current value in the store.
  final Object? value;

  /// Writes [newValue] to the store. Every expression that reads the
  /// variable rebuilds, and queries that use it fetch again.
  void set(BuildContext context, Object? newValue) {
    RendererScope.maybeFind(context)?.store.set(target, newValue);
  }
}
