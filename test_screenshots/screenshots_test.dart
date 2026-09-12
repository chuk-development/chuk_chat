// Generates the Play Store listing screenshots.
//
//   flutter test test_screenshots
//
// or, through fastlane, `cd android && bundle exec fastlane screenshots`.
//
// Output lands in fastlane/metadata/android/<locale>/images/..., which is
// the tree `fastlane supply` uploads from and the one F-Droid reads out of
// the git repository.
//
// Locales default to en-US and de-DE; override with
// SCREENSHOT_LOCALES=en-US,de-DE,fr-FR. Devices default to the phone form
// factor; add tablets with SCREENSHOT_DEVICES=phone,sevenInch,tenInch.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';

import 'src/harness.dart';
import 'src/scenes.dart';

/// A Play Store locale (`de-DE`) mapped to the app locale it renders in (`de`).
class _Locale {
  const _Locale(this.play, this.app);

  final String play;
  final String app;
}

typedef SceneBuilder = Widget Function({required String locale});

class _Scene {
  const _Scene(this.order, this.name, this.build);

  final int order;
  final String name;
  final SceneBuilder build;
}

const List<_Scene> _scenes = <_Scene>[
  _Scene(1, 'chat', chatScene),
  _Scene(2, 'tools', toolsScene),
  _Scene(3, 'reasoning', reasoningScene),
  _Scene(4, 'theme', themeScene),
];

const Map<String, DeviceSpec> _deviceByName = <String, DeviceSpec>{
  'phone': DeviceSpec.phone,
  'sevenInch': DeviceSpec.sevenInch,
  'tenInch': DeviceSpec.tenInch,
};

/// Maps a Play locale (`de-DE`) to the app locale it renders in (`de`), and
/// refuses one the app has no strings for.
///
/// Without this an unsupported locale renders in English and lands in that
/// locale's listing, which reads as a shipped translation that does not exist.
_Locale _resolveLocale(String play) {
  final String app = play.split('-').first;

  final bool supported = AppLocalizations.supportedLocales
      .any((Locale locale) => locale.languageCode == app);
  if (!supported) {
    final String known = AppLocalizations.supportedLocales
        .map((Locale locale) => locale.languageCode)
        .join(', ');
    throw ArgumentError(
      'The app has no strings for "$app" (from "$play"), so its screenshots '
      'would render in English. Translate it first, or drop it from '
      'SCREENSHOT_LOCALES. Known: $known',
    );
  }

  return _Locale(play, app);
}

List<String> _csvEnv(String key, List<String> fallback) {
  final String? raw = Platform.environment[key];
  if (raw == null || raw.trim().isEmpty) return fallback;
  return raw
      .split(',')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
}

void main() {
  final List<_Locale> locales = _csvEnv('SCREENSHOT_LOCALES',
          <String>['en-US', 'de-DE'])
      .map(_resolveLocale)
      .toList();

  final List<DeviceSpec> devices =
      _csvEnv('SCREENSHOT_DEVICES', <String>['phone']).map((String name) {
    final DeviceSpec? spec = _deviceByName[name];
    if (spec == null) {
      throw ArgumentError(
        'Unknown device "$name". Known: ${_deviceByName.keys.join(', ')}',
      );
    }
    return spec;
  }).toList();

  setUpAll(() async {
    await prepareScreenshotEnvironment();
  });

  // The listing banner and the store icon are per-locale but not per-device.
  for (final _Locale locale in locales) {
    group('listing / ${locale.play}', () {
      testWidgets('featureGraphic', (WidgetTester tester) async {
        final String path =
            '${playImagesDir(locale.play)}/featureGraphic.png';

        await captureScreenshot(
          tester,
          child: featureGraphicScene(locale: locale.app),
          device: DeviceSpec.featureGraphic,
          outPath: path,
        );

        expect(File(path).lengthSync(), greaterThan(0));
      });

      // Play wants a 512x512 listing icon; the app already ships one.
      test('icon', () {
        final File source = File('web/icons/Icon-512.png');
        expect(source.existsSync(), isTrue,
            reason: 'web/icons/Icon-512.png is the source of the store icon');

        final File target = File('${playImagesDir(locale.play)}/icon.png');
        target.parent.createSync(recursive: true);
        source.copySync(target.path);

        expect(target.lengthSync(), source.lengthSync());
      });
    });
  }

  for (final DeviceSpec device in devices) {
    for (final _Locale locale in locales) {
      group('${device.name} / ${locale.play}', () {
        for (final _Scene scene in _scenes) {
          testWidgets(scene.name, (WidgetTester tester) async {
            final String path = playStorePath(
              locale: locale.play,
              device: device,
              order: scene.order,
              name: scene.name,
            );

            await captureScreenshot(
              tester,
              child: scene.build(locale: locale.app),
              device: device,
              outPath: path,
            );

            expect(File(path).lengthSync(), greaterThan(0));
          });
        }
      });
    }
  }
}
