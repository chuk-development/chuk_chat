// lib/models/chat_message.dart

/// Represents a single message in a chat.
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    this.reasoning,
    this.images,
    this.imageCostEur,
    this.imageGeneratedAt,
    this.attachments,
    this.attachedFilesJson,
    this.modelId,
    this.provider,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] as String? ?? json['sender'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
      reasoning: json['reasoning'] as String?,
      images: json['images'] as String?,
      imageCostEur: json['imageCostEur'] as String?,
      imageGeneratedAt: json['imageGeneratedAt'] as String?,
      attachments: json['attachments'] as String?,
      attachedFilesJson: json['attachedFilesJson'] as String?,
      modelId: json['modelId'] as String?,
      provider: json['provider'] as String?,
    );
  }

  final String role;
  final String text;
  final String? reasoning;
  final String? images;
  final String? imageCostEur;
  final String? imageGeneratedAt;
  final String? attachments;
  final String? attachedFilesJson;
  final String? modelId;
  final String? provider;

  // Alias for backwards compatibility
  String get sender => role == 'assistant' ? 'ai' : role;

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
    if (images != null && images!.isNotEmpty) 'images': images,
    if (imageCostEur != null && imageCostEur!.isNotEmpty)
      'imageCostEur': imageCostEur,
    if (imageGeneratedAt != null && imageGeneratedAt!.isNotEmpty)
      'imageGeneratedAt': imageGeneratedAt,
    if (attachments != null && attachments!.isNotEmpty)
      'attachments': attachments,
    if (attachedFilesJson != null && attachedFilesJson!.isNotEmpty)
      'attachedFilesJson': attachedFilesJson,
    if (modelId != null && modelId!.isNotEmpty) 'modelId': modelId,
    if (provider != null && provider!.isNotEmpty) 'provider': provider,
  };
}
