import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/models/tool_call.dart';

/// The type of a content block within an AI response.
enum ContentBlockType { text, toolCalls, reasoning, sandboxArtifact }

/// Payload for a [ContentBlockType.sandboxArtifact] block.
///
/// Represents a file that the AI produced inside the sandbox and explicitly
/// handed to the user via the `send_file_to_user` tool. The bytes themselves
/// live encrypted in Supabase Storage; this payload carries only the metadata
/// needed to render or download the artifact in the chat UI.
class SandboxArtifactPayload {
  const SandboxArtifactPayload({
    required this.storagePath,
    required this.filename,
    required this.mime,
    required this.sizeBytes,
    this.document,
  });

  /// Storage path returned by [PdfAttachmentService.upload]:
  /// `"{user_id}/{uuid}.enc"`. The bucket-level content type is `image/png`
  /// (the bucket only allows image/*), but the underlying bytes are opaque
  /// ciphertext — the real mime lives on this payload, not the storage row.
  final String storagePath;
  final String filename;
  final String mime;
  final int sizeBytes;

  /// Full table/Markdown snapshot. Stored inside the encrypted chat payload,
  /// so a new device can read it without this device's local blob cache.
  final Map<String, dynamic>? document;

  Map<String, dynamic> toJson() => {
    'storagePath': storagePath,
    'filename': filename,
    'mime': mime,
    'sizeBytes': sizeBytes,
    if (document != null) 'document': document,
  };

  factory SandboxArtifactPayload.fromJson(Map<String, dynamic> j) =>
      SandboxArtifactPayload(
        storagePath: j['storagePath'] as String? ?? '',
        filename: j['filename'] as String? ?? 'file',
        mime: j['mime'] as String? ?? 'application/octet-stream',
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        document: j['document'] is Map
            ? Map<String, dynamic>.from(j['document'] as Map)
            : null,
      );
}

/// An ordered block of content within an AI response.
///
/// AI responses can contain interleaved text, tool calls, and reasoning.
/// Each [ContentBlock] represents one segment, and the list order determines
/// the display order in the chat UI.
class ContentBlock {
  const ContentBlock._({
    required this.type,
    this.text,
    this.toolCalls,
    this.sandboxArtifact,
  });

  /// A block of visible text shown to the user.
  const ContentBlock.text(String text)
    : this._(type: ContentBlockType.text, text: text);

  /// A block of tool calls (expandable in the UI).
  const ContentBlock.toolCalls(List<ToolCall> calls)
    : this._(type: ContentBlockType.toolCalls, toolCalls: calls);

  /// A reasoning/thinking block (expandable in the UI).
  const ContentBlock.reasoning(String text)
    : this._(type: ContentBlockType.reasoning, text: text);

  /// A sandbox-produced file handed to the user (downloadable / inline-
  /// renderable artifact). Encrypted bytes live in Supabase Storage;
  /// payload carries only metadata.
  const ContentBlock.sandboxArtifact(SandboxArtifactPayload payload)
    : this._(type: ContentBlockType.sandboxArtifact, sandboxArtifact: payload);

  final ContentBlockType type;

  /// The text content (for [ContentBlockType.text] and
  /// [ContentBlockType.reasoning] blocks).
  final String? text;

  /// The tool calls (for [ContentBlockType.toolCalls] blocks).
  final List<ToolCall>? toolCalls;

  /// Sandbox artifact metadata (for [ContentBlockType.sandboxArtifact]).
  final SandboxArtifactPayload? sandboxArtifact;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    if (text != null) 'text': text,
    if (toolCalls != null)
      'toolCalls': toolCalls!.map((c) => c.toJson()).toList(),
    if (sandboxArtifact != null) 'sandboxArtifact': sandboxArtifact!.toJson(),
  };

  /// Stored type name of file blocks. Chat used to write them from the
  /// removed E2B code sandbox; Agents still writes them for every file the
  /// host hands to the user.
  static const String _legacySandboxArtifactType = 'sandboxArtifact';

  /// Whether a stored file block decodes to a file card. With Agents on, it
  /// does: Agents delivers files through this block. Without Agents the only
  /// writer was the removed code sandbox, so an old block becomes a plain
  /// note, exactly as in chuk_chat. Follows [agentsChatCore], the one switch
  /// for every Agents code path.
  static bool get decodesFileBlocks => agentsChatCore;

  /// A test picks a side here. Sets the one shared override.
  @visibleForTesting
  static set decodesFileBlocks(bool value) =>
      debugAgentsChatCoreOverride = value;

  factory ContentBlock.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'text';
    // Old chats can still carry a file block from the removed code sandbox.
    // It cannot be opened any more; show a plain note in its place.
    if (typeName == _legacySandboxArtifactType && !decodesFileBlocks) {
      return ContentBlock.text(legacySandboxArtifactNote(json));
    }
    final type = ContentBlockType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => ContentBlockType.text,
    );

    List<ToolCall>? toolCalls;
    final rawCalls = json['toolCalls'];
    if (rawCalls is List) {
      toolCalls = rawCalls
          .whereType<Map>()
          .map((item) => ToolCall.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }

    SandboxArtifactPayload? sandboxArtifact;
    final rawArtifact = json['sandboxArtifact'];
    if (rawArtifact is Map) {
      sandboxArtifact = SandboxArtifactPayload.fromJson(
        Map<String, dynamic>.from(rawArtifact),
      );
    }

    return ContentBlock._(
      type: type,
      text: json['text'] as String?,
      toolCalls: toolCalls,
      sandboxArtifact: sandboxArtifact,
    );
  }

  /// The note shown in place of a legacy code-sandbox file block.
  static String legacySandboxArtifactNote(Map<String, dynamic> json) {
    final raw = json['sandboxArtifact'];
    final name = raw is Map ? raw['filename'] : null;
    final label = name is String && name.trim().isNotEmpty
        ? '"${name.trim()}"'
        : 'A file';
    return '_$label came from the code sandbox, which is no longer '
        'available._';
  }
}
