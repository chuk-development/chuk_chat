// Guards the Play Store listing tree. Every rule here is one the Play Console
// only enforces at upload time, i.e. after a full release build has already
// run — cheaper to fail in `flutter test`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const String _metadataRoot = 'fastlane/metadata/android';

/// Play's own limits for a store listing.
const int _titleLimit = 30;
const int _shortDescriptionLimit = 80;
const int _fullDescriptionLimit = 4000;
const int _changelogLimit = 500;

/// Play rejects a screenshot with any side below 320 px or above 3840 px.
const int _minScreenshotSide = 320;
const int _maxScreenshotSide = 3840;

List<Directory> _locales() {
  final Directory root = Directory(_metadataRoot);
  if (!root.existsSync()) return <Directory>[];
  return root.listSync().whereType<Directory>().toList()
    ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
}

/// The first eight bytes of every PNG.
const List<int> _pngSignature = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
];

/// Width and height out of a PNG's IHDR chunk, which always starts at byte 16.
///
/// Checks the signature first so a truncated or misnamed file fails with its
/// own path in the message rather than a bare `RangeError`.
({int width, int height}) _pngSize(File file) {
  final Uint8List bytes = file.readAsBytesSync();

  if (bytes.length < 24) {
    fail('${file.path} is ${bytes.length} bytes, too short to be a PNG');
  }
  for (int i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) {
      fail('${file.path} is not a PNG');
    }
  }

  final ByteData data = ByteData.sublistView(bytes, 0, 24);
  return (width: data.getUint32(16), height: data.getUint32(20));
}

void main() {
  final List<Directory> locales = _locales();

  test('the metadata tree exists', () {
    expect(
      locales,
      isNotEmpty,
      reason: '$_metadataRoot should hold one directory per Play locale',
    );
  });

  for (final Directory locale in locales) {
    final String name = locale.path.split('/').last;

    group(name, () {
      void expectWithin(String fileName, int limit) {
        final File file = File('${locale.path}/$fileName');
        expect(file.existsSync(), isTrue,
            reason: '${file.path} is required by `fastlane supply`');

        final String text = file.readAsStringSync().trimRight();
        expect(text, isNotEmpty, reason: '${file.path} is empty');
        expect(
          text.length,
          lessThanOrEqualTo(limit),
          reason: '${file.path} is ${text.length} chars, Play allows $limit',
        );
      }

      test('title fits', () => expectWithin('title.txt', _titleLimit));

      test('short description fits',
          () => expectWithin('short_description.txt', _shortDescriptionLimit));

      test('full description fits',
          () => expectWithin('full_description.txt', _fullDescriptionLimit));

      test('every changelog fits', () {
        final Directory dir = Directory('${locale.path}/changelogs');
        expect(dir.existsSync(), isTrue,
            reason: '${dir.path} should hold at least default.txt');

        final List<File> notes = dir
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.txt'))
            .toList();
        expect(notes, isNotEmpty);

        for (final File note in notes) {
          final String text = note.readAsStringSync().trimRight();
          expect(text, isNotEmpty, reason: '${note.path} is empty');
          expect(
            text.length,
            lessThanOrEqualTo(_changelogLimit),
            reason: '${note.path} is ${text.length} chars, Play allows '
                '$_changelogLimit',
          );
        }
      });

      test('the listing has at least two phone screenshots', () {
        final Directory dir =
            Directory('${locale.path}/images/phoneScreenshots');
        expect(dir.existsSync(), isTrue,
            reason: 'run `flutter test test_screenshots` to generate them');

        final List<File> shots = dir
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.png'))
            .toList();

        expect(shots.length, greaterThanOrEqualTo(2),
            reason: 'Play requires at least two phone screenshots');

        for (final File shot in shots) {
          final ({int width, int height}) size = _pngSize(shot);
          // Play also caps the shape: the long side may be at most twice the
          // short one, or the upload is rejected.
          final int longSide =
              size.width > size.height ? size.width : size.height;
          final int shortSide =
              size.width > size.height ? size.height : size.width;
          expect(longSide, lessThanOrEqualTo(shortSide * 2),
              reason: '${shot.path} is ${size.width}x${size.height}');
          for (final int side in <int>[size.width, size.height]) {
            expect(side, greaterThanOrEqualTo(_minScreenshotSide),
                reason: '${shot.path} is ${size.width}x${size.height}');
            expect(side, lessThanOrEqualTo(_maxScreenshotSide),
                reason: '${shot.path} is ${size.width}x${size.height}');
          }
        }
      });

      test('the feature graphic is exactly 1024x500', () {
        final File graphic = File('${locale.path}/images/featureGraphic.png');
        expect(graphic.existsSync(), isTrue,
            reason: 'run `flutter test test_screenshots` to generate it');

        final ({int width, int height}) size = _pngSize(graphic);
        expect(size.width, 1024);
        expect(size.height, 500);
      });

      test('the store icon is exactly 512x512', () {
        final File icon = File('${locale.path}/images/icon.png');
        expect(icon.existsSync(), isTrue);

        final ({int width, int height}) size = _pngSize(icon);
        expect(size.width, 512);
        expect(size.height, 512);
      });
    });
  }
}
