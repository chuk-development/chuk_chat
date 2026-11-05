// lib/widgets/composer/chat_export.dart
//
// The `/export` command of the composer menu: the open chat as Markdown, on
// the clipboard. Only what the reader sees: the user's and the assistant's
// text, no tool payloads, no reasoning.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/widgets/app_notification.dart';

/// [messages] as Markdown: one `## You` / `## Assistant` section per message.
String chatAsMarkdown(List<Map<String, String>> messages, {String? title}) {
  final StringBuffer out = StringBuffer();
  final String head = title?.trim() ?? '';
  if (head.isNotEmpty) out.writeln('# $head\n');
  for (final Map<String, String> m in messages) {
    final String text = (m['text'] ?? '').trim();
    if (text.isEmpty || text == 'Thinking...') continue;
    final bool user = (m['sender'] ?? '') == 'user';
    out.writeln(user ? '## You\n' : '## Assistant\n');
    out.writeln('$text\n');
  }
  return out.toString().trimRight();
}

/// Copies the chat as Markdown and says so. [doneLabel] is the localised
/// confirmation (the app's "Copied" string).
Future<void> copyChatAsMarkdown(
  BuildContext context,
  List<Map<String, String>> messages, {
  required String doneLabel,
}) async {
  await Clipboard.setData(ClipboardData(text: chatAsMarkdown(messages)));
  if (!context.mounted) return;
  AppNotifications.show(context, doneLabel);
}
