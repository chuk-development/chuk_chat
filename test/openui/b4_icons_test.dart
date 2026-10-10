// The lucide -> HugeIcons mapping of the OpenUI Icon component.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui_icons.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

import 'openui_test_helper.dart';

void main() {
  bool hasAsset(String stem) =>
      File('assets/icons/hugeicons/$stem.svg').existsSync();

  test('every table entry has its SVG in the app set', () {
    final missing = <String>[
      for (final e in kOpenUiLucideIcons.entries)
        if (!hasAsset(e.value)) '${e.key} -> ${e.value}',
    ];
    expect(missing, isEmpty);
    expect(kOpenUiLucideIcons.length, greaterThanOrEqualTo(200));
  });

  test('every category and the default resolve through the table', () {
    for (final e in kOpenUiIconCategories.entries) {
      expect(
        kOpenUiLucideIcons[e.value],
        isNotNull,
        reason: 'category ${e.key} -> ${e.value}',
      );
    }
    expect(kOpenUiLucideIcons[kOpenUiDefaultIcon], isNotNull);
  });

  test('common names resolve', () {
    const expected = <String, String>{
      'circle-check': 'checkmark-circle02',
      'map-pin': 'map-pin',
      'calendar': 'calendar01',
      'star': 'star',
      'trending-up': 'chart-increase',
      'users': 'user-group',
      'plane': 'airplane01',
      'cloud-rain': 'cloud-angled-rain',
      'shopping-cart': 'shopping-cart01',
      'dollar-sign': 'dollar01',
      'clock': 'clock01',
      'file-text': 'file-text',
    };
    for (final e in expected.entries) {
      expect(openUiIconStem(e.key), e.value, reason: e.key);
    }
  });

  test('names are normalised', () {
    // Case, PascalCase, underscores, prefixes and suffixes.
    expect(openUiIconStem('CircleCheck'), 'checkmark-circle02');
    expect(openUiIconStem(' MAP_PIN '), 'map-pin');
    expect(openUiIconStem('lucide-star'), 'star');
    expect(openUiIconStem('star-icon'), 'star');
    // Old lucide names with the shape last.
    expect(openUiIconStem('check-circle'), 'checkmark-circle02');
    expect(openUiIconStem('x-circle'), openUiIconStem('circle-x'));
    expect(openUiIconStem('alert-triangle'), openUiIconStem('triangle-alert'));
    expect(openUiIconStem('help-circle'), openUiIconStem('circle-help'));
    // Number suffixes.
    expect(openUiIconStem('bar-chart-2'), openUiIconStem('bar-chart'));
    expect(openUiIconStem('check-circle-2'), 'checkmark-circle02');
    // A shape prefix, a first-and-last pair, a shorter prefix.
    expect(openUiIconStem('circle-parking'), openUiIconStem('parking'));
    expect(openUiIconStem('arrow-big-right'), openUiIconStem('arrow-right'));
    expect(openUiIconStem('map-pin-check'), 'map-pin');
    expect(openUiIconStem('calendar-clock-2'), isNotNull);
  });

  test('unknown names fall back to the category, then a neutral dot', () {
    expect(openUiIconStem('no-such-icon-xyz'), isNull);
    expect(
      openUiIcon('no-such-icon-xyz', 'travel').name,
      kOpenUiLucideIcons['plane'],
    );
    expect(
      openUiIcon('no-such-icon-xyz', ' Finance ').name,
      kOpenUiLucideIcons['dollar-sign'],
    );
    expect(
      openUiIcon('no-such-icon-xyz', 'no-such-category').name,
      kOpenUiLucideIcons[kOpenUiDefaultIcon],
    );
    expect(openUiIcon(null).name, kOpenUiLucideIcons[kOpenUiDefaultIcon]);
    expect(openUiIcon('').name, kOpenUiLucideIcons[kOpenUiDefaultIcon]);
    expect(openUiIcon('!!!').name, kOpenUiLucideIcons[kOpenUiDefaultIcon]);
    for (final name in <String?>['', null, 'zzz', 'map-pin']) {
      expect(hasAsset(openUiIcon(name, 'weather').name), isTrue);
    }
  });

  testWidgets('OpenUiIcon draws a HugeIcon with the inherited style', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: OpenUiIconStyle(
          size: 22,
          color: Color(0xFF00FF00),
          child: OpenUiIcon('star'),
        ),
      ),
    );
    final icon = tester.widget<HugeIcon>(find.byType(HugeIcon));
    expect(icon.icon.name, 'star');
    expect(icon.size, 22);
    expect(icon.color, const Color(0xFF00FF00));
  });

  testWidgets('OpenUiIcon follows an IconTheme a parent sets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            IconTheme.merge(
              data: const IconThemeData(color: Color(0xFFFF0000), size: 30),
              child: const OpenUiIcon('star', key: ValueKey<String>('a')),
            ),
            // The app's own icon theme gives the defaults.
            const OpenUiIcon('star', key: ValueKey<String>('b')),
            // An own colour wins over the parent.
            IconTheme.merge(
              data: const IconThemeData(color: Color(0xFFFF0000), size: 30),
              child: const OpenUiIcon(
                'star',
                color: Color(0xFF0000FF),
                key: ValueKey<String>('c'),
              ),
            ),
          ],
        ),
      ),
    );
    HugeIcon at(String k) => tester.widget<HugeIcon>(
      find.descendant(
        of: find.byKey(ValueKey<String>(k)),
        matching: find.byType(HugeIcon),
      ),
    );
    expect(at('a').size, 30);
    expect(at('a').color, const Color(0xFFFF0000));
    expect(at('b').size, 18);
    expect(at('c').color, const Color(0xFF0000FF));
    expect(at('c').size, 30);
  });

  testWidgets('an Icon inside an IconButton takes the button colours', (
    tester,
  ) async {
    await pumpOpenUi(
      tester,
      'root = Card([b])\n'
      'b = IconButton("Star", Icon("star"), null, "primary", "large")\n',
      brightness: Brightness.light,
    );
    final ctx = tester.element(find.byType(OpenUiIcon));
    final scheme = Theme.of(ctx).colorScheme;
    final icon = tester.widget<HugeIcon>(find.byType(HugeIcon));
    expect(icon.color, scheme.onPrimary);
    expect(icon.size, 24);
  });
}
