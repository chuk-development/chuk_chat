// lib/services/image_storage_service.dart
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_compression_service.dart';
import 'package:uuid/uuid.dart';

/// Service for storing and retrieving encrypted images in Supabase Storage
class ImageStorageService {
  const ImageStorageService._();

  static const String bucketName = 'images';
  static const Uuid _uuid = Uuid();

  /// Uploads an encrypted image to Supabase Storage
  /// Steps:
  /// 1. Compress image to JPEG (max 1920x1920, ~2MB target, no hard limit)
  /// 2. Encrypt the compressed image bytes
  /// 3. Upload encrypted data to storage bucket
  /// 4. Return the storage path
  static Future<String> uploadEncryptedImage(Uint8List imageBytes) async {
    // Ensure user is authenticated
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to upload images');
    }

    // Ensure encryption key is available
    if (!EncryptionService.hasKey) {
      throw Exception('Encryption key not available');
    }

    // Step 1: Compress image
    final compressedBytes = await ImageCompressionService.compressImage(
      imageBytes,
    );

    // Step 2: Encrypt the compressed image
    final encryptedJson = await EncryptionService.encryptBytes(compressedBytes);
    final encryptedBytes = Uint8List.fromList(encryptedJson.codeUnits);

    // Step 3: Generate unique filename
    final fileId = _uuid.v4();
    final fileName = '$fileId.enc'; // .enc extension for encrypted files

    // Step 4: Upload to Supabase Storage
    final path = '${user.id}/$fileName';

    try {
      await SupabaseService.client.storage
          .from(bucketName)
          .uploadBinary(
            path,
            encryptedBytes,
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: false,
            ),
          );

      // Return the storage path (not the public URL, since files are encrypted)
      return path;
    } catch (e) {
      throw Exception('Failed to upload encrypted image: $e');
    }
  }

  /// Downloads and decrypts an image from Supabase Storage
  /// Returns the decrypted image bytes
  static Future<Uint8List> downloadAndDecryptImage(String storagePath) async {
    // Ensure user is authenticated
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to download images');
    }

    // Ensure encryption key is available
    if (!EncryptionService.hasKey) {
      throw Exception('Encryption key not available');
    }

    try {
      // Download encrypted file
      final encryptedBytes = await SupabaseService.client.storage
          .from(bucketName)
          .download(storagePath);

      // Convert bytes to string (JSON format)
      final encryptedJson = String.fromCharCodes(encryptedBytes);

      // Decrypt the image
      final decryptedBytes = await EncryptionService.decryptBytes(
        encryptedJson,
      );

      return decryptedBytes;
    } catch (e) {
      throw Exception('Failed to download or decrypt image: $e');
    }
  }

  /// Deletes an encrypted image from Supabase Storage
  static Future<void> deleteEncryptedImage(String storagePath) async {
    try {
      await SupabaseService.client.storage.from(bucketName).remove([
        storagePath,
      ]);
    } catch (e) {
      throw Exception('Failed to delete encrypted image: $e');
    }
  }

  /// Gets the file size of a stored image
  static Future<int> getImageSize(String storagePath) async {
    try {
      final response = await SupabaseService.client.storage
          .from(bucketName)
          .download(storagePath);
      return response.length;
    } catch (e) {
      throw Exception('Failed to get image size: $e');
    }
  }
}
