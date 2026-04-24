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

  // Explicitly drop a value without linter warnings.
  static void _noop(Object? _) {}

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

      // Reasoning (truncated — full dumps dominate the export)
      if (reasoning.trim().isNotEmpty) {
        final trimmed = reasoning.trim();
        buf.writeln('Reasoning:');
        if (trimmed.length > 400) {
          buf.writeln(
            '${trimmed.substring(0, 400)}... (${trimmed.length} chars total)',
          );
        } else {
          buf.writeln(trimmed);
        }
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
              // Thinking is a duplicate of the message Reasoning block —
              // omit to keep the export compact.
              if (args != null && args is Map && args.isNotEmpty) {
                try {
                  final argsStr = jsonEncode(args);
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
                // roundThinking intentionally omitted to reduce noise
                _noop(roundThinking);
              }
              if (result != null && result.toString().trim().isNotEmpty) {
                final resultStr = ClipboardTextSanitizer.sanitize(
                  result.toString().trim(),
                );
                if (resultStr.length > 250) {
                  buf.writeln(
                    '    Result: ${resultStr.substring(0, 250)}... '
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

      // Content blocks — collapsed to a one-line type sequence since the
      // text / reasoning / toolCalls fields above already carry the content.
      if (contentBlocksJson.isNotEmpty) {
        try {
          final List<dynamic> blocks = jsonDecode(contentBlocksJson) as List;
          if (blocks.isNotEmpty) {
            final types = blocks
                .whereType<Map>()
                .map((b) => (b['type'] ?? 'text').toString())
                .join(' → ');
            buf.writeln('Block Order: $types');
            buf.writeln();
          }
        } catch (_) {
          // Skip malformed blocks silently — redundant with text field.
        }
      }

      // Raw request payloads — only a compact summary (count + size).
      if (debugRequestsJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(debugRequestsJson);
          if (decoded is List) {
            buf.writeln(
              'Request Payloads: ${decoded.length} pass(es), '
              '${debugRequestsJson.length} chars total',
            );
          } else {
            buf.writeln(
              'Request Payloads: ${debugRequestsJson.length} chars',
            );
          }
        } catch (_) {
          buf.writeln(
            'Request Payloads: ${debugRequestsJson.length} chars (unparsed)',
          );
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
