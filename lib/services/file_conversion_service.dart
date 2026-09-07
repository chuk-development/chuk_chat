// COWORK STUB. Upstream: chuk_chat/lib/services/file_conversion_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — upstream POSTs the file to the hosted converter and
// gets markdown back. In CoWork the host reads files itself, so the client
// never converts one. Both entry points return the upstream failure shape.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:typed_data';

class FileConversionService {
  static const int maxTokensPerFile = 40000;
  static const int maxCharsPerFile = 160000;

  static const Map<String, dynamic> _unavailable = <String, dynamic>{
    'success': false,
    'error': 'File conversion runs on the CoWork host, not on the client.',
    'markdown': null,
  };

  static List<String>? extractPageImages(dynamic responseData) => null;

  static Future<Map<String, dynamic>> convertFile({
    required String filePath,
    required String accessToken,
    String? userId,
  }) async => Map<String, dynamic>.from(_unavailable);

  static Future<Map<String, dynamic>> convertFileFromBytes({
    required Uint8List bytes,
    required String fileName,
    required String accessToken,
  }) async => Map<String, dynamic>.from(_unavailable);

  static bool isExtensionSupported(String extension) => false;

  static String getFileCategory(String extension) => 'document';
}
