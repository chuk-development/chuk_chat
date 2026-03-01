import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/image_storage_service.dart';

class ToolImageUpdateResult {
  const ToolImageUpdateResult({
    required this.toolCalls,
    required this.imagePaths,
    this.imageCostEur,
    this.imageGeneratedAt,
  });

  final List<ToolCall> toolCalls;
  final List<String> imagePaths;
  final String? imageCostEur;
  final String? imageGeneratedAt;
}

class _ExtractionResult {
  const _ExtractionResult({
    required this.storagePath,
    required this.updatedPayload,
  });

  final String? storagePath;
  final Map<String, dynamic>? updatedPayload;
}

class ToolImageResultService {
  const ToolImageResultService._();

  static final Map<String, Future<String?>> _inFlightUploads = {};

  static Future<ToolImageUpdateResult> processToolCalls(
    List<ToolCall> toolCalls,
  ) async {
    final imagePaths = <String>[];
    final seenPaths = <String>{};

    String? latestImageCostEur;
    String? latestGeneratedAt;

    for (final call in toolCalls) {
      final rawResult = call.result;
      if (rawResult == null || rawResult.isEmpty) {
        continue;
      }

      if (rawResult.startsWith('IMAGE:')) {
        final payload = _tryDecodeMap(rawResult.substring(6));
        if (payload == null) {
          continue;
        }

        final extracted = await _ensureStoragePath(payload);
        if (extracted.updatedPayload != null) {
          call.result = 'IMAGE:${jsonEncode(extracted.updatedPayload)}';
        }

        final storagePath = extracted.storagePath;
        if (storagePath != null && seenPaths.add(storagePath)) {
          imagePaths.add(storagePath);
        }

        final costEur = _coerceDouble(
          payload['cost_eur'] ?? payload['costEur'],
        );
        if (costEur != null) {
          latestImageCostEur = costEur.toStringAsFixed(2);
        }

        latestGeneratedAt ??= _coerceDateTimeIso(
          payload['generated_at'] ?? payload['generatedAt'],
        );
        latestGeneratedAt ??= DateTime.now().toUtc().toIso8601String();
        continue;
      }

      if (rawResult.startsWith('IMAGE_DATA:')) {
        final payload = _tryDecodeMap(rawResult.substring(11));
        if (payload == null) {
          continue;
        }

        final extracted = await _ensureStoragePath(payload);
        if (extracted.updatedPayload != null) {
          call.result = 'IMAGE_DATA:${jsonEncode(extracted.updatedPayload)}';
        }

        final storagePath = extracted.storagePath;
        if (storagePath != null && seenPaths.add(storagePath)) {
          imagePaths.add(storagePath);
        }

        latestGeneratedAt ??= _coerceDateTimeIso(
          payload['generated_at'] ?? payload['generatedAt'],
        );
        latestGeneratedAt ??= DateTime.now().toUtc().toIso8601String();
      }
    }

    return ToolImageUpdateResult(
      toolCalls: toolCalls,
      imagePaths: imagePaths,
      imageCostEur: latestImageCostEur,
      imageGeneratedAt: imagePaths.isNotEmpty ? latestGeneratedAt : null,
    );
  }

  static Future<_ExtractionResult> _ensureStoragePath(
    Map<String, dynamic> payload,
  ) async {
    final existingPath = _nonEmptyString(payload['storage_path']);
    if (existingPath != null) {
      return _ExtractionResult(storagePath: existingPath, updatedPayload: null);
    }

    final dataUri = _nonEmptyString(payload['data_uri']);
    if (dataUri != null) {
      final uploadedPath = await _uploadFromDataUri(dataUri);
      if (uploadedPath == null) {
        return const _ExtractionResult(storagePath: null, updatedPayload: null);
      }

      final updated = Map<String, dynamic>.from(payload)
        ..['storage_path'] = uploadedPath
        ..remove('data_uri');
      return _ExtractionResult(
        storagePath: uploadedPath,
        updatedPayload: updated,
      );
    }

    final url =
        _nonEmptyString(payload['url']) ??
        _nonEmptyString(payload['source_url']);
    if (url != null) {
      final uploadedPath = await _uploadFromUrl(url);
      if (uploadedPath == null) {
        return const _ExtractionResult(storagePath: null, updatedPayload: null);
      }

      final updated = Map<String, dynamic>.from(payload)
        ..['storage_path'] = uploadedPath;
      return _ExtractionResult(
        storagePath: uploadedPath,
        updatedPayload: updated,
      );
    }

    return const _ExtractionResult(storagePath: null, updatedPayload: null);
  }

  static Future<String?> _uploadFromDataUri(String dataUri) {
    final sourceKey = 'data:${dataUri.length}:${dataUri.hashCode}';
    return _cacheUpload(sourceKey, () async {
      try {
        final commaIndex = dataUri.indexOf(',');
        if (!dataUri.startsWith('data:') || commaIndex < 0) {
          return null;
        }

        final encoded = dataUri.substring(commaIndex + 1);
        final bytes = base64Decode(encoded);
        if (bytes.isEmpty) {
          return null;
        }

        if (bytes.length > 12 * 1024 * 1024) {
          if (kDebugMode) {
            debugPrint(
              'Skipping IMAGE_DATA upload: ${(bytes.length / (1024 * 1024)).toStringAsFixed(1)}MB',
            );
          }
          return null;
        }

        return ImageStorageService.uploadEncryptedImage(
          Uint8List.fromList(bytes),
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Failed to upload IMAGE_DATA payload: $error');
        }
        return null;
      }
    });
  }

  static Future<String?> _uploadFromUrl(String url) {
    final sourceKey = 'url:$url';
    return _cacheUpload(sourceKey, () async {
      try {
        final response = await http
            .get(
              Uri.parse(url),
              headers: const {
                'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)',
                'Accept': 'image/*,*/*;q=0.8',
              },
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          if (kDebugMode) {
            debugPrint(
              'Failed to download tool image URL ($url): HTTP ${response.statusCode}',
            );
          }
          return null;
        }

        final bytes = response.bodyBytes;
        if (bytes.isEmpty) {
          return null;
        }

        if (bytes.length > 12 * 1024 * 1024) {
          if (kDebugMode) {
            debugPrint(
              'Skipping tool image URL upload: ${(bytes.length / (1024 * 1024)).toStringAsFixed(1)}MB',
            );
          }
          return null;
        }

        return ImageStorageService.uploadEncryptedImage(bytes);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Failed to upload tool image from URL ($url): $error');
        }
        return null;
      }
    });
  }

  static Future<String?> _cacheUpload(
    String sourceKey,
    Future<String?> Function() upload,
  ) {
    final existing = _inFlightUploads[sourceKey];
    if (existing != null) {
      return existing;
    }

    final future = upload();
    _inFlightUploads[sourceKey] = future;
    future.whenComplete(() => _inFlightUploads.remove(sourceKey));
    return future;
  }

  static Map<String, dynamic>? _tryDecodeMap(String jsonString) {
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? _nonEmptyString(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static double? _coerceDouble(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString().trim());
  }

  static String? _coerceDateTimeIso(dynamic value) {
    if (value == null) {
      return null;
    }

    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) {
      return null;
    }
    return parsed.toUtc().toIso8601String();
  }
}
