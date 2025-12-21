// lib/models/project_model.dart
import 'package:flutter/material.dart';

/// Represents a project workspace that groups chats, files, and custom system prompts
class Project {
  final String id;
  final String name;
  final String? description;
  final String? customSystemPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isArchived;

  // Relationships (loaded separately via joins)
  final List<String> chatIds;
  final List<ProjectFile> files;

  Project({
    required this.id,
    required this.name,
    this.description,
    this.customSystemPrompt,
    required this.createdAt,
    required this.updatedAt,
    this.isArchived = false,
    this.chatIds = const [],
    this.files = const [],
  });

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      customSystemPrompt: json['custom_system_prompt'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      isArchived: (json['is_archived'] as bool?) ?? false,
      chatIds: json['chatIds'] != null
          ? List<String>.from(json['chatIds'] as List)
          : const [],
      files: json['files'] != null
          ? (json['files'] as List)
              .map((f) => ProjectFile.fromJson(f as Map<String, dynamic>))
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description != null) 'description': description,
        if (customSystemPrompt != null)
          'custom_system_prompt': customSystemPrompt,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'is_archived': isArchived,
        'chatIds': chatIds,
        'files': files.map((f) => f.toJson()).toList(),
      };

  Project copyWith({
    String? id,
    String? name,
    String? description,
    String? customSystemPrompt,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isArchived,
    List<String>? chatIds,
    List<ProjectFile>? files,
  }) {
    return Project(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      customSystemPrompt: customSystemPrompt ?? this.customSystemPrompt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isArchived: isArchived ?? this.isArchived,
      chatIds: chatIds ?? this.chatIds,
      files: files ?? this.files,
    );
  }

  /// Get number of chats in this project
  int get chatCount => chatIds.length;

  /// Get number of files in this project
  int get fileCount => files.length;

  /// Check if project has a custom system prompt
  bool get hasCustomPrompt =>
      customSystemPrompt != null && customSystemPrompt!.trim().isNotEmpty;

  /// Get total size of all files in bytes
  int get totalFileSize =>
      files.fold(0, (sum, file) => sum + file.fileSize);

  /// Get formatted total file size (e.g., "2.5 MB")
  String get totalFileSizeFormatted => _formatFileSize(totalFileSize);

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Represents a file attached to a project
class ProjectFile {
  final String id;
  final String projectId;
  final String fileName;
  final String storagePath;
  final String fileType;
  final int fileSize;
  final DateTime uploadedAt;
  final String? markdownSummary;

  ProjectFile({
    required this.id,
    required this.projectId,
    required this.fileName,
    required this.storagePath,
    required this.fileType,
    required this.fileSize,
    required this.uploadedAt,
    this.markdownSummary,
  });

  factory ProjectFile.fromJson(Map<String, dynamic> json) {
    return ProjectFile(
      id: json['id'] as String,
      projectId: json['project_id'] as String,
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
        'project_id': projectId,
        'file_name': fileName,
        'storage_path': storagePath,
        'file_type': fileType,
        'file_size': fileSize,
        'uploaded_at': uploadedAt.toIso8601String(),
        if (markdownSummary != null) 'markdown_summary': markdownSummary,
      };

  ProjectFile copyWith({
    String? id,
    String? projectId,
    String? fileName,
    String? storagePath,
    String? fileType,
    int? fileSize,
    DateTime? uploadedAt,
    String? markdownSummary,
  }) {
    return ProjectFile(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
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
  bool get isPreviewable {
    final ext = fileName.split('.').last.toLowerCase();
    const previewableExts = {
      'txt',
      'md',
      'markdown',
      'json',
      'yaml',
      'yml',
      'xml',
      'csv',
      'dart',
      'js',
      'ts',
      'py',
      'java',
      'cpp',
      'c',
      'h',
      'rs',
      'go',
      'rb',
      'php',
      'swift',
      'kt',
      'html',
      'htm',
      'css',
      'scss',
    };
    return previewableExts.contains(ext);
  }

  /// Get file extension
  String get extension => fileName.split('.').last.toLowerCase();

  /// Check if file is an image
  bool get isImage {
    const imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
    return imageExts.contains(extension);
  }

  /// Check if file is a PDF
  bool get isPdf => extension == 'pdf';
}
