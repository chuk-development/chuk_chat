// lib/models/chat_model.dart

class ModelItem {
  final String name; // Display name
  final String value; // Model ID (slug for API)
  final bool isToggle; // Not from API, for potential local use
  final String? badge; // Not from API, for potential local use

  ModelItem({
    required this.name,
    required this.value,
    this.isToggle = false,
    this.badge,
  });

  // Factory constructor to create ModelItem from API JSON
  factory ModelItem.fromJson(Map<String, dynamic> json) {
    return ModelItem(
      name: json['name'] as String,
      value:
          json['id']
              as String, // 'id' from API becomes 'value' for internal use
      isToggle: false, // Defaulting as not from API
      badge: null, // Defaulting as not from API
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelItem &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}

// Class to represent an attached file's state
class AttachedFile {
  final String id; // Unique ID for managing state
  final String fileName;
  final String? markdownContent; // Null if still uploading or failed
  final bool isUploading;
  final String? localPath; // Local file system path when available
  final int? fileSizeBytes; // File size in bytes, used for UI display

  AttachedFile({
    required this.id,
    required this.fileName,
    this.markdownContent,
    this.isUploading = false,
    this.localPath,
    this.fileSizeBytes,
  });

  AttachedFile copyWith({
    String? markdownContent,
    bool? isUploading,
    String? localPath,
    int? fileSizeBytes,
  }) {
    return AttachedFile(
      id: id,
      fileName: fileName,
      markdownContent: markdownContent ?? this.markdownContent,
      isUploading: isUploading ?? this.isUploading,
      localPath: localPath ?? this.localPath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
    );
  }
}
