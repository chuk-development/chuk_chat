// lib/widgets/message_bubble.dart
import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final String message;
  final bool isUser; // true for bot, false for user in voice mode (to match image)
  // In regular chat, true for user, false for AI.
  final double? maxWidth; // Neue optionale Eigenschaft für responsive Breite

  const MessageBubble({
    Key? key,
    required this.message,
    required this.isUser,
    this.maxWidth,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Determine alignment based on whether it's a user message or not.
    // In voice_mode, isUser=true means it's a bot message on the left.
    // In chat_ui, isUser=true means it's a user message on the right.
    // The `isUser` flag's meaning is inverted in `voice_mode_page.dart`
    // to match the visual design, so we respect that here.
    final bool alignRight = isUser; // User messages (regular chat) go right, bot messages go left.

    // Get colors from theme
    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).iconTheme.color!;


    // Nutze die übergebene maxWidth, falls vorhanden, ansonsten den Standardwert von 70% der Bildschirmbreite
    final double effectiveMaxWidth = maxWidth ?? MediaQuery.of(context).size.width * 0.7;

    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth), // Verwendet effectiveMaxWidth
        decoration: BoxDecoration(
          color: alignRight ? accentColor.withOpacity(.8) : bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: iconFgColor.withOpacity(.3)),
        ),
        child: Text(message, style: TextStyle(color: iconFgColor)),
      ),
    );
  }
}