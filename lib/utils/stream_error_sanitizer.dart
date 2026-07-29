// lib/utils/stream_error_sanitizer.dart
//
// Shared by the native and web streaming managers. It lived only in the
// native one, so on web a raw exception went straight into the chat bubble —
// including the base64 fragments this exists to strip.

import 'package:chuk_chat/services/streaming_chat_service.dart';

/// Turns a transport exception into something safe and readable to show.
///
/// Upstream errors can carry a "413 Payload Too Large" body echoing base64
/// image data, or control bytes, which otherwise render verbatim as a garbled
/// wall of text (seen when sending several images at once). Keep it short,
/// printable, and free of leaked payload.
String sanitizeStreamError(Object error) {
  if (error is StreamingChatException && error.statusCode == 413) {
    return 'Attachments are too large to send. Try fewer or smaller images.';
  }

  // Collapse control/non-printable bytes that make the error look garbled.
  var msg = error.toString().replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ').trim();

  // A base64 / data-URL fragment leaked into the error — don't surface it.
  if (msg.contains('data:image/') ||
      RegExp(r'[A-Za-z0-9+/]{200,}').hasMatch(msg)) {
    return 'Failed to send attachments — they may be too large. '
        'Try fewer or smaller images.';
  }

  // Keep only the first line and cap the length so the bubble stays readable.
  final int newline = msg.indexOf('\n');
  if (newline >= 0) msg = msg.substring(0, newline).trim();
  const int maxLen = 200;
  if (msg.length > maxLen) msg = '${msg.substring(0, maxLen)}…';

  return msg.isEmpty ? 'Something went wrong. Please try again.' : msg;
}
