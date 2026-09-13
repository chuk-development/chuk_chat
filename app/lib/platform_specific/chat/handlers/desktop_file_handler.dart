// lib/platform_specific/chat/handlers/desktop_file_handler.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';

/// Temporary container for validated files before upload.
class ValidatedFile {
  ValidatedFile({
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.isImage,
  });

  final File file;
  final String fileName;
  final int fileSize;
  final bool isImage;
  late String id;
}

/// Handles desktop-specific file attachment processing including:
/// - File picker (documents + images)
/// - Drag-and-drop file handling
/// - Web file processing (bytes-only)
/// - Encrypted image upload to Supabase Storage
/// - File removal with storage cleanup
class DesktopFileHandler {
  final List<AttachedFile> attachedFiles = [];
  final Uuid _uuid = const Uuid();
  late ChatApiService _chatApiService;

  // Callbacks
  void Function(String)? onShowSnackBar;
  VoidCallback? onUpdate;
  VoidCallback? onScrollToBottom;

  /// Whether the current model supports image input.
  /// Set by the parent widget before calling file processing methods.
  bool modelSupportsImageInput = false;

  /// Guards against opening a second native picker while one is already open.
  /// The picker can take a moment to appear on Linux, so rapid taps on the
  /// add button would otherwise stack multiple picker windows.
  bool _isPicking = false;

  void initialize(ChatApiService apiService) {
    _chatApiService = apiService;
  }

  bool get hasAttachments => attachedFiles.isNotEmpty;
  bool get hasUploading => attachedFiles.any((f) => f.isUploading);

  List<AttachedFile> getUploadedFiles() =>
      attachedFiles.where((f) => !f.isUploading).toList();

  /// Processes a list of file paths (from drag and drop or file picker)
  Future<void> processFilePaths(List<String> filePaths) async {
    const int maxFileSize = 10 * 1024 * 1024; // 10MB

    // Separate images from non-images and validate all files first
    final List<ValidatedFile> validImages = [];
    final List<ValidatedFile> validDocuments = [];

    for (String filePath in filePaths) {
      final File file = File(filePath);
      if (!await file.exists()) continue;

      final int fileSize = await file.length();
      final String fileName = file.path.split(Platform.pathSeparator).last;
      final String fileExtension = fileName.contains('.')
          ? fileName.split('.').last.toLowerCase()
          : '';
      final bool isImage = FileConstants.imageExtensions.contains(
        fileExtension,
      );

      // Validate extension
      if (!FileConstants.allowedExtensions.contains(fileExtension)) {
        onShowSnackBar?.call('Unsupported file type: .$fileExtension');
        continue;
      }

      // Check file size (skip for images — they'll be compressed)
      if (!isImage && fileSize > maxFileSize) {
        onShowSnackBar?.call('"$fileName" exceeds 10 MB limit');
        continue;
      }

      if (isImage && !modelSupportsImageInput) {
        onShowSnackBar?.call(
          'Image uploads are not supported by the selected model.',
        );
        continue; // Skip this image but keep processing other files
      }

      final validated = ValidatedFile(
        file: file,
        fileName: fileName,
        fileSize: fileSize,
        isImage: isImage,
      );

      if (isImage) {
        validImages.add(validated);
      } else {
        validDocuments.add(validated);
      }
    }

    // Enforce max image limit (count existing images + new ones)
    final int existingImages = attachedFiles.where((f) => f.isImage).length;
    final int slotsLeft = FileConstants.maxImageAttachments - existingImages;
    if (validImages.length > slotsLeft) {
      final int dropped = validImages.length - slotsLeft;
      validImages.removeRange(
        slotsLeft.clamp(0, validImages.length),
        validImages.length,
      );
      if (dropped > 0) {
        onShowSnackBar?.call(
          'Maximum ${FileConstants.maxImageAttachments} images allowed'
          ' — $dropped image${dropped > 1 ? 's' : ''} skipped.',
        );
      }
    }

    // Add all valid files to the UI immediately (showing upload spinners)
    for (final vf in [...validImages, ...validDocuments]) {
      final String fileId = _uuid.v4();
      vf.id = fileId;
      attachedFiles.add(
        AttachedFile(
          id: fileId,
          fileName: vf.fileName,
          isUploading: true,
          localPath: vf.file.path,
          fileSizeBytes: vf.fileSize,
          isImage: vf.isImage,
        ),
      );
    }
    onUpdate?.call();
    onScrollToBottom?.call();

    // Upload non-image documents concurrently (they go through the API)
    for (final vf in validDocuments) {
      _chatApiService.performFileUpload(vf.file, vf.fileName, vf.id);
    }

    // Upload images sequentially to avoid rate limits
    for (final vf in validImages) {
      await _uploadEncryptedImage(vf.file, vf.fileName, vf.id);
    }
  }

  /// Upload image with compression and encryption
  Future<void> _uploadEncryptedImage(
    File file,
    String fileName,
    String fileId,
  ) async {
    try {
      // Read image bytes
      final Uint8List imageBytes = await file.readAsBytes();

      // Upload to encrypted storage (compression + encryption happens inside)
      final String storagePath = await ImageStorageService.uploadEncryptedImage(
        imageBytes,
      );

      // Update the attached file with the storage path
      final int index = attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        attachedFiles[index] = attachedFiles[index].copyWith(
          encryptedImagePath: storagePath,
          isUploading: false,
        );
      }
      onUpdate?.call();

      if (kDebugMode) {
        debugPrint(
          'Image "$fileName" uploaded and encrypted successfully: $storagePath',
        );
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to upload encrypted image "$fileName": $error');
      }

      onShowSnackBar?.call('Failed to upload image "$fileName": $error');

      // Remove failed upload
      attachedFiles.removeWhere((f) => f.id == fileId);
      onUpdate?.call();
    }
  }

  /// Opens file picker and processes selected files.
  Future<void> uploadFiles() async {
    // A picker is already open — ignore repeat taps so we never stack windows.
    if (_isPicking) return;
    _isPicking = true;
    final List<PlatformFile> pickedFiles;
    try {
      pickedFiles = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: FileConstants.allowedExtensions,
      );
    } finally {
      // Clear as soon as the native dialog closes, so processing/uploading the
      // selection does not block the user from opening the picker again.
      _isPicking = false;
    }

    if (pickedFiles.isNotEmpty) {
      if (kIsWeb) {
        await processWebFiles(pickedFiles);
      } else {
        List<String> filePaths = pickedFiles
            .where((f) => f.path != null)
            .map((f) => f.path!)
            .toList();
        await processFilePaths(filePaths);
      }
    } else {
      if (kDebugMode) {
        debugPrint('File picking canceled.');
      }
    }
  }

  /// Process files on web where we only have bytes, not file paths
  Future<void> processWebFiles(List<PlatformFile> platformFiles) async {
    const int maxFileSize = 10 * 1024 * 1024; // 10MB
    const int maxConcurrentUploads = 5;

    if (attachedFiles.where((f) => f.isUploading).length >=
        maxConcurrentUploads) {
      onShowSnackBar?.call('Please wait for current uploads to complete');
      return;
    }

    for (final platformFile in platformFiles) {
      final String fileName = platformFile.name;
      // Ask for the size, not the content: a file rejected below must never
      // have been loaded into the browser heap first.
      final int fileSize = await platformFile.length();
      final String fileExtension = fileName.contains('.')
          ? fileName.split('.').last.toLowerCase()
          : '';

      final isImage = FileConstants.imageExtensions.contains(fileExtension);

      // Check file size (skip for images)
      if (!isImage && fileSize > maxFileSize) {
        onShowSnackBar?.call('File "$fileName" exceeds 10MB limit');
        continue;
      }

      if (!FileConstants.allowedExtensions.contains(fileExtension)) {
        onShowSnackBar?.call(
          'Unsupported file type for "$fileName": .$fileExtension',
        );
        continue;
      }

      if (isImage && !modelSupportsImageInput) {
        onShowSnackBar?.call(
          'Image uploads are not supported by the selected model.',
        );
        continue;
      }

      if (attachedFiles.where((f) => f.isUploading).length >=
          maxConcurrentUploads) {
        continue;
      }

      final Uint8List bytes = await platformFile.readAsBytes();

      String fileId = _uuid.v4();

      attachedFiles.add(
        AttachedFile(
          id: fileId,
          fileName: fileName,
          isUploading: true,
          localPath: '',
          fileSizeBytes: fileSize,
          isImage: isImage,
        ),
      );
      onUpdate?.call();
      onScrollToBottom?.call();

      if (isImage) {
        unawaited(_uploadEncryptedImageFromBytes(bytes, fileName, fileId));
      } else {
        _chatApiService.performFileUploadFromBytes(bytes, fileName, fileId);
      }
    }
  }

  /// Upload image from bytes (web)
  Future<void> _uploadEncryptedImageFromBytes(
    Uint8List imageBytes,
    String fileName,
    String fileId,
  ) async {
    try {
      final String storagePath = await ImageStorageService.uploadEncryptedImage(
        imageBytes,
      );

      final int index = attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        attachedFiles[index] = attachedFiles[index].copyWith(
          encryptedImagePath: storagePath,
          isUploading: false,
        );
      }
      onUpdate?.call();

      if (kDebugMode) {
        debugPrint(
          'Image "$fileName" uploaded and encrypted successfully: $storagePath',
        );
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to upload encrypted image "$fileName": $error');
      }

      onShowSnackBar?.call('Failed to upload image "$fileName": $error');

      attachedFiles.removeWhere((f) => f.id == fileId);
      onUpdate?.call();
    }
  }

  /// Handles files dropped via drag and drop
  Future<void> handleDroppedFiles(List<String> filePaths) async {
    await processFilePaths(filePaths);
  }

  /// Remove an attached file by ID. Cleans up encrypted images from storage.
  void removeAttachedFile(String fileId) {
    // If this was an uploaded image, delete it from Supabase Storage
    final file = attachedFiles.where((f) => f.id == fileId).firstOrNull;
    if (file != null && file.encryptedImagePath != null) {
      unawaited(
        ImageStorageService.deleteEncryptedImage(
          file.encryptedImagePath!,
        ).catchError((_) {
          // Silently ignore — the user chose to remove it
        }),
      );
    }

    attachedFiles.removeWhere((f) => f.id == fileId);
    onUpdate?.call();
  }

  /// Callback for upload status updates from ChatApiService.
  void handleFileUploadUpdate(
    String fileId,
    String? markdownContent,
    bool isUploading,
    String? snackBarMessage, {
    List<String>? pageImages,
  }) {
    int index = attachedFiles.indexWhere((f) => f.id == fileId);
    if (index != -1) {
      if (markdownContent != null) {
        // File successfully uploaded and content received. A scanned PDF
        // also carries page images: stay in the uploading state until they
        // are in encrypted storage so sending cannot race ahead of them.
        final bool hasPages = pageImages != null && pageImages.isNotEmpty;
        attachedFiles[index] = attachedFiles[index].copyWith(
          markdownContent: markdownContent,
          isUploading: hasPages,
        );
        if (hasPages) {
          unawaited(
            _replaceWithScannedPages(
              pageImages,
              fileId,
              attachedFiles[index].fileName,
              markdownContent,
            ),
          );
        }
      } else if (!isUploading) {
        // Upload failed or file was removed by service, remove from list
        attachedFiles.removeAt(index);
      } else {
        // Just updating isUploading status
        attachedFiles[index] = attachedFiles[index].copyWith(
          isUploading: isUploading,
        );
      }
    }
    onUpdate?.call();
    if (snackBarMessage != null) {
      onShowSnackBar?.call(snackBarMessage);
    }
    onScrollToBottom?.call();
  }

  /// Replace a scanned PDF with its rendered pages.
  ///
  /// The PDF has no text layer, so leaving it in the tray would show the
  /// user a document nobody can read. The pages take its place as ordinary
  /// image attachments, and the note explaining that this is a scan rides
  /// on the first one so it still reaches the model.
  Future<void> _replaceWithScannedPages(
    List<String> dataUrls,
    String fileId,
    String fileName,
    String? note,
  ) async {
    final paths = <String>[];
    try {
      for (final dataUrl in dataUrls) {
        final comma = dataUrl.indexOf(',');
        if (comma < 0) continue;
        final bytes = base64Decode(dataUrl.substring(comma + 1));
        paths.add(await ImageStorageService.uploadEncryptedImage(bytes));
      }
    } catch (error) {
      _discardPages(paths);
      final index = attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        attachedFiles.removeAt(index);
        onUpdate?.call();
      }
      onShowSnackBar?.call(
        'Failed to prepare the scanned pages of "$fileName": $error',
      );
      return;
    }

    final index = attachedFiles.indexWhere((f) => f.id == fileId);
    if (index == -1) {
      _discardPages(paths);
      return;
    }
    if (paths.isEmpty) {
      attachedFiles.removeAt(index);
      onUpdate?.call();
      onShowSnackBar?.call('No readable pages found in "$fileName".');
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
          markdownContent: i == 0 ? note : null,
        ),
    ];
    attachedFiles.replaceRange(index, index + 1, pageFiles);
    onUpdate?.call();
  }

  void _discardPages(List<String> paths) {
    for (final path in paths) {
      unawaited(
        ImageStorageService.deleteEncryptedImage(path).catchError((_) {}),
      );
    }
  }

  /// Clear all attachments.
  void clearAll() {
    for (final file in attachedFiles) {
      if (file.encryptedImagePath != null) {
        unawaited(
          ImageStorageService.deleteEncryptedImage(
            file.encryptedImagePath!,
          ).catchError((_) {}),
        );
      }
    }
    attachedFiles.clear();
  }
}
