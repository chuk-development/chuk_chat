// Tests for the OpenUI Lang v0.5 gaps that chuk_chat closed in the
// vendored core. Semantics follow upstream thesysdev/openui
// `packages/lang-core/src`.

import 'package:openui_core/openui_core.dart';
import 'package:test/test.dart';

EvalContext _ctx(String source, {Store? store}) {
  final program = parseProgram(source);
  expect(program.errors, isEmpty, reason: 'source must parse');
  return EvalContext(
    statements: program.statements,
    store: store ?? Store(),
    builtins: functionalBuiltins,
  );
}

Object? _eval(String source, [String name = 'a', Store? store]) {
  final ctx = _ctx(source, store: store);
  return evaluate(ctx.statements[name]!.expression, ctx);
}

void main() {
  group('preprocess: fences', () {
    test('returns input without a fence unchanged', () {
      expect(stripFences('root = A()\n'), 'root = A()\n');
    });

    test('takes the body of a closed fence and drops prose', () {
      const src = 'Here:\n\n```openui-lang\nroot = A()\n```\n\nDone.';
      expect(stripFences(src), 'root = A()\n');
    });

    test('joins several fences with a newline', () {
      const src = '```openui-lang\na = 1\n```\ntext\n```\nb = 2\n```';
      expect(stripFences(src), 'a = 1\n\nb = 2\n');
    });

    test('an open fence while streaming yields the rest', () {
      expect(stripFences('Hi\n```openui-lang\nroot = A("x'), 'root = A("x');
    });

    test('a fence line without a newline yields an empty body', () {
      expect(stripFences('Hi\n```openui-la'), '');
    });

    test('backticks inside a string do not close the fence', () {
      const src = '```\na = "x ``` y"\n```';
      expect(stripFences(src), 'a = "x ``` y"\n');
    });
  });

  group('preprocess: comments', () {
    test('drops // and # comments outside strings', () {
      const src = 'a = 1 // one\n# whole line\nb = "#fff // no"\n';
      expect(stripComments(src), 'a = 1\n\nb = "#fff // no"\n');
    });

    test('comment-only lines do not produce parse errors', () {
      final parser = createStreamingParser();
      final result = parser.set(
        '// the root\nroot = Stack([a]) # main\na = Text("x")\n',
      );
      expect(result.meta.errors, isEmpty);
      expect(result.statements.map((s) => s.name), ['root', 'a']);
    });
  });

  group('streaming parser: inline mode', () {
    test('parses a fenced program with prose around it', () {
      final parser = createStreamingParser();
      final result = parser.set(
        'Here is your chart:\n\n```openui-lang\nroot = Stack([chart])\n'
        'chart = BarChart(["Oct"], [Series("A", [1])])\n```\n\nDone.',
      );
      expect(result.meta.errors, isEmpty);
      expect(result.root, isNotNull);
      expect(result.statements, hasLength(2));
    });

    test('an unclosed fence while streaming still renders a root', () {
      final parser = createStreamingParser();
      final result = parser.set(
        'Text first\n```openui-lang\nroot = Stack([a])\na = Text("hel',
      );
      expect(result.meta.errors, isEmpty);
      expect(result.root, isNotNull);
      expect(result.meta.incomplete, contains('a'));
    });

    test('char-by-char streaming of a fenced program ends error-free', () {
      const src =
          'Intro\n```openui-lang\nroot = Card([t])\n'
          't = TextContent("Hello", "large")\n```\nOutro';
      final parser = createStreamingParser();
      late ParseResult result;
      for (var i = 0; i < src.length; i++) {
        result = parser.push(src[i]);
      }
      expect(result.meta.errors, isEmpty);
      expect(result.statements.map((s) => s.name), ['root', 't']);
    });
  });

  group('canonical Query', () {
    const src =
        'data = Query("analytics", {days: \$days}, {rows: []}, 30)\n'
        '\$days = "7"\n';

    test('parses as a query statement and a QueryDecl', () {
      final result = createStreamingParser().set(src);
      expect(result.meta.errors, isEmpty);
      final decl = result.meta.queries.single;
      expect(decl.statementId, 'data');
      expect(decl.toolName, 'analytics');
      expect(decl.isCanonical, isTrue);
      expect(decl.argsAst, isA<ObjectLit>());
      expect(decl.defaultsAst, isA<ObjectLit>());
      expect(decl.refreshSeconds, 30);
      expect(result.meta.orphaned, isEmpty);
    });

    test('accepts a bare identifier as the tool name', () {
      final decl = canonicalQueryDecl(
        'q',
        parseExpression('Query(tool, {})') as CompCall,
      );
      expect(decl!.toolName, 'tool');
      expect(decl.refreshSeconds, isNull);
    });

    test('returns null without a tool name', () {
      expect(
        canonicalQueryDecl('q', parseExpression('Query(1)') as CompCall),
        isNull,
      );
      expect(
        canonicalQueryDecl('q', parseExpression('Query()') as CompCall),
        isNull,
      );
    });

    test('a reference reads the defaults until data arrives', () {
      final store = Store();
      expect(_eval('a = data.rows\n$src', 'a', store), <Object?>[]);
      store.set('data', {
        'rows': [
          {'day': 'Mon'},
        ],
      });
      expect(_eval('a = data.rows.day\n$src', 'a', store), ['Mon']);
    });

    test('an inline Query evaluates to its defaults', () {
      expect(_eval('a = Query("t", {}, 5)'), 5);
      expect(_eval('a = Query("t", {})'), isNull);
    });

    test('the legacy named form is still a migration error', () {
      final program = parseProgram('users = Query(name: "list")');
      expect(program.errors.single.message, contains('@Query'));
    });
  });

  group('canonical Mutation', () {
    test('positional Mutation parses as a mutation declaration', () {
      final result = createStreamingParser().set(
        'save = Mutation("save_note", {days: 1})\n',
      );
      expect(result.meta.errors, isEmpty);
      final decl = result.meta.mutations.single;
      expect(decl.statementId, 'save');
      expect(decl.args, hasLength(2));
      expect(decl.args.first.name, isNull);
    });
  });

  group('array pluck', () {
    test('plucks a field from each element', () {
      expect(
        _eval('a = rows.title\nrows = [{title: "x"}, {title: "y"}, 3]'),
        ['x', 'y', null],
      );
    });

    test('length on a list is still the length', () {
      expect(_eval('a = [1, 2].length'), 2);
    });

    test('nested pluck works on a list of lists of maps', () {
      expect(
        _eval('a = data.rows.v\ndata = {rows: [{v: 1}, {v: 2}]}'),
        [1, 2],
      );
    });
  });

  group('builtins', () {
    test('@Sum @Avg @Min @Max', () {
      expect(_eval('a = @Sum([1, 2, "3"])'), 6);
      expect(_eval('a = @Avg([1, 2, 3, 4])'), 2.5);
      expect(_eval('a = @Min([3, 1, 2])'), 1);
      expect(_eval('a = @Max([3, 1, 2])'), 3);
      expect(_eval('a = @Sum(null)'), 0);
      expect(_eval('a = @Avg([])'), 0);
      expect(_eval('a = @Min([])'), 0);
      expect(_eval('a = @Max("x")'), 0);
    });

    test('@First @Last', () {
      expect(_eval('a = @First([1, 2])'), 1);
      expect(_eval('a = @Last([1, 2])'), 2);
      expect(_eval('a = @First([])'), isNull);
      expect(_eval('a = @Last(3)'), isNull);
      expect(_eval('a = @First()'), isNull);
    });

    test('@Sort by field, numeric and text, asc and desc', () {
      const rows = '\nrows = [{n: 2, s: "b"}, {n: 10, s: "a"}, {n: 1, s: "c"}]';
      expect(_eval('a = @Sort(rows, "n").n$rows'), [1, 2, 10]);
      expect(_eval('a = @Sort(rows, "n", "desc").n$rows'), [10, 2, 1]);
      expect(_eval('a = @Sort(rows, "s").s$rows'), ['a', 'b', 'c']);
      expect(_eval('a = @Sort([3, 1, 2], "")'), [1, 2, 3]);
      expect(_eval('a = @Sort("x", "n")'), 'x');
    });

    test('@Sort keeps equal elements in order and reads dot paths', () {
      expect(
        _eval(
          'a = @Sort(r, "p.v").id\n'
          'r = [{id: 1, p: {v: 2}}, {id: 2, p: {v: 1}}, {id: 3, p: {v: 1}}]',
        ),
        [2, 3, 1],
      );
    });

    test('@Filter canonical form with every operator', () {
      const rows = '\nrows = [{v: 5, s: "apple"}, {v: 15, s: "pear"}]';
      expect(_eval('a = @Filter(rows, "v", ">", 10).v$rows'), [15]);
      expect(_eval('a = @Filter(rows, "v", "<", 10).v$rows'), [5]);
      expect(_eval('a = @Filter(rows, "v", ">=", 15).v$rows'), [15]);
      expect(_eval('a = @Filter(rows, "v", "<=", 5).v$rows'), [5]);
      expect(_eval('a = @Filter(rows, "v", "==", "5").v$rows'), [5]);
      expect(_eval('a = @Filter(rows, "v", "!=", 5).v$rows'), [15]);
      expect(_eval('a = @Filter(rows, "s", "contains", "pp").v$rows'), [5]);
      expect(_eval('a = @Filter(rows, "s", "~", "x")$rows'), <Object?>[]);
      expect(_eval('a = @Filter(null, "v", ">", 1)'), <Object?>[]);
      expect(_eval('a = @Filter([1, 2, 3], "", ">", 1)'), [2, 3]);
    });

    test('@Filter loose equality matches JavaScript ==', () {
      expect(_eval('a = @Filter([true, false], "", "==", 1)'), [true]);
      expect(_eval('a = @Filter(["a", null], "", "==", null)'), [null]);
      expect(_eval('a = @Filter(["x", "1"], "", "==", 1)'), ['1']);
    });

    test('@Filter predicate form of the port still works', () {
      expect(_eval(r'a = @Filter([1, 2, 3], $item > 1)'), [2, 3]);
    });

    test('@Round @Abs @Floor @Ceil', () {
      expect(_eval('a = @Round(2.5)'), 3);
      expect(_eval('a = @Round(2.345, 2)'), closeTo(2.35, 1e-9));
      expect(_eval('a = @Round("7.06", 1)'), closeTo(7.1, 1e-9));
      expect(_eval('a = @Round()'), 0);
      expect(_eval('a = @Abs(-3)'), 3);
      expect(_eval('a = @Floor(2.7)'), 2);
      expect(_eval('a = @Ceil(2.1)'), 3);
      expect(_eval('a = @Floor(2)'), 2);
    });

    test('toNumber coerces like upstream', () {
      expect(toNumber(3), 3);
      expect(toNumber(' 4.5 '), 4.5);
      expect(toNumber('x'), 0);
      expect(toNumber(true), 1);
      expect(toNumber(false), 0);
      expect(toNumber(null), 0);
    });
  });

  group('actions', () {
    Future<List<ActionEvent>> run(
      ActionPlan plan, {
      EvalContext? context,
      String? label,
    }) async {
      final events = <ActionEvent>[];
      await dispatchAction(
        plan: plan,
        context: context ?? _ctx(''),
        onRun: (_, _) async {},
        onHostStep: events.add,
        humanFriendlyMessage: label,
      );
      return events;
    }

    test('@OpenUrl in Action([...]) emits an openUrl event', () async {
      final plan = actionPlanFromActionCall(
        parseExpression('Action([@OpenUrl("https://a.b")])'),
      )!;
      expect(plan.steps.single, isA<OpenUrlStep>());
      final events = await run(plan);
      expect(events.single.type, BuiltinActionType.openUrl);
      expect(events.single.params['url'], 'https://a.b');
      expect(events.single.params['success'], isTrue);
    });

    test('@OpenUrl without args is dropped, bad URL fails', () async {
      final empty = actionPlanFromActionCall(
        parseExpression('Action([@OpenUrl()])'),
      )!;
      expect(empty.steps, isEmpty);
      final bad = actionPlanFromActionCall(
        parseExpression('Action([@OpenUrl(3)])'),
      )!;
      final events = await run(bad);
      expect(events.single.params['success'], isFalse);
    });

    test('object form continue_conversation sends the label', () async {
      final plan = actionPlanFromObject({
        'type': 'continue_conversation',
        'context': 'Option A',
      })!;
      final events = await run(plan, label: 'Pick A');
      expect(events.single.type, BuiltinActionType.continueConversation);
      expect(events.single.humanFriendlyMessage, 'Pick A');
      expect(events.single.params['context'], 'Option A');
    });

    test('object form without type and with params map', () async {
      final plan = actionPlanFromObject({
        'params': {'context': 'ctx'},
      })!;
      final events = await run(plan, label: 'L');
      expect(events.single.params['context'], 'ctx');
    });

    test('object form open_url', () async {
      final plan = actionPlanFromObject({
        'type': 'open_url',
        'url': 'https://x.y',
      })!;
      final events = await run(plan);
      expect(events.single.params['url'], 'https://x.y');
      expect(actionPlanFromObject({'type': 'open_url'}), isNull);
    });

    test('object form rejects unknown types and non-maps', () {
      expect(actionPlanFromObject({'type': 'custom'}), isNull);
      expect(actionPlanFromObject('x'), isNull);
    });

    test('bindActionPlan keeps loop variables for later clicks', () async {
      final store = Store();
      final base = _ctx('', store: store);
      final loop = base.withIteration({
        'item': {'id': 7, 'url': 'https://i', 'name': 'Seven'},
      });
      final plan = actionPlanFromActionCall(
        parseExpression(
          r'Action([@Set($sel, item.id), @OpenUrl(item.url), '
          '@ToAssistant(item.name, item.name)])',
        ),
      )!;
      final bound = bindActionPlan(plan, loop);
      final events = await run(bound, context: base);
      expect(store.get(r'$sel'), 7);
      expect(events[1].params['url'], 'https://i');
      expect(events[2].humanFriendlyMessage, 'Seven');
      expect(events[2].params['context'], 'Seven');
    });

    test('bindActionPlan keeps label steps and null values', () async {
      final loop = _ctx('').withIteration({'item': null});
      final plan = ActionPlan(
        steps: [
          const ContinueConversationStep(
            messageAst: NullLiteral(offset: 0),
          ),
          OpenUrlStep(urlAst: parseExpression('item')),
          const ResetStep(targets: []),
        ],
      );
      final bound = bindActionPlan(plan, loop);
      expect(
        (bound.steps[0] as ContinueConversationStep).messageAst,
        isA<NullLiteral>(),
      );
      expect((bound.steps[1] as OpenUrlStep).urlAst, isA<NullLiteral>());
      expect(bound.steps[2], isA<ResetStep>());
    });

    test('bindActionPlan without loop variables returns the plan', () {
      const plan = ActionPlan(steps: []);
      expect(identical(bindActionPlan(plan, _ctx('')), plan), isTrue);
    });

    test('step equality covers scope and url', () {
      final a = SetStep(
        target: r'$a',
        valueAst: parseExpression('1'),
        scope: const {'x': 1},
      );
      final b = SetStep(
        target: r'$a',
        valueAst: parseExpression('1'),
        scope: const {'x': 2},
      );
      expect(a == b, isFalse);
      expect(
        OpenUrlStep(urlAst: parseExpression('"u"')),
        OpenUrlStep(urlAst: parseExpression('"u"')),
      );
      expect(
        OpenUrlStep(urlAst: parseExpression('"u"')).hashCode,
        OpenUrlStep(urlAst: parseExpression('"u"')).hashCode,
      );
    });
  });

  group('integration parse', () {
    test('Action and inline Query are not unknown components', () {
      final result = parse(
        'root = B("x", Action([@ToAssistant("hi")]), Query("t", {}, 1))',
        {
          'B': const [
            ParamSpec(name: 'label', required: true),
            ParamSpec(name: 'action', required: false),
            ParamSpec(name: 'data', required: false),
          ],
        },
      );
      expect(result.meta.errors, isEmpty);
      expect(result.root!.props['action'], isA<CompCall>());
    });

    test('parse strips prose around a fence', () {
      final result = parse(
        'Hi\n```openui-lang\nroot = B("x")\n```\nbye',
        {
          'B': const [ParamSpec(name: 'label', required: true)],
        },
      );
      expect(result.root!.props['label'], 'x');
    });
  });
}
