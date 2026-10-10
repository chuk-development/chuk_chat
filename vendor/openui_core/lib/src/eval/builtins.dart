import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:openui_core/src/errors/errors.dart';
import 'package:openui_core/src/eval/evaluator.dart';
import 'package:openui_core/src/parser/parser.dart';

/// The five functional builtins from the OpenUI Lang spec, ready to
/// drop into [EvalContext.builtins]:
///
/// - `@Count(list)` — returns `list.length`, or `0` if the input is
///   null. Anything else is a category error and yields `0`.
/// - `@Filter(list, predicate)` — keeps each item for which
///   `predicate` evaluates truthy with `$item` and `$index` in scope.
/// - `@Each(list, "name", template)` — evaluates `template` once per
///   item with the named loop var (bound under its bare key) and
///   `$index` in scope; returns the list of results. The renderer's
///   iteration source.
/// - `@Map(list, transform)` — `@Filter`-shaped: `$item` / `$index`
///   in scope. Spec calls the second arg a "transform ref", but at
///   the evaluator layer the semantics match `@Filter`.
/// - `@Query(...)` — registered as a no-op at evaluation time; the
///   renderer's query manager performs the actual tool call.
///
/// Action-step builtins (`@Set`, `@Reset`, `@Run`, `@ToAssistant`)
/// are in a separate dispatcher and not part of this
/// registry — they are not value-producing.
///
/// Marked `@experimental` per D12.
@experimental
final Map<String, BuiltinHandler> functionalBuiltins =
    Map<String, BuiltinHandler>.unmodifiable(<String, BuiltinHandler>{
      '@Count': _evalCount,
      '@Filter': _evalFilter,
      '@Each': _evalEach,
      '@Map': _evalMap,
      '@Query': _evalQueryNoop,
      // chuk_chat: the rest of the canonical v0.5 builtins, with the
      // semantics of upstream `lang-core/src/parser/builtins.ts`.
      '@Sum': _eager1((v) => _numbers(v).fold<num>(0, (a, b) => a + b)),
      '@Avg': _eager1((v) {
        final n = _numbers(v);
        return n.isEmpty ? 0 : n.fold<num>(0, (a, b) => a + b) / n.length;
      }),
      '@Min': _eager1((v) {
        final n = _numbers(v);
        return n.isEmpty ? 0 : n.reduce((a, b) => a < b ? a : b);
      }),
      '@Max': _eager1((v) {
        final n = _numbers(v);
        return n.isEmpty ? 0 : n.reduce((a, b) => a > b ? a : b);
      }),
      '@First': _eager1(
        (v) => v is List<Object?> && v.isNotEmpty ? v.first : null,
      ),
      '@Last': _eager1(
        (v) => v is List<Object?> && v.isNotEmpty ? v.last : null,
      ),
      '@Sort': _evalSort,
      '@Round': _evalRound,
      '@Abs': _eager1((v) => toNumber(v).abs()),
      '@Floor': _eager1((v) => _intIfWhole(toNumber(v).floor())),
      '@Ceil': _eager1((v) => _intIfWhole(toNumber(v).ceil())),
    });

/// Coerces [value] to a number as upstream `toNumber` does: numbers
/// pass through, numeric strings parse, `true` is 1, all else is 0.
///
/// Marked `@experimental` per D12.
@experimental
num toNumber(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim()) ?? 0;
  if (value is bool) return value ? 1 : 0;
  return 0;
}

/// Wraps a one-argument function as an eager [BuiltinHandler]: the
/// first argument is evaluated, a missing argument is `null`.
BuiltinHandler _eager1(Object? Function(Object? value) fn) {
  return (call, context) => fn(
    call.args.isEmpty ? null : evaluate(call.args.first.value, context),
  );
}

List<num> _numbers(Object? value) {
  if (value is! List<Object?>) return const <num>[];
  return [for (final v in value) toNumber(v)];
}

num _intIfWhole(num n) => n is double && n == n.roundToDouble() ? n.toInt() : n;

/// Resolves a field path (`a.b`) on [item]. An empty path returns the
/// item itself.
Object? _field(Object? item, String path) {
  if (path.isEmpty) return item;
  var cur = item;
  for (final part in path.split('.')) {
    if (cur is! Map<String, Object?>) return null;
    cur = cur[part];
  }
  return cur;
}

bool _isNumeric(Object? v) =>
    v is num ||
    (v is String && v.trim().isNotEmpty && num.tryParse(v.trim()) != null);

Object? _evalSort(BuiltinCall call, EvalContext context) {
  Object? arg(int i) =>
      call.args.length > i ? evaluate(call.args[i].value, context) : null;
  final list = arg(0);
  if (list is! List<Object?>) return list;
  final field = arg(1)?.toString() ?? '';
  final desc = (arg(2)?.toString() ?? 'asc') == 'desc';
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])]
    ..sort((a, b) {
      final av = _field(a.$2, field);
      final bv = _field(b.$2, field);
      int cmp;
      if (_isNumeric(av) && _isNumeric(bv)) {
        cmp = toNumber(av).compareTo(toNumber(bv));
      } else {
        cmp = (av?.toString() ?? '').compareTo(bv?.toString() ?? '');
      }
      if (desc) cmp = -cmp;
      // Stable sort, like JavaScript's Array.prototype.sort.
      return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
    });
  return [for (final e in indexed) e.$2];
}

Object? _evalRound(BuiltinCall call, EvalContext context) {
  final n = toNumber(
    call.args.isEmpty ? null : evaluate(call.args.first.value, context),
  );
  final d = call.args.length > 1
      ? toNumber(evaluate(call.args[1].value, context)).toInt()
      : 0;
  if (d <= 0) return _intIfWhole(n.round());
  final factor = math.pow(10, d);
  // Same as JavaScript Math.round: halves round up.
  return (n * factor + 0.5).floor() / factor;
}

/// Canonical `@Filter(array, field, op, value)`. An empty field
/// compares the element itself.
Object? _evalFilterCanonical(BuiltinCall call, EvalContext context) {
  Object? arg(int i) =>
      call.args.length > i ? evaluate(call.args[i].value, context) : null;
  final list = arg(0);
  if (list is! List<Object?>) return <Object?>[];
  final field = arg(1)?.toString() ?? '';
  final op = arg(2)?.toString() ?? '==';
  final value = arg(3);
  return [
    for (final item in list)
      if (_compare(_field(item, field), op, value)) item,
  ];
}

bool _compare(Object? v, String op, Object? value) {
  switch (op) {
    case '==':
      return _looseEquals(v, value);
    case '!=':
      return !_looseEquals(v, value);
    case '>':
      return toNumber(v) > toNumber(value);
    case '<':
      return toNumber(v) < toNumber(value);
    case '>=':
      return toNumber(v) >= toNumber(value);
    case '<=':
      return toNumber(v) <= toNumber(value);
    case 'contains':
      return (v?.toString() ?? '').contains(value?.toString() ?? '');
  }
  return false;
}

/// JavaScript `==` for the value kinds OpenUI Lang produces.
bool _looseEquals(Object? a, Object? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a is num && b is num) return a == b;
  if ((a is num && b is String) || (a is String && b is num)) {
    return _isNumeric(a) && _isNumeric(b) && toNumber(a) == toNumber(b);
  }
  if (a is bool || b is bool) return toNumber(a) == toNumber(b);
  return a == b;
}

// `@Query` is fired by the renderer's `QueryManager`, not by the
// evaluator. Registering a no-op here keeps an accidental render-time
// traversal of an unfired `@Query` AST from raising
// `no handler registered for builtin @Query`. The result slot lives in
// the store under the statement id (e.g. `$products`).
Object? _evalQueryNoop(BuiltinCall call, EvalContext context) => null;

Object? _evalCount(BuiltinCall call, EvalContext context) {
  if (call.args.isEmpty) {
    context.errors.add(
      const EvaluationError(message: '@Count requires 1 argument'),
    );
    return 0;
  }
  final v = evaluate(call.args.first.value, context);
  if (v == null) return 0;
  if (v is List<Object?>) return v.length;
  context.errors.add(
    EvaluationError(
      message: '@Count expects a list, got ${v.runtimeType}',
    ),
  );
  return 0;
}

Object? _evalFilter(BuiltinCall call, EvalContext context) {
  // chuk_chat: three or more args is the canonical
  // `@Filter(array, field, op, value)` form. Two args keep the port's
  // predicate form `@Filter(list, predicate)`.
  if (call.args.length >= 3) return _evalFilterCanonical(call, context);
  if (call.args.length < 2) {
    context.errors.add(
      EvaluationError(
        message:
            '@Filter requires (list, predicate) — got ${call.args.length} args',
      ),
    );
    return <Object?>[];
  }
  final listVal = evaluate(call.args[0].value, context);
  if (listVal == null) return <Object?>[];
  if (listVal is! List<Object?>) {
    context.errors.add(
      EvaluationError(
        message:
            '@Filter expects a list as first arg, got ${listVal.runtimeType}',
      ),
    );
    return <Object?>[];
  }
  final predicate = call.args[1].value;
  final result = <Object?>[];
  for (var i = 0; i < listVal.length; i++) {
    final p = evaluate(
      predicate,
      context.withIteration(<String, Object?>{
        r'$item': listVal[i],
        r'$index': i,
      }),
    );
    if (_truthy(p)) result.add(listVal[i]);
  }
  return result;
}

Object? _evalEach(BuiltinCall call, EvalContext context) {
  if (call.args.length != 3) {
    context.errors.add(
      EvaluationError(
        message:
            '@Each requires (list, "name", template) — 3 args, '
            'got ${call.args.length}',
      ),
    );
    return <Object?>[];
  }
  final nameArg = call.args[1].value;
  if (nameArg is! Literal ||
      nameArg.value is! String ||
      !isValidLoopVarName(nameArg.value! as String)) {
    context.errors.add(
      const EvaluationError(
        message:
            '@Each requires (list, "name", template) — second arg must '
            'be a string identifier literal',
      ),
    );
    return <Object?>[];
  }
  final loopVar = nameArg.value! as String;
  final listVal = evaluate(call.args[0].value, context);
  if (listVal == null) return <Object?>[];
  if (listVal is! List<Object?>) {
    context.errors.add(
      EvaluationError(
        message:
            '@Each expects a list as first arg, got ${listVal.runtimeType}',
      ),
    );
    return <Object?>[];
  }
  final template = call.args[2].value;
  return <Object?>[
    for (var i = 0; i < listVal.length; i++)
      evaluate(
        template,
        context.withIteration(<String, Object?>{
          loopVar: listVal[i],
          r'$index': i,
        }),
      ),
  ];
}

Object? _evalMap(BuiltinCall call, EvalContext context) =>
    _iterate(call, context, '@Map');

List<Object?> _iterate(BuiltinCall call, EvalContext context, String name) {
  if (call.args.length < 2) {
    context.errors.add(
      EvaluationError(
        message:
            '$name requires (list, template) — got ${call.args.length} args',
      ),
    );
    return <Object?>[];
  }
  final listVal = evaluate(call.args[0].value, context);
  if (listVal == null) return <Object?>[];
  if (listVal is! List<Object?>) {
    context.errors.add(
      EvaluationError(
        message:
            '$name expects a list as first arg, got ${listVal.runtimeType}',
      ),
    );
    return <Object?>[];
  }
  final template = call.args[1].value;
  return <Object?>[
    for (var i = 0; i < listVal.length; i++)
      evaluate(
        template,
        context.withIteration(<String, Object?>{
          r'$item': listVal[i],
          r'$index': i,
        }),
      ),
  ];
}

bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List<Object?>) return v.isNotEmpty;
  if (v is Map<String, Object?>) return v.isNotEmpty;
  return true;
}
