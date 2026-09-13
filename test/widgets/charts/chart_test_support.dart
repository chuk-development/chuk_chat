// Shared harness for the chart tests: real fonts, a card-sized surface, and
// one call that renders a spec at a chosen width, theme and text scale.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/charts/chuk_chart.dart';

/// Loads Roboto from the SDK so a golden shows real glyphs instead of the
/// Ahem boxes the test font draws.
///
/// The fonts live in `<flutter>/bin/cache/artifacts/material_fonts`, but the
/// test binary does not sit at a fixed depth under it, so the directory is
/// found by walking up from the running executable and then from FLUTTER_ROOT
/// rather than counting `..` and hoping.
Future<void> loadChartFonts() async {
  final Directory? fontsDir = _findMaterialFonts();
  if (fontsDir == null) return;
  final FontLoader loader = FontLoader('Roboto');
  for (final String file in <String>[
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ]) {
    final File f = File('${fontsDir.path}/$file');
    if (!f.existsSync()) continue;
    loader.addFont(
      Future<ByteData>.value(ByteData.sublistView(await f.readAsBytes())),
    );
  }
  await loader.load();
}

Directory? _findMaterialFonts() {
  final List<String> roots = <String>[
    Platform.resolvedExecutable,
    if (Platform.environment['FLUTTER_ROOT'] != null)
      Platform.environment['FLUTTER_ROOT']!,
  ];
  for (final String root in roots) {
    Directory dir = FileSystemEntity.isDirectorySync(root)
        ? Directory(root)
        : File(root).parent;
    for (int up = 0; up < 8; up++) {
      for (final String candidate in <String>[
        '${dir.path}/material_fonts',
        '${dir.path}/bin/cache/artifacts/material_fonts',
      ]) {
        final Directory d = Directory(candidate);
        if (d.existsSync()) return d;
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  return null;
}

/// The app's own scheme shape: a neutral seed, so the chart's colours come
/// from the chart, not from a purple Material default.
ThemeData chartTheme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF2962FF),
    brightness: brightness,
  ),
  fontFamily: 'Roboto',
);

/// Where the tests write the PNGs. Relative to `test/widgets/charts/`.
const String kChartGoldenDir = 'goldens';

/// Pumps [chart] into a bubble-width column on a themed background and
/// returns the finder to shoot.
Future<Finder> pumpChart(
  WidgetTester tester,
  Widget chart, {
  double width = 366,
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
  double surfaceHeight = 900,
}) async {
  tester.view.physicalSize = Size(width + 32, surfaceHeight);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final ThemeData theme = chartTheme(brightness);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width + 32, surfaceHeight),
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Material(
          color: theme.colorScheme.surface,
          child: Align(
            alignment: Alignment.topCenter,
            child: RepaintBoundary(
              key: const ValueKey<String>('chart-shot'),
              // The card's own background comes from the message behind it, so
              // the shot carries the surface with it — otherwise the PNG is a
              // transparent card and a dark theme looks white in a viewer.
              child: ColoredBox(
                color: theme.colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(width: width, child: chart),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return find.byKey(const ValueKey<String>('chart-shot'));
}

/// Renders [spec] finished (no entrance) and writes `<name>.png`.
Future<void> shootChart(
  WidgetTester tester,
  Object? json,
  String name, {
  double width = 366,
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
}) async {
  final Finder target = await pumpChart(
    tester,
    // Explicit, because the harness has no Material ancestor to inherit a
    // default text style from; the app itself has one.
    chukChartFromJson(json, animate: false, fontFamily: 'Roboto'),
    width: width,
    brightness: brightness,
    textScale: textScale,
  );
  await expectLater(
    target,
    matchesGoldenFile('$kChartGoldenDir/$name.png'),
  );
}
