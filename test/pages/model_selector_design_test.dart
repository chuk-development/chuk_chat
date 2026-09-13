import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/model_selector_page.dart';

void main() {
  test('model counts use singular and plural translations', () {
    final l = AppLocalizations(const Locale('de'));
    expect(l.availableModels(1), 'Verfügbar · 1 Modell');
    expect(l.availableModels(2), 'Verfügbar · 2 Modelle');
    expect(l.modelsFound(1), '1 Modell gefunden');
    expect(l.modelsFound(0), '0 Modelle gefunden');
  });

  testWidgets('model name, provider, and prompt have separate rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = ModelProviderInfo(
      slug: 'provider/one',
      name: 'A longer provider name',
      pricing: PricingDetails(prompt: 0, completion: 0, request: 0),
    );
    final model = CustomModelInfo(
      id: 'model/one',
      name: 'A comfortably readable model name',
      providers: [provider],
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ModelSelectionRow(
              model: model,
              selectedProvider: provider,
              onProviderChanged: (_) {},
              onEditPrompt: () {},
              formatContextLength: (_) => '128K',
              buildIconWidget: (_, icon, {double size = 24}) =>
                  Icon(icon, size: size),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(model.name), findsOneWidget);
    expect(find.text(provider.name), findsOneWidget);
    expect(find.text('Provider'), findsOneWidget);
    expect(find.text('System Prompt'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Provider')).dy,
      greaterThan(tester.getBottomLeft(find.text(model.name)).dy),
    );
    expect(
      tester.getTopLeft(find.text('System Prompt')).dy,
      greaterThan(tester.getBottomLeft(find.text('Provider')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider controls use the selected language', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ModelSelectionRow(
              model: CustomModelInfo(
                id: 'model/one',
                name: 'Ein Modell',
                providers: const [],
              ),
              selectedProvider: null,
              onProviderChanged: (_) {},
              onEditPrompt: () {},
              formatContextLength: (_) => '128K',
              buildIconWidget: (_, icon, {double size = 24}) =>
                  Icon(icon, size: size),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Anbieter'), findsOneWidget);
    expect(find.text('Wählen'), findsOneWidget);
    expect(find.text('Systemprompt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
