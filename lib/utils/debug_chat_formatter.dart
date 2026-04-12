// lib/utils/debug_chat_formatter.dart

import 'dart:convert';

import 'package:chuk_chat/utils/clipboard_text_sanitizer.dart';

/// Formats the full chat message list as a debug-friendly text string.
///
/// Includes ALL fields: role, text, reasoning, tool calls (name, arguments,
/// result, status), model ID, provider, redacted image metadata,
/// and attachments.
/// Intended for clipboard copy to aid debugging.
class DebugChatFormatter {
  const DebugChatFormatter._();

  static int _countImages(String rawImages) {
    if (rawImages.trim().isEmpty) {
      return 0;
    }

    try {
      final decoded = jsonDecode(rawImages);
      if (decoded is List) {
        return decoded.length;
      }
    } catch (_) {}

    return 1;
  }

  /// Format a list of message maps (as used by chat UIs) into a debug string.
  ///
  /// Optional context — when supplied — is rendered above the message list so
  /// a pasted debug log is self-contained:
  /// - [systemPrompt]: the resolved system prompt sent with requests.
  /// - [context]: ordered key/value pairs (model, provider, workspace, flags).
  ///   Use a LinkedHashMap (or plain literal) for a stable order.
  static String format(
    List<Map<String, String>> messages, {
    String? systemPrompt,
    Map<String, String>? context,
  }) {
    final hasContext = systemPrompt != null && systemPrompt.trim().isNotEmpty ||
        (context != null && context.isNotEmpty);

    if (messages.isEmpty && !hasContext) return '(empty chat)';

    final buf = StringBuffer();
    buf.writeln('=== Debug Chat Export ===');
    buf.writeln('Messages: ${messages.length}');
    buf.writeln('Exported: ${DateTime.now().toUtc().toIso8601String()}');
    buf.writeln();

    if (context != null && context.isNotEmpty) {
      buf.writeln('--- Context ---');
      context.forEach((k, v) {
        if (v.trim().isEmpty) return;
        buf.writeln(
          '$k: ${ClipboardTextSanitizer.sanitize(v).trim()}',
        );
      });
      buf.writeln();
    }

    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      buf.writeln('--- System Prompt ---');
      buf.writeln(ClipboardTextSanitizer.sanitize(systemPrompt).trim());
      buf.writeln();
    }

    if (messages.isEmpty) {
      return ClipboardTextSanitizer.sanitize(buf.toString());
    }

    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final role = m['sender'] ?? m['role'] ?? 'unknown';
      final text = ClipboardTextSanitizer.sanitize(m['text'] ?? '');
      final reasoning = ClipboardTextSanitizer.sanitize(m['reasoning'] ?? '');
      final modelId = m['modelId'] ?? '';
      final provider = m['provider'] ?? '';
      final toolCallsJson = m['toolCalls'] ?? '';
      final images = m['images'] ?? '';
      final imageCostEur = m['imageCostEur'] ?? '';
      final imageGeneratedAt = m['imageGeneratedAt'] ?? '';
      final attachments = ClipboardTextSanitizer.sanitize(
        m['attachments'] ?? '',
      );
      final attachedFilesJson = ClipboardTextSanitizer.sanitize(
        m['attachedFilesJson'] ?? '',
      );
      final contentBlocksJson = m['contentBlocks'] ?? '';
      final debugRequestsJson = m['debugRequests'] ?? '';

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
                  final sanitizedArgs = ClipboardTextSanitizer.sanitize(
                    argsStr,
                  );
                  buf.writeln('    Args: $sanitizedArgs');
                } catch (_) {
                  final sanitizedArgs = ClipboardTextSanitizer.sanitize(
                    args.toString(),
                  );
                  buf.writeln('    Args: $sanitizedArgs');
                }
              }
              if (result != null && result.toString().trim().isNotEmpty) {
                final resultStr = ClipboardTextSanitizer.sanitize(
                  result.toString().trim(),
                );
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
          final sanitizedRaw = ClipboardTextSanitizer.sanitize(toolCallsJson);
          buf.writeln('  (raw): $sanitizedRaw');
        }
        buf.writeln();
      }

      // Content blocks
      if (contentBlocksJson.isNotEmpty) {
        buf.writeln('Content Blocks:');
        try {
          final List<dynamic> blocks = jsonDecode(contentBlocksJson) as List;
          for (var bi = 0; bi < blocks.length; bi++) {
            final block = blocks[bi];
            if (block is! Map) continue;
            final type = (block['type'] ?? 'text').toString();
            buf.writeln('  [$bi] type=$type');
            final textValue = block['text']?.toString() ?? '';
            if (textValue.trim().isNotEmpty) {
              final sanitizedBlockText = ClipboardTextSanitizer.sanitize(
                textValue.trim(),
              );
              buf.writeln('    text: $sanitizedBlockText');
            }
            final rawCalls = block['toolCalls'];
            if (rawCalls is List && rawCalls.isNotEmpty) {
              buf.writeln('    toolCalls: ${rawCalls.length}');
            }
          }
        } catch (_) {
          final sanitizedRaw = ClipboardTextSanitizer.sanitize(
            contentBlocksJson,
          );
          buf.writeln('  (raw): $sanitizedRaw');
        }
        buf.writeln();
      }

      // Raw request payloads sent during streaming passes
      if (debugRequestsJson.isNotEmpty) {
        buf.writeln('Request Payloads Sent:');
        try {
          final decoded = jsonDecode(debugRequestsJson);
          final pretty = const JsonEncoder.withIndent('  ').convert(decoded);
          final sanitizedPretty = ClipboardTextSanitizer.sanitize(pretty);
          buf.writeln(sanitizedPretty);
        } catch (_) {
          final sanitizedRaw = ClipboardTextSanitizer.sanitize(
            debugRequestsJson,
          );
          buf.writeln(sanitizedRaw);
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
        final imageCount = _countImages(images);
        if (imageCount > 0) {
          buf.writeln('Images: $imageCount (content omitted from clipboard)');
        } else {
          buf.writeln('Images: (content omitted from clipboard)');
        }
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

    return ClipboardTextSanitizer.sanitize(buf.toString());
  }
}
