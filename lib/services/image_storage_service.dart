// lib/services/image_storage_service.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_compression_service.dart';
import 'package:uuid/uuid.dart';

/// Represents a stored image with metadata
class StoredImage {
  final String path;
  final String name;
  final DateTime? createdAt;
  final int? size;

  const StoredImage({
    required this.path,
    required this.name,
    this.createdAt,
    this.size,
  });
}

/// Represents a chat that uses a specific image
class ChatUsingImage {
  final String chatId;
  final String chatName;

  const ChatUsingImage({
    required this.chatId,
    required this.chatName,
  });
}

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
    final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));

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

      // Convert bytes to string (JSON format) - use UTF-8 decoding
      final encryptedJson = utf8.decode(encryptedBytes);

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

  /// Lists all images stored by the current user
  /// Returns a list of StoredImage objects with metadata
  static Future<List<StoredImage>> listUserImages() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to list images');
    }

    try {
      final List<FileObject> files = await SupabaseService.client.storage
          .from(bucketName)
          .list(path: user.id);

      return files
          .where((file) => file.name.endsWith('.enc'))
          .map((file) => StoredImage(
                path: '${user.id}/${file.name}',
                name: file.name,
                createdAt: file.createdAt != null
                    ? DateTime.tryParse(file.createdAt!)
                    : null,
                size: file.metadata?['size'] as int?,
              ))
          .toList();
    } catch (e) {
      debugPrint('Failed to list user images: $e');
      throw Exception('Failed to list images: $e');
    }
  }

  /// Finds all chats that use a specific image
  /// Returns a list of ChatUsingImage with chat ID and name
  static Future<List<ChatUsingImage>> findChatsUsingImage(
      String storagePath) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated');
    }

    try {
      // Query encrypted_chats where image_paths contains this path
      // Using the PostgreSQL array contains operator
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, encrypted_payload')
          .eq('user_id', user.id)
          .contains('image_paths', [storagePath]);

      final List<ChatUsingImage> result = [];

      for (final row in rows) {
        final chatId = row['id'] as String;
        String chatName = 'Unnamed Chat';

        // Try to decrypt the payload to get the chat name
        final encryptedPayload = row['encrypted_payload'] as String?;
        if (encryptedPayload != null && EncryptionService.hasKey) {
          try {
            final decrypted =
                await EncryptionService.decrypt(encryptedPayload);
            final payload = jsonDecode(decrypted) as Map<String, dynamic>;
            chatName = payload['customName'] as String? ?? 'Unnamed Chat';

            // If no custom name, try to derive from first message
            if (chatName == 'Unnamed Chat') {
              final messages = payload['messages'] as List<dynamic>?;
              if (messages != null && messages.isNotEmpty) {
                final firstUserMsg = messages.firstWhere(
                  (m) => m['role'] == 'user',
                  orElse: () => null,
                );
                if (firstUserMsg != null) {
                  final text = firstUserMsg['text'] as String? ?? '';
                  chatName = text.length > 30
                      ? '${text.substring(0, 30)}...'
                      : text;
                }
              }
            }
          } catch (e) {
            debugPrint('Failed to decrypt chat name: $e');
          }
        }

        result.add(ChatUsingImage(chatId: chatId, chatName: chatName));
      }

      return result;
    } catch (e) {
      debugPrint('Failed to find chats using image: $e');
      throw Exception('Failed to find chats using image: $e');
    }
  }

  /// Checks if an image exists in storage
  static Future<bool> imageExists(String storagePath) async {
    try {
      await SupabaseService.client.storage.from(bucketName).download(storagePath);
      return true;
    } catch (e) {
      return false;
    }
  }
}
