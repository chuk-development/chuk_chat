import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class ToolImageUpdateResult {
  const ToolImageUpdateResult({
    required this.toolCalls,
    required this.imagePaths,
    required this.imageMetas,
    this.imageCostEur,
    this.imageGeneratedAt,
  });

  final List<ToolCall> toolCalls;
  final List<String> imagePaths;

  /// Per-image metadata aligned with [imagePaths]. Each entry:
  /// `{"source": "generated"|"fetched", "caption": "...", "model": "..."}`
  /// (caption and model optional; model is only set for generated images).
  final List<Map<String, dynamic>> imageMetas;
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

  /// Source (URL or data hash) -> storage path, for sources already stored in
  /// this session.
  ///
  /// The same tool call is handed to the image step more than once: once when
  /// its pass ends, once when the whole turn ends, and the two carry separate
  /// clones of the payload. Without this the bytes were fetched and uploaded
  /// twice, which put the same picture in the library twice — and with the
  /// API's one-shot image links the second fetch is a 404, not a duplicate.
  static final Map<String, String> _storedSources = <String, String>{};

  /// Keeps [_storedSources] from growing for the life of the process.
  static const int _storedSourcesLimit = 128;

  static Future<ToolImageUpdateResult> processToolCalls(
    List<ToolCall> toolCalls,
  ) async {
    final imagePaths = <String>[];
    final imageMetas = <Map<String, dynamic>>[];
    final seenPaths = <String>{};

    String? latestImageCostEur;
    String? latestGeneratedAt;

    void addImage(
      String path, {
      required String source,
      String? caption,
      String? model,
    }) {
      if (!seenPaths.add(path)) {
        return;
      }
      imagePaths.add(path);
      final meta = <String, dynamic>{'source': source};
      final trimmedCaption = caption?.trim();
      if (trimmedCaption != null && trimmedCaption.isNotEmpty) {
        meta['caption'] = trimmedCaption;
      }
      final trimmedModel = model?.trim();
      if (trimmedModel != null && trimmedModel.isNotEmpty) {
        meta['model'] = trimmedModel;
      }
      imageMetas.add(meta);
    }

    for (final call in toolCalls) {
      final rawResult = call.result;
      if (rawResult == null || rawResult.isEmpty) {
        continue;
      }

      final caption = _nonEmptyString(call.arguments['caption']);

      if (rawResult.startsWith('IMAGE:')) {
        final payload = _tryDecodeMap(rawResult.substring(6));
        if (payload == null) {
          continue;
        }

        final extracted = await _ensureStoragePath(payload);
        final normalizedPayload = extracted.updatedPayload ?? payload;
        call.result = 'IMAGE:${jsonEncode(normalizedPayload)}';

        final storagePath = extracted.storagePath;
        if (storagePath != null) {
          addImage(
            storagePath,
            source: 'generated',
            caption: caption ?? _nonEmptyString(payload['caption']),
            model: _nonEmptyString(payload['model']),
          );
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
        final normalizedPayload = extracted.updatedPayload ?? payload;
        call.result = 'IMAGE_DATA:${jsonEncode(normalizedPayload)}';

        final storagePath = extracted.storagePath;
        if (storagePath != null) {
          addImage(
            storagePath,
            source: 'fetched',
            caption: caption ?? _nonEmptyString(payload['caption']),
          );
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
      imageMetas: imageMetas,
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

      // Upload failed. The bytes are in hand and the API's image links are
      // one-shot, so dropping them here loses the picture for good — the
      // data URI rides along in the message instead. Only while it is small:
      // a multi-megabyte URI is carried by every load of that chat.
      if (dataUri.length <= 2 * 1024 * 1024) {
        return _ExtractionResult(storagePath: dataUri, updatedPayload: null);
      }
      return const _ExtractionResult(storagePath: null, updatedPayload: null);
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

        return await ImageStorageService.uploadEncryptedImage(
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
            .get(uri, headers: _downloadHeaders(uri))
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

        return await ImageStorageService.uploadEncryptedImage(bytes);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Failed to upload tool image from URL ($url): $error');
        }
        return null;
      }
    });
  }

  /// The signed-in user, or null before the client exists (tests, and the
  /// window before `initialize()` completes).
  static String? _currentUserId() => SupabaseService.isInitialized
      ? SupabaseService.auth.currentUser?.id
      : null;

  /// The headers one image download carries.
  ///
  /// The API hands out one-shot vault links for generated images: the bytes
  /// are served once, bound to the user who paid for them, and the entry is
  /// dropped in the same breath. Those need the session token — and only
  /// those: the header never travels to a third-party host.
  static Map<String, String> _downloadHeaders(Uri uri) {
    final headers = <String, String>{
      'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)',
      'Accept': 'image/*,*/*;q=0.8',
    };
    final Uri api = Uri.parse(ApiConfigService.apiBaseUrl);
    final bool sameOrigin =
        uri.scheme == api.scheme && uri.host == api.host && uri.port == api.port;
    if (!sameOrigin) return headers;
    final String? token = SupabaseService.isInitialized
        ? SupabaseService.auth.currentSession?.accessToken
        : null;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static Future<String?> _cacheUpload(
    String rawSourceKey,
    Future<String?> Function() upload,
  ) {
    // Stored paths start with the user id, so a cache shared across an
    // account switch would hand the new user the previous user's path.
    final String sourceKey = '${_currentUserId() ?? "anon"}|$rawSourceKey';
    final stored = _storedSources[sourceKey];
    if (stored != null) {
      return Future<String?>.value(stored);
    }

    final existing = _inFlightUploads[sourceKey];
    if (existing != null) {
      return existing;
    }

    final future = upload();
    _inFlightUploads[sourceKey] = future;
    unawaited(
      future
          .then((path) {
            if (path == null) return;
            if (_storedSources.length >= _storedSourcesLimit) {
              _storedSources.remove(_storedSources.keys.first);
            }
            _storedSources[sourceKey] = path;
          })
          .catchError((_) {}),
    );
    future.whenComplete(() => _inFlightUploads.remove(sourceKey));
    return future;
  }

  static Map<String, dynamic>? _tryDecodeMap(String jsonString) {
    final trimmed = jsonString.trim();

    final direct = _decodeMap(trimmed);
    if (direct != null) {
      return direct;
    }

    final firstLineIndex = trimmed.indexOf('\n');
    if (firstLineIndex > 0) {
      final firstLine = trimmed.substring(0, firstLineIndex).trim();
      final firstLineDecoded = _decodeMap(firstLine);
      if (firstLineDecoded != null) {
        return firstLineDecoded;
      }
    }

    final extracted = _extractLeadingJsonObject(trimmed);
    if (extracted != null) {
      return _decodeMap(extracted);
    }

    return null;
  }

  static Map<String, dynamic>? _decodeMap(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? _extractLeadingJsonObject(String text) {
    final start = text.indexOf('{');
    if (start < 0) {
      return null;
    }

    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = start; i < text.length; i++) {
      final char = text[i];

      if (inString) {
        if (escaped) {
          escaped = false;
          continue;
        }
        if (char == r'\') {
          escaped = true;
          continue;
        }
        if (char == '"') {
          inString = false;
        }
        continue;
      }

      if (char == '"') {
        inString = true;
        continue;
      }

      if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) {
          return text.substring(start, i + 1);
        }
      }
    }

    return null;
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
