// lib/widgets/message_bubble.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/constants.dart'; // Import app constants

class MessageBubble extends StatelessWidget {
  final String message;
  final bool isUser; // true for bot, false for user in voice mode (to match image)
  // In regular chat, true for user, false for AI.

  const MessageBubble({Key? key, required this.message, required this.isUser}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Determine alignment based on whether it's a user message or not.
    // In voice_mode, isUser=true means it's a bot message on the left.
    // In chat_ui, isUser=true means it's a user message on the right.
    // The `isUser` flag's meaning is inverted in `voice_mode_page.dart`
    // to match the visual design, so we respect that here.
    final bool alignRight = isUser; // User messages (regular chat) go right, bot messages go left.

    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7), // Default width limit
        decoration: BoxDecoration(
          color: alignRight ? accent.withOpacity(.8) : bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: iconFg.withOpacity(.3)),
        ),
        child: Text(message, style: TextStyle(color: iconFg)),
      ),
    );
  }
}