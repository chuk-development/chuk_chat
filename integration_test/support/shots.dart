// Full-app screenshots for integration tests.
//
// The app wraps its whole tree in a RepaintBoundary with the key
// `appCaptureBoundaryKey` (lib/main.dart, debug and profile builds only).
// `takeShot` renders that boundary to a PNG file:
//
//   build/integration_shots/<name>.png
//
// The path is absolute, relative to the repository root. The root is found
// from the app executable (`<root>/build/linux/x64/<mode>/bundle/<exe>`),
// because the working directory of the app process is not fixed.
// `--dart-define=INTEGRATION_SHOTS_DIR=<dir>` sets another directory.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chuk_chat/main.dart' show appCaptureBoundaryKey;

const String _shotsDirDefine = String.fromEnvironment('INTEGRATION_SHOTS_DIR');

/// The directory that receives the PNG files.
Directory shotsDirectory() {
  if (_shotsDirDefine.isNotEmpty) return Directory(_shotsDirDefine);
  return Directory(p.join(_repositoryRoot(), 'build', 'integration_shots'));
}

String _repositoryRoot() {
  final List<String> parts = p.split(Platform.resolvedExecutable);
  // <root>/build/linux/<arch>/<mode>/bundle/<exe>
  for (int i = parts.length - 2; i > 0; i--) {
    if (parts[i] == 'build' && parts[i + 1] == 'linux') {
      return p.joinAll(parts.sublist(0, i));
    }
  }
  return Directory.current.path;
}

/// Renders the root boundary of the app and writes it to
/// `<shotsDirectory>/<name>.png`. Returns the written file.
///
/// Pumps a few frames first, so the boundary holds a fresh picture.
Future<File> takeShot(
  WidgetTester tester,
  String name, {
  double pixelRatio = 1.0,
}) async {
  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  final BuildContext? context = appCaptureBoundaryKey.currentContext;
  if (context == null) {
    throw StateError(
      'No capture boundary in the tree. It exists only in debug and profile '
      'builds (lib/main.dart, appCaptureBoundaryKey).',
    );
  }
  final RenderRepaintBoundary boundary =
      context.findRenderObject()! as RenderRepaintBoundary;

  final File file = (await tester.runAsync<File>(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding failed for "$name"');
      final Directory dir = shotsDirectory();
      await dir.create(recursive: true);
      final File out = File(p.join(dir.path, '$name.png'));
      await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return out;
    } finally {
      image.dispose();
    }
  }))!;
  // ignore: avoid_print
  print('[shots] wrote ${file.path}');
  return file;
}
