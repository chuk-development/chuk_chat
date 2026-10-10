// Unit tests for the props helper and the component definition type.
// ignore_for_file: experimental_member_use

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openui/openui.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/openui.dart';

const _def = OpenUiComponentDef(
  name: 'Demo',
  group: 'Test',
  description: 'A demo.',
  params: <OpenUiParam>[
    OpenUiParam('label', 'string'),
    OpenUiParam.opt('size', '"small" | "medium" | "large"'),
    OpenUiParam.opt('action', 'ActionExpression'),
    OpenUiParam.opt('value', r'$binding<string>'),
    OpenUiParam.opt('kind', 'string | Tag'),
  ],
  builder: _noop,
);

Widget _noop(BuildContext context, OpenUiProps props) => const SizedBox();

OpenUiProps _props(Map<String, Object?> values) => OpenUiProps(
  component: 'Demo',
  values: values,
  def: _def,
  lookup: (name) => name == 'Demo' ? _def : null,
);

void main() {
  group('OpenUiParam', () {
    test('reads enum values only from a pure string union', () {
      expect(_def.param('size')!.enumValues, ['small', 'medium', 'large']);
      expect(_def.param('label')!.enumValues, isEmpty);
      expect(_def.param('kind')!.enumValues, isEmpty);
      expect(const OpenUiParam('x', '"').enumValues, isEmpty);
    });

    test('knows action and binding slots', () {
      expect(_def.param('action')!.isAction, isTrue);
      expect(_def.param('value')!.isBinding, isTrue);
      expect(_def.param('label')!.isAction, isFalse);
    });

    test('signature follows the upstream format', () {
      expect(
        _def.signature,
        'Demo(label: string, size?: "small" | "medium" | "large", '
        'action?: ActionExpression, value?: \$binding<string>, '
        'kind?: string | Tag)',
      );
      expect(_def.param('nope'), isNull);
      expect(_def.isData, isFalse);
    });

    test('the core schema keeps the order and the markers', () {
      final schema = _def.toCoreDefinition().schema.value;
      final props = schema['properties']! as Map<String, Object?>;
      expect(props.keys, ['label', 'size', 'action', 'value', 'kind']);
      expect((props['action']! as Map)['x-action'], isTrue);
      expect((props['value']! as Map)['x-reactive'], isTrue);
      expect((props['size']! as Map)['enum'], ['small', 'medium', 'large']);
      expect(schema['required'], ['label']);
    });
  });

  group('OpenUiProps scalars', () {
    test('string converts numbers and bools, falls back on the rest', () {
      final p = _props({
        'a': 'x',
        'b': 3,
        'c': 2.5,
        'd': true,
        'e': [1],
        'f': 4.0,
      });
      expect(p.string('a'), 'x');
      expect(p.string('b'), '3');
      expect(p.string('c'), '2.5');
      expect(p.string('d'), 'true');
      expect(p.string('e', fallback: '-'), '-');
      expect(p.string('missing'), '');
      expect(p.string('f'), '4');
      expect(p.stringOrNull('e'), isNull);
    });

    test('number parses strings and rejects junk', () {
      final p = _props({'a': 3, 'b': ' 4.5 ', 'c': 'x', 'd': double.nan});
      expect(p.number('a'), 3.0);
      expect(p.number('b'), 4.5);
      expect(p.number('c', fallback: -1), -1);
      expect(p.numberOrNull('d'), isNull);
      expect(p.numberOrNull('missing'), isNull);
      expect(p.integer('b'), 5);
      expect(p.integer('c', fallback: 7), 7);
    });

    test('boolean reads bools and the two strings', () {
      final p = _props({'a': true, 'b': 'false', 'c': 1});
      expect(p.boolean('a'), isTrue);
      expect(p.boolean('b', fallback: true), isFalse);
      expect(p.boolean('c', fallback: true), isTrue);
      expect(_props({'x': 'true'}).boolean('x'), isTrue);
    });

    test('choice keeps allowed values and falls back on others', () {
      expect(_props({'size': 'large'}).choice('size', fallback: 'm'), 'large');
      expect(_props({'size': 'huge'}).choice('size', fallback: 'm'), 'm');
      expect(_props({}).choice('size', fallback: 'm'), 'm');
      // A free-text parameter accepts any text.
      expect(_props({'label': 'x'}).choice('label', fallback: 'm'), 'x');
    });

    test('raw and has', () {
      final p = _props({'a': null, 'b': 0});
      expect(p.has('a'), isFalse);
      expect(p.has('b'), isTrue);
      expect(p.raw('b'), 0);
      expect(p.toString(), contains('Demo'));
    });
  });

  group('OpenUiProps collections', () {
    test('list wraps a single value and keeps null empty', () {
      expect(_props({'a': 5}).list('a'), [5]);
      expect(_props({}).list('a'), isEmpty);
      expect(
        _props({
          'a': [1, 2],
        }).list('a'),
        [1, 2],
      );
    });

    test('stringList and numberList', () {
      final p = _props({
        'a': ['x', 2, 2.5, true, null, <String, Object?>{}],
        'b': [1, '2', 'x', null],
      });
      expect(p.stringList('a'), ['x', '2', '2.5', 'true']);
      expect(p.numberList('b'), [1, 2, 0, 0]);
    });

    test('map and mapList', () {
      final p = _props({
        'm': {'k': 1},
        'l': [
          {'k': 1},
          'x',
          {'k': 2},
        ],
        's': 'x',
      });
      expect(p.map('m'), {'k': 1});
      expect(p.map('s'), isEmpty);
      expect(p.mapList('l'), [
        {'k': 1},
        {'k': 2},
      ]);
    });

    test('children flattens, wraps text and skips data nodes', () {
      const w = SizedBox(width: 1);
      const node = DataNode(typeName: 'Demo', props: {}, statementId: 's');
      final p = _props({
        'c': [
          w,
          ['t', 3, 2.5],
          node,
          null,
          false,
        ],
      });
      final kids = p.children('c');
      expect(kids, hasLength(4));
      expect(kids.first, same(w));
      expect((kids[1] as Text).data, 't');
      expect((kids[2] as Text).data, '3');
      expect((kids[3] as Text).data, '2.5');
      expect(p.child('c'), same(w));
      expect(_props({}).child('c'), isNull);
    });

    test('data reads data nodes with their definition', () {
      const a = DataNode(
        typeName: 'Demo',
        props: {'label': 'A', 'size': 'small'},
        statementId: 's1',
      );
      const b = DataNode(typeName: 'Other', props: {}, statementId: 's2');
      final p = _props({
        'items': [
          a,
          [b],
          const SizedBox(),
        ],
      });
      final all = p.data('items');
      expect(all.map((d) => d.component), ['Demo', 'Other']);
      expect(all.first.string('label'), 'A');
      expect(all.first.choice('size', fallback: 'm'), 'small');
      expect(all.first.statementId, 's1');
      expect(all.last.def, isNull);
      expect(p.data('items', type: 'Other'), hasLength(1));
      expect(p.dataOne('items')!.component, 'Demo');
      expect(p.dataOne('missing'), isNull);
    });
  });

  group('OpenUiProps actions and bindings', () {
    test('action wraps a non-empty plan only', () {
      final plan = actionPlanFromObject({'type': 'continue_conversation'})!;
      expect(_props({'action': plan}).action('action')!.plan, plan);
      expect(
        _props({'action': const ActionPlan(steps: [])}).action('action'),
        isNull,
      );
      expect(_props({'action': 'x'}).action('action'), isNull);
    });

    test('binding reads a reactive marker', () {
      final b = _props({
        'value': const ReactiveAssign(target: r'$name', value: 'Ada'),
      }).binding('value')!;
      expect(b.target, r'$name');
      expect(b.value, 'Ada');
      expect(_props({'value': 'x'}).binding('value'), isNull);
    });
  });

  group('OpenUiActionHandler.composeMessage', () {
    test('joins text, context and form values', () {
      expect(
        OpenUiActionHandler.composeMessage(
          'Submit',
          context: 'trip',
          formName: 'contact',
          formValues: {
            'name': 'Ada',
            'tags': ['a', 'b'],
            'none': null,
          },
        ),
        'Submit\n\nContext: trip\n\nForm "contact":\n- name: Ada\n'
        '- tags: ["a","b"]\n- none: ',
      );
      expect(
        OpenUiActionHandler.composeMessage('Hi', formValues: {'a': 1}),
        'Hi\n\nForm:\n- a: 1',
      );
      expect(OpenUiActionHandler.composeMessage(' Hi ', context: ' '), 'Hi');
    });
  });

  group('OpenUiForms', () {
    test('keeps values per form and notifies on change', () {
      final forms = OpenUiForms();
      final f = forms.form('contact');
      var notified = 0;
      f.addListener(() => notified++);
      f.setValue('name', 'Ada');
      f.setValue('name', 'Ada');
      expect(notified, 1);
      expect(identical(forms.form('contact'), f), isTrue);
      expect(forms.valuesOf('contact'), {'name': 'Ada'});
      expect(forms.valuesOf('other'), isNull);
      expect(forms.valuesOf(null), isNull);
      expect(f.value('name'), 'Ada');
      expect(f.hasValue('name'), isTrue);
      f.reset();
      f.reset();
      expect(f.values, isEmpty);
      expect(notified, 2);
      forms.dispose();
    });
  });

  group('chukOpenUiLibrary', () {
    test('composes the four component files and the root Card', () {
      expect(chukOpenUiLibrary.contains('Card'), isTrue);
      expect(chukOpenUiLibrary['TextContent'], isNotNull);
      expect(chukOpenUiLibrary['Button'], isNotNull);
      expect(chukOpenUiLibrary['Nope'], isNull);
      expect(
        chukOpenUiLibrary.definition.components.map((c) => c.name).toSet(),
        chukOpenUiLibrary.names,
      );
    });

    test('a later definition wins on a duplicate name', () {
      const other = OpenUiComponentDef.data(
        name: 'Demo',
        group: 'Test',
        description: 'data',
        params: <OpenUiParam>[],
      );
      final lib = OpenUiLibrary([_def, other]);
      expect(lib.components, hasLength(1));
      expect(lib['Demo']!.isData, isTrue);
      expect(lib.registry.isData('Demo'), isTrue);
      expect(lib.registry['Demo'], isNull);
    });
  });
}
