// lib/services/image_compression_service.dart
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Top-level function for background image compression
/// This function runs in a separate isolate to avoid blocking the UI
Future<Uint8List> _compressImageInBackground(_CompressionParams params) async {
  final imageBytes = params.imageBytes;

  // Decode the image
  img.Image? image = img.decodeImage(imageBytes);
  if (image == null) {
    throw Exception('Failed to decode image. The file may be corrupted.');
  }

  // Check decoded dimensions to prevent decompression bombs
  // (e.g. a tiny PNG that decompresses to 100000x100000 pixels)
  if (image.width > 10000 || image.height > 10000) {
    throw Exception(
      'Image dimensions too large (${image.width}x${image.height}). '
      'Maximum is 10000x10000 pixels.',
    );
  }

  // Start with max 1920x1920
  int currentMaxDimension = params.maxDimension;

  // Try compression with different quality levels and sizes
  for (int quality = params.initialQuality; quality >= params.minQuality; quality -= 10) {
    // Resize if needed (maintaining aspect ratio)
    img.Image resizedImage = image;
    if (image.width > currentMaxDimension ||
        image.height > currentMaxDimension) {
      resizedImage = img.copyResize(
        image,
        width: image.width > image.height ? currentMaxDimension : null,
        height: image.height > image.width ? currentMaxDimension : null,
        interpolation: img.Interpolation.linear,
      );
    }

    // Encode to JPEG
    List<int> compressedBytes;
    try {
      compressedBytes = img.encodeJpg(resizedImage, quality: quality);
    } catch (e) {
      throw Exception('Failed to encode image to JPEG: $e');
    }

    // If under target size, we're done
    if (compressedBytes.length <= params.targetFileSizeBytes) {
      return Uint8List.fromList(compressedBytes);
    }

    // If at minimum quality, try reducing dimensions
    if (quality <= params.minQuality && currentMaxDimension > 1280) {
      currentMaxDimension = (currentMaxDimension * 0.7)
          .round(); // Reduce by 30%
      quality = params.initialQuality; // Reset quality for new dimension
    }
  }

  // Continue reducing dimensions if still too large
  while (currentMaxDimension > 640) {
    currentMaxDimension = (currentMaxDimension * 0.7).round();

    final smallerImage = img.copyResize(
      image,
      width: image.width > image.height ? currentMaxDimension : null,
      height: image.height > image.width ? currentMaxDimension : null,
      interpolation: img.Interpolation.linear,
    );

    final compressedBytes = img.encodeJpg(smallerImage, quality: params.minQuality);

    if (compressedBytes.length <= params.targetFileSizeBytes) {
      return Uint8List.fromList(compressedBytes);
    }
  }

  // Final fallback: 640px at minimum quality
  final smallImage = img.copyResize(
    image,
    width: image.width > image.height ? 640 : null,
    height: image.height > image.width ? 640 : null,
    interpolation: img.Interpolation.linear,
  );
  final finalBytes = img.encodeJpg(smallImage, quality: params.minQuality);
  return Uint8List.fromList(finalBytes);
}

/// Parameters for background image compression
class _CompressionParams {
  final Uint8List imageBytes;
  final int maxDimension;
  final int targetFileSizeBytes;
  final int initialQuality;
  final int minQuality;

  _CompressionParams({
    required this.imageBytes,
    required this.maxDimension,
    required this.targetFileSizeBytes,
    required this.initialQuality,
    required this.minQuality,
  });
}

/// Service for compressing images with no size limit
/// Images are compressed to JPEG format with aggressive optimization
class ImageCompressionService {
  const ImageCompressionService._();

  static const int maxDimension = 1920; // Higher initial resolution
  static const int targetFileSizeBytes = 2 * 1024 * 1024; // Target 2MB for optimal API performance
  static const int initialQuality = 85;
  static const int minQuality = 50;

  /// Maximum raw input size before decoding (50MB sanity check)
  static const int maxInputSizeBytes = 50 * 1024 * 1024;

  /// Maximum pixel dimension after decoding (prevents decompression bombs)
  static const int maxDecodedDimension = 10000;

  /// Compresses an image to JPEG format with aggressive optimization
  /// - Validates magic bytes to ensure the file is a real image
  /// - Rejects files over 50MB raw input size
  /// - Rejects decoded images over 10000x10000 pixels
  /// - Resizes to max 1920x1920 while maintaining aspect ratio
  /// - Converts to JPEG format with optimized quality
  /// - Automatically adjusts quality to achieve ~2MB target
  /// - Will reduce dimensions if needed for large images
  /// - No hard size limit - images are always compressed and sent
  /// - Runs in background isolate to prevent UI blocking
  static Future<Uint8List> compressImage(Uint8List imageBytes) async {
    // Check raw input size before attempting decode
    if (imageBytes.length > maxInputSizeBytes) {
      final sizeMB = (imageBytes.length / (1024 * 1024)).toStringAsFixed(1);
      throw Exception(
        'Image file is too large ($sizeMB MB). Maximum input size is 50 MB.',
      );
    }

    // Validate magic bytes — reject files that aren't real images
    final format = detectImageFormat(imageBytes);
    if (format == null) {
      throw Exception(
        'Invalid image file. The file does not match any supported image format '
        '(JPEG, PNG, GIF, BMP, WebP, TIFF).',
      );
    }

    final params = _CompressionParams(
      imageBytes: imageBytes,
      maxDimension: maxDimension,
      targetFileSizeBytes: targetFileSizeBytes,
      initialQuality: initialQuality,
      minQuality: minQuality,
    );

    // Run compression in background isolate to avoid blocking UI
    return await compute(_compressImageInBackground, params);
  }

  /// Detects image format by checking magic bytes.
  /// Returns the format name or null if not a recognized image.
  static String? detectImageFormat(Uint8List bytes) {
    if (bytes.length < 4) return null;

    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'jpeg';
    }

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'png';
    }

    // GIF: 47 49 46 38 (GIF87a or GIF89a)
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'gif';
    }

    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'bmp';
    }

    // WebP: 52 49 46 46 ... 57 45 42 50 (RIFF....WEBP)
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }

    // TIFF: 49 49 2A 00 (little-endian) or 4D 4D 00 2A (big-endian)
    if ((bytes[0] == 0x49 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x2A &&
            bytes[3] == 0x00) ||
        (bytes[0] == 0x4D &&
            bytes[1] == 0x4D &&
            bytes[2] == 0x00 &&
            bytes[3] == 0x2A)) {
      return 'tiff';
    }

    return null;
  }

  /// Gets the display size of the compressed image in MB
  static String getFileSizeMB(Uint8List bytes) {
    final sizeInMB = bytes.length / 1024 / 1024;
    return sizeInMB.toStringAsFixed(2);
  }
}
