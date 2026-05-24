/// High-level file I/O handler that wires file_picker, platform I/O,
/// and [MarkdrawController] methods together.
///
/// NOTE: chuk_chat vendor patch — all FilePicker.platform calls were removed
/// to keep this file compiling against file_picker ^11 (which no longer
/// exposes the `platform` static). chuk_chat configures the editor with
/// `showMenu: false, showLibraryPanel: false` and drives persistence via
/// `ArtifactStorageService.rewriteArtifact`, so this handler is never
/// invoked in practice. If markdraw is upgraded, re-apply this patch.
library;

import 'package:flutter/widgets.dart';

import 'package:markdraw/markdraw.dart' hide TextAlign;

const String _kDisabledMessage =
    'MarkdrawFileHandler disabled in chuk_chat vendor — '
    'drive persistence through ArtifactStorageService instead.';

/// Encapsulates all file-picker + platform-I/O + controller interactions.
///
/// Create one per editor and pass its methods as callbacks to
/// [MarkdrawEditor].
class MarkdrawFileHandler {
  MarkdrawFileHandler({required this.controller});

  final MarkdrawController controller;

  /// The native file path of the currently-open file (null on web).
  String? currentFilePath;

  /// Saves to [currentFilePath], or falls through to [saveAs].
  Future<void> save() async {
    throw UnimplementedError(_kDisabledMessage);
  }

  /// Shows a save dialog (or blob download on web) and writes the scene.
  Future<void> saveAs() async {
    throw UnimplementedError(_kDisabledMessage);
  }

  /// Shows a file picker and loads the selected drawing.
  Future<void> open() async {
    throw UnimplementedError(_kDisabledMessage);
  }

  /// Exports the scene as PNG bytes via a save dialog (or blob download).
  Future<void> exportPng() async {
    throw UnimplementedError(_kDisabledMessage);
  }

  /// Exports the scene as SVG via a save dialog (or blob download).
  Future<void> exportSvg() async {
    throw UnimplementedError(_kDisabledMessage);
  }

  /// Shows an image picker and imports the selected image.
  ///
  /// [context] is used to determine screen size for centering.
  Future<void> importImage(BuildContext context) async {
    throw UnimplementedError(_kDisabledMessage);
  }

  /// Shows a file picker and imports a library file.
  Future<void> importLibrary() async {
    throw UnimplementedError(_kDisabledMessage);
  }

  /// Exports the current library via a save dialog (or blob download).
  Future<void> exportLibrary() async {
    throw UnimplementedError(_kDisabledMessage);
  }
}
