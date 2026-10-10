// Internal package imports cross openui_core experimental types
// (the entire openui_core surface is marked @experimental in v0.1).
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';
import 'package:openui/src/component_registry.dart';
import 'package:openui/src/error_boundary.dart';
import 'package:openui/src/form_state_cache.dart';
import 'package:openui/src/query_manager.dart';
import 'package:openui/src/renderer_scope.dart';
import 'package:openui/src/tool_registry.dart';
import 'package:openui_core/openui_core.dart';

/// chuk_chat: the URL schemes `@OpenUrl` may hand to
/// [Renderer.onOpenUrl].
const Set<String> kOpenUrlSchemes = <String>{'http', 'https', 'mailto', 'tel'};

/// chuk_chat: [url] as a [Uri] when `@OpenUrl` may open it, else `null`.
///
/// Only http, https, mailto and tel. A web link must have a host, and a
/// mailto or tel link a target. Other schemes (`javascript:`, `file:`,
/// `intent:`, app links) are refused, because the model writes the URL.
Uri? safeOpenUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (!kOpenUrlSchemes.contains(scheme)) return null;
  if ((scheme == 'http' || scheme == 'https') && uri.host.isEmpty) {
    return null;
  }
  if ((scheme == 'mailto' || scheme == 'tel') && uri.path.trim().isEmpty) {
    return null;
  }
  return uri;
}

/// Callback fired when a continue-conversation action occurs.
typedef ContinueConversationCallback = void Function(String message);

/// The Flutter renderer for OpenUI Lang.
///
/// Mirrors the JS reference's `<Renderer />` shape: pass the cumulative
/// streamed response, the active component library, and the optional
/// hook bag, and the widget keeps an internal parser / store / query
/// cache / form-state cache in sync.
///
/// Marked `@experimental` per D12.
@experimental
class Renderer extends StatefulWidget {
  /// Creates a [Renderer].
  const Renderer({
    required this.library,
    required this.componentRegistry,
    required this.toolRegistry,
    this.response,
    this.isStreaming = false,
    this.onAction,
    this.onContinueConversation,
    this.onStateUpdate,
    this.initialState,
    this.onParseResult,
    this.onError,
    this.rootName = 'root',
    this.onOpenUrl,
    this.errorBuilder,
    super.key,
  });

  /// Cumulative streamed source. Replacing this triggers a fresh
  /// parse pass (`StreamParser.set`).
  final String? response;

  /// Component and tool definitions used for schema lookup and prompts.
  final LibraryDefinition library;

  /// Render callbacks keyed by component name.
  final ComponentRegistry componentRegistry;

  /// Tool executors keyed by tool name.
  final ToolRegistry toolRegistry;

  /// Whether `response` is still being appended to by the upstream
  /// stream. Propagated to component implementations via
  /// `RendererScope.isStreaming`.
  final bool isStreaming;

  /// Notified for each host-routed step, including continue-conversation
  /// (`@ToAssistant` and implicit Button activations), failed `@Run`
  /// steps, skipped `@Reset` targets, and invalid `@ToAssistant`
  /// messages (`params['success'] == false` where applicable).
  final void Function(ActionEvent event)? onAction;

  /// Invoked after [onAction] for continue-conversation steps whose
  /// evaluated message is a non-empty string (including implicit Button
  /// activations). Failed or skipped `@ToAssistant` steps still call
  /// [onAction] but do not invoke this callback.
  final ContinueConversationCallback? onContinueConversation;

  /// Notified after every write to the internal [Store], with the
  /// full post-write snapshot.
  final void Function(Map<String, Object?> snapshot)? onStateUpdate;

  /// Initial state seed. Keys must include the leading `$`.
  final Map<String, Object?>? initialState;

  /// Notified after every parse pass with the latest [ParseResult].
  final void Function(ParseResult result)? onParseResult;

  /// Notified when the active [OpenUIError] set changes. Errors are
  /// deduplicated structurally — repeated identical sets do not fire
  /// twice.
  final void Function(List<OpenUIError> errors)? onError;

  /// Name of the entry-point statement. Defaults to `'root'`.
  final String rootName;

  /// chuk_chat: invoked after [onAction] for `@OpenUrl` steps and
  /// `{type: "open_url"}` actions whose URL [safeOpenUrl] accepts.
  final void Function(String url)? onOpenUrl;

  /// chuk_chat: builds the in-tree placeholder for an unknown
  /// component, a missing renderer or a reference cycle. The default
  /// is a short red text line (the port's behaviour).
  final Widget Function(OpenUIError error)? errorBuilder;

  @override
  State<Renderer> createState() => _RendererState();
}

class _RendererState extends State<Renderer> {
  late StreamParser _parser;
  late Store _store;
  late FormStateCache _formStateCache;
  QueryManager? _queryManager;
  ParseResult? _lastResult;
  List<OpenUIError> _lastReportedErrors = const <OpenUIError>[];
  // chuk_chat: the list last handed to `onError`, and whether a
  // post-frame notification is already queued.
  List<OpenUIError> _lastNotifiedErrors = const <OpenUIError>[];
  bool _errorNotifyScheduled = false;
  void Function()? _storeUnsubscribe;

  // "Last good root" cache. Mid-stream, autoClose patches the pending
  // tail differently on every chunk, so a single tick can produce a
  // null or misshapen root while neighboring ticks parse cleanly. When
  // `isStreaming` is true, prefer the cached root over a degraded new
  // parse so the visible tree doesn't flicker between bad shapes.
  // Mirrors the JS reference's completed-statement caching strategy
  // (lang-core/src/parser/parser.ts, completedStmtMap).
  ElementNode? _lastGoodRoot;
  String _previousResponse = '';
  bool _wasStreaming = false;

  @override
  void initState() {
    super.initState();
    _parser = createStreamingParser(rootName: widget.rootName);
    _store = Store();
    _formStateCache = FormStateCache();
    _storeUnsubscribe = _store.subscribe(_handleStoreChange);
    _queryManager = _buildQueryManager();
    _runPipeline();
  }

  @override
  void didUpdateWidget(Renderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final libraryChanged =
        widget.library != oldWidget.library ||
        widget.componentRegistry != oldWidget.componentRegistry ||
        widget.toolRegistry != oldWidget.toolRegistry;
    if (libraryChanged) {
      _queryManager?.dispose();
      _queryManager = _buildQueryManager();
    }
    if (widget.rootName != oldWidget.rootName) {
      _parser = createStreamingParser(rootName: widget.rootName);
    }
    if (widget.response != oldWidget.response ||
        widget.rootName != oldWidget.rootName ||
        widget.isStreaming != oldWidget.isStreaming ||
        libraryChanged) {
      _runPipeline();
    }
  }

  @override
  void dispose() {
    _storeUnsubscribe?.call();
    _queryManager?.dispose();
    _formStateCache.dispose();
    _store.dispose();
    super.dispose();
  }

  QueryManager _buildQueryManager() {
    return QueryManager(
      library: widget.library,
      toolRegistry: widget.toolRegistry,
      store: _store,
      onError: _reportError,
    );
  }

  void _handleStoreChange(StoreChangeOrigin origin) {
    if (!mounted) return;
    widget.onStateUpdate?.call(_store.getSnapshot());
    setState(() {});
    // chuk_chat: a `$var` edit (for example a Select bound to `$days`)
    // re-fires the canonical queries whose args read it. `ensureFired`
    // skips queries whose evaluated args did not change. The microtask
    // lets a following `@Run` in the same action plan fire first, so
    // the tool is not called twice.
    if (origin == StoreChangeOrigin.mutation) {
      scheduleMicrotask(() {
        final result = _lastResult;
        if (!mounted || result == null) return;
        _fireReadyQueries(result, canonicalOnly: true);
      });
    }
  }

  void _runPipeline() {
    final refreshDeclarativeDefaults = widget.isStreaming || _wasStreaming;
    final response = widget.response ?? '';
    // Reset the last-good cache when the new buffer can't be a
    // continuation of the previous one (shorter, or starts differently).
    // Matches the JS reference's StreamParser.set reset rule.
    if (response.length < _previousResponse.length ||
        !response.startsWith(_previousResponse)) {
      _lastGoodRoot = null;
      // chuk_chat: a new program; errors of the old one are gone. Build
      // errors of the new one are reported again on the next build.
      if (_lastReportedErrors.isNotEmpty) {
        _lastReportedErrors = const <OpenUIError>[];
        _scheduleErrorNotify();
      }
    }
    _previousResponse = response;
    final ParseResult result;
    try {
      result = _parser.set(response);
    } on Object catch (error) {
      // chuk_chat: a parser failure must never break the host. Keep
      // the last result and report the failure.
      _reportError(EvaluationError(message: 'parser failure: $error'));
      return;
    }
    _lastResult = result;
    if (result.root != null && result.meta.errors.isEmpty) {
      _lastGoodRoot = result.root;
    }

    // Eval state defaults against a throwaway store so the seed values
    // can reference plain (non-state) statements but cannot read from
    // the user-facing store mid-initialization.
    final seedStore = Store();
    final seedCtx = EvalContext(
      statements: result.statements,
      store: seedStore,
      builtins: functionalBuiltins,
    );
    final defaults = <String, Object?>{
      for (final decl in result.meta.stateDecls)
        decl.name: evaluate(decl.defaultValue, seedCtx),
    };
    seedStore.dispose();
    _store.initialize(
      defaults,
      persisted: widget.initialState,
      refreshDeclarativeDefaults: refreshDeclarativeDefaults,
    );
    _wasStreaming = widget.isStreaming;

    _fireReadyQueries(result);

    widget.onParseResult?.call(result);
    _maybeReportErrors(result);
  }

  void _maybeReportErrors(ParseResult result) {
    final errors = <OpenUIError>[
      for (final parseError in result.meta.errors)
        ParseError(
          message: parseError.message,
          offset: parseError.offset,
        ),
    ];
    // Preserve other error categories (eval, cycle, unknown-component,
    // boundary throws, query failures) added via _reportError so they
    // survive a post-dispatch rebuild of the parse slice.
    for (final e in _lastReportedErrors) {
      if (e is ParseError) continue;
      errors.add(e);
    }
    if (!_errorListsEqual(errors, _lastReportedErrors)) {
      _lastReportedErrors = List.unmodifiable(errors);
      _scheduleErrorNotify();
    }
  }

  Future<void> _triggerAction(
    String userMessage, {
    required ActionPlan action,
  }) async {
    final result = _lastResult;
    final ctx = _buildEvalContext(result);
    final stateDefaults = <String, AstNode>{
      if (result != null)
        for (final decl in result.meta.stateDecls) decl.name: decl.defaultValue,
    };
    final onAction = widget.onAction;
    final onContinueConversation = widget.onContinueConversation;
    await dispatchAction(
      plan: action,
      context: ctx,
      stateDefaults: stateDefaults,
      onRun: (step, args) => _onRun(result, step, args),
      onHostStep: (event) {
        if (event.type == BuiltinActionType.continueConversation) {
          onAction?.call(event);
          final message = event.humanFriendlyMessage;
          if (message != null) {
            onContinueConversation?.call(message);
          }
          return;
        }
        if (event.type == BuiltinActionType.openUrl) {
          onAction?.call(event);
          final url = event.params['url'];
          // chuk_chat: the model writes the URL; pass on safe ones only.
          if (url is String && safeOpenUrl(url) != null) {
            widget.onOpenUrl?.call(url);
          }
          return;
        }
        onAction?.call(event);
      },
      humanFriendlyMessage: userMessage,
    );
    // dispatchAction collects @Reset-target-not-declared and similar
    // category errors in `ctx.errors`; surface them so they're not
    // silently swallowed.
    ctx.errors.forEach(_reportError);
    if (result != null) {
      _maybeReportErrors(result);
      _fireReadyQueries(result);
    }
  }

  void _fireReadyQueries(ParseResult result, {bool canonicalOnly = false}) {
    final manager = _queryManager;
    if (manager == null) return;
    // chuk_chat: refresh timers wait while the response streams.
    manager.paused = widget.isStreaming;
    if (widget.isStreaming) return;
    // chuk_chat: stop refresh timers of queries the program dropped.
    manager.retainTimers({for (final q in result.meta.queries) q.statementId});
    final incomplete = result.meta.incomplete.toSet();
    final fireCtx = _buildEvalContext(result);
    for (final query in result.meta.queries) {
      if (canonicalOnly && !query.isCanonical) continue;
      if (incomplete.contains(query.statementId)) continue;
      manager.ensureFired(query, fireCtx);
    }
  }

  Future<void> _onRun(
    ParseResult? result,
    RunStep step,
    Map<String, Object?> args,
  ) async {
    final manager = _queryManager;
    if (manager == null) return;
    final id = step.statementId;
    if (result != null) {
      for (final m in result.meta.mutations) {
        if (m.statementId != id) continue;
        await manager.fireMutation(id, m.args, _buildEvalContext(result));
        return;
      }
      for (final q in result.meta.queries) {
        if (q.statementId != id) continue;
        manager.invalidate(q, _buildEvalContext(result));
        return;
      }
    }
    final toolDef = widget.library.tool(id);
    if (toolDef != null) {
      final executor = widget.toolRegistry[id];
      if (executor == null) {
        final error = MissingToolExecutorError(toolName: id, statementId: id);
        _reportError(error);
        throw error;
      }
      // chuk_chat: an error result stops the plan, like a mutation.
      final value = await executor(args);
      if (value.isError) {
        final error = EvaluationError(
          message: value.result?.toString() ?? 'Tool call failed',
          statementId: id,
        );
        _reportError(error);
        throw error;
      }
      return;
    }
    throw EvaluationError(
      message: '@Run target "$id" is not a declared query or mutation',
      statementId: id,
    );
  }

  EvalContext _buildEvalContext(ParseResult? result) {
    final statements = result?.statements ?? const <Statement>[];
    return EvalContext(
      statements: statements,
      store: _store,
      builtins: functionalBuiltins,
    );
  }

  @override
  Widget build(BuildContext context) {
    _formStateCache.beginPass();
    final result = _lastResult;
    // Mid-stream the parser can produce a null root for one tick and a
    // non-null root the next; falling back to the cached good root
    // keeps the rendered tree mounted across those gaps. After the
    // stream finishes, the cache is irrelevant — the final parse wins.
    final root = result?.root ?? (widget.isStreaming ? _lastGoodRoot : null);
    final incomplete = <String>{...?result?.meta.incomplete};

    Widget body;
    if (root == null) {
      body = const SizedBox.shrink();
    } else {
      final ctx = _buildEvalContext(result);
      body = _renderAst(
        root.expression,
        ctx,
        statementHint: root.statementId,
      );
    }

    // Reap form fields that didn't get a controllerFor call this pass.
    // Schedule for end-of-frame so build-time mutations don't fight with
    // Flutter's diagnostics.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _formStateCache.endPass();
    });

    return RendererScope(
      store: _store,
      formStateCache: _formStateCache,
      isStreaming: widget.isStreaming,
      incomplete: incomplete,
      triggerAction: _triggerAction,
      child: body,
    );
  }

  // Reference names currently being expanded — guards against cycles
  // like `a = b\nb = a`. Reset on every top-level build pass.
  final Set<String> _expanding = <String>{};

  Widget _renderAst(AstNode node, EvalContext ctx, {String? statementHint}) {
    switch (node) {
      case Reference(:final name):
        if (_expanding.contains(name)) {
          final error = CyclicStateError(
            cycle: [..._expanding, name],
            statementId: statementHint,
          );
          _reportError(error);
          return widget.errorBuilder?.call(error) ??
              _OpenUiErrorPlaceholder(error: error);
        }
        final stmt = ctx.statements[name];
        if (stmt == null) return const SizedBox.shrink();
        // chuk_chat: a query or mutation has no widget form.
        if (stmt.kind == StatementKind.query ||
            stmt.kind == StatementKind.mutation) {
          return const SizedBox.shrink();
        }
        _expanding.add(name);
        try {
          return _renderAst(stmt.expression, ctx, statementHint: name);
        } finally {
          _expanding.remove(name);
        }
      case CompCall():
        return _renderComp(node, ctx, statementHint: statementHint);
      case BuiltinCall():
        return _renderBuiltinAsWidget(node, ctx, statementHint: statementHint);
      case Literal(:final value):
        return _wrapPrimitive(value);
      case StateRef(:final name):
        return _wrapPrimitive(ctx.store.get('\$$name'));
      case ArrayLit(:final elements):
        return _wrapList(
          [
            for (final e in elements)
              _renderAst(e, ctx, statementHint: statementHint),
          ],
        );
      case NullLiteral():
        return const SizedBox.shrink();
      case StateAssign():
      case BinaryOp():
      case UnaryOp():
      case MemberAccess():
      case IndexAccess():
      case ObjectLit():
      case MutationCall():
        final value = evaluate(node, ctx);
        return _wrapPrimitive(value);
      case Ternary(:final condition, :final then, :final otherwise):
        final condVal = evaluate(condition, ctx);
        final takeThen = isTruthyValue(condVal);
        return _renderAst(
          takeThen ? then : otherwise,
          ctx,
          statementHint: statementHint,
        );
    }
  }

  Widget _renderComp(
    CompCall call,
    EvalContext ctx, {
    String? statementHint,
  }) {
    final definition = widget.library.component(call.type);
    if (definition == null) {
      return _errorPlaceholder(
        UnknownComponentError(
          component: call.type,
          statementId: statementHint,
        ),
      );
    }
    final id = statementHint ?? '';
    if (widget.componentRegistry.isData(call.type)) {
      // chuk_chat: data-only components resolve their props now and
      // hand them to the parent as a DataNode.
      Map<String, Object?> props;
      try {
        props = _resolveProps(call, definition.schema, ctx, id);
      } on Object catch (error) {
        _reportError(EvaluationError(message: '$error', statementId: id));
        props = const <String, Object?>{};
      }
      return DataNode(typeName: call.type, props: props, statementId: id);
    }
    final render = widget.componentRegistry[call.type];
    if (render == null) {
      return _errorPlaceholder(
        MissingRendererError(
          component: call.type,
          statementId: statementHint,
        ),
      );
    }
    // No explicit key: relying on tree-position identity. Adding a
    // ValueKey('${call.type}#$id') would collide when an `ArrayLit` lists
    // multiple siblings of the same component type at the same parent
    // statement id.
    // chuk_chat: the builder runs later, in its own build. Carry the
    // chain of statements that led here, so a cycle through component
    // calls (`a = Column([b])`, `b = Column([a])`) is detected instead
    // of building an endless tree.
    final ancestors = Set<String>.of(_expanding);
    return ErrorBoundary(
      statementId: id,
      onError: _reportError,
      builder: (context) {
        final saved = Set<String>.of(_expanding);
        _expanding
          ..clear()
          ..addAll(ancestors);
        try {
          final props = _resolveProps(call, definition.schema, ctx, id);
          return render(ctx, props, _renderAst, id);
        } finally {
          _expanding
            ..clear()
            ..addAll(saved);
        }
      },
    );
  }

  Widget _renderBuiltinAsWidget(
    BuiltinCall call,
    EvalContext ctx, {
    String? statementHint,
  }) {
    if (_isIterating(call)) {
      final widgets = _renderIteration(call, ctx, statementHint: statementHint);
      if (widgets == null) return const SizedBox.shrink();
      return _wrapList(widgets);
    }
    return _wrapPrimitive(evaluate(call, ctx));
  }

  /// Evaluates an `@Each`/`@Map` call and renders its template once per
  /// item with the iteration vars in scope. `@Each` binds a named loop
  /// var (`args[1]` is a string literal) and `$index`; `@Map` keeps
  /// `$item` / `$index`. Returns `null` when the call isn't shaped
  /// right (missing args, non-list list, invalid name literal).
  List<Widget>? _renderIteration(
    BuiltinCall call,
    EvalContext ctx, {
    String? statementHint,
  }) {
    if (call.name == '@Each') {
      if (call.args.length != 3) return null;
      final nameArg = call.args[1].value;
      if (nameArg is! Literal || nameArg.value is! String) return null;
      final loopVar = nameArg.value! as String;
      final listVal = evaluate(call.args[0].value, ctx);
      if (listVal is! List<Object?>) return null;
      final template = call.args[2].value;
      return [
        for (var i = 0; i < listVal.length; i++)
          _renderAst(
            template,
            ctx.withIteration(<String, Object?>{
              loopVar: listVal[i],
              r'$index': i,
            }),
            statementHint: statementHint,
          ),
      ];
    }
    if (call.args.length < 2) return null;
    final listVal = evaluate(call.args[0].value, ctx);
    if (listVal is! List<Object?>) return null;
    final template = call.args[1].value;
    return [
      for (var i = 0; i < listVal.length; i++)
        _renderAst(
          template,
          ctx.withIteration(<String, Object?>{
            r'$item': listVal[i],
            r'$index': i,
          }),
          statementHint: statementHint,
        ),
    ];
  }

  Map<String, Object?> _resolveProps(
    CompCall call,
    Schema schema,
    EvalContext ctx,
    String statementId,
  ) {
    final properties =
        (schema.value['properties'] as Map<String, Object?>?) ??
        const <String, Object?>{};
    final propNames = orderedPropertyNames(schema);
    return bindPositionalProps(
      call: call,
      propNames: propNames,
      resolveArg: (arg, propName) {
        final value = arg.value;
        final isReactive = _isReactivePropName(properties, propName);
        final isAction = _isActionPropName(properties, propName);
        if (isReactive && value is StateRef) {
          final fullName = '\$${value.name}';
          return ReactiveAssign(
            target: fullName,
            value: _store.get(fullName),
          );
        }
        return _resolvePropValue(
          value,
          ctx,
          statementId,
          allowAction: isAction,
        );
      },
    );
  }

  Object? _resolvePropValue(
    AstNode value,
    EvalContext ctx,
    String statementId, {
    bool allowAction = false,
  }) {
    if (allowAction) {
      if (value is ArrayLit) {
        ctx.errors.add(
          const EvaluationError(
            message:
                'x-action props require Action([...]); bare arrays are not '
                'supported',
          ),
        );
        return null;
      }
      var evaluated =
          value is BuiltinCall && _actionStepNames.contains(value.name)
          // chuk_chat: a bare step (`@ToAssistant("x")`) without the
          // `Action([...])` wrapper.
          ? actionPlanFromActionCall(
              CompCall('Action', [
                Argument(
                  value: ArrayLit([value], offset: value.offset),
                  offset: value.offset,
                ),
              ], offset: value.offset),
            )
          : evaluate(value, ctx);
      // chuk_chat: the object-literal form
      // `{type: "continue_conversation", context: "..."}`.
      if (evaluated is Map) evaluated = actionPlanFromObject(evaluated);
      if (evaluated is ActionPlan) evaluated = bindActionPlan(evaluated, ctx);
      if (evaluated is ActionPlan && evaluated.steps.isNotEmpty) {
        // Disable interactivity while the containing statement is still
        // being streamed (Acceptance Gap A6).
        final result = _lastResult;
        final disabled =
            widget.isStreaming &&
            (result?.meta.incomplete.contains(statementId) ?? false);
        if (disabled) return null;
        return evaluated;
      }
      return null;
    }
    if (value is CompCall) {
      // chuk_chat: `Action(...)` and an inline `Query(...)` are values.
      if (value.type == 'Action' || value.type == 'Query') {
        return evaluate(value, ctx);
      }
      return _renderAst(value, ctx, statementHint: statementId);
    }
    // chuk_chat: a reference to a component statement
    // (`Form("f", btns, ...)` with `btns = Buttons(...)`) renders that
    // component. A reference to a plain value evaluates as before.
    if (value is Reference &&
        ctx.statements.containsKey(value.name) &&
        _isWidgetLike(value, ctx, <String>{})) {
      // chuk_chat: a reference to an array or object statement
      // (`slides = [[a, b], [c]]`) keeps its shape.
      if (_collectionStatement(value.name, ctx, <String>{}) != null) {
        return _resolveCollectionReference(value.name, ctx);
      }
      return _renderAst(value, ctx, statementHint: statementId);
    }
    if (value is Ternary && _isWidgetLike(value, ctx, <String>{})) {
      final takeThen = isTruthyValue(evaluate(value.condition, ctx));
      return _resolvePropValue(
        takeThen ? value.then : value.otherwise,
        ctx,
        statementId,
      );
    }
    if (value is ArrayLit || value is ObjectLit) {
      // `Reference` counts as widget-like because the JS reference's
      // canonical idiom is `root = Column(children: [a, b])` with
      // `a = Card(...)`. The reference target is most often a CompCall
      // and renderNode follows it to the right widget.
      //
      // chuk_chat: only references that lead to a component count, so
      // `["a", b]` with `b = "x"` stays a list of strings. Nested
      // arrays and object values resolve the same way.
      if (_isWidgetLike(value, ctx, <String>{})) {
        return _resolveCollection(value, ctx, statementId);
      }
      return evaluate(value, ctx);
    }
    if (value is BuiltinCall && _isIterating(value)) {
      // @Each/@Map producing widgets — pre-render when the template is
      // a component call. @Each's template lives at args[2] (the loop
      // name occupies args[1]); @Map keeps args[1].
      final templateIndex = value.name == '@Each' ? 2 : 1;
      if (value.args.length > templateIndex &&
          value.args[templateIndex].value is CompCall) {
        final widgets = _renderIteration(
          value,
          ctx,
          statementHint: statementId,
        );
        if (widgets != null) return widgets;
      }
      return evaluate(value, ctx);
    }
    return evaluate(value, ctx);
  }

  /// chuk_chat: resolves an array or object literal that holds
  /// components. A component becomes its widget (a data-only one its
  /// [DataNode]), a nested array or object resolves the same way, and
  /// a plain value is evaluated.
  Object? _resolveCollection(
    AstNode node,
    EvalContext ctx,
    String statementId,
  ) {
    Object? item(AstNode e) {
      if (!_isWidgetLike(e, ctx, <String>{})) return evaluate(e, ctx);
      if (e is ArrayLit || e is ObjectLit) {
        return _resolveCollection(e, ctx, statementId);
      }
      if (e is Reference &&
          _collectionStatement(e.name, ctx, <String>{}) != null) {
        return _resolveCollectionReference(e.name, ctx);
      }
      return _renderAst(e, ctx, statementHint: statementId);
    }

    return switch (node) {
      ArrayLit(:final elements) => [for (final e in elements) item(e)],
      ObjectLit(:final entries) => <String, Object?>{
        for (final e in entries) e.key: item(e.value),
      },
      _ => item(node),
    };
  }

  /// chuk_chat: resolves the array or object a statement holds, with
  /// the same cycle guard as a reference in widget position.
  Object? _resolveCollectionReference(String name, EvalContext ctx) {
    if (_expanding.contains(name)) {
      _reportError(
        CyclicStateError(cycle: [..._expanding, name], statementId: name),
      );
      return null;
    }
    final node = _collectionStatement(name, ctx, <String>{});
    if (node == null) return null;
    _expanding.add(name);
    try {
      return _resolveCollection(node, ctx, name);
    } finally {
      _expanding.remove(name);
    }
  }

  /// chuk_chat: the array or object literal that the value statement
  /// [name] holds, following references to references. Null for
  /// anything else.
  AstNode? _collectionStatement(
    String name,
    EvalContext ctx,
    Set<String> seen,
  ) {
    if (ctx.iterationVars.containsKey(name)) return null;
    if (!seen.add(name)) return null;
    final stmt = ctx.statements[name];
    if (stmt == null || stmt.kind != StatementKind.value) return null;
    final expr = stmt.expression;
    if (expr is ArrayLit || expr is ObjectLit) return expr;
    if (expr is Reference) return _collectionStatement(expr.name, ctx, seen);
    return null;
  }

  bool _isIterating(BuiltinCall call) =>
      call.name == '@Each' || call.name == '@Map';

  static const Set<String> _actionStepNames = <String>{
    '@ToAssistant',
    '@OpenUrl',
    '@Run',
    '@Set',
    '@Reset',
  };

  /// chuk_chat: whether [node] produces a widget (a component call, a
  /// widget-producing `@Each`/`@Map`, a ternary with a widget branch,
  /// an array or object with a widget inside, or a reference to one of
  /// those). `Action` and `Query` calls are values, not widgets.
  bool _isWidgetLike(AstNode node, EvalContext ctx, Set<String> seen) {
    switch (node) {
      case CompCall(:final type):
        return type != 'Action' && type != 'Query';
      case BuiltinCall():
        return _isIterating(node);
      case Ternary(:final then, :final otherwise):
        return _isWidgetLike(then, ctx, seen) ||
            _isWidgetLike(otherwise, ctx, seen);
      case ArrayLit(:final elements):
        return elements.any((e) => _isWidgetLike(e, ctx, seen));
      case ObjectLit(:final entries):
        return entries.any((e) => _isWidgetLike(e.value, ctx, seen));
      case Reference(:final name):
        if (ctx.iterationVars.containsKey(name)) return false;
        if (!seen.add(name)) return false;
        final stmt = ctx.statements[name];
        // An unresolved reference counts as widget-like while streaming:
        // its statement most often is a component that has not arrived.
        if (stmt == null) return true;
        if (stmt.kind != StatementKind.value) return false;
        return _isWidgetLike(stmt.expression, ctx, seen);
      default:
        return false;
    }
  }

  bool _isReactivePropName(Map<String, Object?> properties, String name) {
    final spec = properties[name];
    if (spec is! Map<String, Object?>) return false;
    return spec['x-reactive'] == true;
  }

  bool _isActionPropName(Map<String, Object?> properties, String name) {
    final spec = properties[name];
    if (spec is! Map<String, Object?>) return false;
    return spec['x-action'] == true;
  }

  /// Routes [error] through the [Renderer.onError] callback with the
  /// renderer-wide structural-equality dedup. Called from the error
  /// boundary (build-time component throws), the reference-cycle guard
  /// in [_renderAst], and [_errorPlaceholder] (unknown component, etc).
  /// All call sites land here so the reporting policy lives in one
  /// place.
  ///
  /// chuk_chat: an error already in the list is not added again (each
  /// rebuild reports build-time errors anew), and `onError` runs after
  /// the frame, never during build, so the host may call `setState`.
  void _reportError(OpenUIError error) {
    if (_lastReportedErrors.contains(error)) return;
    _lastReportedErrors = List.unmodifiable(<OpenUIError>[
      ..._lastReportedErrors,
      error,
    ]);
    _scheduleErrorNotify();
  }

  void _scheduleErrorNotify() {
    if (widget.onError == null || _errorNotifyScheduled) return;
    _errorNotifyScheduled = true;
    // Outside a frame (a tool future, a timer), ensureVisualUpdate
    // makes sure a frame comes and runs the callback.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _errorNotifyScheduled = false;
        if (!mounted) return;
        final errors = _lastReportedErrors;
        if (_errorListsEqual(errors, _lastNotifiedErrors)) return;
        _lastNotifiedErrors = errors;
        widget.onError?.call(errors);
      })
      ..ensureVisualUpdate();
  }

  Widget _errorPlaceholder(OpenUIError error) {
    _reportError(error);
    return widget.errorBuilder?.call(error) ??
        _OpenUiErrorPlaceholder(error: error);
  }

  Widget _wrapPrimitive(Object? value) {
    if (value == null) return const SizedBox.shrink();
    if (value is Widget) return value;
    return Text('$value');
  }

  Widget _wrapList(List<Widget> children) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

bool _errorListsEqual(List<OpenUIError> a, List<OpenUIError> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _OpenUiErrorPlaceholder extends StatelessWidget {
  const _OpenUiErrorPlaceholder({required this.error});

  final OpenUIError error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        '${error.code}: ${error.message ?? ''}',
        style: const TextStyle(color: Color(0xFFB00020)),
      ),
    );
  }
}
