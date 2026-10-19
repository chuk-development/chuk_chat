import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/multiplex_tool_proxy.dart';

/// Shared helper: send a multipart POST to an image generation endpoint
/// and return the IMAGE: result string. When a multiplex chat session
/// is open the request is forwarded over /v2/ws instead — same payload,
/// no HTTP round-trip.
Future<String> _generateImageRequest({
  required String? serverHttpUrl,
  required String? accessToken,
  required String endpoint,
  required Map<String, String> fields,
  required String muxTool,
  required String modelName,
}) async {
  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.trim().isEmpty) {
    return 'Error: Not connected to server';
  }

  try {
    Map<String, dynamic>? data;
    final mux = await tryToolViaMultiplex(
      tool: muxTool,
      payload: Map<String, dynamic>.from(fields),
    );
    if (mux.isError) {
      return 'Image generation error: ${mux.error}';
    }
    if (mux.isOk) {
      data = mux.body;
    } else {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl$endpoint'),
      )..fields.addAll(fields);

      if (accessToken != null && accessToken.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $accessToken';
      }

      final streamed =
          await request.send().timeout(const Duration(seconds: 120));
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode != 200) {
        try {
          final errBody = jsonDecode(response.body) as Map<String, dynamic>;
          final detail = errBody['detail'] ?? errBody['error'] ?? 'Unknown error';
          return 'Image generation error: $detail';
        } catch (_) {
          return 'Image generation error: HTTP ${response.statusCode}';
        }
      }

      data = jsonDecode(response.body) as Map<String, dynamic>;
    }
    if (data == null) {
      return 'Image generation error: empty response';
    }

    final imageUrl = (data['image_url'] as String? ?? '').trim();
    if (imageUrl.isEmpty) {
      return 'Image generation error: no image URL returned';
    }

    final billing = data['billing'] as Map<String, dynamic>?;
    final result = {
      'url': imageUrl,
      'width': data['width'],
      'height': data['height'],
      'seed': data['seed'],
      'prompt': data['prompt'] ?? fields['prompt'],
      'image_size': fields['image_size'],
      'model': modelName,
      if (data['source_url'] != null) 'source_url': data['source_url'],
      if (billing != null) ...{
        'cost_eur': billing['cost_eur'],
        'megapixels': billing['megapixels'],
      },
    };
    return 'IMAGE:${jsonEncode(result)}';
  } catch (error) {
    return 'Image generation failed: $error';
  }
}

/// Human-readable display names per generator key. Adding a model = one entry
/// here (and the matching server registry entry). The single `generate_image`
/// tool routes everything through `/v1/ai/image/generate` (mux: image_generate).
/// The server runs every model on OpenRouter with Zero Data Retention.
const Map<String, String> imageModelDisplayNames = {
  'krea': 'Krea 2 Large',
  'turbo': 'Krea 2 Medium Turbo',
  'hunyuan': 'Hunyuan Image 3.5',
  'seedream': 'Seedream 5 Lite',
  'edit': 'Krea K3 Edit',
};

/// Default generator key when the model omits or blanks `model`.
const String defaultImageModel = 'krea';

/// Old generator keys that map onto the current lineup. The server accepts
/// them too; the client folds them here so the display name is current.
const Map<String, String> legacyImageModelAliases = {
  'quality': 'krea',
  'flux': 'krea',
  'ideogram': 'seedream',
  'k3': 'edit',
};

/// Normalises a generator key: trims, lower-cases, maps legacy aliases and
/// falls back to [defaultImageModel] for an empty value. Unknown keys are
/// returned unchanged so the caller can report them.
String normalizeImageModel(String? raw) {
  final key = (raw ?? '').trim().toLowerCase();
  if (key.isEmpty) return defaultImageModel;
  return legacyImageModelAliases[key] ?? key;
}

/// Single image generation/editing tool. `args['model']` selects the
/// generator; only the params relevant to that model are forwarded.
Future<String> executeGenerateImage({
  required String? serverHttpUrl,
  required String? accessToken,
  required Map<String, dynamic> args,
}) async {
  final model = normalizeImageModel(args['model'] as String?);
  final modelName = imageModelDisplayNames[model];
  if (modelName == null) {
    return 'Error: unknown image model "$model". '
        'Valid: ${imageModelDisplayNames.keys.join(', ')}.';
  }

  final prompt = (args['prompt'] as String? ?? '').trim();
  if (prompt.isEmpty) {
    return 'Error: "prompt" parameter required';
  }

  final fields = <String, String>{'model': model, 'prompt': prompt};

  final imageUrl = (args['image_url'] as String? ?? '').trim();
  if (model == 'edit') {
    if (imageUrl.isEmpty) {
      return 'Error: "image_url" parameter required for model "edit" — '
          'provide the URL of the image to edit (up to 8 URLs, one per line)';
    }
    fields['image_url'] = imageUrl;
    fields['image_size'] = (args['image_size'] as String? ?? 'auto').trim();
  } else {
    // aspect_ratio overrides the image_size preset.
    final aspectRatio = (args['aspect_ratio'] as String?)?.trim();
    if (aspectRatio != null && aspectRatio.isNotEmpty) {
      fields['aspect_ratio'] = aspectRatio;
    } else {
      fields['image_size'] =
          (args['image_size'] as String? ?? 'landscape_4_3').trim();
    }
  }

  return _generateImageRequest(
    serverHttpUrl: serverHttpUrl,
    accessToken: accessToken,
    endpoint: '/v1/ai/image/generate',
    muxTool: 'image_generate',
    modelName: modelName,
    fields: fields,
  );
}

Future<String> executeFetchImage(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final url = (args['url'] as String? ?? '').trim();
  if (url.isEmpty) {
    return 'Error: "url" parameter required';
  }

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final response = await effectiveClient
        .get(
          Uri.parse(url),
          headers: const {
            'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)',
            'Accept': 'image/*,*/*;q=0.8',
          },
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      return 'Error: Failed to fetch image (HTTP ${response.statusCode})';
    }

    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      return 'Error: Image data is empty';
    }

    if (bytes.length > 4 * 1024 * 1024) {
      return 'Error: Image too large '
          '(${(bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB, max 4 MB)';
    }

    final contentType = response.headers['content-type'] ?? '';
    final mimeType = _detectMimeType(contentType: contentType, url: url);
    final dataUri = 'data:$mimeType;base64,${base64Encode(bytes)}';

    return 'IMAGE_DATA:${jsonEncode({'data_uri': dataUri, 'url': url, 'mime_type': mimeType, 'size_bytes': bytes.length})}';
  } catch (error) {
    return 'Error: Failed to fetch image: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}

String executeViewChatImagesUnsupported() {
  return 'Error: view_chat_images is not available in this build yet.';
}

String _detectMimeType({required String contentType, required String url}) {
  if (contentType.contains('image/')) {
    return contentType.split(';').first.trim();
  }

  final normalizedUrl = url.toLowerCase().split('?').first;
  if (normalizedUrl.endsWith('.png')) {
    return 'image/png';
  }
  if (normalizedUrl.endsWith('.gif')) {
    return 'image/gif';
  }
  if (normalizedUrl.endsWith('.webp')) {
    return 'image/webp';
  }
  if (normalizedUrl.endsWith('.svg')) {
    return 'image/svg+xml';
  }
  return 'image/jpeg';
}
