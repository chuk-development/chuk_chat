// lib/platform_specific/chat/voice/voice_call_context.dart
//
// The pure text helpers of the voice-call glue: the call context the worker
// gets at start, and the marker a spoken task carries when it lands in the
// chat as a user message. No Flutter, no LiveKit.

/// Prefix of a task the voice worker hands to the chat. It shows in the
/// thread, so the reader can tell a spoken task from a typed one. The same
/// marker in a normal chat and in an Agents thread.
const String kVoiceTaskMarker = '🎙 ';

/// Most recent messages the call context carries.
const int kVoiceContextMaxMessages = 10;

/// Upper bound of the call context, in characters.
const int kVoiceContextMaxChars = 4000;

/// One message line is cut here, so one long answer cannot use the whole
/// budget.
const int kVoiceContextMaxLineChars = 1200;

/// A task result longer than this is cut before it goes back to the worker.
/// The worker speaks a summary; it does not need a whole document.
const int kVoiceResultMaxChars = 6000;

/// The placeholder text a chat row carries while its answer is on the way.
const String _kThinkingPlaceholder = 'Thinking...';

final RegExp _visualTag = RegExp(
  r'<(chart|map|email|think)\b[^>]*>[\s\S]*?</\1>',
  caseSensitive: false,
);
final RegExp _whitespace = RegExp(r'\s+');

/// The call context: the last [maxMessages] text messages of a chat as plain
/// `User: …` / `Assistant: …` lines, oldest first, at most [maxChars] long.
///
/// Only the `text` field is read, so attachments, images, tool calls and
/// reasoning never reach the worker. Empty rows and the "Thinking..."
/// placeholder are skipped. Visual tags (`<chart>`, `<map>`, …) are dropped,
/// and each message is folded to one line. When the lines do not fit, the
/// oldest go first; a single newest line that alone is too long is cut.
String buildVoiceCallContext(
  List<Map<String, String>> messages, {
  int maxMessages = kVoiceContextMaxMessages,
  int maxChars = kVoiceContextMaxChars,
  int maxLineChars = kVoiceContextMaxLineChars,
}) {
  if (maxMessages <= 0 || maxChars <= 0) return '';
  final List<String> lines = <String>[];
  for (int i = messages.length - 1; i >= 0; i--) {
    if (lines.length >= maxMessages) break;
    final String? line = _contextLine(messages[i], maxLineChars);
    if (line != null) lines.add(line);
  }
  // Newest first in [lines]; keep the newest that fit, then flip.
  final List<String> kept = <String>[];
  int used = 0;
  for (final String line in lines) {
    final int cost = line.length + (kept.isEmpty ? 0 : 1);
    if (used + cost <= maxChars) {
      kept.add(line);
      used += cost;
      continue;
    }
    if (kept.isEmpty) {
      // The newest line alone is over the budget: cut it, keep the start.
      kept.add(_cut(line, maxChars));
    }
    break;
  }
  return kept.reversed.join('\n');
}

String? _contextLine(Map<String, String> message, int maxLineChars) {
  final String raw = message['text'] ?? '';
  if (raw.trim() == _kThinkingPlaceholder) return null;
  final String text = raw
      .replaceAll(_visualTag, ' ')
      .replaceAll(_whitespace, ' ')
      .trim();
  if (text.isEmpty) return null;
  final String sender = message['sender'] ?? message['role'] ?? 'ai';
  final String who = sender == 'user' ? 'User' : 'Assistant';
  return _cut('$who: $text', maxLineChars);
}

String _cut(String text, int max) {
  if (text.length <= max) return text;
  if (max <= 1) return text.substring(0, max);
  return '${text.substring(0, max - 1)}…';
}

/// The text a spoken task is sent with: the marker, then the task on one
/// line. Returns null for an empty task.
String? voiceTaskMessageText(String task) {
  final String trimmed = task.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith(kVoiceTaskMarker.trim())) return trimmed;
  return '$kVoiceTaskMarker$trimmed';
}

/// Cuts a task result to what the worker gets back.
String voiceResultText(String text) =>
    _cut(text.trim(), kVoiceResultMaxChars);

/// The texts the chat pipeline finalizes a turn with when the turn did not
/// produce an answer. A voice task that ends on one of them is `failed`.
bool looksLikeFailedTurn(String text) {
  final String t = text.trim();
  if (t.isEmpty) return true;
  return t.startsWith('Error:') ||
      t.startsWith('Failed to start streaming') ||
      t.startsWith('You have used all free messages') ||
      t.startsWith('Tool loop stopped after reaching the safety limit');
}
