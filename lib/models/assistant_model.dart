// lib/models/assistant_model.dart

import 'package:flutter/material.dart';

/// Represents a custom AI assistant with its own system prompt and personality.
/// Similar to ChatGPT's GPTs - each assistant has isolated memory and behavior.
class Assistant {
  final String id;
  final String name;
  final String? description;
  final String systemPrompt;
  final bool memoryEnabled;
  final String? modelId; // Optional preferred model
  final String? avatarColor; // Hex color string
  final String? avatarIcon; // Icon identifier
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isArchived;

  Assistant({
    required this.id,
    required this.name,
    this.description,
    required this.systemPrompt,
    this.memoryEnabled = true,
    this.modelId,
    this.avatarColor,
    this.avatarIcon,
    required this.createdAt,
    required this.updatedAt,
    this.isArchived = false,
  });

  factory Assistant.fromJson(Map<String, dynamic> json) {
    return Assistant(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      systemPrompt: json['system_prompt'] as String,
      memoryEnabled: (json['memory_enabled'] as bool?) ?? true,
      modelId: json['model_id'] as String?,
      avatarColor: json['avatar_color'] as String?,
      avatarIcon: json['avatar_icon'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      isArchived: (json['is_archived'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    'system_prompt': systemPrompt,
    'memory_enabled': memoryEnabled,
    if (modelId != null) 'model_id': modelId,
    if (avatarColor != null) 'avatar_color': avatarColor,
    if (avatarIcon != null) 'avatar_icon': avatarIcon,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'is_archived': isArchived,
  };

  /// Convert to Supabase insert/update format (snake_case, no id/timestamps for insert)
  Map<String, dynamic> toSupabaseJson() => {
    'name': name,
    if (description != null) 'description': description,
    'system_prompt': systemPrompt,
    'memory_enabled': memoryEnabled,
    if (modelId != null) 'model_id': modelId,
    if (avatarColor != null) 'avatar_color': avatarColor,
    if (avatarIcon != null) 'avatar_icon': avatarIcon,
    'is_archived': isArchived,
  };

  Assistant copyWith({
    String? id,
    String? name,
    String? description,
    String? systemPrompt,
    bool? memoryEnabled,
    String? modelId,
    String? avatarColor,
    String? avatarIcon,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isArchived,
  }) {
    return Assistant(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      memoryEnabled: memoryEnabled ?? this.memoryEnabled,
      modelId: modelId ?? this.modelId,
      avatarColor: avatarColor ?? this.avatarColor,
      avatarIcon: avatarIcon ?? this.avatarIcon,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isArchived: isArchived ?? this.isArchived,
    );
  }

  /// Get the display color for this assistant
  Color get displayColor {
    if (avatarColor != null) {
      try {
        return Color(
          int.parse(avatarColor!.replaceFirst('#', ''), radix: 16) | 0xFF000000,
        );
      } catch (_) {
        // Fall through to default
      }
    }
    // Deterministic color based on name hash
    final index = name.hashCode.abs() % _kAssistantColors.length;
    return _kAssistantColors[index];
  }

  /// Get the display icon for this assistant
  IconData get displayIcon {
    if (avatarIcon != null) {
      // Map common icon names to Icons
      final iconName = avatarIcon!.toLowerCase();
      if (_iconMap.containsKey(iconName)) {
        return _iconMap[iconName]!;
      }
    }
    // Deterministic icon based on name hash
    final index = (name.hashCode.abs() ~/ 7) % _kAssistantIcons.length;
    return _kAssistantIcons[index];
  }

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

  /// Check if this assistant has a description
  bool get hasDescription =>
      description != null && description!.trim().isNotEmpty;

  /// Get formatted memory status text
  String get memoryStatusText =>
      memoryEnabled ? 'Memory enabled' : 'Memory disabled';

  /// Predefined assistant colors - vibrant but balanced for both themes
  static const List<Color> _kAssistantColors = [
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

  /// Predefined assistant icons
  static const List<IconData> _kAssistantIcons = [
    Icons.smart_toy_outlined,
    Icons.psychology_outlined,
    Icons.lightbulb_outline,
    Icons.auto_awesome_outlined,
    Icons.chat_bubble_outline,
    Icons.support_agent_outlined,
    Icons.emoji_people_outlined,
    Icons.person_outline,
    Icons.face_outlined,
    Icons.mood_outlined,
    Icons.sentiment_satisfied_outlined,
    Icons.sentiment_very_satisfied_outlined,
    Icons.bubble_chart_outlined,
    Icons.cloud_outlined,
    Icons.star_outline,
    Icons.favorite_outline,
  ];

  /// Icon name to IconData mapping for avatar_icon field
  static final Map<String, IconData> _iconMap = {
    'smart_toy': Icons.smart_toy_outlined,
    'psychology': Icons.psychology_outlined,
    'lightbulb': Icons.lightbulb_outline,
    'auto_awesome': Icons.auto_awesome_outlined,
    'chat': Icons.chat_bubble_outline,
    'support': Icons.support_agent_outlined,
    'person': Icons.person_outline,
    'face': Icons.face_outlined,
    'mood': Icons.mood_outlined,
    'star': Icons.star_outline,
    'favorite': Icons.favorite_outline,
    'code': Icons.code,
    'school': Icons.school_outlined,
    'work': Icons.work_outline,
    'science': Icons.science_outlined,
    'book': Icons.auto_stories_outlined,
    'palette': Icons.palette_outlined,
    'terminal': Icons.terminal,
    'rocket': Icons.rocket_launch_outlined,
    'cloud': Icons.cloud_outlined,
    'robot': Icons.smart_toy,
    'brain': Icons.psychology,
    'idea': Icons.lightbulb,
    'assistant': Icons.support_agent,
    'bot': Icons.smart_toy_outlined,
    'ai': Icons.auto_awesome,
  };

  /// Get all available icon options for UI selection
  static Map<String, IconData> get availableIcons => _iconMap;

  /// Get hex color string from Color
  static String colorToHex(Color color) {
    return '#${color.value.toRadixString(16).substring(2).toUpperCase()}';
  }
}

/// Represents a link between an assistant and a chat
class AssistantChat {
  final String id;
  final String assistantId;
  final String chatId;
  final DateTime createdAt;

  AssistantChat({
    required this.id,
    required this.assistantId,
    required this.chatId,
    required this.createdAt,
  });

  factory AssistantChat.fromJson(Map<String, dynamic> json) {
    return AssistantChat(
      id: json['id'] as String,
      assistantId: json['assistant_id'] as String,
      chatId: json['chat_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'assistant_id': assistantId,
    'chat_id': chatId,
    'created_at': createdAt.toIso8601String(),
  };
}
