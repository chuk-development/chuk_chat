// B3 tests: the shared rules, Form, FormControl, Label, Input and
// TextArea, the submit with validation, and two-way bindings.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/components/forms_buttons.dart';
import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

Finder _field(String placeholder) =>
    find.widgetWithText(TextField, placeholder);

Finder _rich(String text) => find.textContaining(text, findRichText: true);

const String _contact = '''
root = Card([f])
f = Form("contact", Buttons([submit, later]), [nameField, emailField, ageField])
nameField = FormControl("Name", Input("name", "Your name", "text", {required: true, minLength: 2}), "As in your passport")
emailField = FormControl("Email", Input("email", "you@example.com", "email", {required: true, email: true}))
ageField = FormControl("Age", Input("age", "Age", "number", {numeric: true, min: 18}))
submit = Button("Send")
later = Button("Later", Action([@ToAssistant("later")]), "secondary")
''';

void main() {
  group('rules', () {
    test('parse skips false, null and unknown keys', () {
      final r = OpenUiRules.parse(<String, Object?>{
        'required': true,
        'email': false,
        'url': null,
        'bogus': true,
        'minLength': 3,
      });
      expect(r.rules.map((e) => e.type), <String>['required', 'minLength']);
      expect(r.required, isTrue);
      expect(OpenUiRules.parse(null).isEmpty, isTrue);
      expect(OpenUiRules.parse('x').isEmpty, isTrue);
      expect(OpenUiRules.parse(<Object?>[1]).isEmpty, isTrue);
    });

    test('required', () {
      final r = OpenUiRules.parse(<String, Object?>{'required': true});
      expect(r.validate(null), 'This field is required');
      expect(r.validate(''), 'This field is required');
      expect(r.validate('  '), 'This field is required');
      expect(r.validate(<String>[]), 'This field is required');
      expect(r.validate(<String, Object?>{}), 'This field is required');
      expect(
        r.validate(<String, bool>{'a': false, 'b': false}),
        'At least one option is required',
      );
      expect(r.validate(<String, bool>{'a': true}), isNull);
      expect(r.validate('x'), isNull);
      expect(r.validate(0), isNull);
    });

    test('email, url, numeric, pattern', () {
      final email = OpenUiRules.parse(<String, Object?>{'email': true});
      expect(email.validate('a@b.co'), isNull);
      expect(email.validate('a@b'), 'Please enter a valid email');
      expect(email.validate(''), isNull);
      final url = OpenUiRules.parse(<String, Object?>{'url': true});
      expect(url.validate('https://x.y/z'), isNull);
      expect(url.validate('not a url'), 'Please enter a valid URL');
      expect(url.validate('example.com'), 'Please enter a valid URL');
      final numeric = OpenUiRules.parse(<String, Object?>{'numeric': true});
      expect(numeric.validate('12.5'), isNull);
      expect(numeric.validate(3), isNull);
      expect(numeric.validate('12a'), 'Must be a number');
      final pattern = OpenUiRules.parse(<String, Object?>{
        'pattern': r'^[A-Z]{3}$',
      });
      expect(pattern.validate('ABC'), isNull);
      expect(pattern.validate('abc'), 'Invalid format');
      final bad = OpenUiRules.parse(<String, Object?>{'pattern': '('});
      expect(bad.validate('x'), isNull, reason: 'a bad pattern is skipped');
    });

    test('min, max, minLength, maxLength', () {
      final r = OpenUiRules.parse(<String, Object?>{'min': 2, 'max': 5});
      expect(r.validate('1'), 'Must be at least 2');
      expect(r.validate(6), 'Must be no more than 5');
      expect(r.validate(<num>[3]), isNull, reason: 'slider values');
      expect(r.validate('abc'), isNull, reason: 'not a number: skipped');
      final len = OpenUiRules.parse(<String, Object?>{
        'minLength': 2,
        'maxLength': '4',
      });
      expect(len.validate('a'), 'Must be at least 2 characters');
      expect(len.validate('abcde'), 'Must be no more than 4 characters');
      expect(len.validate('abc'), isNull);
    });

    test('the first failing rule wins', () {
      final r = OpenUiRules.parse(<String, Object?>{
        'required': true,
        'email': true,
      });
      expect(r.validate(''), 'This field is required');
      expect(r.validate('x'), 'Please enter a valid email');
    });
  });

  group('Form', () {
    testWidgets('renders labels, placeholders, hint and a required star', (
      tester,
    ) async {
      await pumpOpenUi(tester, _contact);
      expect(_rich('Name'), findsWidgets);
      expect(find.text('Your name'), findsOneWidget);
      expect(find.text('As in your passport'), findsOneWidget);
      // The star carries the semantics label ", required".
      expect(_rich('Name, required'), findsOneWidget);
      expect(_rich('Email, required'), findsOneWidget);
      expect(_rich('Age, required'), findsNothing);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('submit checks the rules and shows the errors', (tester) async {
      final h = await pumpOpenUi(tester, _contact);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(h.messages, isEmpty);
      expect(find.text('This field is required'), findsNWidgets(2));
      // The error replaces the hint.
      expect(find.text('As in your passport'), findsNothing);

      await tester.enterText(_field('Your name'), 'A');
      await tester.enterText(_field('you@example.com'), 'ada@');
      await tester.enterText(_field('Age'), '12');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(h.messages, isEmpty);
      expect(find.text('Must be at least 2 characters'), findsOneWidget);
      expect(find.text('Please enter a valid email'), findsOneWidget);
      expect(find.text('Must be at least 18'), findsOneWidget);
    });

    testWidgets('a valid submit sends the label and every value', (
      tester,
    ) async {
      final h = await pumpOpenUi(tester, _contact);
      await tester.enterText(_field('Your name'), 'Ada');
      await tester.enterText(_field('you@example.com'), 'ada@example.com');
      await tester.enterText(_field('Age'), '36');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(h.messages, hasLength(1));
      expect(h.messages.single.text, 'Send');
      expect(h.messages.single.formValues, <String, Object?>{
        'name': 'Ada',
        'email': 'ada@example.com',
        'age': '36',
      });
      expect(find.text('This field is required'), findsNothing);
    });

    testWidgets('typing hides the error of the field', (tester) async {
      await pumpOpenUi(tester, _contact);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('This field is required'), findsNWidgets(2));
      await tester.enterText(_field('Your name'), 'Ad');
      await tester.pumpAndSettle();
      expect(find.text('This field is required'), findsOneWidget);
      expect(find.text('As in your passport'), findsOneWidget);
    });

    testWidgets('leaving a field checks its rules', (tester) async {
      await pumpOpenUi(tester, _contact);
      await tester.enterText(_field('you@example.com'), 'nope');
      // Move the focus to the next field: the email field blurs.
      await tester.tap(_field('Age'));
      await tester.pumpAndSettle();
      expect(find.text('Please enter a valid email'), findsOneWidget);
    });

    testWidgets('a secondary button does not validate', (tester) async {
      final h = await pumpOpenUi(tester, _contact);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'later');
      expect(find.text('This field is required'), findsNothing);
    });

    testWidgets('a single Button in the buttons slot works', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([f])\n'
        'f = Form("f", Button("Go"), [FormControl("Q", Input("q", "Ask"))])\n',
      );
      await tester.enterText(_field('Ask'), 'why');
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(h.messages.single.formValues, <String, Object?>{'q': 'why'});
    });
  });

  group('Input and TextArea', () {
    testWidgets('a binding shows its value and follows the typing', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        '\$name = "Ada"\n'
        'root = Card([greet, f])\n'
        'greet = TextContent("Hi " + \$name)\n'
        'f = Form("f", Button("Go"), [FormControl("Name", '
        'Input("name", "Name", "text", null, \$name))])\n',
      );
      expect(find.text('Ada'), findsOneWidget);
      expect(_rich('Hi Ada'), findsOneWidget);
      await tester.enterText(_field('Name'), 'Bob');
      await tester.pumpAndSettle();
      expect(_rich('Hi Bob'), findsOneWidget);
      expect(h.states.last[r'$name'], 'Bob');
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(h.messages.single.formValues, <String, Object?>{'name': 'Bob'});
    });

    testWidgets('a bound value is in the form values without typing', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        '\$city = "Kiel"\n'
        'root = Card([f])\n'
        'f = Form("f", Button("Go"), [FormControl("City", '
        'Input("city", "City", "text", {required: true}, \$city))])\n',
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(h.messages.single.formValues, <String, Object?>{'city': 'Kiel'});
    });

    testWidgets('a password field hides the text and can show it', (
      tester,
    ) async {
      await pumpOpenUi(
        tester,
        'root = Card([f])\n'
        'f = Form("f", Button("Go"), [FormControl("Password", '
        'Input("pw", "Password", "password"))])\n',
      );
      TextField field() => tester.widget<TextField>(_field('Password'));
      expect(field().obscureText, isTrue);
      await tester.tap(find.bySemanticsLabel('Show password'));
      await tester.pumpAndSettle();
      expect(field().obscureText, isFalse);
    });

    testWidgets('a TextArea has several lines', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([f])\n'
        'f = Form("f", Button("Go"), [FormControl("Notes", '
        'TextArea("notes", "Notes", 4, {maxLength: 5}))])\n',
      );
      final field = tester.widget<TextField>(_field('Notes'));
      expect(field.minLines, 4);
      expect(field.maxLines, greaterThanOrEqualTo(4));
      await tester.enterText(_field('Notes'), 'one\ntwo');
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(h.messages, isEmpty);
      expect(find.text('Must be no more than 5 characters'), findsOneWidget);
    });

    testWidgets('a field outside a Form still writes its binding', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        '\$q = ""\n'
        'root = Card([Input("q", "Search", "text", null, \$q), '
        'TextContent("q=" + \$q)])\n',
      );
      await tester.enterText(_field('Search'), 'abc');
      await tester.pumpAndSettle();
      expect(_rich('q=abc'), findsOneWidget);
      expect(h.states.last[r'$q'], 'abc');
    });

    testWidgets('a Label draws its text', (tester) async {
      await pumpOpenUi(tester, 'root = Card([Label("Plain label")])\n');
      expect(_rich('Plain label'), findsOneWidget);
    });
  });

  group('remount', () {
    const source =
        '\$name = "Ada"\n'
        'root = Card([f])\n'
        'f = Form("f", Button("Go"), [FormControl("Name", '
        'Input("name", "Name", "text", null, \$name)), FormControl("City", '
        'Input("city", "City")), FormControl("Stay", Chips("stay", "single", '
        '[ChipItem("hotel", "Hotel"), ChipItem("camp", "Camp")], null, '
        '"hotel"))])\n';

    Future<void> mount(
      WidgetTester tester,
      OpenUiForms forms,
      RecordingOpenUiHandler h,
      int generation,
    ) async {
      await tester.pumpWidget(
        openUiTestApp(
          OpenUiView(
            key: ValueKey<int>(generation),
            source: source,
            actionHandler: h,
            forms: forms,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the values survive a remount with the same forms', (
      tester,
    ) async {
      final forms = OpenUiForms();
      addTearDown(forms.dispose);
      final h = RecordingOpenUiHandler();
      await mount(tester, forms, h, 1);
      await tester.enterText(_field('Name'), 'Bob');
      await tester.enterText(_field('City'), 'Kiel');
      await tester.tap(find.text('Camp'));
      await tester.pumpAndSettle();

      // Away and back: a new view state, a new store, the same forms.
      await tester.pumpWidget(const SizedBox());
      await mount(tester, forms, h, 2);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Kiel'), findsOneWidget);
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(h.messages.single.formValues, <String, Object?>{
        'name': 'Bob',
        'city': 'Kiel',
        'stay': 'camp',
      });
    });
  });
}
