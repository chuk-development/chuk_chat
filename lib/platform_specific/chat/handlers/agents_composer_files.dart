// lib/platform_specific/chat/handlers/agents_composer_files.dart
//
// The composer's rules for a file attached in an Agents thread
// (docs/WIRE_CONTRACT.md, "Attachments to Agents"): any type, up to 25 MiB,
// at most 10 per message. A picture goes the chat's own way (compressed and
// encrypted); every other file is sealed on this device
// (AgentsAttachmentStore) instead of being turned into Markdown, and is
// uploaded to the host when the message goes out.

import 'dart:typed_data';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/agents/agents_attachment_store.dart';
import 'package:chuk_chat/services/agents/agents_attachments.dart';

class AgentsComposerFiles {
  AgentsComposerFiles._();

  /// Why [fileName] cannot be attached, or null when it can. [attached] is
  /// what the composer already holds.
  static String? refusal({
    required String fileName,
    required int sizeBytes,
    required List<AttachedFile> attached,
  }) {
    if (attached.length >= kAgentsAttachmentMaxFiles) {
      return 'At most $kAgentsAttachmentMaxFiles files per message.';
    }
    if (sizeBytes > kAgentsAttachmentMaxBytes) {
      return '"$fileName" is larger than 25 MB.';
    }
    if (sizeBytes <= 0) return '"$fileName" is empty.';
    return null;
  }

  /// Seals [bytes] on this device and returns the ready attachment, with the
  /// store ref as its path.
  static Future<AttachedFile> keep({
    required String id,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final String ref = await AgentsAttachmentStore.put(bytes, name: fileName);
    return AttachedFile(
      id: id,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      encryptedImagePath: ref,
    );
  }

  /// Removes a file the user took off the composer before sending.
  static Future<void> discard(String? path) async {
    if (AgentsAttachmentStore.isRef(path) && path != null) {
      await AgentsAttachmentStore.delete(path);
    }
  }
}
