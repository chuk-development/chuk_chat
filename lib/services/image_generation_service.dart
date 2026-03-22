// lib/services/image_generation_service.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Result of an image generation request
class ImageGenerationResult {
  const ImageGenerationResult({
    required this.success,
    this.imageUrl,
    this.encryptedPath,
    this.imageBytes,
    this.width,
    this.height,
    this.seed,
    this.costEur,
    this.errorMessage,
  });

  final bool success;
  final String? imageUrl; // Remote URL from API
  final String? encryptedPath; // Supabase storage path for encrypted image
  final Uint8List? imageBytes; // Image data for immediate display
  final int? width;
  final int? height;
  final int? seed;
  final double? costEur;
  final String? errorMessage;

  factory ImageGenerationResult.error(String message) {
    return ImageGenerationResult(success: false, errorMessage: message);
  }
}

/// Size presets matching the API server (used by turbo endpoint).
class ImageSizePresets {
  static const Map<String, Map<String, int>> presets = {
    'square_hd': {'width': 1024, 'height': 1024},
    'square': {'width': 512, 'height': 512},
    'portrait_4_3': {'width': 768, 'height': 1024},
    'portrait_16_9': {'width': 576, 'height': 1024},
    'landscape_4_3': {'width': 1024, 'height': 768},
    'landscape_16_9': {'width': 1024, 'height': 576},
  };

  static Map<String, int> getDimensions(String preset) {
    return presets[preset] ?? presets['landscape_4_3']!;
  }

  /// Estimate cost for z-image-turbo (tiered pricing by megapixels).
  /// Returns approximate cost rounded up to nearest cent.
  /// Actual cost comes from the server billing response.
  static double estimateTurboCost(int width, int height) {
    final megapixels = (width * height) / 1000000;
    final double cost;
    if (megapixels <= 0.5) {
      cost = 0.0025;
    } else if (megapixels <= 1) {
      cost = 0.005;
    } else if (megapixels <= 2) {
      cost = 0.01;
    } else if (megapixels <= 3) {
      cost = 0.015;
    } else {
      cost = 0.02;
    }
    return (cost * 100).ceil() / 100;
  }
}

/// Service for generating images via API.
///
/// Endpoints:
/// - `/v1/ai/image/turbo`   — Z-Image Turbo (fastest, cheapest)
/// - `/v1/ai/image/hunyuan` — Hunyuan Image 3 (high quality, $0.08/image)
/// - `/v1/ai/image/flux`    — FLUX 2 Klein 9B (best quality, $0.015/MP)
/// - `/v1/ai/image/edit`    — Qwen Image Edit Plus ($0.03/image)
class ImageGenerationService {
  const ImageGenerationService();

  /// Generate an image using Z-Image Turbo (fastest, cheapest).
  static Future<ImageGenerationResult> generateImage({
    required String prompt,
    String? sizePreset,
    int? customWidth,
    int? customHeight,
    bool storeEncrypted = true,
  }) async {
    final fields = <String, String>{'prompt': prompt};
    if (customWidth != null && customHeight != null) {
      fields['custom_width'] = customWidth.toString();
      fields['custom_height'] = customHeight.toString();
    } else {
      fields['image_size'] = sizePreset ?? 'landscape_4_3';
    }
    return _generate(
      endpoint: '/v1/ai/image/turbo',
      fields: fields,
      storeEncrypted: storeEncrypted,
    );
  }

  /// Generate an image using Hunyuan Image 3 (high quality, ~0.08 EUR).
  static Future<ImageGenerationResult> generateImageHunyuan({
    required String prompt,
    String? sizePreset,
    String? aspectRatio,
    bool storeEncrypted = true,
  }) async {
    final fields = <String, String>{'prompt': prompt};
    if (aspectRatio != null) {
      fields['aspect_ratio'] = aspectRatio;
    } else {
      fields['image_size'] = sizePreset ?? 'landscape_4_3';
    }
    return _generate(
      endpoint: '/v1/ai/image/hunyuan',
      fields: fields,
      storeEncrypted: storeEncrypted,
    );
  }

  /// Generate an image using FLUX 2 Klein 9B (best quality, ~0.02 EUR).
  static Future<ImageGenerationResult> generateImageFlux({
    required String prompt,
    String? sizePreset,
    String? aspectRatio,
    String? megapixels,
    bool storeEncrypted = true,
  }) async {
    final fields = <String, String>{'prompt': prompt};
    if (aspectRatio != null) {
      fields['aspect_ratio'] = aspectRatio;
    } else {
      fields['image_size'] = sizePreset ?? 'landscape_4_3';
    }
    if (megapixels != null) {
      fields['megapixels'] = megapixels;
    }
    return _generate(
      endpoint: '/v1/ai/image/flux',
      fields: fields,
      storeEncrypted: storeEncrypted,
    );
  }

  /// Shared generation logic for all image endpoints.
  static Future<ImageGenerationResult> _generate({
    required String endpoint,
    required Map<String, String> fields,
    bool storeEncrypted = true,
  }) async {
    try {
      // Get access token
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        return ImageGenerationResult.error('Not authenticated');
      }
      final accessToken = session.accessToken;

      // Build request
      final uri = Uri.parse(
        '${ApiConfigService.apiBaseUrl}$endpoint',
      );

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $accessToken';
      request.fields.addAll(fields);

      // Send request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 402) {
        // Payment required - insufficient credits
        final body = jsonDecode(response.body);
        return ImageGenerationResult.error(
          body['detail'] ?? 'Insufficient credits for image generation',
        );
      }

      if (response.statusCode != 200) {
        final body = jsonDecode(response.body);
        return ImageGenerationResult.error(
          body['detail'] ?? 'Image generation failed',
        );
      }

      final body = jsonDecode(response.body);

      if (body['success'] != true) {
        return ImageGenerationResult.error(
          body['detail'] ?? 'Image generation failed',
        );
      }

      final imageUrl = body['image_url'] as String?;
      final width = body['width'] as int?;
      final height = body['height'] as int?;
      final seed = body['seed'] as int?;
      final billing = body['billing'] as Map<String, dynamic>?;
      final costEur = (billing?['cost_eur'] as num?)?.toDouble();

      if (imageUrl == null) {
        return ImageGenerationResult.error('No image URL returned');
      }

      // Download and optionally encrypt/store the image
      String? encryptedPath;
      Uint8List? imageBytes;

      if (storeEncrypted) {
        try {
          // Download image
          final imageResponse = await http.get(Uri.parse(imageUrl));
          if (imageResponse.statusCode != 200) {
            if (kDebugMode) {
              debugPrint(
                'Failed to download generated image: ${imageResponse.statusCode}',
              );
            }
          } else {
            imageBytes = imageResponse.bodyBytes;

            // Encrypt and store
            final user = SupabaseService.auth.currentUser;
            if (user != null && imageBytes.isNotEmpty) {
              encryptedPath = await ImageStorageService.uploadEncryptedImage(
                imageBytes,
              );
              if (kDebugMode) {
                debugPrint('Stored generated image at: $encryptedPath');
              }
            }
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Error storing generated image: $e');
          }
          // Continue even if storage fails - we still have the URL
        }
      }

      return ImageGenerationResult(
        success: true,
        imageUrl: imageUrl,
        encryptedPath: encryptedPath,
        imageBytes: imageBytes,
        width: width,
        height: height,
        seed: seed,
        costEur: costEur,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Image generation error: $e');
      }
      return ImageGenerationResult.error('Image generation failed: $e');
    }
  }
}
