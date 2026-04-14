// lib/services/file_save_service.dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chuk_chat/services/download_preferences_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';

/// Outcome of a save attempt. Callers use this to drive snackbars or follow-up
/// actions without needing to know which underlying mechanism ran.
class SaveResult {
  const SaveResult._({required this.outcome, this.path});

  final SaveOutcome outcome;
  final String? path;

  bool get success =>
      outcome == SaveOutcome.savedToFolder ||
      outcome == SaveOutcome.savedViaPicker ||
      outcome == SaveOutcome.savedViaShare;
}

enum SaveOutcome {
  savedToFolder,
  savedViaPicker,
  savedViaShare,
  cancelled,
  failed,
}

/// Centralised file-save entry point. Every download in the app should funnel
/// through here so the user's prompt-vs-default-folder preference is always
/// respected, regardless of which screen triggered the save.
class FileSaveService {
  const FileSaveService._();

  /// Save [bytes] to disk under [suggestedName].
  ///
  /// Behaviour:
  /// - Web: hands off to the system share sheet (no real filesystem).
  /// - Native + "always ask" enabled OR no default folder configured →
  ///   open a save dialog so the user picks a destination.
  /// - Native + default folder configured + "always ask" disabled →
  ///   write straight to that folder, suffixing on filename collision.
  ///
  /// [allowedExtensions] is a hint for the picker; [dialogTitle] is used by
  /// the picker on platforms that show one.
  static Future<SaveResult> save({
    required Uint8List bytes,
    required String suggestedName,
    String? dialogTitle,
    List<String>? allowedExtensions,
  }) async {
    await DownloadPreferencesService.ensureLoaded();

    if (kIsWeb) {
      try {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile.fromData(bytes, name: suggestedName)],
          ),
        );
        return const SaveResult._(outcome: SaveOutcome.savedViaShare);
      } catch (error, stack) {
        if (kDebugMode) {
          debugPrint('FileSaveService web share failed: $error\n$stack');
        }
        return const SaveResult._(outcome: SaveOutcome.failed);
      }
    }

    final folder = DownloadPreferencesService.defaultFolder;
    if (DownloadPreferencesService.shouldSkipPrompt &&
        folder != null &&
        folder.isNotEmpty) {
      try {
        final path = await _writeWithCollisionSuffix(
          folder: folder,
          fileName: suggestedName,
          bytes: bytes,
        );
        return SaveResult._(outcome: SaveOutcome.savedToFolder, path: path);
      } catch (error, stack) {
        if (kDebugMode) {
          debugPrint(
            'FileSaveService default-folder write failed: $error\n$stack',
          );
        }
        // Fall through to picker so the user can still save somewhere.
      }
    }

    try {
      final selectedPath = await FilePicker.saveFile(
        dialogTitle: dialogTitle ?? 'Save file',
        fileName: suggestedName,
        type: allowedExtensions == null ? FileType.any : FileType.custom,
        allowedExtensions: allowedExtensions,
        bytes: bytes,
      );
      if (selectedPath == null || selectedPath.isEmpty) {
        return const SaveResult._(outcome: SaveOutcome.cancelled);
      }
      // On some platforms (e.g. Android) FilePicker writes the bytes itself
      // when the `bytes` arg is provided; on others (desktop) we still need
      // to write the file ourselves. Writing again is a no-op overwrite.
      final file = File(selectedPath);
      if (!await file.exists() || (await file.length()) != bytes.length) {
        await file.writeAsBytes(bytes, flush: true);
      }
      return SaveResult._(
        outcome: SaveOutcome.savedViaPicker,
        path: selectedPath,
      );
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint('FileSaveService picker save failed: $error\n$stack');
      }
      return const SaveResult._(outcome: SaveOutcome.failed);
    }
  }

  static Future<String> _writeWithCollisionSuffix({
    required String folder,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final dir = Directory(folder);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final separator = Platform.pathSeparator;
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';

    var path = '$folder$separator$fileName';
    var counter = 1;
    while (await File(path).exists()) {
      path = '$folder$separator${base}_$counter$ext';
      counter++;
    }
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }
}
