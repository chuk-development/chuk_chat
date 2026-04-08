// lib/models/workspace_model.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants/file_constants.dart';

/// Represents a workspace that combines AI persona, system prompts, files,
/// and chat organization. Unifies the former "Projects" and "Assistants" features.
class Workspace {
  final String id;
  final String name;
  final String? description;
  final String? customSystemPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isArchived;

  // Workspace persona fields
  final bool memoryEnabled;
  final String? modelId;
  final String? avatarColor;
  final String? avatarIcon;
  final String? avatarImagePath;
  final bool isPublic;
  final String? userId;
  final String? ownerDisplayName;

  // Relationships (loaded separately via joins)
  final List<String> chatIds;
  final List<WorkspaceFile> files;

  Workspace({
    required this.id,
    required this.name,
    this.description,
    this.customSystemPrompt,
    required this.createdAt,
    required this.updatedAt,
    this.isArchived = false,
    this.memoryEnabled = true,
    this.modelId,
    this.avatarColor,
    this.avatarIcon,
    this.avatarImagePath,
    this.isPublic = false,
    this.userId,
    this.ownerDisplayName,
    this.chatIds = const [],
    this.files = const [],
  });

  factory Workspace.fromJson(Map<String, dynamic> json) {
    return Workspace(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      customSystemPrompt: json['custom_system_prompt'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      isArchived: (json['is_archived'] as bool?) ?? false,
      memoryEnabled: (json['memory_enabled'] as bool?) ?? true,
      modelId: json['model_id'] as String?,
      avatarColor: json['avatar_color'] as String?,
      avatarIcon: json['avatar_icon'] as String?,
      avatarImagePath: json['avatar_image_path'] as String?,
      isPublic: (json['is_public'] as bool?) ?? false,
      userId: json['user_id'] as String?,
      ownerDisplayName: json['owner_display_name'] as String?,
      chatIds: json['chatIds'] != null
          ? List<String>.from(json['chatIds'] as List)
          : const [],
      files: json['files'] != null
          ? (json['files'] as List)
                .map((f) => WorkspaceFile.fromJson(f as Map<String, dynamic>))
                .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    if (customSystemPrompt != null) 'custom_system_prompt': customSystemPrompt,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'is_archived': isArchived,
    'memory_enabled': memoryEnabled,
    if (modelId != null) 'model_id': modelId,
    if (avatarColor != null) 'avatar_color': avatarColor,
    if (avatarIcon != null) 'avatar_icon': avatarIcon,
    if (avatarImagePath != null) 'avatar_image_path': avatarImagePath,
    'is_public': isPublic,
    if (userId != null) 'user_id': userId,
    if (ownerDisplayName != null) 'owner_display_name': ownerDisplayName,
    'chatIds': chatIds,
    'files': files.map((f) => f.toJson()).toList(),
  };

  Workspace copyWith({
    String? id,
    String? name,
    String? description,
    String? customSystemPrompt,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isArchived,
    bool? memoryEnabled,
    String? modelId,
    String? avatarColor,
    String? avatarIcon,
    String? avatarImagePath,
    bool? isPublic,
    String? userId,
    String? ownerDisplayName,
    List<String>? chatIds,
    List<WorkspaceFile>? files,
  }) {
    return Workspace(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      customSystemPrompt: customSystemPrompt ?? this.customSystemPrompt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isArchived: isArchived ?? this.isArchived,
      memoryEnabled: memoryEnabled ?? this.memoryEnabled,
      modelId: modelId ?? this.modelId,
      avatarColor: avatarColor ?? this.avatarColor,
      avatarIcon: avatarIcon ?? this.avatarIcon,
      avatarImagePath: avatarImagePath ?? this.avatarImagePath,
      isPublic: isPublic ?? this.isPublic,
      userId: userId ?? this.userId,
      ownerDisplayName: ownerDisplayName ?? this.ownerDisplayName,
      chatIds: chatIds ?? this.chatIds,
      files: files ?? this.files,
    );
  }

  /// Get number of chats in this workspace
  int get chatCount => chatIds.length;

  /// Get number of files in this workspace
  int get fileCount => files.length;

  /// Check if workspace has a custom system prompt
  bool get hasCustomPrompt =>
      customSystemPrompt != null && customSystemPrompt!.trim().isNotEmpty;

  /// Get total size of all files in bytes
  int get totalFileSize => files.fold(0, (sum, file) => sum + file.fileSize);

  /// Get formatted total file size (e.g., "2.5 MB")
  String get totalFileSizeFormatted => _formatFileSize(totalFileSize);

  /// Display color — uses custom avatar color if set, otherwise deterministic
  Color get displayColor {
    if (avatarColor != null) {
      try {
        return Color(
          int.parse(avatarColor!.replaceFirst('#', ''), radix: 16) |
              0xFF000000,
        );
      } catch (_) {}
    }
    final index = name.hashCode.abs() % kWorkspaceColors.length;
    return kWorkspaceColors[index];
  }

  /// Display icon — uses custom avatar icon if set, otherwise deterministic
  IconData get displayIcon {
    if (avatarIcon != null) {
      final iconName = avatarIcon!.toLowerCase();
      if (_iconMap.containsKey(iconName)) return _iconMap[iconName]!;
    }
    final index = (name.hashCode.abs() ~/ 7) % kWorkspaceIcons.length;
    return kWorkspaceIcons[index];
  }

  /// Check if this workspace has a custom uploaded image
  bool get hasCustomImage =>
      avatarImagePath != null && avatarImagePath!.isNotEmpty;

  /// Check if this is owned by a specific user
  bool isOwnedBy(String? currentUserId) =>
      userId != null && userId == currentUserId;

  static final Map<String, IconData> _iconMap = {
    'smart_toy': Icons.smart_toy_outlined,
    'psychology': Icons.psychology_outlined,
    'lightbulb': Icons.lightbulb_outline,
    'auto_awesome': Icons.auto_awesome_outlined,
    'chat': Icons.chat_bubble_outline,
    'support': Icons.support_agent_outlined,
    'code': Icons.code,
    'school': Icons.school_outlined,
    'work': Icons.work_outline,
    'science': Icons.science_outlined,
    'book': Icons.auto_stories_outlined,
    'terminal': Icons.terminal,
    'rocket': Icons.rocket_launch_outlined,
    'folder': Icons.folder_outlined,
  };

  static Map<String, IconData> get availableIcons => _iconMap;

  /// Get relative time string for updatedAt (e.g., "2h ago", "3d ago")
  String get updatedAgo {
    final now = DateTime.now();
    final diff = now.difference(updatedAt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${diff.inDays ~/ 7}w ago';
    if (diff.inDays < 365) return '${diff.inDays ~/ 30}mo ago';
    return '${diff.inDays ~/ 365}y ago';
  }

  /// Get the first letter(s) for avatar display
  String get initials {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';

    final words = trimmed.split(RegExp(r'\s+'));
    if (words.length >= 2) {
      final first = words[0].characters.first;
      final second = words[1].characters.first;
      return '$first$second'.toUpperCase();
    }
    return trimmed.characters.take(2).toString().toUpperCase();
  }

  /// Predefined workspace colors - vibrant but balanced for both themes
  static const List<Color> kWorkspaceColors = [
    Color(0xFF6366F1), // Indigo
    Color(0xFF8B5CF6), // Violet
    Color(0xFFEC4899), // Pink
    Color(0xFFEF4444), // Red
    Color(0xFFF97316), // Orange
    Color(0xFFEAB308), // Yellow
    Color(0xFF22C55E), // Green
    Color(0xFF14B8A6), // Teal
    Color(0xFF06B6D4), // Cyan
    Color(0xFF3B82F6), // Blue
    Color(0xFF8B5E3C), // Brown
    Color(0xFF64748B), // Slate
  ];

  /// Predefined workspace icons
  static const List<IconData> kWorkspaceIcons = [
    Icons.folder_outlined,
    Icons.code,
    Icons.science_outlined,
    Icons.auto_stories_outlined,
    Icons.palette_outlined,
    Icons.build_outlined,
    Icons.school_outlined,
    Icons.work_outline,
    Icons.language,
    Icons.terminal,
    Icons.data_object,
    Icons.psychology_outlined,
    Icons.lightbulb_outline,
    Icons.rocket_launch_outlined,
    Icons.auto_awesome_outlined,
    Icons.hub_outlined,
  ];

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Represents a file attached to a workspace
class WorkspaceFile {
  final String id;
  final String workspaceId;
  final String fileName;
  final String storagePath;
  final String fileType;
  final int fileSize;
  final DateTime uploadedAt;
  final String? markdownSummary;

  WorkspaceFile({
    required this.id,
    required this.workspaceId,
    required this.fileName,
    required this.storagePath,
    required this.fileType,
    required this.fileSize,
    required this.uploadedAt,
    this.markdownSummary,
  });

  factory WorkspaceFile.fromJson(Map<String, dynamic> json) {
    return WorkspaceFile(
      id: json['id'] as String,
      workspaceId: json['project_id'] as String,
      fileName: json['file_name'] as String,
      storagePath: json['storage_path'] as String,
      fileType: json['file_type'] as String,
      fileSize: json['file_size'] as int,
      uploadedAt: DateTime.parse(json['uploaded_at'] as String),
      markdownSummary: json['markdown_summary'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'project_id': workspaceId,
    'file_name': fileName,
    'storage_path': storagePath,
    'file_type': fileType,
    'file_size': fileSize,
    'uploaded_at': uploadedAt.toIso8601String(),
    if (markdownSummary != null) 'markdown_summary': markdownSummary,
  };

  WorkspaceFile copyWith({
    String? id,
    String? workspaceId,
    String? fileName,
    String? storagePath,
    String? fileType,
    int? fileSize,
    DateTime? uploadedAt,
    String? markdownSummary,
  }) {
    return WorkspaceFile(
      id: id ?? this.id,
      workspaceId: workspaceId ?? this.workspaceId,
      fileName: fileName ?? this.fileName,
      storagePath: storagePath ?? this.storagePath,
      fileType: fileType ?? this.fileType,
      fileSize: fileSize ?? this.fileSize,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      markdownSummary: markdownSummary ?? this.markdownSummary,
    );
  }

  /// Check if this file has an AI-generated markdown summary
  bool get hasMarkdownSummary =>
      markdownSummary != null && markdownSummary!.trim().isNotEmpty;

  /// Get formatted file size (e.g., "1.5 MB")
  String get fileSizeFormatted {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Get file icon based on file type
  IconData get fileIcon {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      // Code files
      case 'dart':
      case 'js':
      case 'ts':
      case 'py':
      case 'java':
      case 'cpp':
      case 'c':
      case 'h':
      case 'rs':
      case 'go':
      case 'rb':
      case 'php':
      case 'swift':
      case 'kt':
        return Icons.code;

      // Text/Markdown
      case 'txt':
      case 'md':
      case 'markdown':
        return Icons.description;

      // JSON/YAML/Config
      case 'json':
      case 'yaml':
      case 'yml':
      case 'toml':
      case 'xml':
      case 'csv':
        return Icons.data_object;

      // Documents
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.article;

      // Web
      case 'html':
      case 'htm':
      case 'css':
      case 'scss':
        return Icons.web;

      // Images
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'svg':
        return Icons.image;

      // Default
      default:
        return Icons.insert_drive_file;
    }
  }

  /// Check if file is a text-based file that can be previewed
  /// Uses shared FileConstants for consistency with chat file handling
  bool get isPreviewable => FileConstants.isPlainText(extension);

  /// Check if file is a text-based file (not binary)
  bool get isTextFile => isPreviewable;

  /// Get file extension
  String get extension => fileName.split('.').last.toLowerCase();

  /// Check if file is an image
  /// Uses shared FileConstants for consistency with chat file handling
  bool get isImage => FileConstants.isImage(extension);

  /// Check if file is a PDF
  bool get isPdf => extension == 'pdf';

  /// Estimate how many tokens this file will consume in context.
  /// Uses the same logic as WorkspaceMessageService._estimateContentLength
  /// but converts chars to tokens (~4 chars per token).
  int get estimatedTokens {
    int chars;
    if (hasMarkdownSummary) {
      chars = markdownSummary!.length + 200; // +200 for headers
    } else if (isPdf) {
      chars = 150; // Just a note saying content unavailable
    } else if (isImage) {
      chars = 100;
    } else {
      chars = fileSize + 200; // +200 for code block markers
    }
    return (chars / 4).ceil();
  }

  /// Format estimated tokens for display (e.g. "2.5k tokens")
  String get estimatedTokensFormatted {
    final tokens = estimatedTokens;
    if (tokens < 1000) return '$tokens tokens';
    if (tokens < 10000) return '${(tokens / 1000).toStringAsFixed(1)}k tokens';
    return '${(tokens / 1000).round()}k tokens';
  }
}
