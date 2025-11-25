// lib/platform_specific/chat/handlers/file_attachment_handler.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';

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

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileConstants.allowedExtensions,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) {
      debugPrint('File picking canceled.');
      return;
    }

    for (final platformFile in result.files) {
      final String? path = platformFile.path;
      if (path == null) continue;

      await _handleFileAttachment(
        file: File(path),
        fileName: platformFile.name,
        fileSizeBytes: platformFile.size,
        supportsImages: supportsImages,
      );
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
      _uploadEncryptedImage(file, fileName, fileId);
    } else {
      _chatApiService.performFileUpload(file, fileName, fileId);
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
      int index = _attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        _attachedFiles[index] = _attachedFiles[index].copyWith(
          encryptedImagePath: storagePath,
          isUploading: false,
          // Don't set markdownContent for images - they'll be sent separately
        );
        onUpdate?.call();
      }

      debugPrint(
        'Image "$fileName" uploaded and encrypted successfully: $storagePath',
      );
    } catch (error) {
      debugPrint('Failed to upload encrypted image "$fileName": $error');
      onError?.call('Failed to upload image "$fileName": $error');

      // Remove failed upload
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
    bool isUploading,
  ) {
    int index = _attachedFiles.indexWhere((f) => f.id == fileId);
    if (index != -1) {
      if (markdownContent != null) {
        _attachedFiles[index] = _attachedFiles[index].copyWith(
          markdownContent: markdownContent,
          isUploading: false,
        );
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

  /// Remove an attached file
  void removeFile(String fileId) {
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
