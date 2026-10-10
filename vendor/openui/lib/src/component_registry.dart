// Internal references to openui_core experimental types — the entire
// openui_core surface is marked @experimental in v0.1.
// ignore_for_file: experimental_member_use

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';
import 'package:openui_core/openui_core.dart';

/// Render callback for a registered OpenUI component.
typedef ComponentRender =
    Widget Function(
      EvalContext context,
      Map<String, Object?> props,
      Widget Function(AstNode node, EvalContext context) renderNode,
      String statementId,
    );

/// Lookup map from component name to render callback.
///
/// Marked `@experimental` per D12.
@experimental
class ComponentRegistry {
  /// Creates a [ComponentRegistry].
  const ComponentRegistry({
    required this.renderers,
    this.dataComponents = const <String>{},
  });

  /// Registered render callbacks keyed by component name.
  final Map<String, ComponentRender> renderers;

  /// chuk_chat: names of data-only components (for example `Series`,
  /// `Col`, `SelectItem`). The renderer does not call a render
  /// callback for them. It resolves their props and returns a
  /// [DataNode], which the parent component reads.
  final Set<String> dataComponents;

  /// Returns the render callback for [name], or `null` when not registered.
  ComponentRender? operator [](String name) => renderers[name];

  /// Whether [name] is a data-only component.
  bool isData(String name) => dataComponents.contains(name);
}

/// chuk_chat: the value of a data-only component call.
///
/// It is a widget so it can travel through the same prop lists as
/// rendered children (`[Series(...), Series(...)]`). It draws nothing.
/// A parent component reads [typeName] and [props].
///
/// Marked `@experimental` per D12.
@experimental
class DataNode extends StatelessWidget {
  /// Creates a [DataNode].
  const DataNode({
    required this.typeName,
    required this.props,
    required this.statementId,
    super.key,
  });

  /// The component name, for example `'Series'`.
  final String typeName;

  /// The resolved props, keyed by prop name.
  final Map<String, Object?> props;

  /// The statement this node came from.
  final String statementId;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
