# NOTICE: vendored openui

This folder is a vendored copy of the `openui` package (the Flutter
renderer for OpenUI Lang).

- Source: https://github.com/mtwichel/openui_flutter, folder
  `packages/openui`, commit `e1525eed` (2026-05-26).
- License: MIT, `Copyright (c) 2026 Very Good Ventures` (see `LICENSE`).
- The language, OpenUI Lang, is by Thesys Inc.:
  https://github.com/thesysdev/openui, MIT,
  `Copyright (c) 2011-2024 Thesys Inc.`

## What chuk_chat changed

Each change is marked with a `chuk_chat` comment in the code and has
tests in `test/src/chuk_renderer_test.dart`.

1. `openui_core` is a path dependency on `../openui_core` (the vendored
   copy). pubspec: `publish_to: none`, version `0.0.1-dev.2+chuk`.
2. Data-only components: `ComponentRegistry.dataComponents` and the
   `DataNode` widget. The renderer resolves their props and hands a
   `DataNode` to the parent instead of calling a render callback.
3. Props: a reference to a component statement (`Form("f", btns)` with
   `btns = Buttons(...)`) and a ternary with a component branch render
   the component. In an array, only references that lead to a component
   count as widgets, so `["a", b]` with `b = "x"` stays a list of
   strings. `Action(...)` and `Query(...)` are values.
4. Action slots also accept a bare step (`@ToAssistant("x")`) and the
   object-literal form; loop variables are bound with `bindActionPlan`.
   `Renderer.onOpenUrl` receives `@OpenUrl` steps.
5. Canonical Query and Mutation in `QueryManager`: a query without an
   executor stays on its defaults (no error); the result is stored
   under the bare statement id; `refreshSeconds` re-fires on a timer;
   a `$variable` write re-fires canonical queries whose args changed;
   `Mutation("tool", {args})` evaluates its args at run time.
6. `Renderer.errorBuilder` replaces the red in-tree error text.
7. Robustness: a parser exception keeps the last result; a cycle
   through component calls (`a = Column([b])`, `b = Column([a])`) is
   reported instead of building an endless tree.
8. Props: components inside nested arrays and object literals resolve
   too. `Carousel([[a, b], [c, d]])` gets a list of widget lists, and
   `{price: BoldText(...), button: Button(...)}` gets a map of widgets
   (a data-only component gives its `DataNode`). A reference to an
   array or object statement (`slides = [[a, b], [c]]`) keeps its
   shape; a cycle through such statements is reported. Plain values
   inside stay values.
9. Review fixes (tests in `test/src/chuk_renderer_test.dart` and
   `test/src/query_manager_test.dart`, group `chuk_chat` / `review
   fixes`):
   - `@OpenUrl` hands only http/https (with a host), mailto and tel
     URLs to `onOpenUrl` (`safeOpenUrl`, `kOpenUrlSchemes`, exported;
     the chat host uses the same rule).
   - A `ToolResult` with `isError` from a legacy `Mutation(name: ...)`
     or a direct `@Run(tool)` throws `EvaluationError`, so the action
     plan stops, like the canonical form.
   - Legacy `@Query` args are compared deeply, so list or map args do
     not re-fire the tool on every pass.
   - Errors: an error already reported is not added again; `onError`
     runs after the frame (only while mounted), never during build;
     a response that is not a continuation clears the old errors.
   - `refreshSeconds`: a non-finite value means no timer; the interval
     is clamped to 5 s .. 1 day; timers of queries that the new parse
     dropped are cancelled (`QueryManager.retainTimers`); timers skip
     their tick while the response streams (`QueryManager.paused`).
