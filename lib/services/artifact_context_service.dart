// lib/services/artifact_context_service.dart

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';

class ArtifactContextService {
  const ArtifactContextService._();

  static const int _maxContextChars = 140000;

  /// Builds a system-prompt section with active artifacts for [chatId].
  ///
  /// Flushes any pending in-memory editor state (e.g. live excalidraw
  /// edits that are still inside the debounce window) so the AI sees the
  /// user's latest scene, not the last debounced snapshot.
  static Future<String?> buildArtifactsSystemMessage(String chatId) async {
    await ArtifactStorageService.flushPendingEdits();
    final artifacts = await ArtifactStorageService.loadArtifactsForChat(chatId);
    if (artifacts.isEmpty) {
      return null;
    }

    final buffer = StringBuffer();
    buffer.writeln('=== ACTIVE ARTIFACTS ===');
    buffer.writeln(
      'The following artifacts are part of the current chat state. '
      'Use artifact_manager to update them incrementally.',
    );
    buffer.writeln();

    var usedChars = buffer.length;
    var skipped = 0;

    for (final artifact in artifacts) {
      final header =
          '- id: ${artifact.id}, title: ${artifact.title}, '
          'type: ${artifact.type.value}, '
          'language: ${artifact.language ?? 'n/a'}, '
          'version: ${artifact.version}\n';

      final body =
          '<artifact id="${artifact.id}" type="${artifact.type.value}" '
          'version="${artifact.version}">\n'
          '${artifact.content}\n'
          '</artifact>\n\n';

      final nextSize = header.length + body.length;
      if (usedChars + nextSize > _maxContextChars) {
        skipped += 1;
        continue;
      }

      usedChars += nextSize;
      buffer.write(header);
      buffer.write(body);
    }

    if (skipped > 0) {
      buffer.writeln(
        'Note: $skipped artifact(s) excluded from prompt due to context limits.',
      );
    }

    return buffer.toString().trimRight();
  }
}
