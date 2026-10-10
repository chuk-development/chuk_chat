// Widget tests for OpenUiView: rendering, the action handler wiring,
// streaming of a partial program, and the calm failure line.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

// A minimal Form / FormControl / Input, only for these tests. The real
// ones belong to agent B3 (lib/openui/components/forms_buttons.dart).
final OpenUiLibrary _formLibrary = OpenUiLibrary(<OpenUiComponentDef>[
  ...chukOpenUiLibrary.components,
  OpenUiComponentDef(
    name: 'Form',
    group: 'Forms',
    description: 'test form',
    params: const <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('buttons', 'Buttons'),
      OpenUiParam.opt('fields', 'FormControl[]'),
    ],
    builder: (context, p) => OpenUiFormScope(
      formName: p.string('name'),
      child: Column(
        children: <Widget>[...p.children('fields'), ...p.children('buttons')],
      ),
    ),
  ),
  OpenUiComponentDef(
    name: 'FormControl',
    group: 'Forms',
    description: 'test control',
    params: const <OpenUiParam>[
      OpenUiParam('label', 'string'),
      OpenUiParam('input', 'Input'),
    ],
    builder: (context, p) => Column(
      children: <Widget>[Text(p.string('label')), ...p.children('input')],
    ),
  ),
  OpenUiComponentDef(
    name: 'Input',
    group: 'Forms',
    description: 'test input',
    params: const <OpenUiParam>[OpenUiParam('name', 'string')],
    builder: (context, p) => _TestField(name: p.string('name')),
  ),
]);

class _TestField extends StatelessWidget {
  const _TestField({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: ValueKey<String>('field-$name'),
      onChanged: (v) => OpenUiFormScope.formOf(context)?.setValue(name, v),
    );
  }
}

Finder _rich(String text) => find.textContaining(text, findRichText: true);

void main() {
  testWidgets('renders the reference components', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([intro, btn])\n'
      'intro = TextContent("Hello **world**", "large-heavy")\n'
      'btn = Button("Go", Action([@ToAssistant("go")]), "secondary")\n',
    );
    expect(_rich('Hello'), findsOneWidget);
    expect(find.text('Go'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in light mode too', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([TextContent("Light"), Button("A", null, "tertiary", '
      '"destructive", "small")])\n',
      brightness: Brightness.light,
    );
    expect(_rich('Light'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
  });

  group('actions reach the handler', () {
    testWidgets('@ToAssistant sends its message and context', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([Button("Go", Action([@ToAssistant("go now", "ctx")]))])\n',
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'go now');
      expect(h.messages.single.context, 'ctx');
      expect(h.messages.single.formValues, isNull);
    });

    testWidgets('a Button without action sends its label', (tester) async {
      final h = await pumpOpenUi(tester, 'root = Card([Button("Yes")])\n');
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'Yes');
    });

    testWidgets('a Button without action in a Form sends the form values', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([f])\n'
        'f = Form("contact", Button("Submit"), [FormControl("Name", '
        'Input("name"))])\n',
        library: _formLibrary,
      );
      await tester.enterText(find.byKey(const ValueKey('field-name')), 'Ada');
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'Submit');
      expect(h.messages.single.formValues, {'name': 'Ada'});
    });

    testWidgets('@OpenUrl opens the URL', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([Button("Docs", Action([@OpenUrl("https://x.y")]))])\n',
      );
      await tester.tap(find.text('Docs'));
      await tester.pumpAndSettle();
      expect(h.urls, ['https://x.y']);
      expect(h.messages, isEmpty);
    });

    testWidgets('the object-literal action sends the label with context', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([Button("Paris", {type: "continue_conversation", '
        'context: "city"})])\n',
      );
      await tester.tap(find.text('Paris'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'Paris');
      expect(h.messages.single.context, 'city');
    });

    testWidgets('@Set reports the state to the handler', (tester) async {
      final h = await pumpOpenUi(
        tester,
        '\$n = 0\n'
        'root = Card([TextContent("n=" + \$n), '
        'Button("Inc", Action([@Set(\$n, \$n + 1)]))])\n',
      );
      await tester.tap(find.text('Inc'));
      await tester.pumpAndSettle();
      expect(_rich('n=1'), findsOneWidget);
      expect(h.states.last[r'$n'], 1);
    });

    testWidgets('a source in the Card strip opens its URL', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([TextContent("Fact [1]")], [{title: "T", '
        'sourceName: "Wiki", url: "https://w.org"}, {title: "No URL", '
        'sourceName: ""}])\n',
      );
      expect(find.text('Wiki'), findsOneWidget);
      expect(find.text('No URL'), findsOneWidget);
      await tester.tap(find.text('Wiki'));
      await tester.pumpAndSettle();
      expect(h.urls, ['https://w.org']);
    });
  });

  group('streaming', () {
    const program =
        'Sure, here it is:\n\n```openui-lang\n'
        'root = Card([intro, more, btn])\n'
        'intro = TextContent("First block")\n'
        'more = TextContent("Second block with **bold** text")\n'
        'btn = Button("Next", Action([@ToAssistant("next")]))\n'
        '```\n\nAnything else?';

    testWidgets('every prefix renders without an exception', (tester) async {
      final h = RecordingOpenUiHandler();
      for (var i = 0; i <= program.length; i += 7) {
        await pumpOpenUi(
          tester,
          program.substring(0, i),
          isStreaming: true,
          handler: h,
          settle: false,
        );
        expect(tester.takeException(), isNull, reason: 'prefix $i');
        expect(find.text(OpenUiView.failureText), findsNothing);
      }
      await pumpOpenUi(tester, program, handler: h);
      expect(tester.takeException(), isNull);
      expect(_rich('First block'), findsOneWidget);
      expect(_rich('Second block'), findsOneWidget);
    });

    testWidgets('a partial program shows its finished part', (tester) async {
      final cut = program.indexOf('more = ') + 'more = TextContent("Sec'.length;
      await pumpOpenUi(
        tester,
        program.substring(0, cut),
        isStreaming: true,
        settle: false,
      );
      expect(_rich('First block'), findsOneWidget);
      expect(_rich('Sec'), findsOneWidget);
      expect(find.text('Next'), findsNothing);
    });

    testWidgets('a button whose statement still streams is disabled', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([b])\nb = Button("Go", Action([@ToAssistant("x")]))',
        isStreaming: true,
        settle: false,
      );
      await tester.tap(find.text('Go'));
      await tester.pump();
      expect(h.messages, isEmpty);
    });
  });

  group('failure line', () {
    testWidgets('shows only after the stream when nothing renders', (
      tester,
    ) async {
      await pumpOpenUi(tester, 'root = Nope("x")', isStreaming: true);
      expect(find.text(OpenUiView.failureText), findsNothing);
      await pumpOpenUi(tester, 'root = Nope("x")');
      expect(find.text(OpenUiView.failureText), findsOneWidget);
    });

    testWidgets('shows for a program without root', (tester) async {
      await pumpOpenUi(tester, 'a = TextContent("x")\n');
      expect(find.text(OpenUiView.failureText), findsOneWidget);
    });

    testWidgets('follows a root that is a reference', (tester) async {
      await pumpOpenUi(tester, 'root = c\nc = Card([TextContent("Via ref")])');
      expect(_rich('Via ref'), findsOneWidget);
      await pumpOpenUi(tester, 'root = c\n');
      expect(find.text(OpenUiView.failureText), findsOneWidget);
    });

    testWidgets('an empty source shows nothing', (tester) async {
      await pumpOpenUi(tester, '   ');
      expect(find.text(OpenUiView.failureText), findsNothing);
    });

    testWidgets('an unknown child is hidden, the rest renders', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([Nope("x"), TextContent("Still here")])',
      );
      expect(_rich('Still here'), findsOneWidget);
      expect(find.text(OpenUiView.failureText), findsNothing);
      expect(find.textContaining('unknown'), findsNothing);
    });
  });

  testWidgets('a Query renders its defaults without tools', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([t])\n'
      't = TextContent("Rows: " + @Count(data.rows))\n'
      'data = Query("stats", {}, {rows: [1, 2]})\n',
    );
    expect(_rich('Rows: 2'), findsOneWidget);
  });

  testWidgets('a Query uses a tool executor when given', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([t])\n'
      't = TextContent("Sum: " + @Sum(data.rows.v))\n'
      'data = Query("stats", {}, {rows: []})\n',
      tools: {
        'stats': (_) async => const ToolResult({
          'rows': [
            {'v': 2},
            {'v': 3},
          ],
        }),
      },
    );
    expect(_rich('Sum: 5'), findsOneWidget);
  });
}
