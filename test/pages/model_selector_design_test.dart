import 'package:chuk_chat/model_selector_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';

import '../support/test_app.dart';

void main() {
  final provider = ModelProviderInfo(
    slug: 'provider/one',
    name: 'Provider One',
    pricing: PricingDetails(prompt: 0, completion: 0, request: 0),
  );
  final model = CustomModelInfo(
    id: 'model/one',
    name: 'A comfortably readable model name',
    providers: [provider],
  );

  Widget row({
    ValueChanged<ModelProviderInfo?>? onChanged,
    VoidCallback? onEdit,
  }) => ModelSelectionRow(
    model: model,
    selectedProvider: provider,
    onProviderChanged: onChanged ?? (_) {},
    onEditPrompt: onEdit,
    formatContextLength: (_) => '128K',
    buildIconWidget: (_, icon, {double size = 24}) => Icon(icon, size: size),
  );

  testWidgets(
    'model heading, provider and prompt occupy separate settings rows',
    (tester) async {
      var edits = 0;
      await tester.pumpWidget(
        testApp(Scaffold(body: row(onEdit: () => edits++))),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Provider')).dy,
        greaterThan(tester.getBottomLeft(find.text(model.name)).dy),
      );
      expect(
        tester.getTopLeft(find.text('System prompt')).dy,
        greaterThan(tester.getBottomLeft(find.text('Provider')).dy),
      );
      expect(findIcon(Icons.arrow_drop_down), findsNothing);
      expect(findIcon(Icons.chevron_right_rounded), findsNWidgets(2));
      await tester.tap(find.text('System prompt'));
      expect(edits, 1);
    },
  );

  testWidgets('provider still selects the real provider', (tester) async {
    ModelProviderInfo? selected;
    await tester.pumpWidget(
      testApp(Scaffold(body: row(onChanged: (p) => selected = p))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Provider One').last);
    await tester.pumpAndSettle();
    expect(selected?.slug, provider.slug);
  });

  testWidgets('grouped controls fit narrow phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 900),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: row(onEdit: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
