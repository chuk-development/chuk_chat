// lib/platform_specific/chat/handlers/desktop_file_handler.dart
import 'dart:async';

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
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileConstants.allowedExtensions,
      allowMultiple: true,
      withData: kIsWeb, // On web, we need bytes since paths aren't available
    );

    if (result != null && result.files.isNotEmpty) {
      if (kIsWeb) {
        await processWebFiles(result.files);
      } else {
        List<String> filePaths = result.files
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
      final Uint8List? bytes = platformFile.bytes;
      if (bytes == null) continue;

      final String fileName = platformFile.name;
      final int fileSize = platformFile.size;
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
    String? snackBarMessage,
  ) {
    int index = attachedFiles.indexWhere((f) => f.id == fileId);
    if (index != -1) {
      if (markdownContent != null) {
        // File successfully uploaded and content received
        attachedFiles[index] = attachedFiles[index].copyWith(
          markdownContent: markdownContent,
          isUploading: false,
        );
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
