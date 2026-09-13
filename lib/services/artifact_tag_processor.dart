import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/utils/artifact_tag_parser.dart';

/// Processes inline `<artifact>` tags emitted by the assistant. For each tag:
///
/// - if the id is new, creates a fresh artifact
/// - if the id exists, rewrites it (bumps version, keeping history)
///
/// Returns synthetic completed [ToolCall] objects shaped like
/// `artifact_manager` outputs, so the existing inline-card render path in
/// `message_bubble.dart` picks them up with no extra branching.
class ArtifactTagProcessor {
  static Future<List<ToolCall>> processTags({
    required String content,
    required String chatId,
    String? messageId,
  }) async {
    final tags = parseArtifactTags(content);
    if (kDebugMode) {
      debugPrint(
        '[ArtifactTags] parseArtifactTags found ${tags.length} tag(s) '
        'in ${content.length}-char content',
      );
    }
    if (tags.isEmpty) return const [];

    final calls = <ToolCall>[];
    for (final tag in tags) {
      if (kDebugMode) {
        debugPrint(
          '[ArtifactTags] processing tag id=${tag.id} type=${tag.type} '
          'title=${tag.title} content=${tag.content.length}chars',
        );
      }
      final call = await _processOne(tag, chatId: chatId, messageId: messageId);
      if (kDebugMode) {
        debugPrint(
          '[ArtifactTags] tag id=${tag.id} → status=${call.status.name} '
          'result=${call.result}',
        );
      }
      calls.add(call);
    }
    return calls;
  }

  static Future<ToolCall> _processOne(
    ParsedArtifactTag tag, {
    required String chatId,
    String? messageId,
  }) async {
    final ArtifactType type;
    try {
      type = ArtifactTypeX.fromValue(tag.type);
    } catch (e) {
      return _errorCall(tag, action: 'create', message: 'invalid type: $e');
    }

    // Determine create-vs-rewrite, then persist. Any failure (load lookup,
    // create, or rewrite) surfaces as an error ToolCall rather than silently
    // picking the wrong action — otherwise a transient load failure could
    // produce a spurious create attempt against an existing id.
    try {
      final existing = await ArtifactStorageService.loadArtifactById(tag.id);
      final action = existing == null ? 'create' : 'rewrite';
      final args = <String, dynamic>{
        'action': action,
        'artifact_id': tag.id,
        'title': tag.title,
        'type': tag.type,
        if (tag.language != null) 'language': tag.language,
        'content': tag.content,
      };

      if (existing == null) {
        final created = await ArtifactStorageService.createArtifact(
          chatId: chatId,
          artifactId: tag.id,
          title: tag.title,
          type: type,
          content: tag.content,
          language: tag.language,
          messageId: messageId,
        );
        return ToolCall(
          name: 'artifact_manager',
          arguments: args,
          result:
              'Artifact "${created.id}" created '
              '(type: ${created.type.value}, version: ${created.version}).',
          status: ToolCallStatus.completed,
          completedAt: DateTime.now(),
        );
      }

      final rewritten = await ArtifactStorageService.rewriteArtifact(
        artifactId: tag.id,
        content: tag.content,
        title: tag.title,
        type: type,
        language: tag.language,
      );
      return ToolCall(
        name: 'artifact_manager',
        arguments: args,
        result:
            'Artifact "${rewritten.id}" rewritten to '
            'version ${rewritten.version}.',
        status: ToolCallStatus.completed,
        completedAt: DateTime.now(),
      );
    } catch (e) {
      return _errorCall(tag, action: 'create', message: e.toString());
    }
  }

  static ToolCall _errorCall(
    ParsedArtifactTag tag, {
    required String action,
    required String message,
  }) {
    return ToolCall(
      name: 'artifact_manager',
      arguments: {
        'action': action,
        'artifact_id': tag.id,
        'title': tag.title,
        'type': tag.type,
        if (tag.language != null) 'language': tag.language,
        'content': tag.content,
      },
      result: 'Error: $message',
      status: ToolCallStatus.error,
      completedAt: DateTime.now(),
    );
  }
}
