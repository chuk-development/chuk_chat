// lib/services/message_composition_service.dart
import 'dart:convert';
import 'dart:math' as math;
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/input_validator.dart';
import 'package:chuk_chat/utils/token_estimator.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:flutter/foundation.dart';

/// Result of message composition preparation
class MessageCompositionResult {
  final bool isValid;
  final String? errorMessage;
  final String? displayMessageText;
  final String? aiPromptContent;
  final String? accessToken;
  final String? providerSlug;
  final int? maxResponseTokens;
  final String? effectiveSystemPrompt;
  final List<String>? images;

  const MessageCompositionResult({
    required this.isValid,
    this.errorMessage,
    this.displayMessageText,
    this.aiPromptContent,
    this.accessToken,
    this.providerSlug,
    this.maxResponseTokens,
    this.effectiveSystemPrompt,
    this.images,
  });

  factory MessageCompositionResult.error(String message) {
    return MessageCompositionResult(isValid: false, errorMessage: message);
  }

  factory MessageCompositionResult.success({
    required String displayMessageText,
    required String aiPromptContent,
    required String accessToken,
    required String providerSlug,
    required int maxResponseTokens,
    String? effectiveSystemPrompt,
    List<String>? images,
  }) {
    return MessageCompositionResult(
      isValid: true,
      displayMessageText: displayMessageText,
      aiPromptContent: aiPromptContent,
      accessToken: accessToken,
      providerSlug: providerSlug,
      maxResponseTokens: maxResponseTokens,
      effectiveSystemPrompt: effectiveSystemPrompt,
      images: images,
    );
  }
}

/// Service for composing and validating chat messages before sending
class MessageCompositionService {
  const MessageCompositionService._();

  /// Prepare a message for sending with all necessary validation and processing
  static Future<MessageCompositionResult> prepareMessage({
    required String userInput,
    required List<AttachedFile> attachedFiles,
    required String selectedModelId,
    required List<Map<String, String>> apiHistory,
    String? systemPrompt,
    required Future<String?> Function() getProviderSlug,
  }) async {
    // Validate message length
    if (userInput.isNotEmpty) {
      final validationResult = InputValidator.validateAndSanitizeMessage(
        userInput,
      );
      if (!validationResult['valid']) {
        return MessageCompositionResult.error(
          validationResult['error'] ?? 'Invalid input',
        );
      }
    }

    // Check if there's content to send
    final bool hasText = userInput.isNotEmpty;
    final bool hasAttachments = attachedFiles.any(
      (f) => f.markdownContent != null || f.encryptedImagePath != null,
    );

    if (!hasText && !hasAttachments) {
      return MessageCompositionResult.error('No content to send');
    }

    // Build display message and AI prompt with attachments
    final messageContent = await _buildMessageContent(
      userInput: userInput,
      attachedFiles: attachedFiles,
    );

    // Refresh session and get access token
    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;

    if (session == null) {
      return MessageCompositionResult.error(
        'Session expired. Please sign in again.',
      );
    }

    final String accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      return MessageCompositionResult.error(
        'Unable to authenticate your session.',
      );
    }

    // Get provider slug for the model
    final String? providerSlug = await getProviderSlug();
    if (providerSlug == null || providerSlug.isEmpty) {
      return MessageCompositionResult.error(
        'No provider is configured for $selectedModelId. '
        'Select a provider in Settings and try again.',
      );
    }

    // Prepare system prompt
    final String? effectiveSystemPrompt =
        (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        ? systemPrompt
        : null;

    // Calculate token limits
    final tokenLimits = _calculateTokenLimits(
      selectedModelId: selectedModelId,
      apiHistory: apiHistory,
      aiPromptContent: messageContent.aiPromptContent,
      systemPrompt: effectiveSystemPrompt,
    );

    if (!tokenLimits.isValid) {
      return MessageCompositionResult.error(tokenLimits.errorMessage!);
    }

    return MessageCompositionResult.success(
      displayMessageText: messageContent.displayText,
      aiPromptContent: messageContent.aiPromptContent,
      accessToken: accessToken,
      providerSlug: providerSlug,
      maxResponseTokens: tokenLimits.maxResponseTokens!,
      effectiveSystemPrompt: effectiveSystemPrompt,
      images: messageContent.images.isNotEmpty ? messageContent.images : null,
    );
  }

  /// Build message content with attachments
  static Future<_MessageContent> _buildMessageContent({
    required String userInput,
    required List<AttachedFile> attachedFiles,
  }) async {
    String displayMessageText = userInput;
    String aiPromptContent = userInput;

    final bool hasAttachments = attachedFiles.any(
      (f) => f.markdownContent != null || f.encryptedImagePath != null,
    );

    if (hasAttachments) {
      // Separate images from documents
      final imageFiles = attachedFiles
          .where((f) => f.isImage && f.encryptedImagePath != null)
          .toList();
      final documentFiles = attachedFiles
          .where((f) => !f.isImage && f.markdownContent != null)
          .toList();

      // Build display message with attachment names
      final attachmentNames = <String>[];
      if (imageFiles.isNotEmpty) {
        final imageNames = imageFiles
            .map((f) {
              final sanitized = InputValidator.sanitizeFileName(f.fileName);
              final escaped = InputValidator.escapeFileNameForDisplay(
                sanitized,
              );
              return '"$escaped"';
            })
            .join(', ');
        attachmentNames.add('Images: $imageNames');
      }
      if (documentFiles.isNotEmpty) {
        final docNames = documentFiles
            .map((f) {
              final sanitized = InputValidator.sanitizeFileName(f.fileName);
              final escaped = InputValidator.escapeFileNameForDisplay(
                sanitized,
              );
              return '"$escaped"';
            })
            .join(', ');
        attachmentNames.add('Documents: $docNames');
      }

      if (attachmentNames.isNotEmpty) {
        final String attachmentsLine = attachmentNames.join(', ');
        if (displayMessageText.isNotEmpty) {
          displayMessageText = '$attachmentsLine\n\n$displayMessageText';
        } else {
          displayMessageText = attachmentsLine;
        }
      }

      // Build AI prompt with attachments
      final promptParts = <String>[];
      final imageDataUrls = <String>[];

      // Prepare encrypted images as base64 data URLs
      if (imageFiles.isNotEmpty) {
        for (final imageFile in imageFiles) {
          try {
            // Download and decrypt image
            final imageBytes =
                await ImageStorageService.downloadAndDecryptImage(
                  imageFile.encryptedImagePath!,
                );
            // Convert to base64 data URL (JPEG format)
            final base64Image = base64Encode(imageBytes);
            final dataUrl = 'data:image/jpeg;base64,$base64Image';
            imageDataUrls.add(dataUrl);
          } catch (e) {
            debugPrint(
              'Failed to load encrypted image ${imageFile.fileName}: $e',
            );
            // Skip failed images
          }
        }
      }

      // Add documents with markdown content
      if (documentFiles.isNotEmpty) {
        final markdownSections = documentFiles
            .map((f) {
              final sanitized = InputValidator.sanitizeFileName(f.fileName);
              final escaped = InputValidator.escapeFileNameForDisplay(
                sanitized,
              );
              return 'Document: "$escaped"\n```\n${f.markdownContent}\n```';
            })
            .join('\n\n');
        promptParts.add(markdownSections);
      }

      final String queryText = userInput.isNotEmpty
          ? userInput
          : (imageFiles.isNotEmpty
                ? 'Please describe these images.'
                : 'Please review the uploaded documents.');

      if (promptParts.isNotEmpty) {
        aiPromptContent =
            '${promptParts.join('\n\n')}\n\nUser query: $queryText';
      } else {
        aiPromptContent = queryText;
      }

      return _MessageContent(
        displayText: displayMessageText,
        aiPromptContent: aiPromptContent,
        images: imageDataUrls,
      );
    }

    return _MessageContent(
      displayText: displayMessageText,
      aiPromptContent: aiPromptContent,
    );
  }

  /// Calculate token limits and validate context length
  static _TokenLimits _calculateTokenLimits({
    required String selectedModelId,
    required List<Map<String, String>> apiHistory,
    required String aiPromptContent,
    String? systemPrompt,
  }) {
    final ModelProviderLimits? providerLimits =
        ModelSelectionDropdown.providerLimitsForModel(selectedModelId);

    final int promptTokens = TokenEstimator.estimatePromptTokens(
      history: apiHistory,
      currentMessage: aiPromptContent,
      systemPrompt: systemPrompt,
    );

    int maxResponseTokens = 512; // Default

    if (providerLimits?.contextLength != null &&
        providerLimits!.contextLength! > 0) {
      final int contextLength = providerLimits.contextLength!;

      // Check if prompt exceeds context length
      if (promptTokens >= contextLength) {
        return _TokenLimits.error(
          'Too much context for this model '
          '($promptTokens vs $contextLength token limit). '
          'Clear history or shorten your message.',
        );
      }

      // Calculate max response tokens
      final int availableForCompletion = contextLength - promptTokens;
      final int completionCap =
          providerLimits.maxCompletionTokens != null &&
              providerLimits.maxCompletionTokens! > 0
          ? providerLimits.maxCompletionTokens!
          : math.max(256, contextLength ~/ 4);

      maxResponseTokens = math.max(
        1,
        math.min(completionCap, availableForCompletion),
      );

      if (kDebugMode) {
        debugPrint(
          'Prompt tokens (est): $promptTokens / $contextLength, '
          'max completion tokens: $maxResponseTokens',
        );
      }
    } else {
      if (kDebugMode) {
        debugPrint(
          'Prompt tokens (est): $promptTokens (no context limit data)',
        );
      }
    }

    return _TokenLimits.success(maxResponseTokens);
  }
}

/// Internal class for message content
class _MessageContent {
  final String displayText;
  final String aiPromptContent;
  final List<String> images;

  const _MessageContent({
    required this.displayText,
    required this.aiPromptContent,
    this.images = const [],
  });
}

/// Internal class for token limits
class _TokenLimits {
  final bool isValid;
  final String? errorMessage;
  final int? maxResponseTokens;

  const _TokenLimits({
    required this.isValid,
    this.errorMessage,
    this.maxResponseTokens,
  });

  factory _TokenLimits.error(String message) {
    return _TokenLimits(isValid: false, errorMessage: message);
  }

  factory _TokenLimits.success(int maxResponseTokens) {
    return _TokenLimits(isValid: true, maxResponseTokens: maxResponseTokens);
  }
}
