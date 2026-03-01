import 'dart:convert';

import 'package:http/http.dart' as http;

Future<String> executeGenerateImage({
  required String? serverHttpUrl,
  required String? accessToken,
  required Map<String, dynamic> args,
}) async {
  final prompt = (args['prompt'] as String? ?? '').trim();
  if (prompt.isEmpty) {
    return 'Error: "prompt" parameter required';
  }

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.trim().isEmpty) {
    return 'Error: Not connected to server';
  }

  final imageSize = (args['image_size'] as String? ?? 'landscape_4_3').trim();

  try {
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/v1/ai/generate-image'),
          )
          ..fields['prompt'] = prompt
          ..fields['image_size'] = imageSize;

    if (accessToken != null && accessToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }

    final streamed = await request.send().timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode != 200) {
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final detail = data['detail'] ?? data['error'] ?? 'Unknown error';
        return 'Image generation error: $detail';
      } catch (_) {
        return 'Image generation error: HTTP ${response.statusCode}';
      }
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
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
      'prompt': data['prompt'] ?? prompt,
      'image_size': imageSize,
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

Future<String> executeEditImage({
  required String? serverHttpUrl,
  required String? accessToken,
  required Map<String, dynamic> args,
}) async {
  final prompt = (args['prompt'] as String? ?? '').trim();
  if (prompt.isEmpty) {
    return 'Error: "prompt" parameter required';
  }

  final imageUrl = (args['image_url'] as String? ?? '').trim();
  if (imageUrl.isEmpty) {
    return 'Error: "image_url" parameter required – provide the URL of '
        'an image to edit';
  }

  final baseUrl = serverHttpUrl;
  if (baseUrl == null || baseUrl.trim().isEmpty) {
    return 'Error: Not connected to server';
  }

  final imageSize = (args['image_size'] as String? ?? 'auto').trim();

  try {
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/v1/ai/edit-image'))
          ..fields['prompt'] = prompt
          ..fields['image_url'] = imageUrl
          ..fields['image_size'] = imageSize;

    if (accessToken != null && accessToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }

    final streamed = await request.send().timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode != 200) {
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final detail = data['detail'] ?? data['error'] ?? 'Unknown error';
        return 'Image edit error: $detail';
      } catch (_) {
        return 'Image edit error: HTTP ${response.statusCode}';
      }
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final resultUrl = (data['image_url'] as String? ?? '').trim();
    if (resultUrl.isEmpty) {
      return 'Image edit error: no image URL returned';
    }

    final billing = data['billing'] as Map<String, dynamic>?;
    final result = {
      'url': resultUrl,
      'width': data['width'],
      'height': data['height'],
      'seed': data['seed'],
      'prompt': data['prompt'] ?? prompt,
      'source_url': imageUrl,
      if (billing != null) ...{
        'cost_eur': billing['cost_eur'],
        'megapixels': billing['megapixels'],
      },
    };
    return 'IMAGE:${jsonEncode(result)}';
  } catch (error) {
    return 'Image edit failed: $error';
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
