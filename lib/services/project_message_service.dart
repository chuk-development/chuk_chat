// lib/services/project_message_service.dart
import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:flutter/foundation.dart';

/// Service for composing AI messages with project context
class ProjectMessageService {
  // Maximum total content length to include in context (to avoid token limits)
  // This is for the actual text sent to LLM, not raw file sizes
  static const int maxTotalContentLength = 500000; // ~500KB of text content
  static const int maxChatHistoryContentLength =
      100000; // ~100KB for chat history

  /// Estimate how much content a file will add to the context
  static int _estimateContentLength(ProjectFile file) {
    // For files with markdown summaries (PDFs, etc.), use summary length
    if (file.hasMarkdownSummary) {
      return file.markdownSummary!.length + 200; // +200 for headers
    }
    // For PDFs without markdown, we only add a small note
    if (file.isPdf) {
      return 150; // Just a note saying content unavailable
    }
    // For images, just metadata
    if (file.isImage) {
      return 100;
    }
    // For text files, use file size as estimate (will be decrypted)
    return file.fileSize + 200; // +200 for code block markers
  }

  /// Build a system message with project context
  static Future<String> buildProjectSystemMessage(String projectId) async {
    final project = ProjectStorageService.getProject(projectId);
    if (project == null) {
      throw StateError('Project not found: $projectId');
    }

    final buffer = StringBuffer();

    // Project name and description
    buffer.writeln('You are working in the project: "${project.name}"');
    if (project.description != null && project.description!.trim().isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Project Description:');
      buffer.writeln(project.description!.trim());
    }

    // Custom system prompt
    if (project.hasCustomPrompt) {
      buffer.writeln();
      buffer.writeln('Custom System Prompt for this Project:');
      buffer.writeln(project.customSystemPrompt!.trim());
    }

    // File context
    if (project.files.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
      buffer.writeln('Available Files in this Project:');
      buffer.writeln();

      int totalContentLength = 0;
      final includedFiles = <ProjectFile>[];

      // Sort files by upload date (most recent first)
      final sortedFiles = List<ProjectFile>.from(project.files)
        ..sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));

      // Include files until we hit the size limit
      for (final file in sortedFiles) {
        // Estimate actual content length (markdown summary for PDFs, not raw file size)
        final estimatedLength = _estimateContentLength(file);
        if (totalContentLength + estimatedLength > maxTotalContentLength) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [ProjectMessage] Skipping file ${file.fileName} due to size limit '
              '(estimated: $estimatedLength, total: $totalContentLength, max: $maxTotalContentLength)',
            );
          }
          continue;
        }

        includedFiles.add(file);
        totalContentLength += estimatedLength;
      }

      // Include file contents (prefer markdown summary for non-text files like PDFs)
      for (final file in includedFiles) {
        try {
          buffer.writeln('### File: ${file.fileName}');
          buffer.writeln('- Type: ${file.fileType.toUpperCase()}');
          buffer.writeln('- Size: ${file.fileSizeFormatted}');
          buffer.writeln('- Uploaded: ${file.uploadedAt.toLocal()}');
          buffer.writeln();

          // For PDFs and other binary files, prefer the AI-generated markdown summary
          if (file.hasMarkdownSummary) {
            buffer.writeln(
              '**Document Summary (AI-generated from ${file.fileType.toUpperCase()}):**',
            );
            buffer.writeln();
            buffer.writeln(file.markdownSummary!);
          } else if (file.isPdf) {
            // PDF without markdown summary - note that content isn't directly readable
            buffer.writeln(
              '*This is a PDF document. The markdown summary is not yet available.*',
            );
            buffer.writeln(
              '*Consider re-uploading to generate an AI summary.*',
            );
          } else if (file.isImage) {
            // Image file - describe it
            buffer.writeln(
              '*This is an image file (${file.extension.toUpperCase()}).*',
            );
            if (file.hasMarkdownSummary) {
              buffer.writeln();
              buffer.writeln('**Image Analysis:**');
              buffer.writeln(file.markdownSummary!);
            }
          } else {
            // Text-based file - include actual content
            final content = await ProjectStorageService.decryptFile(file.id);
            buffer.writeln('**File Content:**');
            buffer.writeln('```${file.extension}');
            buffer.writeln(content);
            buffer.writeln('```');
          }

          buffer.writeln();
          buffer.writeln('---');
          buffer.writeln();
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '❌ [ProjectMessage] Failed to process file ${file.id}: $e',
            );
          }
          // Skip this file but continue with others
          buffer.writeln('File: ${file.fileName} (content unavailable)');
          buffer.writeln();
        }
      }

      // Note about excluded files
      final excludedCount = project.files.length - includedFiles.length;
      if (excludedCount > 0) {
        buffer.writeln(
          'Note: $excludedCount additional file(s) excluded due to size limits.',
        );
        buffer.writeln();
      }
    }

    // Include chat history from associated chats
    if (project.chatIds.isNotEmpty) {
      buffer.writeln('---');
      buffer.writeln();
      buffer.writeln('Previous Conversations in this Project:');
      buffer.writeln();

      int chatContentLength = 0;
      int includedChats = 0;

      for (final chatId in project.chatIds) {
        if (chatContentLength >= maxChatHistoryContentLength) {
          if (kDebugMode) {
            debugPrint(
              '⚠️ [ProjectMessage] Skipping remaining chats due to size limit',
            );
          }
          break;
        }

        try {
          final chat = ChatStorageService.getChatById(chatId);
          if (chat == null) continue;

          // Build chat summary
          final chatSummary = _buildChatSummary(
            chat,
            maxChatHistoryContentLength - chatContentLength,
          );
          if (chatSummary.isEmpty) continue;

          final chatTitle = chat.customName ?? chat.previewText;
          buffer.writeln('### Chat: $chatTitle');
          buffer.writeln(
            '(${chat.messages.length} messages, ${_formatDate(chat.createdAt)})',
          );
          buffer.writeln();
          buffer.writeln(chatSummary);
          buffer.writeln();
          buffer.writeln('---');
          buffer.writeln();

          chatContentLength += chatSummary.length;
          includedChats++;
        } catch (e) {
          if (kDebugMode) {
            debugPrint('⚠️ [ProjectMessage] Failed to load chat $chatId: $e');
          }
        }
      }

      final excludedChats = project.chatIds.length - includedChats;
      if (excludedChats > 0) {
        buffer.writeln(
          'Note: $excludedChats additional chat(s) excluded due to size limits.',
        );
        buffer.writeln();
      }
    }

    buffer.writeln('---');
    buffer.writeln();
    buffer.writeln(
      'Please use the above project context, files, chat history, and custom instructions when responding to the user.',
    );

    return buffer.toString();
  }

  /// Build a summary of chat messages (up to maxLength characters)
  static String _buildChatSummary(StoredChat chat, int maxLength) {
    final buffer = StringBuffer();

    for (final message in chat.messages) {
      final role = message.role == 'user' ? 'User' : 'Assistant';
      final content = message.text.trim();
      if (content.isEmpty) continue;

      // Truncate very long messages
      final truncatedContent = content.length > 2000
          ? '${content.substring(0, 2000)}... [truncated]'
          : content;

      final line = '**$role:** $truncatedContent\n\n';

      if (buffer.length + line.length > maxLength) {
        buffer.writeln('... [earlier messages truncated]');
        break;
      }

      buffer.write(line);
    }

    return buffer.toString();
  }

  /// Format date for display
  static String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return 'today';
    } else if (diff.inDays == 1) {
      return 'yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  /// Inject project context into message list
  /// Prepends a system message with project context to the conversation
  static Future<List<Map<String, dynamic>>> injectProjectContext(
    String projectId,
    List<Map<String, dynamic>> messages,
  ) async {
    try {
      final projectSystemMessage = await buildProjectSystemMessage(projectId);

      // Create system message
      final systemMessage = {'role': 'system', 'text': projectSystemMessage};

      // Prepend to messages
      return [systemMessage, ...messages];
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('❌ [ProjectMessage] Failed to inject context: $e\n$st');
      }
      // Return original messages if context injection fails
      return messages;
    }
  }

  /// Get a summary of project context (for UI display)
  static String getProjectContextSummary(Project project) {
    final parts = <String>[];

    if (project.hasCustomPrompt) {
      parts.add('Custom prompt');
    }

    if (project.fileCount > 0) {
      parts.add(
        '${project.fileCount} file${project.fileCount == 1 ? '' : 's'}',
      );
    }

    if (project.chatCount > 0) {
      parts.add(
        '${project.chatCount} chat${project.chatCount == 1 ? '' : 's'}',
      );
    }

    if (parts.isEmpty) {
      return 'No context';
    }

    return parts.join(' • ');
  }

  /// Check if a project has meaningful context
  static bool hasContext(Project project) {
    return project.hasCustomPrompt ||
        project.fileCount > 0 ||
        project.chatCount > 0;
  }

  // ============ CONTEXT BUDGET ============

  /// Estimate total tokens for all files in a project.
  static int estimateTotalFileTokens(Project project) {
    int total = 0;
    for (final file in project.files) {
      total += file.estimatedTokens;
    }
    return total;
  }

  /// Estimate total tokens used by the project context (files + chats + prompt).
  /// This is an approximate upper bound of what buildProjectSystemMessage produces.
  static int estimateProjectContextTokens(Project project) {
    int total = 0;

    // Project header (~50 tokens for name + description)
    total += 50;

    // Custom system prompt
    if (project.hasCustomPrompt) {
      total += (project.customSystemPrompt!.length / 4).ceil() + 10;
    }

    // Files
    total += estimateTotalFileTokens(project);

    // Chat history estimate aligned to actual prompt cap:
    // up to ~100k chars (~25k tokens) total across linked chats.
    final estimatedChatTokens = project.chatCount * 2000;
    final chatTokenCap = maxChatHistoryContentLength ~/ 4;
    total += estimatedChatTokens > chatTokenCap
        ? chatTokenCap
        : estimatedChatTokens;

    return total;
  }

  /// Get the context window size for the currently selected model.
  /// Returns null if unknown.
  static int? getModelContextWindow(String? modelId) {
    if (modelId == null || modelId.isEmpty) return null;
    final limits = ModelSelectionDropdown.providerLimitsForModel(modelId);
    return limits?.contextLength;
  }

  /// Calculate what % of the model's context window the project would use.
  /// Returns null if model context window is unknown.
  /// Value is 0.0 to 1.0+.
  static double? contextUsageRatio(Project project, String? modelId) {
    final contextWindow = getModelContextWindow(modelId);
    if (contextWindow == null || contextWindow <= 0) return null;
    final projectTokens = estimateProjectContextTokens(project);
    return projectTokens / contextWindow;
  }

  /// Calculate what % of the model's context a single file would use.
  /// Returns null if model context window is unknown.
  static double? fileContextRatio(ProjectFile file, String? modelId) {
    final contextWindow = getModelContextWindow(modelId);
    if (contextWindow == null || contextWindow <= 0) return null;
    return file.estimatedTokens / contextWindow;
  }

  /// Check whether adding [newFileTokens] additional tokens would exceed
  /// a reasonable budget (e.g. 75% of context reserved for project files).
  /// Returns remaining token capacity, or negative if over budget.
  static int remainingFileTokenBudget(Project project, String? modelId) {
    final contextWindow = getModelContextWindow(modelId);
    if (contextWindow == null || contextWindow <= 0) {
      // Unknown context window - use the service's hard limit
      return maxTotalContentLength ~/ 4 - estimateTotalFileTokens(project);
    }
    // Reserve 25% of context for conversation + response
    final fileBudget = (contextWindow * 0.75).round();
    return fileBudget - estimateTotalFileTokens(project);
  }
}
