import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
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

        latestGeneratedAt =
            _coerceDateTimeIso(
              payload['generated_at'] ?? payload['generatedAt'],
            ) ??
            latestGeneratedAt ??
            DateTime.now().toUtc().toIso8601String();
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
      if (uploadedPath != null) {
        final updated = Map<String, dynamic>.from(payload)
          ..['storage_path'] = uploadedPath
          ..remove('data_uri');
        return _ExtractionResult(
          storagePath: uploadedPath,
          updatedPayload: updated,
        );
      }

      // Upload failed — fall back to the data URI directly so the image
      // still renders in the message bubble without encrypted storage.
      return _ExtractionResult(storagePath: dataUri, updatedPayload: null);
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
    final commaIndex = dataUri.indexOf(',');
    if (!dataUri.startsWith('data:') || commaIndex < 0) {
      return Future.value(null);
    }
    final encoded = dataUri.substring(commaIndex + 1);
    final contentHash = sha256.convert(utf8.encode(encoded)).toString();
    final sourceKey = 'data:$contentHash';
    return _cacheUpload(sourceKey, () async {
      try {
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

  /// Returns true if the host is a private/internal address that should not
  /// be fetched (SSRF protection).
  static bool _isPrivateHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower == '::1') return true;
    // Cloud metadata endpoints
    if (lower == '169.254.169.254' || lower == 'metadata.google.internal') {
      return true;
    }
    // IPv4 private ranges
    final parts = lower.split('.');
    if (parts.length == 4) {
      final a = int.tryParse(parts[0]);
      final b = int.tryParse(parts[1]);
      if (a == 127) return true; // 127.0.0.0/8
      if (a == 10) return true; // 10.0.0.0/8
      if (a == 172 && b != null && b >= 16 && b <= 31) return true; // 172.16-31
      if (a == 192 && b == 168) return true; // 192.168.0.0/16
      if (a == 169 && b == 254) return true; // link-local
    }
    return false;
  }

  static Future<String?> _uploadFromUrl(String url) {
    // SSRF validation: only allow http(s) to public hosts.
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        !{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        _isPrivateHost(uri.host)) {
      if (kDebugMode) {
        debugPrint('Rejected URL with invalid or private host: $url');
      }
      return Future.value(null);
    }

    final sourceKey = 'url:$url';
    return _cacheUpload(sourceKey, () async {
      try {
        final response = await http
            .get(
              uri,
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
