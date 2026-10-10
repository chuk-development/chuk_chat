# NOTICE: vendored openui_core

This folder is a vendored copy of the `openui_core` package.

- Source: https://github.com/mtwichel/openui_flutter, folder
  `packages/openui_core`, commit `e1525eed` (2026-05-26).
- License: MIT, `Copyright (c) 2026 Very Good Ventures` (see `LICENSE`).
- The language, OpenUI Lang, is by Thesys Inc.:
  https://github.com/thesysdev/openui, MIT,
  `Copyright (c) 2011-2024 Thesys Inc.` The new code below follows the
  semantics of its TypeScript reference (`packages/lang-core/src`).

## What chuk_chat changed

Each change is marked with a `chuk_chat` comment in the code and has
tests in `test/src/chuk/v05_gaps_test.dart`.

1. Removed `dart_mappable` and `build_runner`. `LibraryDefinition`,
   `ComponentDefinition` and `ToolDefinition` have hand-written
   `toJson`/`fromJson`/`fromMap`/`toMap`. `definitions.mapper.dart` and
   `schema_mapper.dart` are gone. `json_schema_builder` stays.
2. Preprocessing (`lib/src/parser/preprocess.dart`): `stripFences`
   (inline mode: code from all ```` ``` ```` fences, prose dropped, an
   open fence while streaming) and `stripComments` (`//` and `#` line
   comments outside strings). The streaming parser and `parse` use it.
3. Canonical `name = Query("tool", {args}, {defaults}, refreshSeconds?)`
   (`StatementKind.query`, `QueryDecl.isCanonical`, `argsAst`,
   `defaultsAst`, `refreshSeconds`, `canonicalQueryDecl`). A reference
   to the query reads the stored result, else the defaults. The old
   named form `Query(name: ...)` is still a migration error.
4. Array pluck in member access: `rows.title` on a list returns the
   `title` of each element.
5. Builtins `@Sum @Avg @Min @Max @First @Last @Sort @Round @Abs @Floor
   @Ceil`, the canonical `@Filter(array, field, op, value)` (the port's
   two-argument predicate form still works), and `toNumber`.
6. Actions: `@OpenUrl` (`OpenUrlStep`, `BuiltinActionType.openUrl`),
   the object-literal form (`actionPlanFromObject`), a
   `ContinueConversationStep` with a `NullLiteral` message sends the
   component label, and `bindActionPlan` keeps `@Each` loop variables
   for a later click (`SetStep.scope`).
7. `parse`: `Action(...)` and an inline `Query(...)` are runtime
   values, not unknown components.
8. pubspec: `publish_to: none`, version `0.0.1-dev.2+chuk`.

Two port tests changed with the semantics: the builtin registry test
lists the new builtins, and member access on a list now plucks.
