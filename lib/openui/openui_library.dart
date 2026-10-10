// The chuk_chat OpenUI component library and its registry.
//
// The registry composes the four component files. A component agent
// adds components to ITS file only; this file does not change.

// The vendored openui packages mark their whole API experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/components/content_layout.dart';
import 'package:chuk_chat/openui/components/data_cards.dart';
import 'package:chuk_chat/openui/components/forms_buttons.dart';
import 'package:chuk_chat/openui/components/tables_charts.dart';
import 'package:chuk_chat/openui/openui_component.dart';
import 'package:chuk_chat/openui/openui_props.dart';

/// A set of [OpenUiComponentDef]s, ready for the vendored renderer.
///
/// On a duplicate name the later definition wins.
class OpenUiLibrary {
  /// Creates a library from [components].
  OpenUiLibrary(List<OpenUiComponentDef> components)
    : _byName = <String, OpenUiComponentDef>{
        for (final c in components) c.name: c,
      };

  final Map<String, OpenUiComponentDef> _byName;

  /// Every component, in registration order (duplicates removed).
  List<OpenUiComponentDef> get components =>
      List<OpenUiComponentDef>.unmodifiable(_byName.values);

  /// The registered component names.
  Set<String> get names => Set<String>.unmodifiable(_byName.keys);

  /// The component called [name], or `null`.
  OpenUiComponentDef? operator [](String name) => _byName[name];

  /// Whether [name] is registered.
  bool contains(String name) => _byName.containsKey(name);

  /// The core definition (schemas in positional order) for the parser
  /// and the renderer. Built once.
  late final LibraryDefinition definition = LibraryDefinition(
    components: [for (final c in _byName.values) c.toCoreDefinition()],
  );

  /// The render callbacks for the vendored renderer. Built once.
  late final ComponentRegistry registry = ComponentRegistry(
    renderers: <String, ComponentRender>{
      for (final c in _byName.values)
        if (!c.isData) c.name: _renderFor(c),
    },
    dataComponents: <String>{
      for (final c in _byName.values)
        if (c.isData) c.name,
    },
  );

  ComponentRender _renderFor(OpenUiComponentDef def) {
    return (EvalContext _, Map<String, Object?> props, _, String id) {
      return _OpenUiComponentHost(
        def: def,
        props: OpenUiProps(
          component: def.name,
          values: props,
          def: def,
          statementId: id,
          lookup: (name) => _byName[name],
        ),
      );
    };
  }
}

/// Calls the builder of one component inside its own build, so the
/// builder gets a real [BuildContext] below the renderer scopes. A
/// throwing builder draws nothing instead of an error box.
class _OpenUiComponentHost extends StatelessWidget {
  const _OpenUiComponentHost({required this.def, required this.props});

  final OpenUiComponentDef def;
  final OpenUiProps props;

  @override
  Widget build(BuildContext context) {
    try {
      return def.builder!(context, props);
    } on Object catch (error, stack) {
      if (kDebugMode) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'chuk_chat openui',
            context: ErrorDescription('while building OpenUI ${def.name}'),
          ),
        );
      }
      return const SizedBox.shrink();
    }
  }
}

/// The chuk_chat OpenUI library: the chat root `Card` plus every
/// component of the four component files.
final OpenUiLibrary chukOpenUiLibrary = OpenUiLibrary(<OpenUiComponentDef>[
  ...contentLayoutComponents,
  ...tablesChartsComponents,
  ...formsButtonsComponents,
  ...dataCardsComponents,
]);
