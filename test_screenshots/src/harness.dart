// Screenshot harness: renders app widgets headlessly at store-listing sizes
// and writes PNGs where `fastlane supply` picks them up.
//
// This runs under `flutter test`, not on a device, so it needs two things the
// normal test environment does not give it: real fonts (the test binding ships
// a blank placeholder font, which would render every glyph as a box) and a
// repaint boundary it can rasterise.
//
// It lives outside `test/` on purpose — `flutter test` with no path only walks
// `test/`, so the normal suite stays fast and free of file writes.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One store-listing form factor.
///
/// [width] and [height] are the physical pixels of the PNG — exactly what the
/// Play Console stores. [dpr] is the device pixel ratio the layout is done at,
/// so the logical canvas is `width / dpr` by `height / dpr`: a phone lays out
/// at 360x640 and rasterises at 1080x1920, like real hardware.
class DeviceSpec {
  const DeviceSpec({
    required this.name,
    required this.width,
    required this.height,
    required this.dpr,
    required this.playFolder,
  });

  final String name;
  final double width;
  final double height;
  final double dpr;

  /// The directory name `supply` expects under `images/`.
  final String playFolder;

  Size get physicalSize => Size(width, height);

  /// Phone: 1080x1920 is the safest 9:16 the Play Console accepts everywhere.
  static const DeviceSpec phone = DeviceSpec(
    name: 'phone',
    width: 1080,
    height: 1920,
    dpr: 3,
    playFolder: 'phoneScreenshots',
  );

  /// 7-inch tablet: laid out at 600x960, the classic `sw600dp` breakpoint.
  static const DeviceSpec sevenInch = DeviceSpec(
    name: 'sevenInch',
    width: 1200,
    height: 1920,
    dpr: 2,
    playFolder: 'sevenInchScreenshots',
  );

  /// The banner at the top of the store listing. Play fixes it at 1024x500
  /// and shows it cropped on some surfaces, so keep the message centred.
  static const DeviceSpec featureGraphic = DeviceSpec(
    name: 'featureGraphic',
    width: 1024,
    height: 500,
    dpr: 1,
    playFolder: '',
  );

  /// 10-inch tablet: laid out at 800x1280, i.e. `sw720dp`.
  static const DeviceSpec tenInch = DeviceSpec(
    name: 'tenInch',
    width: 1600,
    height: 2560,
    dpr: 2,
    playFolder: 'tenInchScreenshots',
  );
}

/// One-time setup for a screenshot run: a test binding, an empty preferences
/// store (several widgets read `SharedPreferences` in `initState` and throw
/// `MissingPluginException` without it) and the real fonts.
Future<void> prepareScreenshotEnvironment() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This directory sits outside `test/`, so the analyzer does not recognise it
  // as test code; the call is still only ever made from a test run.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await loadAppFonts();
}

/// Registers every font the app bundles, plus the Material icon font.
///
/// Without this the test binding draws its placeholder font and every
/// screenshot comes out as rows of empty rectangles.
Future<void> loadAppFonts() async {
  final String manifestJson =
      await rootBundle.loadString('FontManifest.json');
  final List<dynamic> manifest = json.decode(manifestJson) as List<dynamic>;

  for (final dynamic entry in manifest) {
    final Map<String, dynamic> family = entry as Map<String, dynamic>;
    final String rawFamily = family['family'] as String;

    // Package fonts arrive as `packages/<pkg>/<family>`; Flutter resolves both
    // that and the bare family name, so register the bare one too.
    final List<String> names = rawFamily.startsWith('packages/')
        ? <String>[rawFamily, rawFamily.split('/').last]
        : <String>[rawFamily];

    for (final String name in names) {
      final FontLoader loader = FontLoader(name);
      for (final dynamic fontEntry in family['fonts'] as List<dynamic>) {
        final String asset =
            (fontEntry as Map<String, dynamic>)['asset'] as String;
        loader.addFont(rootBundle.load(asset));
      }
      await loader.load();
    }
  }

  await _loadMonospaceAlias();
  await _loadPlatformDefaultFont();
}

/// The app asks for `fontFamily: 'monospace'` in a dozen places. That is a
/// platform alias Android and Linux resolve at runtime; the test engine cannot,
/// and every code block would come out as empty boxes. Point the alias at the
/// mono font the app already bundles.
Future<void> _loadMonospaceAlias() async {
  final FontLoader loader = FontLoader('monospace');
  loader.addFont(rootBundle.load('assets/fonts/JetBrainsMono-wght.ttf'));
  await loader.load();
}

/// App chrome (title bar, buttons, composer) leaves `fontFamily` null and takes
/// the platform default, which on Android is Roboto. The Flutter SDK ships
/// Roboto for exactly this reason, so register it under its own name.
Future<void> _loadPlatformDefaultFont() async {
  final Directory? materialFonts = _materialFontsDir();
  if (materialFonts == null) {
    // Falling through here would produce screenshots whose chrome is rows of
    // empty boxes, and every test would still pass. Fail instead.
    throw StateError(
      'Could not find <flutter sdk>/bin/cache/artifacts/material_fonts. '
      'Set FLUTTER_ROOT, or run `flutter precache` to populate the cache.',
    );
  }

  const List<String> faces = <String>[
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Italic.ttf',
  ];

  final FontLoader loader = FontLoader('Roboto');
  int loaded = 0;
  for (final String file in faces) {
    final File f = File('${materialFonts.path}/$file');
    if (!f.existsSync()) continue;
    loaded++;
    loader.addFont(
      Future<ByteData>.value(ByteData.view(f.readAsBytesSync().buffer)),
    );
  }

  if (loaded == 0) {
    throw StateError('No Roboto face in ${materialFonts.path}');
  }
  await loader.load();
}

/// `<flutter sdk>/bin/cache/artifacts/material_fonts`, found via FLUTTER_ROOT
/// when the tool sets it and otherwise from the Dart binary running the test
/// (`<sdk>/bin/cache/dart-sdk/bin/dart`).
Directory? _materialFontsDir() {
  final List<String> roots = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null)
      Platform.environment['FLUTTER_ROOT']!,
    Directory(Platform.resolvedExecutable).parent.parent.parent.parent.parent
        .path,
  ];

  for (final String root in roots) {
    final Directory dir =
        Directory('$root/bin/cache/artifacts/material_fonts');
    if (dir.existsSync()) return dir;
  }
  return null;
}

/// Renders [child] at [device] and writes the PNG to [outPath].
///
/// [settle] is off for scenes that hold an endless animation (a streaming
/// indicator, a spinner) — `pumpAndSettle` would never return on those.
Future<void> captureScreenshot(
  WidgetTester tester, {
  required Widget child,
  required DeviceSpec device,
  required String outPath,
  bool settle = true,
}) async {
  tester.view.physicalSize = device.physicalSize;
  tester.view.devicePixelRatio = device.dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final GlobalKey boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(key: boundaryKey, child: child),
  );

  if (settle) {
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }

  final Uint8List? bytes = await tester.runAsync<Uint8List?>(() async {
    final RenderRepaintBoundary boundary =
        boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: device.dpr);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  });

  if (bytes == null) {
    throw StateError('Failed to rasterise $outPath');
  }

  // Write through a temporary file and rename. A reader in another isolate —
  // test/fastlane_metadata_test.dart checks these same PNGs — then never sees
  // a half-written header.
  final File out = File(outPath);
  out.parent.createSync(recursive: true);
  final File tmp = File('$outPath.tmp');
  tmp.writeAsBytesSync(bytes, flush: true);
  tmp.renameSync(out.path);
}

/// Where a locale's store images live: `.../images/`.
String playImagesDir(String locale) =>
    '$kMetadataRoot/$locale/images';

/// The listing tree, at the repository root.
///
/// This is the one layout both stores read: `fastlane supply` uploads from it
/// (via `metadata_path`), and F-Droid picks up `fastlane/metadata/android/`
/// straight out of the git repository. One tree, two stores.
const String kMetadataRoot = 'fastlane/metadata/android';

/// Where a scene's PNG goes, in the layout both stores read:
/// `fastlane/metadata/android/<locale>/images/<folder>/<n>_<name>.png`.
/// Paths are relative to the repository root, which is where `flutter test`
/// runs.
///
/// The numeric prefix is the listing order in the Play Console.
String playStorePath({
  required String locale,
  required DeviceSpec device,
  required int order,
  required String name,
}) {
  final String index = order.toString().padLeft(2, '0');
  return '$kMetadataRoot/$locale/images/'
      '${device.playFolder}/${index}_$name.png';
}
