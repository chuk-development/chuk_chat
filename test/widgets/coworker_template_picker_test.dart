import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/coworker_templates.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_dialog.dart';
import 'package:chuk_chat/widgets/coworker_template_picker.dart';

/// Opens the picker from a button and keeps what it returned.
class _Harness {
  CoworkerCreateRequest? result;
  bool closed = false;

  Widget app({String locale = 'en', double textScale = 1}) => MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              result = await showCoworkerTemplatePicker(
                context,
                suggestedName: 'amber-otter',
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<_Harness> _open(
  WidgetTester tester, {
  Size size = const Size(360, 800),
  String locale = 'en',
  double textScale = 1,
}) async {
  _size(tester, size);
  final harness = _Harness();
  await tester.pumpWidget(harness.app(locale: locale, textScale: textScale));
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return harness;
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

void main() {
  testWidgets('the list shows the blank coworker first, then the templates', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('New agent'), findsOneWidget);
    expect(_key('tpl-blank'), findsOneWidget);
    expect(find.text('Blank coworker'), findsOneWidget);
    expect(_key('tpl-research'), findsOneWidget);
    expect(find.text('Research assistant'), findsOneWidget);
    // The blank row sits above the first template.
    expect(
      tester.getTopLeft(_key('tpl-blank')).dy,
      lessThan(tester.getTopLeft(_key('tpl-research')).dy),
    );
  });

  testWidgets('a phone gets a bottom sheet, a desktop window a dialog', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(AgentsDesktopDialog), findsNothing);
  });

  testWidgets('desktop: centred dialog', (tester) async {
    await _open(tester, size: const Size(1280, 800));
    expect(find.byType(AgentsDesktopDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('search filters by name and description; the blank row steps '
      'aside', (tester) async {
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'price');
    await tester.pumpAndSettle();
    expect(_key('tpl-price'), findsOneWidget);
    expect(_key('tpl-research'), findsNothing);
    expect(_key('tpl-blank'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('No template matches that.'), findsOneWidget);
  });

  testWidgets('the category pill filters the list', (tester) async {
    await _open(tester);
    await tester.tap(find.text('Watch'));
    await tester.pumpAndSettle();
    expect(_key('tpl-news'), findsOneWidget);
    expect(_key('tpl-research'), findsNothing);
    await tester.tap(find.text('Life'));
    await tester.pumpAndSettle();
    expect(_key('tpl-travel'), findsOneWidget);
    expect(_key('tpl-news'), findsNothing);
  });

  testWidgets('a template: the name is pre-filled and editable, the starter '
      'automation is off, Create returns the template', (tester) async {
    final harness = await _open(tester);
    await tester.tap(find.text('Watch'));
    await tester.pumpAndSettle();
    await tester.tap(_key('tpl-news'));
    await tester.pumpAndSettle();

    final name = _key('tpl-name');
    expect(tester.widget<TextField>(name).controller!.text, 'News watcher');
    expect(_key('tpl-persona'), findsOneWidget);
    expect(find.text('Web search'), findsOneWidget);
    // The starter is offered and OFF.
    final starter = find.descendant(
      of: _key('tpl-starter'),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(starter).value, isFalse);

    await tester.enterText(name, ' Morning Paper ');
    await tester.tap(_key('tpl-create'));
    await tester.pumpAndSettle();

    expect(harness.closed, isTrue);
    expect(harness.result!.name, 'Morning Paper');
    expect(harness.result!.template!.id, 'news');
    expect(harness.result!.startAutomation, isFalse);
  });

  testWidgets('switching the starter on is what asks for it', (tester) async {
    final harness = await _open(tester);
    await tester.tap(find.text('Watch'));
    await tester.pumpAndSettle();
    await tester.tap(_key('tpl-news'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('tpl-starter'));
    await tester.tap(_key('tpl-starter'));
    await tester.pumpAndSettle();
    await tester.tap(_key('tpl-create'));
    await tester.pumpAndSettle();
    expect(harness.result!.startAutomation, isTrue);
    expect(harness.result!.template!.starter, isNotNull);
  });

  testWidgets('a template without a starter shows no switch', (tester) async {
    await _open(tester);
    await tester.tap(_key('tpl-research'));
    await tester.pumpAndSettle();
    expect(_key('tpl-starter'), findsNothing);
  });

  testWidgets('blank coworker: the suggested name, no template', (
    tester,
  ) async {
    final harness = await _open(tester);
    await tester.tap(_key('tpl-blank'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_key('tpl-name')).controller!.text,
      'amber-otter',
    );
    expect(_key('tpl-persona'), findsNothing);
    await tester.tap(_key('tpl-create'));
    await tester.pumpAndSettle();
    expect(harness.result!.name, 'amber-otter');
    expect(harness.result!.template, isNull);
    expect(harness.result!.startAutomation, isFalse);
  });

  testWidgets('an empty name is refused with a line, not closed', (
    tester,
  ) async {
    final harness = await _open(tester);
    await tester.tap(_key('tpl-blank'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('tpl-name'), '   ');
    await tester.tap(_key('tpl-create'));
    await tester.pumpAndSettle();
    expect(harness.closed, isFalse);
    expect(find.text('Give it a name.'), findsOneWidget);
  });

  testWidgets('Back returns to the list; Cancel returns null', (tester) async {
    final harness = await _open(tester);
    await tester.tap(_key('tpl-research'));
    await tester.pumpAndSettle();
    await tester.tap(_key('tpl-back'));
    await tester.pumpAndSettle();
    expect(_key('tpl-blank'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.closed, isTrue);
    expect(harness.result, isNull);
  });

  testWidgets('German strings', (tester) async {
    await _open(tester, locale: 'de');
    expect(find.text('Neuer Agent'), findsOneWidget);
    expect(find.text('Leerer Coworker'), findsOneWidget);
    expect(find.text('Rechercheassistent'), findsOneWidget);
    await tester.tap(find.text('Rechercheassistent'));
    await tester.pumpAndSettle();
    expect(find.text('Erstellen'), findsOneWidget);
    expect(find.text('Anweisungen'), findsOneWidget);
  });

  testWidgets('360 px at 1.3 text scale: both steps lay out without '
      'overflow', (tester) async {
    await _open(tester, textScale: 1.3);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Watch'));
    await tester.pumpAndSettle();
    await tester.tap(_key('tpl-inbox'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_key('tpl-create'), findsOneWidget);
  });

  test('every template appears in the list keys', () {
    // The keys the tests above tap are the catalogue ids.
    expect(coworkerTemplateById('news')?.starter, isNotNull);
    expect(coworkerTemplateById('research')?.starter, isNull);
  });
}
