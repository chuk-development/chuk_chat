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

  /// Compresses an image to JPEG format with aggressive optimization
  /// - Resizes to max 1920x1920 while maintaining aspect ratio
  /// - Converts to JPEG format with optimized quality
  /// - Automatically adjusts quality to achieve ~2MB target
  /// - Will reduce dimensions if needed for large images
  /// - No hard size limit - images are always compressed and sent
  /// - Runs in background isolate to prevent UI blocking
  static Future<Uint8List> compressImage(Uint8List imageBytes) async {
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

  /// Gets the display size of the compressed image in MB
  static String getFileSizeMB(Uint8List bytes) {
    final sizeInMB = bytes.length / 1024 / 1024;
    return sizeInMB.toStringAsFixed(2);
  }
}
