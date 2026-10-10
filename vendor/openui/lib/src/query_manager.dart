// Internal references to openui_core experimental types — the entire
// openui_core surface is marked @experimental in v0.1.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:openui/src/tool_registry.dart';
import 'package:openui_core/openui_core.dart';

/// Per-renderer gate that turns `@Query` declarations into one-shot
/// tool calls.
///
/// The manager has no result storage of its own. Results are written
/// straight to the [Store] via `store.set(decl.statementId, value.result)`,
/// which the renderer already subscribes to for reactive rebuilds.
/// Failures are routed to [_onError] (the renderer's existing error
/// sink). The only state the manager keeps is `_fired`: the most
/// recently dispatched evaluated-args map per `statementId`, which
/// gates re-fires.
///
/// `@Run($var)` invalidates a query by clearing its `_fired` entry and
/// calling [ensureFired] again. Args are re-evaluated at fire time
/// against the live [EvalContext], so a `@Set` ahead of `@Run` is
/// reflected in the new call.
///
/// Mutations keep their pre-`@Query` dispatcher path via [fireMutation]
/// — they're explicitly out of scope for this iteration.
///
/// Marked `@experimental` per D12.
@experimental
class QueryManager {
  /// Creates a [QueryManager].
  QueryManager({
    required this.library,
    required this.toolRegistry,
    required this.store,
    required void Function(OpenUIError) onError,
  }) : _onError = onError;

  /// Component and tool definitions used for dispatch lookup.
  final LibraryDefinition library;

  /// Tool executors keyed by tool name.
  final ToolRegistry toolRegistry;

  /// The reactive store that receives resolved query values.
  final Store store;

  final void Function(OpenUIError) _onError;

  final Map<String, Map<String, Object?>> _fired =
      <String, Map<String, Object?>>{};
  // chuk_chat: refresh timers and the latest context per canonical
  // query with a `refreshSeconds` argument.
  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, num> _timerSeconds = <String, num>{};
  final Map<String, (QueryDecl, EvalContext)> _latest =
      <String, (QueryDecl, EvalContext)>{};
  bool _disposed = false;

  /// chuk_chat: the shortest refresh interval a program may ask for.
  /// The model writes `refreshSeconds`, so a tiny value must not turn
  /// into a busy loop against the tool backend.
  static const Duration minRefreshInterval = Duration(seconds: 5);

  /// chuk_chat: the longest refresh interval (one day).
  static const Duration maxRefreshInterval = Duration(days: 1);

  /// chuk_chat: while `true`, refresh timers skip their tick. The
  /// renderer sets it while the response is still streaming.
  bool paused = false;

  /// Fires the query identified by [decl] when its
  /// `(statementId, evaluated-args)` fingerprint differs from the
  /// last fire. Subsequent calls with the same args are no-ops.
  ///
  /// Args are evaluated against [ctx] before the fingerprint compare,
  /// so a `@Run` that re-runs `ensureFired` after a `@Set` re-issues
  /// the call with fresh values.
  void ensureFired(QueryDecl decl, EvalContext ctx) {
    if (_disposed) return;
    if (decl.isCanonical) {
      _ensureCanonical(decl, ctx);
      return;
    }
    final evaluatedArgs = <String, Object?>{
      for (final arg in decl.namedArgs)
        if (arg.name != null) arg.name!: evaluate(arg.value, ctx),
    };
    final last = _fired[decl.statementId];
    // chuk_chat: compare deeply. `evaluate` builds new lists and maps
    // on every call, so `!=` saw a change each time and re-ran the tool.
    if (last != null && _deepEquals(last, evaluatedArgs)) return;
    // Set the in-flight gate synchronously so a second `ensureFired`
    // landing in the same micro-task tick short-circuits before
    // dispatching a duplicate tool call.
    _fired[decl.statementId] = evaluatedArgs;

    final toolDef = library.tool(decl.toolName);
    if (toolDef == null) {
      _onError(
        EvaluationError(
          message: 'Unknown tool: ${decl.toolName}',
          statementId: decl.statementId,
        ),
      );
      return;
    }
    final executor = toolRegistry[decl.toolName];
    if (executor == null) {
      _onError(
        MissingToolExecutorError(
          toolName: decl.toolName,
          statementId: decl.statementId,
        ),
      );
      return;
    }
    unawaited(
      executor(evaluatedArgs)
          .then((value) {
            if (_disposed) return;
            if (value.isError) {
              _onError(
                EvaluationError(
                  message: value.result?.toString() ?? 'Tool call failed',
                  statementId: decl.statementId,
                ),
              );
              return;
            }
            store.set(decl.statementId, value.result);
          })
          .catchError((Object error, StackTrace _) {
            if (_disposed) return;
            _onError(
              error is OpenUIError
                  ? error
                  : EvaluationError(
                      message: error.toString(),
                      statementId: decl.statementId,
                    ),
            );
          }),
    );
  }

  /// chuk_chat: the canonical `name = Query("tool", {args}, {defaults},
  /// refreshSeconds?)` form.
  ///
  /// - Without an executor for the tool, the query stays on its
  ///   defaults. This is not an error: a host without tools still
  ///   renders the view.
  /// - The result is stored under the bare statement id.
  /// - A `$var` change re-fires the query, because the args map then
  ///   differs from the last fire.
  /// - `refreshSeconds > 0` re-fires the query on that interval.
  void _ensureCanonical(QueryDecl decl, EvalContext ctx) {
    final id = decl.statementId;
    _latest[id] = (decl, ctx);
    _syncTimer(decl);
    final argsAst = decl.argsAst;
    final raw = argsAst == null ? null : evaluate(argsAst, ctx);
    final evaluatedArgs = raw is Map<String, Object?>
        ? Map<String, Object?>.of(raw)
        : <String, Object?>{};
    final last = _fired[id];
    if (last != null && _deepEquals(last, evaluatedArgs)) return;
    _fired[id] = evaluatedArgs;
    final executor = toolRegistry[decl.toolName];
    if (executor == null) return;
    unawaited(
      executor(evaluatedArgs)
          .then((value) {
            if (_disposed || value.isError) return;
            store.set(id, value.result);
          })
          .catchError((Object error, StackTrace _) {
            if (_disposed) return;
            _onError(
              error is OpenUIError
                  ? error
                  : EvaluationError(message: error.toString(), statementId: id),
            );
          }),
    );
  }

  void _syncTimer(QueryDecl decl) {
    final id = decl.statementId;
    final seconds = decl.refreshSeconds;
    if (seconds == null || !seconds.isFinite || seconds <= 0) {
      _timers.remove(id)?.cancel();
      _timerSeconds.remove(id);
      return;
    }
    if (_timerSeconds[id] == seconds && _timers.containsKey(id)) return;
    _timers.remove(id)?.cancel();
    _timerSeconds[id] = seconds;
    final ms = (seconds * 1000).round().clamp(
      minRefreshInterval.inMilliseconds,
      maxRefreshInterval.inMilliseconds,
    );
    _timers[id] = Timer.periodic(
      Duration(milliseconds: ms),
      (_) {
        final latest = _latest[id];
        if (_disposed || paused || latest == null) return;
        _fired.remove(id);
        _ensureCanonical(latest.$1, latest.$2);
      },
    );
  }

  /// chuk_chat: cancels the refresh timers of queries whose ids are not
  /// in [liveIds]. The renderer calls it after each parse, so a query
  /// that a new response removed stops polling.
  void retainTimers(Set<String> liveIds) {
    for (final id in _timers.keys.toList()) {
      if (liveIds.contains(id)) continue;
      _timers.remove(id)?.cancel();
      _timerSeconds.remove(id);
      _latest.remove(id);
    }
  }

  /// Number of running refresh timers. For tests.
  @visibleForTesting
  int get activeTimerCount => _timers.length;

  /// Drops the fingerprint for [decl] and re-runs [ensureFired]
  /// against [ctx]. Used by the renderer's `@Run($var)` path and by
  /// tests covering re-fire semantics.
  void invalidate(QueryDecl decl, EvalContext ctx) {
    if (_disposed) return;
    _fired.remove(decl.statementId);
    ensureFired(decl, ctx);
  }

  /// Fires a mutation by [statementId]. Returns the resolved value on
  /// success (mutations are not cached). Errors are wrapped as
  /// [OpenUIError] and rethrown so the dispatcher can halt the plan.
  ///
  /// chuk_chat: the canonical positional form
  /// `Mutation("tool", {args})` is accepted too. Its args object is
  /// evaluated against [ctx] (so `$vars` read the live store).
  Future<Object?> fireMutation(
    String statementId,
    List<Argument> args, [
    EvalContext? ctx,
  ]) async {
    if (_disposed) return null;
    try {
      if (args.isNotEmpty && args.first.name == null) {
        return await _invokeCanonicalMutation(statementId, args, ctx);
      }
      return await _invokeMutation(statementId, args);
    } on Object catch (error) {
      if (_disposed) rethrow;
      final wrapped = error is OpenUIError
          ? error
          : EvaluationError(
              message: error.toString(),
              statementId: statementId,
            );
      _onError(wrapped);
      throw wrapped;
    }
  }

  /// Releases the manager. In-flight futures still complete; their
  /// results are discarded.
  void dispose() {
    _disposed = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _latest.clear();
  }

  Future<Object?> _invokeCanonicalMutation(
    String statementId,
    List<Argument> args,
    EvalContext? ctx,
  ) {
    final first = args.first.value;
    final toolName = first is Literal && first.value is String
        ? first.value! as String
        : first is Reference
        ? first.name
        : null;
    if (toolName == null) {
      return Future<Object?>.error(
        EvaluationError(
          message: 'Mutation needs a tool name as its first argument',
          statementId: statementId,
        ),
      );
    }
    final executor = toolRegistry[toolName];
    if (executor == null) {
      return Future<Object?>.error(
        MissingToolExecutorError(toolName: toolName, statementId: statementId),
      );
    }
    Object? raw;
    if (args.length > 1) {
      raw = ctx != null
          ? evaluate(args[1].value, ctx)
          : _literalValue(args[1].value);
    }
    final toolArgs = raw is Map<String, Object?>
        ? raw
        : const <String, Object?>{};
    return executor(toolArgs).then((value) {
      if (value.isError) {
        throw EvaluationError(
          message: value.result?.toString() ?? 'Tool call failed',
          statementId: statementId,
        );
      }
      return value.result;
    });
  }

  Future<Object?> _invokeMutation(String statementId, List<Argument> args) {
    final toolName = _stringArg(args, 'name');
    if (toolName == null) {
      return Future<Object?>.error(
        EvaluationError(
          message: 'Mutation is missing required string arg "name"',
          statementId: statementId,
        ),
      );
    }
    final toolArgs = _mapArg(args, 'args') ?? const <String, Object?>{};
    final toolDef = library.tool(toolName);
    if (toolDef == null) {
      return Future<Object?>.error(
        ToolNotFoundError(toolName: toolName, statementId: statementId),
      );
    }
    final executor = toolRegistry[toolName];
    if (executor == null) {
      return Future<Object?>.error(
        MissingToolExecutorError(toolName: toolName, statementId: statementId),
      );
    }
    // chuk_chat: an error result is a failure, as in the canonical
    // form, so the action plan stops.
    return executor(toolArgs).then((value) {
      if (value.isError) {
        throw EvaluationError(
          message: value.result?.toString() ?? 'Tool call failed',
          statementId: statementId,
        );
      }
      return value;
    });
  }
}

String? _stringArg(List<Argument> args, String name) {
  for (final a in args) {
    if (a.name != name) continue;
    final v = a.value;
    if (v is Literal && v.value is String) return v.value! as String;
    return null;
  }
  return null;
}

Map<String, Object?>? _mapArg(List<Argument> args, String name) {
  for (final a in args) {
    if (a.name != name) continue;
    final v = a.value;
    if (v is! ObjectLit) return null;
    final out = <String, Object?>{};
    for (final entry in v.entries) {
      out[entry.key] = _literalValue(entry.value);
    }
    return out;
  }
  return null;
}

Object? _literalValue(AstNode node) {
  if (node is Literal) return node.value;
  if (node is NullLiteral) return null;
  return null;
}

bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_deepEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
