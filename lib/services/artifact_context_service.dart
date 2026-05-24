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
  ///
  /// Forces a refresh on the artifact load so the AI never sees a stale
  /// pre-flush body. The flushers themselves keep `_cacheByChatId` in sync
  /// when they succeed, but a swallowed flusher error or a partial flush
  /// would otherwise leak the previous version into the system message —
  /// silently dropping the user's edits on the next AI rewrite. Re-reading
  /// from Supabase here is the smallest fix that guarantees freshness.
  static Future<String?> buildArtifactsSystemMessage(String chatId) async {
    await ArtifactStorageService.flushPendingEdits();
    final artifacts = await ArtifactStorageService.loadArtifactsForChat(
      chatId,
      forceRefresh: true,
    );
    if (artifacts.isEmpty) {
      return null;
    }

    final buffer = StringBuffer();

    // ── Roster: list every existing artifact id up front so the AI
    // anchors on real ids instead of inventing new ones. ──
    buffer.writeln('## Active artifacts in this chat');
    buffer.writeln(
      'You MUST reuse these EXACT artifact_id values for any update/rewrite. '
      'Inventing a new id when one already exists for the same logical '
      'artifact is a bug — use action="rewrite" with the existing id instead.',
    );
    buffer.writeln();
    for (final artifact in artifacts) {
      final lang = artifact.language ?? 'n/a';
      buffer.writeln(
        '- id="${artifact.id}"  type=${artifact.type.value}  '
        'title="${artifact.title}"  language=$lang  '
        'version=${artifact.version}',
      );
    }
    buffer.writeln();
    buffer.writeln(
      'To create a NEW artifact (different topic), invent a fresh id. '
      'To MODIFY an existing artifact, reuse one of the ids above.',
    );
    buffer.writeln();

    buffer.writeln('=== ACTIVE ARTIFACTS (LATEST VERSION) ===');
    buffer.writeln(
      'The following artifact bodies are the CURRENT, LIVE content — they '
      'include every user edit (drag, color, text, added/removed elements) '
      'made since you first authored them. They are NOT the version you '
      'originally generated.',
    );
    buffer.writeln(
      'When you rewrite or update any artifact below, the new content MUST '
      'be derived from THIS body — never from your memory of what you '
      'previously produced. Apply the user\'s requested change on top of '
      'the body shown here, preserving every element they added, moved, or '
      'styled. Regenerating from scratch silently destroys user edits.',
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
