// lib/platform_specific/chat/chat_ui_helpers.dart

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/artifact_context_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/project_message_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart' show DocumentAttachment;
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

/// Data class holding pre-parsed render information for a single chat message.
///
/// Shared by both desktop and mobile chat UIs to avoid duplicating parsing
/// logic.
class MessageRenderData {
  const MessageRenderData({
    required this.sender,
    required this.displayText,
    required this.reasoning,
    required this.isReasoningStreaming,
    this.modelLabel,
    this.modelProvider,
    this.tps,
    this.images,
    this.imageCostEur,
    this.imageGeneratedAt,
    this.attachments,
    this.toolCalls,
    this.contentBlocks,
    this.replyPreviewText,
    this.replyPreviewLabel,
    this.isStreamingMessage = false,
  });

  final String sender;
  final String displayText;
  final String reasoning;
  final bool isReasoningStreaming;
  final String? modelLabel;
  final String? modelProvider;
  final double? tps;
  final List<String>? images;
  final double? imageCostEur;
  final DateTime? imageGeneratedAt;
  final List<DocumentAttachment>? attachments;
  final List<ToolCall>? toolCalls;
  final List<ContentBlock>? contentBlocks;
  final String? replyPreviewText;
  final String? replyPreviewLabel;
  final bool isStreamingMessage;

  bool get isUser => sender == 'user';
}

/// Static utility functions shared between the desktop and mobile chat UIs.
class ChatUiHelpers {
  const ChatUiHelpers._();

  static const int _kReplyPreviewMaxChars = 160;

  /// Format model info for display in message bubble.
  static String? formatModelInfo(String? modelId, String? provider) {
    final String normalizedModel = (modelId ?? '').trim();
    final String normalizedProvider = (provider ?? '').trim();
    if (normalizedModel.isEmpty && normalizedProvider.isEmpty) {
      return null;
    }
    if (normalizedModel.isEmpty) {
      return normalizedProvider;
    }
    return normalizedModel;
  }

  /// Check if the selected model supports image input.
  static bool modelSupportsImageInput(String selectedModelId) =>
      ModelCapabilitiesService.supportsImageInputSync(selectedModelId);

  /// Show a styled snack bar.
  static void showSnackBar(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        duration: const Duration(seconds: 2),
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  /// Navigate to Coming Soon page.
  static void openComingSoonFeature(BuildContext context, String featureName) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComingSoonPage(
          title: featureName,
          message: 'Stay tuned for $featureName.',
        ),
      ),
    );
  }

  /// Load provider slug for a model.
  static Future<String?> loadProviderSlugForModel(String modelId) async {
    if (modelId.isEmpty) return null;

    final String? dropdownSlug = ModelSelectionDropdown.providerSlugForModel(
      modelId,
    );
    if (dropdownSlug != null && dropdownSlug.isNotEmpty) {
      return dropdownSlug;
    }

    return await UserPreferencesService.loadSelectedProvider(modelId);
  }

  /// Ensure provider slug is available for the current model.
  static Future<String?> ensureProviderSlug(
    String selectedModelId,
    String? currentSlug,
  ) async {
    if (selectedModelId.isEmpty) return null;
    if (currentSlug != null && currentSlug.isNotEmpty) {
      return currentSlug;
    }
    return await loadProviderSlugForModel(selectedModelId);
  }

  /// Load system prompt from preferences.
  static Future<String?> loadSystemPrompt() async {
    try {
      return await UserPreferencesService.loadSystemPrompt();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading system prompt: $e');
      }
      return null;
    }
  }

  /// Resolve system prompt with project + artifact context.
  static Future<String?> resolveSystemPromptForSend({
    required String? cachedSystemPrompt,
    required String? selectedProjectId,
    required String? activeChatId,
  }) async {
    String? basePrompt;
    try {
      basePrompt = await UserPreferencesService.loadSystemPrompt();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Error resolving system prompt for send: $error');
      }
      basePrompt = cachedSystemPrompt;
    }

    var resolvedPrompt = basePrompt;

    // If a project is active, prepend project context.
    if (selectedProjectId != null) {
      try {
        final projectContext =
            await ProjectMessageService.buildProjectSystemMessage(
              selectedProjectId,
            );
        if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
          resolvedPrompt =
              '$projectContext\n\n---\n\nAdditional User Instructions:\n$resolvedPrompt';
        } else {
          resolvedPrompt = projectContext;
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Error building project system message: $error');
        }
      }
    }

    // Inject active artifact context for this chat (when feature is enabled).
    if (kFeatureArtifacts) {
      final chatId = activeChatId ?? ChatStorageService.selectedChatId;
      if (chatId != null && chatId.isNotEmpty) {
        try {
          final artifactContext =
              await ArtifactContextService.buildArtifactsSystemMessage(chatId);
          if (artifactContext != null && artifactContext.isNotEmpty) {
            if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
              resolvedPrompt = '$artifactContext\n\n---\n\n$resolvedPrompt';
            } else {
              resolvedPrompt = artifactContext;
            }
          }
        } catch (error) {
          if (kDebugMode) {
            debugPrint('Error building artifact system message: $error');
          }
        }
      }
    }

    return resolvedPrompt;
  }

  /// Convert a [ChatMessage] to a raw `Map<String, String>`.
  static Map<String, String> messageToRawMap(ChatMessage message) {
    final map = <String, String>{
      'sender': message.sender,
      'text': message.text,
      'reasoning': message.reasoning ?? '',
    };
    if (message.modelId != null && message.modelId!.isNotEmpty) {
      map['modelId'] = message.modelId!;
    }
    if (message.provider != null && message.provider!.isNotEmpty) {
      map['provider'] = message.provider!;
    }
    if (message.images != null && message.images!.isNotEmpty) {
      map['images'] = message.images!;
    }
    if (message.imageCostEur != null && message.imageCostEur!.isNotEmpty) {
      map['imageCostEur'] = message.imageCostEur!;
    }
    if (message.imageGeneratedAt != null &&
        message.imageGeneratedAt!.isNotEmpty) {
      map['imageGeneratedAt'] = message.imageGeneratedAt!;
    }
    if (message.attachments != null && message.attachments!.isNotEmpty) {
      map['attachments'] = message.attachments!;
    }
    if (message.attachedFilesJson != null &&
        message.attachedFilesJson!.isNotEmpty) {
      map['attachedFilesJson'] = message.attachedFilesJson!;
    }
    if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
      map['toolCalls'] = message.toolCalls!;
    }
    if (message.contentBlocks != null && message.contentBlocks!.isNotEmpty) {
      map['contentBlocks'] = message.contentBlocks!;
    }
    if (message.replyContext != null && message.replyContext!.isNotEmpty) {
      map['replyContext'] = message.replyContext!;
    }
    return map;
  }

  /// Finalize stale tool-call statuses in a raw message map.
  ///
  /// This heals orphaned `running/pending` tool calls that can remain after
  /// app/process interruptions. Returns `true` if the message was modified.
  static bool finalizeStaleToolCallsInRawMessage(Map<String, String> message) {
    var modified = false;

    final toolCallsJson = message['toolCalls'];
    if (toolCallsJson != null && toolCallsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(toolCallsJson);
        if (decoded is List) {
          final toolCalls = decoded
              .whereType<Map>()
              .map((item) => ToolCall.fromJson(Map<String, dynamic>.from(item)))
              .toList();
          if (_finalizeStaleToolCallsForRecovery(toolCalls)) {
            message['toolCalls'] = jsonEncode(
              toolCalls.map((call) => call.toJson()).toList(),
            );
            modified = true;
          }
        }
      } catch (_) {}
    }

    final contentBlocksJson = message['contentBlocks'];
    if (contentBlocksJson != null && contentBlocksJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(contentBlocksJson);
        if (decoded is List) {
          final blocks = decoded
              .whereType<Map>()
              .map(
                (item) =>
                    ContentBlock.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList();
          var blockModified = false;
          for (final block in blocks) {
            if (block.type == ContentBlockType.toolCalls &&
                block.toolCalls != null &&
                _finalizeStaleToolCallsForRecovery(block.toolCalls!)) {
              blockModified = true;
            }
          }
          if (blockModified) {
            message['contentBlocks'] = jsonEncode(
              blocks.map((block) => block.toJson()).toList(),
            );
            modified = true;
          }
        }
      } catch (_) {}
    }

    return modified;
  }

  static bool _finalizeStaleToolCallsForRecovery(List<ToolCall> toolCalls) {
    return finalizeStaleToolCalls(toolCalls);
  }

  /// Build a normalized JSON payload for a reply-to-block target.
  static String buildReplyContextJson({
    required int sourceMessageIndex,
    required int sourceBlockIndex,
    required String blockType,
    required String blockText,
  }) {
    final String normalized = blockText.trim();
    final String truncated = normalized.length > 2000
        ? '${normalized.substring(0, 2000)}...'
        : normalized;
    return jsonEncode({
      'sourceMessageIndex': sourceMessageIndex,
      'sourceBlockIndex': sourceBlockIndex,
      'blockType': blockType.trim().toLowerCase(),
      'blockText': truncated,
    });
  }

  /// Extract a short preview text from a stored reply context JSON payload.
  static String? extractReplyPreviewText(String? replyContextJson) {
    if (replyContextJson == null || replyContextJson.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(replyContextJson);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final String text = (map['blockText'] as String? ?? '').trim();
      if (text.isEmpty) return null;
      if (text.length <= _kReplyPreviewMaxChars) return text;
      return '${text.substring(0, _kReplyPreviewMaxChars)}...';
    } catch (_) {
      return null;
    }
  }

  /// Extract a human-readable label from reply context JSON.
  static String extractReplyPreviewLabel(String? replyContextJson) {
    if (replyContextJson == null || replyContextJson.trim().isEmpty) {
      return 'Reply to AI';
    }
    try {
      final decoded = jsonDecode(replyContextJson);
      if (decoded is! Map) return 'Reply to AI';
      final map = Map<String, dynamic>.from(decoded);
      final String blockType = (map['blockType'] as String? ?? 'text')
          .trim()
          .toLowerCase();
      switch (blockType) {
        case 'tool':
          return 'Reply to AI tool block';
        case 'reasoning':
          return 'Reply to AI reasoning';
        default:
          return 'Reply to AI text';
      }
    } catch (_) {
      return 'Reply to AI';
    }
  }

  /// Decode images from JSON with caching support.
  static List<String>? decodeImages(
    String json,
    Map<String, List<String>?> cache,
  ) {
    if (cache.containsKey(json)) {
      return cache[json];
    }
    List<String>? parsed;
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        parsed = decoded.cast<String>();
      }
    } catch (_) {}
    cache[json] = parsed;
    return parsed;
  }

  /// Decode document attachments from JSON with caching support.
  static List<DocumentAttachment>? decodeAttachments(
    String json,
    Map<String, List<DocumentAttachment>?> cache,
  ) {
    if (cache.containsKey(json)) {
      return cache[json];
    }
    List<DocumentAttachment>? parsed;
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        parsed = decoded
            .whereType<Map>()
            .map(
              (item) =>
                  DocumentAttachment.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
      }
    } catch (_) {}
    cache[json] = parsed;
    return parsed;
  }

  /// Decode tool calls from JSON with caching support.
  static List<ToolCall>? decodeToolCalls(
    String json,
    Map<String, List<ToolCall>?> cache,
  ) {
    if (cache.containsKey(json)) {
      return cache[json];
    }
    List<ToolCall>? parsed;
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        parsed = decoded
            .whereType<Map>()
            .map((item) => ToolCall.fromJson(Map<String, dynamic>.from(item)))
            .toList();
      }
    } catch (_) {}
    cache[json] = parsed;
    return parsed;
  }

  /// Decode content blocks from JSON with caching support.
  static List<ContentBlock>? decodeContentBlocks(
    String json,
    Map<String, List<ContentBlock>?> cache,
  ) {
    if (cache.containsKey(json)) {
      return cache[json];
    }
    List<ContentBlock>? parsed;
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        parsed = decoded
            .whereType<Map>()
            .map(
              (item) => ContentBlock.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
      }
    } catch (_) {}
    cache[json] = parsed;
    return parsed;
  }

  /// Trim decode caches if they get too large.
  static void trimCachesIfNeeded(List<Map<dynamic, dynamic>> caches) {
    const int maxEntriesPerCache = 240;
    for (final cache in caches) {
      if (cache.length > maxEntriesPerCache) {
        cache.clear();
      }
    }
  }

  /// Reconstruct [AttachedFile] objects from stored JSON for resend.
  static List<AttachedFile> reconstructAttachedFilesForResend(
    Map<String, String> message,
    Uuid uuid,
  ) {
    final attachedFiles = <AttachedFile>[];
    final String? attachedFilesJson = message['attachedFilesJson'];

    if (attachedFilesJson != null && attachedFilesJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(attachedFilesJson);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              attachedFiles.add(
                AttachedFile.fromJson(Map<String, dynamic>.from(item)),
              );
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to parse attachedFilesJson: $e');
        }
      }
    }

    if (attachedFiles.isNotEmpty) {
      return attachedFiles;
    }

    // Fallback for older messages.
    final String? attachmentsJson = message['attachments'];
    if (attachmentsJson != null && attachmentsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(attachmentsJson);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) {
            final data = Map<String, dynamic>.from(item);
            final String fileName = (data['fileName'] as String? ?? '').trim();
            final String markdownContent =
                (data['markdownContent'] as String? ?? '').trim();
            if (fileName.isEmpty || markdownContent.isEmpty) continue;
            attachedFiles.add(
              AttachedFile(
                id: uuid.v4(),
                fileName: fileName,
                markdownContent: markdownContent,
                isUploading: false,
                isImage: false,
              ),
            );
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to parse attachments JSON: $e');
        }
      }
    }

    return attachedFiles;
  }

  /// Extract the user's original query from display text that may include
  /// attachment headers.
  static String extractResendUserQuery(
    String displayText,
    List<AttachedFile> attachedFiles,
  ) {
    final text = displayText.trim();
    if (text.isEmpty || attachedFiles.isEmpty) return text;

    final separatorIndex = text.indexOf('\n\n');
    if (separatorIndex < 0) {
      return _looksLikeGeneratedAttachmentHeader(text) ? '' : text;
    }

    final header = text.substring(0, separatorIndex).trim();
    if (!_looksLikeGeneratedAttachmentHeader(header)) return text;

    return text.substring(separatorIndex + 2).trim();
  }

  static bool _looksLikeGeneratedAttachmentHeader(String text) {
    if (text.startsWith('Documents: ')) return true;
    return RegExp(r'^\d+ images? attached(?:, Documents: .+)?$').hasMatch(text);
  }

  /// Build the user prompt for resending with attachments.
  static String buildResendUserPrompt(
    String userQuery,
    List<AttachedFile> attachedFiles,
  ) {
    final normalizedQuery = userQuery.trim();
    final documentFiles = attachedFiles
        .where(
          (file) =>
              !file.isImage &&
              file.markdownContent != null &&
              file.markdownContent!.isNotEmpty,
        )
        .toList(growable: false);

    if (documentFiles.isEmpty) {
      if (normalizedQuery.isNotEmpty) return normalizedQuery;
      final hasImageAttachments = attachedFiles.any(
        (file) => file.isImage && file.encryptedImagePath != null,
      );
      return hasImageAttachments ? '1 image attached' : '';
    }

    final markdownSections = documentFiles
        .map((file) {
          final safeName = file.fileName
              .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
              .replaceAll('"', "'")
              .trim();
          final content = file.markdownContent ?? '';
          final fence = _buildMarkdownFence(content);
          return 'Document: "$safeName"\n$fence\n$content\n$fence';
        })
        .join('\n\n');

    final effectiveQuery = normalizedQuery.isNotEmpty
        ? normalizedQuery
        : 'Please review the uploaded documents.';

    return '$markdownSections\n\nUser query: $effectiveQuery';
  }

  static String _buildMarkdownFence(String content) {
    var maxBacktickRun = 0;
    for (final match in RegExp(r'`+').allMatches(content)) {
      final runLength = match.group(0)?.length ?? 0;
      if (runLength > maxBacktickRun) maxBacktickRun = runLength;
    }
    final fenceLength = math.max(3, maxBacktickRun + 1);
    return List<String>.filled(fenceLength, '`').join();
  }

  /// Detect image MIME type from byte header.
  static String detectImageMimeType(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'image/bmp';
    }
    return 'image/jpeg';
  }

  /// Build a [MessageRenderData] from a raw message map, using decode caches.
  static MessageRenderData buildMessageRenderData({
    required Map<String, String> raw,
    required int index,
    required int messageCount,
    required bool isStreaming,
    required Map<String, List<String>?> imagesCache,
    required Map<String, List<DocumentAttachment>?> attachmentsCache,
    required Map<String, List<ToolCall>?> toolCallsCache,
    required Map<String, List<ContentBlock>?> contentBlocksCache,
  }) {
    final String sender = raw['sender'] ?? 'ai';
    final String displayText = (raw['text'] ?? '').trimRight();
    final String reasoning = raw['reasoning'] ?? '';
    final bool isAiMessage = sender != 'user';
    final bool isStreamingMessage =
        isStreaming && index == messageCount - 1 && isAiMessage;
    final bool hasReasoning = reasoning.isNotEmpty;
    final String? modelLabel = isAiMessage
        ? formatModelInfo(raw['modelId'], raw['provider'])
        : null;
    final String? modelProvider = isAiMessage
        ? (raw['provider'] ?? '').trim()
        : null;

    List<String>? images;
    final String? imagesJson = raw['images'];
    if (imagesJson != null && imagesJson.isNotEmpty) {
      images = decodeImages(imagesJson, imagesCache);
    }

    List<DocumentAttachment>? attachments;
    final String? attachmentsJson = raw['attachments'];
    if (attachmentsJson != null && attachmentsJson.isNotEmpty) {
      attachments = decodeAttachments(attachmentsJson, attachmentsCache);
    }

    final tpsStr = raw['tps'];
    final double? tps = (tpsStr != null && tpsStr.isNotEmpty)
        ? double.tryParse(tpsStr)
        : null;

    List<ToolCall>? toolCalls;
    final String? toolCallsJson = raw['toolCalls'];
    if (toolCallsJson != null && toolCallsJson.isNotEmpty) {
      toolCalls = decodeToolCalls(toolCallsJson, toolCallsCache);
    }

    List<ContentBlock>? parsedContentBlocks;
    final String? contentBlocksJson = raw['contentBlocks'];
    if (contentBlocksJson != null && contentBlocksJson.isNotEmpty) {
      parsedContentBlocks = decodeContentBlocks(
        contentBlocksJson,
        contentBlocksCache,
      );
    }

    final String? imageCostStr = raw['imageCostEur'];
    final double? imageCostEur = imageCostStr != null && imageCostStr.isNotEmpty
        ? double.tryParse(imageCostStr)
        : null;
    final String? imageGeneratedAtStr = raw['imageGeneratedAt'];
    final DateTime? imageGeneratedAt =
        imageGeneratedAtStr != null && imageGeneratedAtStr.isNotEmpty
        ? DateTime.tryParse(imageGeneratedAtStr)
        : null;
    final String? replyContextJson = raw['replyContext'];
    final String? replyPreviewText = extractReplyPreviewText(replyContextJson);
    final String? replyPreviewLabel = replyPreviewText != null
        ? extractReplyPreviewLabel(replyContextJson)
        : null;

    return MessageRenderData(
      sender: sender,
      displayText: displayText,
      reasoning: reasoning,
      isReasoningStreaming:
          isStreamingMessage && (hasReasoning || displayText.isNotEmpty),
      modelLabel: modelLabel,
      modelProvider: modelProvider,
      tps: tps,
      images: images,
      imageCostEur: imageCostEur,
      imageGeneratedAt: imageGeneratedAt,
      attachments: attachments,
      toolCalls: toolCalls,
      contentBlocks: parsedContentBlocks,
      replyPreviewText: replyPreviewText,
      replyPreviewLabel: replyPreviewLabel,
      isStreamingMessage: isStreamingMessage,
    );
  }
}
