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

  static const int _maxContextValueChars = 220;
  static const int _maxReasoningChars = 400;
  static const int _maxMessageTextChars = 2200;
  static const int _maxToolArgsChars = 320;
  static const int _maxToolResultChars = 250;
  static const int _maxAttachmentsChars = 420;

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

  static String _truncateForExport(String value, {required int maxChars}) {
    final trimmed = value.trim();
    if (trimmed.length <= maxChars) {
      return trimmed;
    }
    return '${trimmed.substring(0, maxChars)}... '
        '(${trimmed.length} chars total)';
  }

  /// Format a list of message maps (as used by chat UIs) into a debug string.
  ///
  /// Optional context — when supplied — is rendered above the message list so
  /// a pasted debug log is self-contained:
  /// - [context]: ordered key/value pairs (model, provider, workspace, flags).
  ///   Use a LinkedHashMap (or plain literal) for a stable order.
  ///
  /// The resolved system prompt is deliberately NOT included: it can carry
  /// sensitive or injected instructions, and a debug copy is meant to capture
  /// the *conversation*, not the prompt scaffolding.
  static String format(
    List<Map<String, String>> messages, {
    Map<String, String>? context,
  }) {
    final hasContext = context != null && context.isNotEmpty;

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
        final compactValue = _truncateForExport(
          ClipboardTextSanitizer.sanitize(v),
          maxChars: _maxContextValueChars,
        );
        buf.writeln('$k: $compactValue');
      });
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
        buf.writeln(_truncateForExport(trimmed, maxChars: _maxReasoningChars));
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
                  buf.writeln(
                    '    Args: ${_truncateForExport(sanitizedArgs, maxChars: _maxToolArgsChars)}',
                  );
                } catch (_) {
                  final sanitizedArgs = ClipboardTextSanitizer.sanitize(
                    args.toString(),
                  );
                  buf.writeln(
                    '    Args: ${_truncateForExport(sanitizedArgs, maxChars: _maxToolArgsChars)}',
                  );
                }
                // roundThinking intentionally omitted to reduce noise
                _noop(roundThinking);
              }
              if (result != null && result.toString().trim().isNotEmpty) {
                final resultStr = ClipboardTextSanitizer.sanitize(
                  result.toString().trim(),
                );
                buf.writeln(
                  '    Result: ${_truncateForExport(resultStr, maxChars: _maxToolResultChars)}',
                );
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
            buf.writeln('Request Payloads: ${debugRequestsJson.length} chars');
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
        buf.writeln(_truncateForExport(text, maxChars: _maxMessageTextChars));
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
        buf.writeln(
          'Attachments: ${_truncateForExport(attachments, maxChars: _maxAttachmentsChars)}',
        );
      }
      if (attachedFilesJson.isNotEmpty) {
        buf.writeln(
          'Attached Files: ${_truncateForExport(attachedFilesJson, maxChars: _maxAttachmentsChars)}',
        );
      }

      buf.writeln();
    }

    return ClipboardTextSanitizer.sanitize(buf.toString());
  }
}
