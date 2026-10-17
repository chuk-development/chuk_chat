// Renders the screenshot gallery: every scene in src/gallery_scenes.dart, in
// light and dark, at a mobile (412x915) and a desktop (1440x900) window.
//
//   flutter test test_screenshots/gallery_test.dart
//
// Output (never the fastlane tree):
//
//   build/gallery/<size>-<theme>/<NN>-<name>.png
//   build/gallery/index.json        one entry per PNG
//   build/gallery/manifest.sha256   `sha256sum -c` format, sorted by path
//
// A reviewer scans the PNGs. CI can diff manifest.sha256 against the one from
// the base branch and list the screens whose pixels changed.
//
// GALLERY_VARIANTS=mobile-dark,desktop-light limits the run to some variants.
// GALLERY_DPR=2 renders at twice the pixel density (default 1).
//
// This gallery is a review aid, not a gate. A layout error (an overflow, a
// throw inside build) does not fail the run: it lands in index.json under
// "errors", and the PNG shows it. test/layout/every_screen_layout_test.dart is
// the gate for those.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

import 'src/gallery_scenes.dart';
import 'src/harness.dart';

/// The gallery root, relative to the repository root where `flutter test`
/// runs. Kept apart from `fastlane/` on purpose.
const String kGalleryRoot = 'build/gallery';

class _Variant {
  const _Variant(this.size, this.theme, this.logical, this.brightness);

  final String size;
  final String theme;
  final Size logical;
  final Brightness brightness;

  String get id => '$size-$theme';
  bool get desktop => size == 'desktop';
}

const List<_Variant> _allVariants = <_Variant>[
  _Variant('mobile', 'light', Size(412, 915), Brightness.light),
  _Variant('mobile', 'dark', Size(412, 915), Brightness.dark),
  _Variant('desktop', 'light', Size(1440, 900), Brightness.light),
  _Variant('desktop', 'dark', Size(1440, 900), Brightness.dark),
];

List<_Variant> _selectedVariants() {
  final String? raw = Platform.environment['GALLERY_VARIANTS'];
  if (raw == null || raw.trim().isEmpty) return _allVariants;
  final Set<String> wanted =
      raw.split(',').map((String s) => s.trim()).toSet();
  final List<_Variant> out =
      _allVariants.where((_Variant v) => wanted.contains(v.id)).toList();
  if (out.isEmpty) {
    throw ArgumentError(
      'GALLERY_VARIANTS="$raw" matches nothing. Known: '
      '${_allVariants.map((_Variant v) => v.id).join(', ')}',
    );
  }
  return out;
}

double _dpr() {
  final String? raw = Platform.environment['GALLERY_DPR'];
  final double? value = raw == null ? null : double.tryParse(raw);
  return (value == null || value <= 0) ? 1.0 : value;
}

Color _background(Brightness brightness) =>
    galleryTheme(brightness).scaffoldBackgroundColor;

Widget _app(Widget home, Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: galleryTheme(brightness),
  localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: home,
);

/// Pumps until nothing animates, or gives up after a bounded time for a
/// screen with an endless animation (a spinner while it waits).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  } on FlutterError {
    // Never settles; the frames above are what the capture shows.
  }
}

Future<Uint8List> _rasterise(
  WidgetTester tester,
  GlobalKey key,
  double dpr,
) async {
  final Uint8List? bytes = await tester.runAsync<Uint8List?>(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    return data?.buffer.asUint8List();
  });
  if (bytes == null) throw StateError('toImage returned no bytes');
  return bytes;
}

void main() {
  final List<GalleryScene> scenes = gallerySceneList();
  final List<_Variant> variants = _selectedVariants();
  final double dpr = _dpr();
  final List<Map<String, Object?>> index = <Map<String, Object?>>[];

  setUpAll(() async {
    await prepareScreenshotEnvironment();
    final Directory root = Directory(kGalleryRoot);
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
  });

  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // ignore: invalid_use_of_visible_for_testing_member
    AgentsRelayLink.instance.reset();
  });
  // ignore: invalid_use_of_visible_for_testing_member
  tearDown(() => AgentsRelayLink.instance.reset());

  tearDownAll(() {
    index.sort(
      (Map<String, Object?> a, Map<String, Object?> b) =>
          (a['file']! as String).compareTo(b['file']! as String),
    );
    File('$kGalleryRoot/index.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'dpr': dpr,
        'count': index.length,
        'cannotMount': kGalleryCannotMount,
        'screens': index,
      })}\n',
    );
    File('$kGalleryRoot/manifest.sha256').writeAsStringSync(
      index.map((Map<String, Object?> e) => '${e['sha256']}  ${e['file']}\n')
          .join(),
    );
  });

  test('scene names are unique and file-name safe', () {
    final Set<String> seen = <String>{};
    for (final GalleryScene scene in scenes) {
      expect(RegExp(r'^[a-z0-9-]+$').hasMatch(scene.name), isTrue,
          reason: scene.name);
      expect(seen.add(scene.name), isTrue, reason: 'duplicate ${scene.name}');
    }
  });

  for (final _Variant variant in variants) {
    group(variant.id, () {
      for (int i = 0; i < scenes.length; i++) {
        final GalleryScene scene = scenes[i];
        final String file =
            '${variant.id}/${(i + 1).toString().padLeft(2, '0')}-${scene.name}.png';

        testWidgets(scene.name, (WidgetTester tester) async {
          tester.view.physicalSize = variant.logical * dpr;
          tester.view.devicePixelRatio = dpr;
          tester.view.padding = FakeViewPadding.zero;
          tester.view.viewInsets = FakeViewPadding.zero;
          addTearDown(tester.view.reset);

          // Desktop screens branch on the platform in a few places (hover,
          // keyboard hints, scroll bars); render them as Linux does.
          debugDefaultTargetPlatformOverride =
              variant.desktop ? TargetPlatform.linux : TargetPlatform.android;

          final GalleryContext ctx = GalleryContext(
            brightness: variant.brightness,
            desktop: variant.desktop,
          );
          final GlobalKey boundary = GlobalKey();
          final List<String> errors = <String>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = (FlutterErrorDetails d) =>
              errors.add(d.exception.toString().split('\n').first);

          late Uint8List png;
          try {
            scene.setUp?.call(ctx);
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: _background(variant.brightness),
                  child: _app(scene.build(ctx), variant.brightness),
                ),
              ),
            );
            await _settle(tester);
            await scene.after?.call(tester);
            png = await _rasterise(tester, boundary, dpr);

            // Unmount and drain inside the body: the binding checks for
            // pending timers before any tearDown runs.
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 1));
            try {
              await tester.pumpAndSettle(const Duration(milliseconds: 100));
            } on FlutterError {
              // Nothing left to settle.
            }
          } finally {
            FlutterError.onError = previous;
            debugDefaultTargetPlatformOverride = null;
            ctx.dispose();
          }

          final File out = File('$kGalleryRoot/$file');
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(png, flush: true);

          index.add(<String, Object?>{
            'name': scene.name,
            'file': file,
            'size': variant.size,
            'theme': variant.theme,
            'width': (variant.logical.width * dpr).round(),
            'height': (variant.logical.height * dpr).round(),
            'sha256': sha256.convert(png).toString(),
            if (errors.isNotEmpty) 'errors': errors,
          });

          expect(png.length, greaterThan(1000), reason: '$file is empty');
        });
      }
    });
  }
}
