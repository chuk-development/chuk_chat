// COWORK STUB. Upstream: chuk_chat/lib/services/pdf_attachment_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by cowork service — upstream stores encrypted PDFs in a
// Supabase bucket. CoWork keeps them LOCAL, in the same blob store as images:
// one file per blob under the app support directory, addressed as
// `cowork://blob/<id>`.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:typed_data';

import 'package:cowork/services/image_storage_service.dart';

class PdfAttachmentService {
  const PdfAttachmentService._();

  /// Kept for signature compatibility. Nothing is uploaded anywhere.
  static const String bucketName = 'images';

  static Uint8List? getCached(String path) => ImageStorageService.getCached(path);

  static void clearFromCache(String path) =>
      ImageStorageService.clearFromCache(path);

  static void clearCache() => ImageStorageService.clearCache();

  static Future<String> upload(Uint8List bytes) =>
      ImageStorageService.uploadEncryptedImage(bytes);

  static Future<Uint8List> download(String path, {bool bypassCache = false}) =>
      ImageStorageService.downloadAndDecryptImage(
        path,
        bypassCache: bypassCache,
      );

  static Future<void> delete(String path) =>
      ImageStorageService.deleteEncryptedImage(path);
}
