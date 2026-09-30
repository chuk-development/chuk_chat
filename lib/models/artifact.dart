// lib/models/artifact.dart

enum ArtifactType {
  code,
  markdown,
  html,
  mermaid,
  svg,
  technicalDrawing,
  typst,
  excalidraw,
}

extension ArtifactTypeX on ArtifactType {
  String get value => switch (this) {
    ArtifactType.code => 'code',
    ArtifactType.markdown => 'markdown',
    ArtifactType.html => 'html',
    ArtifactType.mermaid => 'mermaid',
    ArtifactType.svg => 'svg',
    ArtifactType.technicalDrawing => 'technical_drawing',
    ArtifactType.typst => 'typst',
    ArtifactType.excalidraw => 'excalidraw',
  };

  static ArtifactType fromValue(String raw) {
    final normalized = raw.trim().toLowerCase();
    return switch (normalized) {
      'code' => ArtifactType.code,
      'markdown' => ArtifactType.markdown,
      'html' => ArtifactType.html,
      'mermaid' => ArtifactType.mermaid,
      'svg' => ArtifactType.svg,
      'technical_drawing' => ArtifactType.technicalDrawing,
      'typst' => ArtifactType.typst,
      'excalidraw' => ArtifactType.excalidraw,
      _ => ArtifactType.markdown,
    };
  }

  String get displayLabel => switch (this) {
    ArtifactType.code => 'Code',
    ArtifactType.markdown => 'Markdown',
    ArtifactType.html => 'HTML',
    ArtifactType.mermaid => 'Mermaid',
    ArtifactType.svg => 'SVG',
    ArtifactType.technicalDrawing => 'Drawing',
    ArtifactType.typst => 'Typst PDF',
    ArtifactType.excalidraw => 'Excalidraw',
  };

  String get defaultExtension => switch (this) {
    ArtifactType.code => 'txt',
    ArtifactType.markdown => 'md',
    ArtifactType.html => 'html',
    ArtifactType.mermaid => 'mmd',
    ArtifactType.svg => 'svg',
    ArtifactType.technicalDrawing => 'json',
    ArtifactType.typst => 'typ',
    ArtifactType.excalidraw => 'excalidraw',
  };
}

class ArtifactDocument {
  const ArtifactDocument({
    required this.id,
    required this.chatId,
    required this.userId,
    required this.title,
    required this.type,
    required this.content,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.messageId,
    this.language,
    this.attachmentPath,
    this.updatedAtStamp,
    String? rowId,
  }) : rowId = rowId ?? id;

  /// The handle: the slug the AI chose (`todo-app`). Everything outside
  /// `ArtifactStorageService` addresses an artifact by it: UI, prompt
  /// context, tool calls, `<artifact>` tags, pending flushers.
  final String id;

  /// Primary key of the `artifacts` row. A random UUID for a sealed row;
  /// equal to [id] for a legacy row that is not re-sealed yet, and for
  /// documents that never came from the database. Only
  /// `ArtifactStorageService` uses it — it never leaves the client in place
  /// of the handle, and the handle never goes to the server.
  final String rowId;
  final String chatId;
  final String userId;
  final String? messageId;
  final String title;
  final ArtifactType type;
  final String? language;
  final String content;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Supabase Storage path of an encrypted binary attachment (e.g. the
  /// compiled PDF for a `typst` artifact). Null when no binary blob is
  /// persisted; clients fall back to compiling/rendering from [content].
  final String? attachmentPath;

  /// The row's `updated_at` exactly as the server returned it with the data
  /// of this document. `ArtifactStorageService` uses it as an
  /// optimistic-concurrency stamp, so a background write never overwrites a
  /// newer edit. Null when unknown.
  final String? updatedAtStamp;

  ArtifactDocument copyWith({
    String? id,
    String? rowId,
    String? chatId,
    String? userId,
    String? messageId,
    String? title,
    ArtifactType? type,
    String? language,
    String? content,
    int? version,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? attachmentPath,
    String? updatedAtStamp,
  }) {
    return ArtifactDocument(
      id: id ?? this.id,
      rowId: rowId ?? this.rowId,
      chatId: chatId ?? this.chatId,
      userId: userId ?? this.userId,
      messageId: messageId ?? this.messageId,
      title: title ?? this.title,
      type: type ?? this.type,
      language: language ?? this.language,
      content: content ?? this.content,
      version: version ?? this.version,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      attachmentPath: attachmentPath ?? this.attachmentPath,
      updatedAtStamp: updatedAtStamp ?? this.updatedAtStamp,
    );
  }
}

class ArtifactVersionSnapshot {
  const ArtifactVersionSnapshot({
    required this.artifactId,
    required this.version,
    required this.content,
    required this.createdAt,
    this.attachmentPath,
  });

  /// The handle of the artifact (see [ArtifactDocument.id]), not the row id
  /// the `artifact_versions.artifact_id` column holds.
  final String artifactId;
  final int version;
  final String content;
  final DateTime createdAt;
  final String? attachmentPath;

  /// [artifactId] is the handle the caller resolved for the row; without it
  /// the row's `artifact_id` (a row id) is used.
  static ArtifactVersionSnapshot fromMap(
    Map<String, dynamic> map, {
    required String decryptedContent,
    String? artifactId,
  }) {
    return ArtifactVersionSnapshot(
      artifactId: artifactId ?? (map['artifact_id'] as String? ?? ''),
      version: (map['version'] as num?)?.toInt() ?? 1,
      content: decryptedContent,
      attachmentPath:
          (map['attachment_path'] as String?)?.trim().isEmpty == true
          ? null
          : map['attachment_path'] as String?,
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

class ArtifactEdit {
  const ArtifactEdit({required this.oldStr, required this.newStr});

  final String oldStr;
  final String newStr;

  static ArtifactEdit fromMap(Map<String, dynamic> map) {
    return ArtifactEdit(
      oldStr: map['old_str'] as String? ?? '',
      newStr: map['new_str'] as String? ?? '',
    );
  }
}
