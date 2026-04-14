// lib/models/artifact.dart

enum ArtifactType { code, markdown, html, mermaid, svg, technicalDrawing, typst }

extension ArtifactTypeX on ArtifactType {
  String get value => switch (this) {
    ArtifactType.code => 'code',
    ArtifactType.markdown => 'markdown',
    ArtifactType.html => 'html',
    ArtifactType.mermaid => 'mermaid',
    ArtifactType.svg => 'svg',
    ArtifactType.technicalDrawing => 'technical_drawing',
    ArtifactType.typst => 'typst',
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
  };

  String get defaultExtension => switch (this) {
    ArtifactType.code => 'txt',
    ArtifactType.markdown => 'md',
    ArtifactType.html => 'html',
    ArtifactType.mermaid => 'mmd',
    ArtifactType.svg => 'svg',
    ArtifactType.technicalDrawing => 'json',
    ArtifactType.typst => 'typ',
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
  });

  final String id;
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

  ArtifactDocument copyWith({
    String? id,
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
  }) {
    return ArtifactDocument(
      id: id ?? this.id,
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
    );
  }

  Map<String, dynamic> toMap({String? encryptedContent}) {
    return {
      'id': id,
      'chat_id': chatId,
      'user_id': userId,
      'message_id': messageId,
      'title': title,
      'type': type.value,
      'language': language,
      'content': encryptedContent ?? content,
      'version': version,
      'attachment_path': attachmentPath,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  static ArtifactDocument fromMap(
    Map<String, dynamic> map, {
    required String decryptedContent,
  }) {
    return ArtifactDocument(
      id: map['id'] as String,
      chatId: map['chat_id'] as String,
      userId: map['user_id'] as String,
      messageId: map['message_id'] as String?,
      title: map['title'] as String,
      type: ArtifactTypeX.fromValue(map['type'] as String? ?? 'markdown'),
      language: map['language'] as String?,
      content: decryptedContent,
      version: (map['version'] as num?)?.toInt() ?? 1,
      attachmentPath: (map['attachment_path'] as String?)?.trim().isEmpty == true
          ? null
          : map['attachment_path'] as String?,
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
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

  final String artifactId;
  final int version;
  final String content;
  final DateTime createdAt;
  final String? attachmentPath;

  static ArtifactVersionSnapshot fromMap(
    Map<String, dynamic> map, {
    required String decryptedContent,
  }) {
    return ArtifactVersionSnapshot(
      artifactId: map['artifact_id'] as String,
      version: (map['version'] as num?)?.toInt() ?? 1,
      content: decryptedContent,
      attachmentPath: (map['attachment_path'] as String?)?.trim().isEmpty == true
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
