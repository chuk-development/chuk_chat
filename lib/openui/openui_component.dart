// The component definition type of the chuk_chat OpenUI library.
//
// One `OpenUiComponentDef` describes one OpenUI Lang component: its
// name, its upstream group, a one-line description, its positional
// parameters in upstream order, and how to draw it. See docs/OPENUI.md.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter/widgets.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/openui_props.dart';

/// Draws one component from its typed props.
///
/// The builder runs inside the OpenUI renderer. It must not throw; the
/// [OpenUiProps] readers never throw and fall back on bad values.
typedef OpenUiBuilder = Widget Function(
  BuildContext context,
  OpenUiProps props,
);

/// One positional parameter of a component.
///
/// [type] is the type text exactly as in the upstream signature, for
/// example `string`, `number[]`, `"grouped" | "stacked"`, `Series[]` or
/// `ActionExpression`. The source of truth is
/// `test/openui/fixtures/upstream/components-chat.json`.
@immutable
class OpenUiParam {
  /// Creates a parameter. [optional] is the `?` in the signature.
  const OpenUiParam(this.name, this.type, {this.optional = false});

  /// Creates an optional parameter (`name?: type`).
  const OpenUiParam.opt(this.name, this.type) : optional = true;

  /// The prop name, as in the upstream signature.
  final String name;

  /// The type text, as in the upstream signature.
  final String type;

  /// Whether the parameter can be left out.
  final bool optional;

  /// The allowed values when [type] is a pure string enum
  /// (`"a" | "b"`), else an empty list.
  List<String> get enumValues {
    final parts = type.split('|').map((p) => p.trim()).toList();
    final values = <String>[];
    for (final p in parts) {
      if (p.length < 2 || !p.startsWith('"') || !p.endsWith('"')) {
        return const <String>[];
      }
      values.add(p.substring(1, p.length - 1));
    }
    return values;
  }

  /// Whether the slot takes an action (`Action([...])`, a bare step or
  /// an object literal). The renderer turns it into an [OpenUiAction].
  bool get isAction => type == 'ActionExpression';

  /// Whether the slot takes a two-way `$state` binding. The renderer
  /// passes an [OpenUiBinding] when the argument is a `$variable`.
  bool get isBinding => type.startsWith(r'$binding');

  /// `name: type` or `name?: type`, as in the upstream signature.
  String get signature => '$name${optional ? '?' : ''}: $type';
}

/// One OpenUI Lang component of the chuk_chat library.
///
/// The positional order of [params] must equal the upstream order. The
/// test `test/openui/openui_signatures_test.dart` compares [signature]
/// with the upstream signature text.
///
/// A visual component has a [builder]. A data-only component (for
/// example `Series`, `Col`, `SelectItem`) has none: it is created with
/// [OpenUiComponentDef.data], draws nothing, and its parent reads its
/// props with [OpenUiProps.data].
@immutable
class OpenUiComponentDef {
  /// Creates a visual component.
  const OpenUiComponentDef({
    required this.name,
    required this.group,
    required this.description,
    required this.params,
    required OpenUiBuilder this.builder,
  });

  /// Creates a data-only component. Its parent reads it.
  const OpenUiComponentDef.data({
    required this.name,
    required this.group,
    required this.description,
    required this.params,
  }) : builder = null;

  /// The component name used in OpenUI Lang (`Card`, `Series`).
  final String name;

  /// The upstream prompt group (`Content`, `Charts (2D)`, `Forms`).
  final String group;

  /// One line for the model prompt, normally the upstream description.
  final String description;

  /// The positional parameters, in upstream order.
  final List<OpenUiParam> params;

  /// Draws the component. `null` for a data-only component.
  final OpenUiBuilder? builder;

  /// Whether this is a data-only component.
  bool get isData => builder == null;

  /// Returns the parameter called [paramName], or `null`.
  OpenUiParam? param(String paramName) {
    for (final p in params) {
      if (p.name == paramName) return p;
    }
    return null;
  }

  /// `Name(a: string, b?: number)`, the upstream signature format.
  String get signature => '$name(${params.map((p) => p.signature).join(', ')})';

  /// The vendored core's definition: a JSON schema whose `properties`
  /// keep the positional order. Action params carry `x-action`, binding
  /// params carry `x-reactive`.
  ComponentDefinition toCoreDefinition() {
    return ComponentDefinition(
      name: name,
      description: description,
      schema: Schema.fromMap(<String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          for (final p in params)
            p.name: <String, Object?>{
              'description': p.type,
              if (p.isAction) 'x-action': true,
              if (p.isBinding) 'x-reactive': true,
              if (p.enumValues.isNotEmpty) 'enum': p.enumValues,
            },
        },
        'required': <String>[
          for (final p in params)
            if (!p.optional) p.name,
        ],
      }),
    );
  }
}
