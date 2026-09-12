// lib/platform_specific/chat/handlers/scanned_pdf_pages.dart

import 'dart:async';
import 'dart:convert';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:uuid/uuid.dart';

/// Replaces a scanned PDF in [attachedFiles] with its rendered pages.
///
/// The PDF itself has no text layer, so keeping it in the tray would show the
/// user a document nobody can read. The pages take its place as ordinary image
/// attachments — the same encrypted storage, the same send path — and [note],
/// which explains that this is a scan, rides on the first one so it still
/// reaches the model.
///
/// Both the desktop and the mobile attachment handler call this; they differ
/// only in how they report a failure, which is why [onError] is a callback.
Future<void> replaceWithScannedPages({
  required List<String> dataUrls,
  required String fileId,
  required String fileName,
  required String? note,
  required List<AttachedFile> attachedFiles,
  void Function()? onUpdate,
  void Function(String message)? onError,
}) async {
  final paths = <String>[];
  try {
    for (final dataUrl in dataUrls) {
      final comma = dataUrl.indexOf(',');
      if (comma < 0) continue;
      final bytes = base64Decode(dataUrl.substring(comma + 1));
      paths.add(await ImageStorageService.uploadEncryptedImage(bytes));
    }
  } catch (error) {
    discardScannedPages(paths);
    final index = attachedFiles.indexWhere((f) => f.id == fileId);
    if (index != -1) {
      attachedFiles.removeAt(index);
      onUpdate?.call();
    }
    onError?.call(
      'Failed to prepare the scanned pages of "$fileName": $error',
    );
    return;
  }

  final index = attachedFiles.indexWhere((f) => f.id == fileId);
  if (index == -1) {
    // Removed while we were uploading: do not leave orphans in storage.
    discardScannedPages(paths);
    return;
  }
  if (paths.isEmpty) {
    attachedFiles.removeAt(index);
    onUpdate?.call();
    onError?.call('No readable pages found in "$fileName".');
    return;
  }

  const uuid = Uuid();
  final pageFiles = <AttachedFile>[
    for (int i = 0; i < paths.length; i++)
      AttachedFile(
        id: uuid.v4(),
        fileName: '$fileName — page ${i + 1}',
        encryptedImagePath: paths[i],
        isImage: true,
        // Only the first page carries the note; repeating it per page would
        // send the model the same paragraph ten times.
        markdownContent: i == 0 ? note : null,
      ),
  ];
  attachedFiles.replaceRange(index, index + 1, pageFiles);
  onUpdate?.call();
}

/// Deletes pages that were uploaded before the replacement failed, so a
/// half-finished scan does not leave orphans in encrypted storage.
void discardScannedPages(List<String> paths) {
  for (final path in paths) {
    unawaited(
      ImageStorageService.deleteEncryptedImage(path).catchError((_) {}),
    );
  }
}
