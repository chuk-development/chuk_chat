// lib/utils/debug_chat_formatter.dart

import 'dart:convert';

/// Formats the full chat message list as a debug-friendly text string.
///
/// Includes ALL fields: role, text, reasoning, tool calls (name, arguments,
/// result, status), model ID, provider, images metadata, and attachments.
/// Intended for clipboard copy to aid debugging.
class DebugChatFormatter {
  const DebugChatFormatter._();

  /// Format a list of message maps (as used by chat UIs) into a debug string.
  static String format(List<Map<String, String>> messages) {
    if (messages.isEmpty) return '(empty chat)';

    final buf = StringBuffer();
    buf.writeln('=== Debug Chat Export ===');
    buf.writeln('Messages: ${messages.length}');
    buf.writeln('Exported: ${DateTime.now().toUtc().toIso8601String()}');
    buf.writeln();

    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final role = m['sender'] ?? m['role'] ?? 'unknown';
      final text = m['text'] ?? '';
      final reasoning = m['reasoning'] ?? '';
      final modelId = m['modelId'] ?? '';
      final provider = m['provider'] ?? '';
      final toolCallsJson = m['toolCalls'] ?? '';
      final images = m['images'] ?? '';
      final imageCostEur = m['imageCostEur'] ?? '';
      final imageGeneratedAt = m['imageGeneratedAt'] ?? '';
      final attachments = m['attachments'] ?? '';
      final attachedFilesJson = m['attachedFilesJson'] ?? '';

      buf.writeln('--- Message ${i + 1} [$role] ---');

      // Model info
      if (modelId.isNotEmpty) {
        buf.write('Model: $modelId');
        if (provider.isNotEmpty) buf.write(' ($provider)');
        buf.writeln();
      }

      // Reasoning
      if (reasoning.trim().isNotEmpty) {
        buf.writeln('Reasoning:');
        buf.writeln(reasoning.trim());
        buf.writeln();
      }

      // Tool calls
      if (toolCallsJson.isNotEmpty) {
        buf.writeln('Tool Calls:');
        try {
          final List<dynamic> calls = jsonDecode(toolCallsJson) as List;
          for (final call in calls) {
            if (call is Map) {
              final name = call['name'] ?? '?';
              final callStatus = call['status'] ?? 'unknown';
              final args = call['arguments'];
              final result = call['result'];
              final roundThinking = call['roundThinking'];

              buf.writeln('  [$callStatus] $name');
              if (roundThinking != null &&
                  roundThinking.toString().trim().isNotEmpty) {
                buf.writeln('    Thinking: ${roundThinking.toString().trim()}');
              }
              if (args != null && args is Map && args.isNotEmpty) {
                try {
                  final argsStr = const JsonEncoder.withIndent(
                    '    ',
                  ).convert(args);
                  buf.writeln('    Args: $argsStr');
                } catch (_) {
                  buf.writeln('    Args: $args');
                }
              }
              if (result != null && result.toString().trim().isNotEmpty) {
                final resultStr = result.toString().trim();
                if (resultStr.length > 500) {
                  buf.writeln(
                    '    Result: ${resultStr.substring(0, 500)}... '
                    '(${resultStr.length} chars)',
                  );
                } else {
                  buf.writeln('    Result: $resultStr');
                }
              }
            }
          }
        } catch (_) {
          // Not valid JSON — dump raw
          buf.writeln('  (raw): $toolCallsJson');
        }
        buf.writeln();
      }

      // Message text
      if (text.trim().isNotEmpty) {
        buf.writeln('Text:');
        buf.writeln(text.trim());
        buf.writeln();
      }

      // Images
      if (images.isNotEmpty) {
        buf.writeln('Images: $images');
        if (imageCostEur.isNotEmpty) buf.writeln('Image Cost: €$imageCostEur');
        if (imageGeneratedAt.isNotEmpty) {
          buf.writeln('Image Generated: $imageGeneratedAt');
        }
        buf.writeln();
      }

      // Attachments
      if (attachments.isNotEmpty) {
        buf.writeln('Attachments: $attachments');
      }
      if (attachedFilesJson.isNotEmpty) {
        buf.writeln('Attached Files: $attachedFilesJson');
      }

      buf.writeln();
    }

    return buf.toString();
  }
}
