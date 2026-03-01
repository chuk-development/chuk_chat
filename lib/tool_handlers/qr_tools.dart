import 'dart:convert';

import 'package:http/http.dart' as http;

Future<String> executeGenerateQr(
  Map<String, dynamic> args, {
  http.Client? client,
}) async {
  final data = (args['data'] as String? ?? '').trim();
  if (data.isEmpty) {
    return 'Error: "data" parameter required';
  }

  final requestedSize = (args['size'] as num?)?.toInt() ?? 400;
  final size = requestedSize.clamp(100, 1000);

  final effectiveClient = client ?? http.Client();
  final shouldCloseClient = client == null;

  try {
    final uri = Uri.parse(
      'https://api.qrserver.com/v1/create-qr-code/'
      '?size=${size}x$size'
      '&data=${Uri.encodeComponent(data)}'
      '&format=png'
      '&margin=10',
    );

    final response = await effectiveClient
        .get(uri, headers: const {'Accept': 'image/png'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      return 'Error: QR API returned ${response.statusCode}';
    }

    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      return 'Error: QR code image is empty';
    }

    final result = {
      'data_uri': 'data:image/png;base64,${base64Encode(bytes)}',
      'source_url': uri.toString(),
      'mime_type': 'image/png',
      'size_bytes': bytes.length,
    };

    return 'IMAGE_DATA:${jsonEncode(result)}\n\n'
        'QR code generated for: $data\n'
        'Size: ${size}x$size pixels';
  } catch (error) {
    return 'Error generating QR code: $error';
  } finally {
    if (shouldCloseClient) {
      effectiveClient.close();
    }
  }
}
