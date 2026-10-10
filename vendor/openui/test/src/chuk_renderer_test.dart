// Renderer tests for the features chuk_chat added to the vendored
// port: canonical Query/Mutation, data-only components, references to
// component statements in props, components inside nested arrays and
// object literals, object-literal and bare-step actions,
// `@OpenUrl`, loop-bound actions, the error placeholder builder.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

ComponentDefinition _def(String name, Map<String, Object?> props) {
  return ComponentDefinition(
    name: name,
    schema: Schema.fromMap(<String, Object?>{
      'type': 'object',
      'properties': props,
    }),
  );
}

const _any = <String, Object?>{};
const _action = <String, Object?>{'x-action': true};

final _library = LibraryDefinition(
  components: [
    _def('Text', {'text': _any}),
    _def('Column', {'children': _any}),
    _def('Btn', {'label': _any, 'action': _action}),
    _def('Series', {'category': _any, 'values': _any}),
    _def('Chart', {'labels': _any, 'series': _any}),
    _def('Slot', {'child': _any}),
    _def('Deep', {'value': _any}),
  ],
);

/// Flattens nested lists and maps: widgets stay, other values become
/// text (`key=value` for a map entry).
List<Widget> _flatten(Object? v, [String prefix = '']) {
  if (v is DataNode) return [Text('$prefix${_describe(v)}')];
  if (v is Widget) return [v];
  if (v is List) return [for (final e in v) ..._flatten(e, prefix)];
  if (v is Map) {
    return [
      for (final e in v.entries) ..._flatten(e.value, '$prefix${e.key}='),
    ];
  }
  return [Text('$prefix$v')];
}

String _describe(Object? v) {
  if (v is DataNode) return '${v.typeName}${v.props}';
  if (v is List) return '[${v.map(_describe).join(', ')}]';
  return '$v';
}

final _registry = ComponentRegistry(
  dataComponents: const {'Series'},
  renderers: {
    'Text': (ctx, props, _, _) => Text('${props['text']}'),
    'Column': (ctx, props, _, _) => Column(
      children: [
        for (final c in (props['children'] as List?) ?? const <Object?>[])
          if (c is Widget) c else Text('$c'),
      ],
    ),
    'Btn': (ctx, props, _, _) {
      final label = '${props['label']}';
      final action = props['action'];
      return Builder(
        builder: (context) => TextButton(
          onPressed: action is ActionPlan
              ? () => RendererScope.maybeFind(
                  context,
                )?.triggerAction(label, action: action)
              : null,
          child: Text(label),
        ),
      );
    },
    'Chart': (ctx, props, _, _) =>
        Text('chart ${props['labels']} ${_describe(props['series'])}'),
    'Deep': (ctx, props, _, _) => Column(children: _flatten(props['value'])),
    'Slot': (ctx, props, _, _) {
      final child = props['child'];
      return child is Widget ? child : Text('value ${_describe(child)}');
    },
  },
);

Widget _app({
  required String response,
  ToolRegistry toolRegistry = const ToolRegistry(executors: {}),
  bool isStreaming = false,
  void Function(ActionEvent)? onAction,
  void Function(String)? onOpenUrl,
  void Function(String)? onContinueConversation,
  Widget Function(OpenUIError)? errorBuilder,
  void Function(List<OpenUIError>)? onError,
}) {
  return MaterialApp(
    home: Material(
      child: Renderer(
        response: response,
        library: _library,
        componentRegistry: _registry,
        toolRegistry: toolRegistry,
        isStreaming: isStreaming,
        onAction: onAction,
        onOpenUrl: onOpenUrl,
        onContinueConversation: onContinueConversation,
        errorBuilder: errorBuilder,
        onError: onError,
      ),
    ),
  );
}

void main() {
  group('canonical Query', () {
    const program =
        '\$days = "7"\n'
        'root = Column([t])\n'
        't = Text("rows=" + @Count(data.rows) + '
        '" first=" + @First(data.rows.d))\n'
        'data = Query("stats", {days: \$days}, {rows: []})\n';

    testWidgets('renders defaults and no error without a tool', (
      tester,
    ) async {
      final errors = <OpenUIError>[];
      await tester.pumpWidget(
        _app(response: program, onError: errors.addAll),
      );
      await tester.pumpAndSettle();
      expect(find.text('rows=0 first='), findsOneWidget);
      expect(errors, isEmpty);
    });

    testWidgets(r'renders the tool result and re-fires on a $var change', (
      tester,
    ) async {
      final calls = <Object?>[];
      final tools = ToolRegistry(
        executors: {
          'stats': (args) async {
            calls.add(args['days']);
            return ToolResult({
              'rows': [
                {'d': 'Mon-${args['days']}'},
              ],
            });
          },
        },
      );
      await tester.pumpWidget(
        _app(
          response:
              '${program}b = Btn("30", Action([@Set(\$days, "30")]))\n'
              'root = Column([t, b])\n',
          toolRegistry: tools,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('rows=1 first=Mon-7'), findsOneWidget);
      await tester.tap(find.text('30'));
      await tester.pumpAndSettle();
      expect(calls, ['7', '30']);
      expect(find.text('rows=1 first=Mon-30'), findsOneWidget);
    });

    testWidgets('a tool error keeps the defaults', (tester) async {
      final tools = ToolRegistry(
        executors: {'stats': (_) async => const ToolResult('x', isError: true)},
      );
      await tester.pumpWidget(_app(response: program, toolRegistry: tools));
      await tester.pumpAndSettle();
      expect(find.text('rows=0 first='), findsOneWidget);
    });

    testWidgets('a thrown tool error is reported', (tester) async {
      final errors = <OpenUIError>[];
      final tools = ToolRegistry(
        executors: {'stats': (_) => Future.error(StateError('down'))},
      );
      await tester.pumpWidget(
        _app(response: program, toolRegistry: tools, onError: errors.addAll),
      );
      await tester.pumpAndSettle();
      expect(errors.whereType<EvaluationError>(), isNotEmpty);
    });

    testWidgets('refreshSeconds re-fires on the interval', (tester) async {
      var calls = 0;
      final tools = ToolRegistry(
        executors: {
          'tick': (_) async {
            calls++;
            return ToolResult(calls);
          },
        },
      );
      await tester.pumpWidget(
        _app(
          response:
              'root = Text("n=" + n)\n'
              'n = Query("tick", {}, 0, 1)\n',
          toolRegistry: tools,
        ),
      );
      await tester.pump();
      expect(find.text('n=1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pump();
      expect(find.text('n=2'), findsOneWidget);
      // Dropping the refresh argument stops the timer.
      await tester.pumpWidget(
        _app(
          response:
              'root = Text("n=" + n)\n'
              'n = Query("tick", {}, 0)\n',
          toolRegistry: tools,
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a reference to a query in widget position draws nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          response:
              'root = data\n'
              'data = Query("x", {}, {})\n'
              'm = Mutation("y", {})\n',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Text), findsNothing);
    });
  });

  group('canonical Mutation', () {
    testWidgets('@Run(mutation) calls the tool with evaluated args', (
      tester,
    ) async {
      final calls = <Map<String, Object?>>[];
      final tools = ToolRegistry(
        executors: {
          'save': (args) async {
            calls.add(args);
            return const ToolResult('ok');
          },
        },
      );
      await tester.pumpWidget(
        _app(
          response:
              '\$n = 3\n'
              'root = Btn("Save", Action([@Run(s), @Set(\$n, 4)]))\n'
              's = Mutation("save", {n: \$n})\n',
          toolRegistry: tools,
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(calls, [
        {'n': 3},
      ]);
    });

    testWidgets('a missing executor or an error result halts the plan', (
      tester,
    ) async {
      final events = <ActionEvent>[];
      await tester.pumpWidget(
        _app(
          response:
              'root = Column([a, b, c])\n'
              'a = Btn("A", Action([@Run(s), @ToAssistant("after")]))\n'
              'b = Btn("B", Action([@Run(e), @ToAssistant("after")]))\n'
              'c = Btn("C", Action([@Run(bad)]))\n'
              's = Mutation("nope", {})\n'
              'e = Mutation("err")\n'
              'bad = Mutation(1)\n',
          toolRegistry: ToolRegistry(
            executors: {
              'err': (_) async => const ToolResult('fail', isError: true),
            },
          ),
          onAction: events.add,
        ),
      );
      for (final label in ['A', 'B', 'C']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(events, hasLength(3));
      expect(events.every((e) => e.params['success'] == false), isTrue);
    });
  });

  group('data-only components', () {
    testWidgets('inline and referenced data nodes reach the parent', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          response:
              'root = Chart(["a", "b"], [s1, Series("B", [3, 4])])\n'
              's1 = Series("A", [1, 2])\n',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'chart [a, b] [Series{category: A, values: [1, 2]}, '
          'Series{category: B, values: [3, 4]}]',
        ),
        findsOneWidget,
      );
    });

    testWidgets('@Each over data components yields data nodes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          response:
              'root = Chart(["x"], @Each(rows, "r", Series(r.n, [r.v])))\n'
              'rows = [{n: "A", v: 1}]\n',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('chart [x] [Series{category: A, values: [1]}]'),
        findsOneWidget,
      );
    });
  });

  group('props with references', () {
    testWidgets('a reference to a component statement renders it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(response: 'root = Slot(inner)\ninner = Text("inside")\n'),
      );
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsOneWidget);
    });

    testWidgets('a reference to a value stays a value', (tester) async {
      await tester.pumpWidget(
        _app(response: 'root = Slot(v)\nv = [1, 2]\n'),
      );
      await tester.pumpAndSettle();
      expect(find.text('value [1, 2]'), findsOneWidget);
    });

    testWidgets('a ternary with a component branch renders the branch', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(response: 'root = Slot(1 > 2 ? Text("a") : Text("b"))\n'),
      );
      await tester.pumpAndSettle();
      expect(find.text('b'), findsOneWidget);
    });

    testWidgets('an array of strings and a component keeps the strings', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(response: 'root = Column([s, Text("w")])\ns = "plain"\n'),
      );
      await tester.pumpAndSettle();
      expect(find.text('plain'), findsOneWidget);
      expect(find.text('w'), findsOneWidget);
    });

    testWidgets('Action and Query in a slot are values', (tester) async {
      await tester.pumpWidget(
        _app(response: 'root = Slot(Query("t", {}, 5))\n'),
      );
      await tester.pumpAndSettle();
      expect(find.text('value 5'), findsOneWidget);
    });
  });

  group('nested arrays and objects', () {
    testWidgets('components inside a nested array render', (tester) async {
      await tester.pumpWidget(
        _app(
          response:
              'root = Column([Deep([[Text("a1"), t], [Text("b1")]]), '
              'Deep(slides)])\n'
              't = Text("a2")\n'
              'slides = [[Text("c1"), Text("c2")], row]\n'
              'row = [Text("d1")]\n',
        ),
      );
      await tester.pumpAndSettle();
      for (final s in ['a1', 'a2', 'b1', 'c1', 'c2', 'd1']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('null'), findsNothing);
    });

    testWidgets('a nested array keeps plain values and data nodes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          response:
              'root = Deep([[Text("w"), "plain", 3], [Series("A", [1])]])\n',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('w'), findsOneWidget);
      expect(find.text('plain'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Series{category: A, values: [1]}'), findsOneWidget);
    });

    testWidgets('a nested array of plain values stays a value', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(response: 'root = Slot(v)\nv = [[1, 2], [3]]\n'),
      );
      await tester.pumpAndSettle();
      expect(find.text('value [[1, 2], [3]]'), findsOneWidget);
    });

    testWidgets('components inside an object literal render', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          response:
              'root = Column([Deep({price: Text("9 €"), button: b, '
              'note: "n", more: {inner: [Text("deep")]}}), Deep(f)])\n'
              'b = Text("Buy")\n'
              'f = {x: Text("ref")}\n',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('9 €'), findsOneWidget);
      expect(find.text('Buy'), findsOneWidget);
      expect(find.text('note=n'), findsOneWidget);
      expect(find.text('deep'), findsOneWidget);
      expect(find.text('ref'), findsOneWidget);
    });

    testWidgets('a cycle through array statements is reported', (
      tester,
    ) async {
      final errors = <OpenUIError>[];
      await tester.pumpWidget(
        _app(
          response: 'root = Deep(a)\na = [b, Text("x")]\nb = [a]\n',
          onError: errors.addAll,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('x'), findsOneWidget);
      expect(errors.whereType<CyclicStateError>(), isNotEmpty);
    });
  });

  group('actions', () {
    testWidgets('object-literal continue_conversation sends the label', (
      tester,
    ) async {
      final events = <ActionEvent>[];
      final messages = <String>[];
      await tester.pumpWidget(
        _app(
          response:
              'root = Btn("Pick", {type: "continue_conversation", '
              'context: "ctx"})\n',
          onAction: events.add,
          onContinueConversation: messages.add,
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(messages, ['Pick']);
      expect(events.single.params['context'], 'ctx');
    });

    testWidgets('@OpenUrl and object open_url call onOpenUrl', (
      tester,
    ) async {
      final urls = <String>[];
      await tester.pumpWidget(
        _app(
          response:
              'root = Column([a, b, c])\n'
              'a = Btn("A", Action([@OpenUrl("https://a")]))\n'
              'b = Btn("B", {type: "open_url", url: "https://b"})\n'
              'c = Btn("C", @OpenUrl("https://c"))\n',
          onOpenUrl: urls.add,
        ),
      );
      for (final label in ['A', 'B', 'C']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(urls, ['https://a', 'https://b', 'https://c']);
    });

    testWidgets('an action inside @Each keeps its loop variable', (
      tester,
    ) async {
      final messages = <String>[];
      await tester.pumpWidget(
        _app(
          response:
              'root = Column(@Each(items, "it", Btn(it.n, '
              'Action([@ToAssistant("Tell me about " + it.n)]))))\n'
              'items = [{n: "Rome"}, {n: "Oslo"}]\n',
          onContinueConversation: messages.add,
        ),
      );
      await tester.tap(find.text('Oslo'));
      await tester.pumpAndSettle();
      expect(messages, ['Tell me about Oslo']);
    });
  });

  group('robustness', () {
    testWidgets('errorBuilder replaces the red placeholder', (tester) async {
      await tester.pumpWidget(
        _app(
          response: 'root = Column([Nope("x"), Text("ok")])\n',
          errorBuilder: (_) => const Text('hidden'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('hidden'), findsOneWidget);
      expect(find.text('ok'), findsOneWidget);
    });

    testWidgets('a cycle also uses errorBuilder', (tester) async {
      await tester.pumpWidget(
        _app(
          response: 'root = Column([a])\na = Column([b])\nb = Column([a])\n',
          errorBuilder: (_) => const Text('cycle'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('cycle'), findsWidgets);
    });

    testWidgets('a fenced, streaming program renders its partial tree', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          response:
              'Sure:\n```openui-lang\nroot = Column([a, b])\n'
              'a = Text("first")\nb = Text("sec',
          isStreaming: true,
        ),
      );
      await tester.pump();
      expect(find.text('first'), findsOneWidget);
      expect(find.text('sec'), findsOneWidget);
      unawaited(Future<void>.value());
    });
  });
}
