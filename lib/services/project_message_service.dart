// lib/services/project_message_service.dart
import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:flutter/foundation.dart';

/// Service for composing AI messages with project context
class ProjectMessageService {
  // Maximum total file content length to include in context (to avoid token limits)
  static const int maxTotalFileContentLength = 50000; // ~50KB

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
        // Estimate content length (file size is a rough proxy)
        if (totalContentLength + file.fileSize > maxTotalFileContentLength) {
          debugPrint(
            '⚠️ [ProjectMessage] Skipping file ${file.fileName} due to size limit',
          );
          continue;
        }

        includedFiles.add(file);
        totalContentLength += file.fileSize;
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
            buffer.writeln('**Document Summary (AI-generated from ${file.fileType.toUpperCase()}):**');
            buffer.writeln();
            buffer.writeln(file.markdownSummary!);
          } else if (file.isPdf) {
            // PDF without markdown summary - note that content isn't directly readable
            buffer.writeln('*This is a PDF document. The markdown summary is not yet available.*');
            buffer.writeln('*Consider re-uploading to generate an AI summary.*');
          } else if (file.isImage) {
            // Image file - describe it
            buffer.writeln('*This is an image file (${file.extension.toUpperCase()}).*');
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
          debugPrint('❌ [ProjectMessage] Failed to process file ${file.id}: $e');
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

    buffer.writeln('---');
    buffer.writeln();
    buffer.writeln(
      'Please use the above project context, files, and custom instructions when responding to the user.',
    );

    return buffer.toString();
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
      final systemMessage = {
        'role': 'system',
        'text': projectSystemMessage,
      };

      // Prepend to messages
      return [systemMessage, ...messages];
    } catch (e, st) {
      debugPrint('❌ [ProjectMessage] Failed to inject context: $e\n$st');
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
      parts.add('${project.fileCount} file${project.fileCount == 1 ? '' : 's'}');
    }

    if (project.chatCount > 0) {
      parts.add('${project.chatCount} chat${project.chatCount == 1 ? '' : 's'}');
    }

    if (parts.isEmpty) {
      return 'No context';
    }

    return parts.join(' • ');
  }

  /// Check if a project has meaningful context
  static bool hasContext(Project project) {
    return project.hasCustomPrompt || project.fileCount > 0;
  }
}
