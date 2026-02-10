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
    return ImageGenerationResult(
      success: false,
      errorMessage: message,
    );
  }
}

/// Size presets matching the API server
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

  /// Calculate cost in EUR for given dimensions
  static double calculateCostEur(int width, int height) {
    final megapixels = (width * height) / 1000000;
    final costUsd = megapixels * 0.005;
    // Round up to nearest cent
    return (costUsd * 100).ceil() / 100;
  }
}

/// Service for generating images via Z-Image Turbo API
class ImageGenerationService {
  const ImageGenerationService();

  /// Generate an image from a text prompt
  ///
  /// If [storeEncrypted] is true, the image will be downloaded, encrypted,
  /// and stored in Supabase storage. The [encryptedPath] will be returned
  /// in the result for chat message storage.
  static Future<ImageGenerationResult> generateImage({
    required String prompt,
    String? sizePreset,
    int? customWidth,
    int? customHeight,
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
      final uri = Uri.parse('${ApiConfigService.apiBaseUrl}/v1/ai/generate-image');

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $accessToken';

      // Add form fields
      request.fields['prompt'] = prompt;

      if (customWidth != null && customHeight != null) {
        request.fields['custom_width'] = customWidth.toString();
        request.fields['custom_height'] = customHeight.toString();
      } else {
        request.fields['image_size'] = sizePreset ?? 'landscape_4_3';
      }

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
            debugPrint('Failed to download generated image: ${imageResponse.statusCode}');
          } else {
            imageBytes = imageResponse.bodyBytes;

            // Encrypt and store
            final user = SupabaseService.auth.currentUser;
            if (user != null && imageBytes.isNotEmpty) {
              encryptedPath = await ImageStorageService.uploadEncryptedImage(imageBytes);
              debugPrint('Stored generated image at: $encryptedPath');
            }
          }
        } catch (e) {
          debugPrint('Error storing generated image: $e');
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
      debugPrint('Image generation error: $e');
      return ImageGenerationResult.error('Image generation failed: $e');
    }
  }
}
