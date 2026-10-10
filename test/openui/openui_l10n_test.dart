// The fixed UI texts of the OpenUI components come from the app l10n.
// German shows German; a tree without app localizations shows English.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/l10n/strings_de.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/l10n/strings_es.dart';
import 'package:chuk_chat/l10n/strings_fr.dart';
import 'package:chuk_chat/l10n/strings_pt.dart';
import 'package:chuk_chat/openui/components/forms_buttons/rules.dart';
import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

const String _form = '''
root = Card([f])
f = Form("f", Button("Send"), [a, b, c])
a = FormControl("Name", Input("name", "Your name", "text", {required: true}))
b = FormControl("City", Select("city", [SelectItem("b", "Berlin")]))
c = FormControl("Day", DatePicker("day"))
''';

Future<void> _pump(WidgetTester tester, String source, Locale? locale) {
  return tester.pumpWidget(
    MaterialApp(
      theme: openUiTestTheme(Brightness.dark),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: locale == null
          ? null
          : const <LocalizationsDelegate<Object>>[
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
      home: Scaffold(
        body: SingleChildScrollView(
          child: OpenUiView(
            source: source,
            actionHandler: RecordingOpenUiHandler(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a German app shows German field texts and errors', (
    tester,
  ) async {
    await _pump(tester, _form, const Locale('de'));
    await tester.pumpAndSettle();
    expect(find.text(stringsDe['openUiSelectPlaceholder']!), findsOneWidget);
    expect(find.text(stringsDe['openUiPickDate']!), findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text(stringsDe['openUiFieldRequired']!), findsOneWidget);
    expect(find.text('This field is required'), findsNothing);
  });

  testWidgets('without app localizations the texts are English', (
    tester,
  ) async {
    await _pump(tester, _form, null);
    await tester.pumpAndSettle();
    expect(find.text('Select...'), findsOneWidget);
    expect(find.text('Pick a date'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text('This field is required'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the failure line follows the locale', (tester) async {
    await _pump(tester, 'root = NoSuchThing()\n', const Locale('de'));
    await tester.pumpAndSettle();
    expect(find.text(stringsDe['openUiViewFailed']!), findsOneWidget);
  });

  test('every OpenUI key has a text in every shipped locale', () {
    final keys = stringsEn.keys.where((k) => k.startsWith('openUi')).toList();
    expect(keys, isNotEmpty);
    expect(stringsEn['openUiViewFailed'], OpenUiView.failureText);
    for (final (name, table) in <(String, Map<String, String>)>[
      ('de', stringsDe),
      ('es', stringsEs),
      ('fr', stringsFr),
      ('pt', stringsPt),
    ]) {
      final missing = keys.where((k) => !table.containsKey(k)).toList();
      expect(missing, isEmpty, reason: 'locale $name');
    }
  });

  test('the English rule messages match the English l10n', () {
    final l = AppLocalizations(const Locale('en'));
    final rules = OpenUiRuleMessages.of(l);
    expect(rules, OpenUiRuleMessages.english);
  });
}
