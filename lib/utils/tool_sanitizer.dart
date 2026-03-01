import 'dart:convert';

/// Strip large binary/base64 data from tool results before sending to the
/// model's text context. Images are only sent via the vision input when
/// the model explicitly calls view_chat_images.
String sanitizeResultForModel(String result) {
  // Fetched images — strip the base64 data_uri, return clean metadata
  if (result.startsWith('IMAGE_DATA:')) {
    try {
      final json = result.substring(11);
      final data = jsonDecode(json) as Map<String, dynamic>;
      data.remove('data_uri');
      final url = data['url'] ?? 'unknown';
      final mime = data['mime_type'] ?? 'unknown';
      final size = data['size_bytes'] ?? 'unknown';
      return 'Image fetched successfully.\n'
          'URL: $url\n'
          'Type: $mime\n'
          'Size: $size bytes\n'
          'Use this data only when the user asks for image analysis.';
    } catch (_) {
      return 'Image fetched successfully.';
    }
  }

  // Generated images — strip the internal IMAGE: prefix and return clean
  // metadata.
  if (result.startsWith('IMAGE:')) {
    try {
      final json = result.substring(6);
      final data = jsonDecode(json) as Map<String, dynamic>;
      final url = data['url'] ?? '';
      final width = data['width'] ?? '';
      final height = data['height'] ?? '';
      final model = data['model'] ?? '';
      final prompt = data['prompt'] ?? '';
      final seed = data['seed'] ?? '';
      return 'Image generated successfully.\n'
          'URL: $url\n'
          'Size: ${width}x$height\n'
          'Model: $model\n'
          'Seed: $seed\n'
          'Prompt: $prompt\n'
          'Share the URL directly with the user.';
    } catch (_) {
      return 'Image generated successfully.';
    }
  }

  return result;
}
