// lib/platform_specific/chat/handlers/file_attachment_handler.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/file_upload_validator.dart';

/// Handles file and image attachments
class FileAttachmentHandler {
  final List<AttachedFile> _attachedFiles = [];
  final Uuid _uuid = const Uuid();
  final ImagePicker _imagePicker = ImagePicker();
  late final ChatApiService _chatApiService;

  // Callbacks
  Function(String)? onError;
  VoidCallback? onUpdate;

  List<AttachedFile> get attachedFiles => _attachedFiles;
  bool get hasAttachments => _attachedFiles.isNotEmpty;
  bool get hasUploading => _attachedFiles.any((f) => f.isUploading);

  void initialize(ChatApiService apiService) {
    _chatApiService = apiService;
  }

  /// Pick image from camera or gallery
  Future<void> pickImageFromSource(
    ImageSource source, {
    required bool supportsImages,
  }) async {
    if (!supportsImages) {
      onError?.call(
        'Image uploads are not supported by the selected model. Choose a vision-capable model in Settings.',
      );
      return;
    }

    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        imageQuality: 90,
      );
      if (pickedFile == null) return;

      final File file = File(pickedFile.path);
      final int fileSize = await pickedFile.length();
      final String fileName = pickedFile.name.isNotEmpty
          ? pickedFile.name
          : pickedFile.path.split('/').last;

      await _handleFileAttachment(
        file: file,
        fileName: fileName,
        fileSizeBytes: fileSize,
        supportsImages: supportsImages,
      );
    } catch (error) {
      final String sourceName = source == ImageSource.camera
          ? 'camera'
          : 'photo picker';
      onError?.call('Unable to open $sourceName: $error');
    }
  }

  /// Pick multiple images from gallery
  Future<void> pickImagesFromGallery({required bool supportsImages}) async {
    if (!supportsImages) {
      onError?.call(
        'Image uploads are not supported by the selected model. Choose a vision-capable model in Settings.',
      );
      return;
    }

    try {
      final List<XFile> pickedImages = await _imagePicker.pickMultiImage(
        imageQuality: 90,
      );
      if (pickedImages.isEmpty) return;

      for (final XFile image in pickedImages) {
        final File file = File(image.path);
        final int fileSize = await image.length();
        final String fileName = image.name.isNotEmpty
            ? image.name
            : image.path.split('/').last;
        await _handleFileAttachment(
          file: file,
          fileName: fileName,
          fileSizeBytes: fileSize,
          supportsImages: supportsImages,
        );
      }
    } catch (error) {
      onError?.call('Unable to access photo library: $error');
    }
  }

  /// Upload files using file picker
  Future<void> uploadFiles({required bool supportsImages}) async {
    if (_attachedFiles.where((f) => f.isUploading).length >=
        FileConstants.maxConcurrentUploads) {
      onError?.call('Please wait for current uploads to complete');
      return;
    }

    final List<PlatformFile> pickedFiles = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileConstants.allowedExtensions,
    );

    if (pickedFiles.isEmpty) {
      if (kDebugMode) {
        debugPrint('File picking canceled.');
      }
      return;
    }

    for (final platformFile in pickedFiles) {
      if (kIsWeb) {
        // Size first, bytes only once the file passed the checks — reading a
        // rejected 200 MB selection would take the browser heap with it.
        await _handleWebFileAttachment(
          readBytes: platformFile.readAsBytes,
          fileName: platformFile.name,
          fileSizeBytes: await platformFile.length(),
          supportsImages: supportsImages,
        );
      } else {
        final String? path = platformFile.path;
        if (path == null) continue;
        await _handleFileAttachment(
          file: File(path),
          fileName: platformFile.name,
          fileSizeBytes: await platformFile.length(),
          supportsImages: supportsImages,
        );
      }
    }
  }

  Future<void> _handleFileAttachment({
    required File file,
    required String fileName,
    required int fileSizeBytes,
    required bool supportsImages,
  }) async {
    final String extension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    // Skip size check for images - they'll be compressed automatically (no size limit)
    if (!_isImageExtension(extension) &&
        fileSizeBytes > FileConstants.maxFileSizeBytes) {
      onError?.call('File "$fileName" exceeds 10MB limit');
      return;
    }

    if (extension.isEmpty ||
        !FileConstants.allowedExtensions.contains(extension)) {
      final String detail = extension.isEmpty ? '' : ': .$extension';
      onError?.call('Unsupported file type for "$fileName"$detail');
      return;
    }

    if (_isImageExtension(extension) && !supportsImages) {
      onError?.call('Image uploads are not supported by the selected model.');
      return;
    }

    if (_attachedFiles.where((f) => f.isUploading).length >=
        FileConstants.maxConcurrentUploads) {
      onError?.call(
        'Skipping "$fileName": too many concurrent uploads. Try again soon.',
      );
      return;
    }

    final String fileId = _uuid.v4();
    final bool isImage = _isImageExtension(extension);

    _attachedFiles.add(
      AttachedFile(
        id: fileId,
        fileName: fileName,
        isUploading: true,
        localPath: file.path,
        fileSizeBytes: fileSizeBytes,
        isImage: isImage,
      ),
    );
    onUpdate?.call();

    // Handle images differently - compress, encrypt, and upload to storage
    if (isImage) {
      // Validate image magic bytes before uploading
      final imageBytes = await file.readAsBytes();
      final validation = FileUploadValidator.validateImageBytes(
        imageBytes,
        fileName,
      );
      if (!validation.isValid) {
        onError?.call(validation.errorMessage ?? 'Invalid image file');
        _attachedFiles.removeWhere((f) => f.id == fileId);
        onUpdate?.call();
        return;
      }
      _uploadEncryptedImageFromBytes(imageBytes, fileName, fileId);
    } else {
      _chatApiService.performFileUpload(file, fileName, fileId);
    }
  }

  /// Handle file attachment from bytes (web).
  ///
  /// [readBytes] is called only after the file passed the type and size
  /// checks, so a rejected file is never loaded into memory.
  Future<void> _handleWebFileAttachment({
    required Future<Uint8List> Function() readBytes,
    required String fileName,
    required int fileSizeBytes,
    required bool supportsImages,
  }) async {
    final String extension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    if (!_isImageExtension(extension) &&
        fileSizeBytes > FileConstants.maxFileSizeBytes) {
      onError?.call('File "$fileName" exceeds 10MB limit');
      return;
    }

    if (extension.isEmpty ||
        !FileConstants.allowedExtensions.contains(extension)) {
      onError?.call('Unsupported file type for "$fileName"');
      return;
    }

    if (_isImageExtension(extension) && !supportsImages) {
      onError?.call('Image uploads are not supported by the selected model.');
      return;
    }

    final Uint8List bytes = await readBytes();

    final String fileId = _uuid.v4();
    final bool isImage = _isImageExtension(extension);

    _attachedFiles.add(
      AttachedFile(
        id: fileId,
        fileName: fileName,
        isUploading: true,
        localPath: '',
        fileSizeBytes: fileSizeBytes,
        isImage: isImage,
      ),
    );
    onUpdate?.call();

    if (isImage) {
      // Validate image magic bytes before uploading
      final validation = FileUploadValidator.validateImageBytes(
        bytes,
        fileName,
      );
      if (!validation.isValid) {
        onError?.call(validation.errorMessage ?? 'Invalid image file');
        _attachedFiles.removeWhere((f) => f.id == fileId);
        onUpdate?.call();
        return;
      }
      _uploadEncryptedImageFromBytes(bytes, fileName, fileId);
    } else {
      _chatApiService.performFileUploadFromBytes(bytes, fileName, fileId);
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

      int index = _attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        _attachedFiles[index] = _attachedFiles[index].copyWith(
          encryptedImagePath: storagePath,
          isUploading: false,
        );
        onUpdate?.call();
      }
    } catch (error) {
      onError?.call('Failed to upload image "$fileName": $error');
      int index = _attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        _attachedFiles.removeAt(index);
        onUpdate?.call();
      }
    }
  }

  bool _isImageExtension(String extension) {
    return FileConstants.imageExtensions.contains(extension);
  }

  /// Handle file upload status update from ChatApiService
  void handleUploadStatusUpdate(
    String fileId,
    String? markdownContent,
    bool isUploading, {
    List<String>? pageImages,
  }) {
    int index = _attachedFiles.indexWhere((f) => f.id == fileId);
    if (index != -1) {
      if (markdownContent != null) {
        // A scanned PDF comes back as page images instead of text. Stay in
        // the uploading state until they are in encrypted storage, so
        // sending cannot race ahead of them, then swap the PDF out for the
        // pages themselves.
        final bool hasPages = pageImages != null && pageImages.isNotEmpty;
        _attachedFiles[index] = _attachedFiles[index].copyWith(
          markdownContent: markdownContent,
          isUploading: hasPages,
        );
        if (hasPages) {
          unawaited(
            _replaceWithScannedPages(
              pageImages,
              fileId,
              _attachedFiles[index].fileName,
              markdownContent,
            ),
          );
        }
      } else if (!isUploading) {
        _attachedFiles.removeAt(index);
      } else {
        _attachedFiles[index] = _attachedFiles[index].copyWith(
          isUploading: isUploading,
        );
      }
      onUpdate?.call();
    }
  }

  /// Replace a scanned PDF with its rendered pages.
  ///
  /// The PDF itself has no text layer, so keeping it in the tray would show
  /// the user a document nobody can read. The pages take its place as
  /// ordinary image attachments — the same encrypted storage, the same send
  /// path — and the note explaining that this is a scan rides on the first
  /// one so it still reaches the model.
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
      await _discardPages(paths);
      final index = _attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        _attachedFiles.removeAt(index);
        onUpdate?.call();
      }
      onError?.call('Failed to prepare the scanned pages of "$fileName": $error');
      return;
    }

    final index = _attachedFiles.indexWhere((f) => f.id == fileId);
    if (index == -1) {
      // Removed while we were uploading: do not leave orphans in storage.
      await _discardPages(paths);
      return;
    }
    if (paths.isEmpty) {
      _attachedFiles.removeAt(index);
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
          // Only the first page carries the note; repeating it per page
          // would send the model the same paragraph ten times.
          markdownContent: i == 0 ? note : null,
        ),
    ];
    _attachedFiles.replaceRange(index, index + 1, pageFiles);
    onUpdate?.call();
  }

  Future<void> _discardPages(List<String> paths) async {
    for (final path in paths) {
      unawaited(
        ImageStorageService.deleteEncryptedImage(path).catchError((_) {}),
      );
    }
  }

  /// Remove an attached file.
  /// If the file was an uploaded image, silently deletes it from Supabase Storage.
  void removeFile(String fileId) {
    final file = _attachedFiles.where((f) => f.id == fileId).firstOrNull;
    if (file != null && file.encryptedImagePath != null) {
      ImageStorageService.deleteEncryptedImage(
        file.encryptedImagePath!,
      ).catchError((_) {
        // Silently ignore — user chose to remove it
      });
    }
    _attachedFiles.removeWhere((f) => f.id == fileId);
    onUpdate?.call();
  }

  /// Clear all attachments
  void clearAll() {
    _attachedFiles.clear();
    onUpdate?.call();
  }

  /// Get files with markdown content (successfully uploaded)
  List<AttachedFile> getUploadedFiles() {
    return _attachedFiles.where((f) => f.markdownContent != null).toList();
  }
}
