import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:chuk_chat/utils/io_helper.dart';

/// File upload validation result.
class FileValidationResult {
  final bool isValid;
  final String? errorMessage;
  final int? fileSizeBytes;
  final String? mimeType;

  const FileValidationResult({
    required this.isValid,
    this.errorMessage,
    this.fileSizeBytes,
    this.mimeType,
  });

  factory FileValidationResult.success({
    required int fileSizeBytes,
    String? mimeType,
  }) {
    return FileValidationResult(
      isValid: true,
      fileSizeBytes: fileSizeBytes,
      mimeType: mimeType,
    );
  }

  factory FileValidationResult.error(String message) {
    return FileValidationResult(isValid: false, errorMessage: message);
  }
}

/// Utility for validating file uploads to prevent security issues.
class FileUploadValidator {
  FileUploadValidator._();

  /// Maximum file size in bytes (10MB)
  static const int maxFileSizeBytes = 10 * 1024 * 1024; // 10MB

  /// Maximum number of files in an archive
  static const int maxArchiveEntries = 1000;

  /// Maximum uncompressed size for archives (50MB)
  static const int maxArchiveUncompressedSize = 50 * 1024 * 1024;

  /// MIME type mappings for common file extensions
  static const Map<String, List<String>> extensionToMimeTypes = {
    // Documents
    'pdf': ['application/pdf'],
    'doc': ['application/msword'],
    'docx': [
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    ],
    'xls': ['application/vnd.ms-excel'],
    'xlsx': [
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ],
    'ppt': ['application/vnd.ms-powerpoint'],
    'pptx': [
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    ],
    'odt': ['application/vnd.oasis.opendocument.text'],
    'ods': ['application/vnd.oasis.opendocument.spreadsheet'],
    'odp': ['application/vnd.oasis.opendocument.presentation'],

    // Text formats
    'txt': ['text/plain'],
    'csv': ['text/csv', 'application/csv'],
    'json': ['application/json'],
    'xml': ['application/xml', 'text/xml'],
    'html': ['text/html'],
    'htm': ['text/html'],
    'md': ['text/markdown', 'text/plain'],
    'markdown': ['text/markdown', 'text/plain'],

    // Images
    'png': ['image/png'],
    'jpg': ['image/jpeg'],
    'jpeg': ['image/jpeg'],
    'gif': ['image/gif'],
    'bmp': ['image/bmp'],
    'tiff': ['image/tiff'],
    'tif': ['image/tiff'],
    'webp': ['image/webp'],

    // Audio
    'wav': ['audio/wav', 'audio/wave'],
    'mp3': ['audio/mpeg'],
    'm4a': ['audio/mp4', 'audio/x-m4a'],
    'aac': ['audio/aac'],
    'flac': ['audio/flac'],
    'ogg': ['audio/ogg'],

    // Archives
    'zip': ['application/zip', 'application/x-zip-compressed'],

    // E-books
    'epub': ['application/epub+zip'],

    // Email
    'msg': ['application/vnd.ms-outlook'],
    'eml': ['message/rfc822'],

    // Code files
    'py': ['text/x-python', 'text/plain'],
    'js': ['application/javascript', 'text/javascript', 'text/plain'],
    'ts': ['application/typescript', 'text/typescript', 'text/plain'],
    'java': ['text/x-java-source', 'text/plain'],
    'c': ['text/x-c', 'text/plain'],
    'cpp': ['text/x-c++', 'text/plain'],
    'go': ['text/x-go', 'text/plain'],
    'rs': ['text/x-rust', 'text/plain'],
    'rb': ['text/x-ruby', 'text/plain'],
    'php': ['application/x-php', 'text/x-php', 'text/plain'],
    'yaml': ['application/x-yaml', 'text/yaml', 'text/plain'],
    'yml': ['application/x-yaml', 'text/yaml', 'text/plain'],
  };

  /// Validates a file before upload.
  ///
  /// Checks:
  /// - File exists
  /// - File size is within limits
  /// - MIME type matches extension
  /// - Archive files are not malicious (zip bombs, etc.)
  static Future<FileValidationResult> validateFile(String filePath) async {
    try {
      final file = File(filePath);

      // Check if file exists
      if (!await file.exists()) {
        return FileValidationResult.error('File not found');
      }

      // Get file size
      final fileSize = await file.length();

      // Check file size
      if (fileSize > maxFileSizeBytes) {
        final sizeMB = (fileSize / (1024 * 1024)).toStringAsFixed(2);
        final maxMB = (maxFileSizeBytes / (1024 * 1024)).toStringAsFixed(0);
        return FileValidationResult.error(
          'File is too large ($sizeMB MB). Maximum size is $maxMB MB.',
        );
      }

      // Get file extension
      final fileName = file.path.split('/').last;
      final parts = fileName.split('.');
      if (parts.length < 2) {
        return FileValidationResult.error('File has no extension');
      }
      final extension = parts.last.toLowerCase();

      // Validate MIME type (basic check by reading first bytes)
      final mimeType = await _detectMimeType(file, extension);

      // Check if MIME type matches expected types for extension
      final expectedMimeTypes = extensionToMimeTypes[extension];
      if (expectedMimeTypes != null && mimeType != null) {
        // For text files, be more lenient
        final isTextFile =
            expectedMimeTypes.contains('text/plain') ||
            mimeType.startsWith('text/');

        if (!isTextFile && !expectedMimeTypes.contains(mimeType)) {
          // Check if it's a generic type that might be acceptable
          final isAcceptable =
              mimeType == 'application/octet-stream' ||
              mimeType == 'text/plain' ||
              mimeType.startsWith('text/');

          if (!isAcceptable) {
            return FileValidationResult.error(
              'File type mismatch. Expected $extension but got MIME type: $mimeType',
            );
          }
        }
      }

      // Special validation for archive files
      if (extension == 'zip') {
        final archiveValidation = await _validateArchive(file);
        if (!archiveValidation.isValid) {
          return archiveValidation;
        }
      }

      return FileValidationResult.success(
        fileSizeBytes: fileSize,
        mimeType: mimeType,
      );
    } catch (e) {
      return FileValidationResult.error(
        'File validation error: ${e.toString()}',
      );
    }
  }

  /// Detects MIME type by reading file magic bytes.
  static Future<String?> _detectMimeType(File file, String extension) async {
    try {
      // Read first 512 bytes for magic byte detection
      final bytes = await file.openRead(0, 512).first;

      // Check magic bytes for common file types
      if (bytes.length >= 4) {
        // PDF
        if (bytes[0] == 0x25 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x44 &&
            bytes[3] == 0x46) {
          return 'application/pdf';
        }

        // ZIP (includes DOCX, XLSX, PPTX, EPUB, etc.)
        if (bytes[0] == 0x50 &&
            bytes[1] == 0x4B &&
            bytes[2] == 0x03 &&
            bytes[3] == 0x04) {
          // Check for Office Open XML formats
          if (extension == 'docx') {
            return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
          } else if (extension == 'xlsx') {
            return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
          } else if (extension == 'pptx') {
            return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
          } else if (extension == 'epub') {
            return 'application/epub+zip';
          }
          return 'application/zip';
        }

        // PNG
        if (bytes.length >= 8 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47) {
          return 'image/png';
        }

        // JPEG
        if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
          return 'image/jpeg';
        }

        // GIF
        if (bytes[0] == 0x47 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x38) {
          return 'image/gif';
        }
      }

      // Check if it's a text file
      if (_isLikelyTextFile(bytes)) {
        return 'text/plain';
      }

      // Default to application/octet-stream
      return 'application/octet-stream';
    } catch (e) {
      return null;
    }
  }

  /// Checks if bytes are likely from a text file.
  static bool _isLikelyTextFile(List<int> bytes) {
    // Check for common text characters and lack of null bytes
    int textCharCount = 0;
    int nullByteCount = 0;

    for (int i = 0; i < bytes.length && i < 512; i++) {
      final byte = bytes[i];
      if (byte == 0) {
        nullByteCount++;
      } else if ((byte >= 0x20 && byte <= 0x7E) || // Printable ASCII
          byte == 0x09 || // Tab
          byte == 0x0A || // Line feed
          byte == 0x0D) {
        // Carriage return
        textCharCount++;
      }
    }

    // If more than 90% are text characters and few null bytes, likely text
    return textCharCount > (bytes.length * 0.9) && nullByteCount < 5;
  }

  /// Validates archive files to prevent zip bombs and malicious content.
  static Future<FileValidationResult> _validateArchive(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Check number of entries
      if (archive.length > maxArchiveEntries) {
        return FileValidationResult.error(
          'Archive contains too many files (${archive.length}). Maximum is $maxArchiveEntries.',
        );
      }

      // Check total uncompressed size (zip bomb detection)
      int totalUncompressedSize = 0;
      for (final file in archive) {
        totalUncompressedSize += file.size;
      }

      // Check for suspicious compression ratios (possible zip bomb)
      // Compare total uncompressed size with original compressed file size
      final compressedSize = bytes.length;
      if (compressedSize > 0 && totalUncompressedSize > 0) {
        final compressionRatio = totalUncompressedSize / compressedSize;
        if (compressionRatio > 100) {
          // Compression ratio over 100:1 is suspicious (possible zip bomb)
          return FileValidationResult.error(
            'Archive has suspicious compression ratio (possible zip bomb)',
          );
        }
      }

      if (totalUncompressedSize > maxArchiveUncompressedSize) {
        final sizeMB = (totalUncompressedSize / (1024 * 1024)).toStringAsFixed(
          2,
        );
        final maxMB = (maxArchiveUncompressedSize / (1024 * 1024))
            .toStringAsFixed(0);
        return FileValidationResult.error(
          'Archive uncompressed size is too large ($sizeMB MB). Maximum is $maxMB MB.',
        );
      }

      return FileValidationResult.success(
        fileSizeBytes: bytes.length,
        mimeType: 'application/zip',
      );
    } catch (e) {
      return FileValidationResult.error(
        'Failed to validate archive: ${e.toString()}',
      );
    }
  }

  /// Maximum image file size in bytes (20MB — images are compressed before upload,
  /// but we still reject absurdly large files to prevent DoS).
  static const int maxImageFileSizeBytes = 20 * 1024 * 1024;

  /// Validates image bytes by checking magic bytes and size.
  ///
  /// Unlike [validateFile], this works on raw bytes (no file path needed)
  /// so it supports both native and web platforms.
  ///
  /// Checks:
  /// - File size is within [maxImageFileSizeBytes]
  /// - Magic bytes match a known image format (JPEG, PNG, GIF, BMP, WebP, TIFF)
  static FileValidationResult validateImageBytes(
    Uint8List bytes,
    String fileName,
  ) {
    // Check size
    if (bytes.length > maxImageFileSizeBytes) {
      final sizeMB = (bytes.length / (1024 * 1024)).toStringAsFixed(2);
      final maxMB = (maxImageFileSizeBytes / (1024 * 1024)).toStringAsFixed(0);
      return FileValidationResult.error(
        'Image is too large ($sizeMB MB). Maximum size is $maxMB MB.',
      );
    }

    // Check magic bytes
    final detectedMime = _detectImageMimeFromBytes(bytes);
    if (detectedMime == null) {
      return FileValidationResult.error(
        'File "$fileName" does not appear to be a valid image.',
      );
    }

    return FileValidationResult.success(
      fileSizeBytes: bytes.length,
      mimeType: detectedMime,
    );
  }

  /// Detects image MIME type from raw bytes using magic byte signatures.
  /// Returns null if the bytes don't match any known image format.
  static String? _detectImageMimeFromBytes(Uint8List bytes) {
    if (bytes.length < 4) return null;

    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }

    // PNG: 89 50 4E 47
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }

    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'image/gif';
    }

    // WebP: 52 49 46 46 ... 57 45 42 50
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }

    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'image/bmp';
    }

    // TIFF: 49 49 2A 00 (little-endian) or 4D 4D 00 2A (big-endian)
    if (bytes.length >= 4 &&
        ((bytes[0] == 0x49 &&
                bytes[1] == 0x49 &&
                bytes[2] == 0x2A &&
                bytes[3] == 0x00) ||
            (bytes[0] == 0x4D &&
                bytes[1] == 0x4D &&
                bytes[2] == 0x00 &&
                bytes[3] == 0x2A))) {
      return 'image/tiff';
    }

    return null;
  }

  /// Formats file size in human-readable format.
  static String formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
  }
}
