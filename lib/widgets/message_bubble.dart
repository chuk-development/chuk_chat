// lib/widgets/message_bubble.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

class MessageBubbleAction {
  const MessageBubbleAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.isEnabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool isEnabled;
}

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isUser,
    this.maxWidth,
    this.actions = const <MessageBubbleAction>[],
    this.reasoning,
    this.isReasoningStreaming = false,
    this.modelLabel,
  });

  final String message;
  final bool
  isUser; // true for bot, false for user in voice mode (to match image)
  // In regular chat, true for user, false for AI.
  final double? maxWidth; // Neue optionale Eigenschaft für responsive Breite
  final List<MessageBubbleAction> actions;
  final String? reasoning;
  final bool isReasoningStreaming;
  final String? modelLabel;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _isReasoningExpanded = false;

  bool get _hasReasoning =>
      widget.reasoning != null && widget.reasoning!.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // Determine alignment based on whether it's a user message or not.
    // Historically voice mode inverted this flag, so we keep compatibility.
    final bool isUserMessage =
        widget.isUser; // In regular chat, true for user, false for AI.
    final bool alignRight =
        isUserMessage; // User messages go right, assistant responses go left.

    // Get colors from theme
    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).iconTheme.color!;

    // Nutze die übergebene maxWidth, falls vorhanden, ansonsten den Standardwert von 70% der Bildschirmbreite
    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.7;

    final bool hasActions = widget.actions.isNotEmpty;

    final EdgeInsetsGeometry containerPadding = isUserMessage
        ? const EdgeInsets.all(12)
        : const EdgeInsets.symmetric(horizontal: 4, vertical: 2);

    final BoxDecoration? decoration = isUserMessage
        ? BoxDecoration(
            color: accentColor.withValues(alpha: .8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: iconFgColor.withValues(alpha: .3)),
          )
        : null;

    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: containerPadding,
          decoration: decoration,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: alignRight
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (_hasReasoning) ...[
                _buildReasoningToggle(iconFgColor, alignRight),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _isReasoningExpanded
                      ? _buildReasoningBox(iconFgColor, alignRight)
                      : const SizedBox(key: ValueKey('reasoning-collapsed')),
                ),
              ],
              if (widget.modelLabel != null && widget.modelLabel!.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: isUserMessage ? 4 : 8),
                  child: Text(
                    widget.modelLabel!,
                    style: TextStyle(
                      color: iconFgColor.withValues(alpha: 0.6),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: alignRight ? TextAlign.right : TextAlign.left,
                  ),
                ),
              _buildMessageBody(
                iconFgColor: iconFgColor,
                accentColor: accentColor,
                bgColor: bgColor,
                isUserMessage: isUserMessage,
              ),
              if (hasActions) ...[
                const SizedBox(height: 8),
                Wrap(
                  alignment: alignRight
                      ? WrapAlignment.end
                      : WrapAlignment.start,
                  spacing: 4,
                  runSpacing: 4,
                  children: widget.actions
                      .map(
                        (action) => IconButton(
                          iconSize: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: action.tooltip,
                          onPressed: action.isEnabled ? action.onPressed : null,
                          icon: Icon(action.icon, color: iconFgColor),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReasoningToggle(Color iconFgColor, bool alignRight) {
    final bool expanded = _isReasoningExpanded;
    final IconData icon = expanded ? Icons.expand_less : Icons.expand_more;
    final String label = expanded ? 'Hide reasoning' : 'Show reasoning';

    return InkWell(
      onTap: () {
        setState(() => _isReasoningExpanded = !expanded);
      },
      child: Row(
        mainAxisAlignment: alignRight
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: iconFgColor.withValues(alpha: 0.6)),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: iconFgColor.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReasoningBox(Color iconFgColor, bool alignRight) {
    final Color containerColor = iconFgColor.withValues(alpha: 0.08);
    return Container(
      key: const ValueKey('reasoning-expanded'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: iconFgColor.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: alignRight
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.psychology_alt_outlined,
                size: 16,
                color: iconFgColor.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Text(
                'Reasoning',
                style: TextStyle(
                  color: iconFgColor.withValues(alpha: 0.75),
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              if (widget.isReasoningStreaming) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      iconFgColor.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            widget.reasoning!,
            style: TextStyle(
              color: iconFgColor.withValues(alpha: 0.85),
              height: 1.35,
            ),
            textAlign: alignRight ? TextAlign.right : TextAlign.left,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBody({
    required Color iconFgColor,
    required Color accentColor,
    required Color bgColor,
    required bool isUserMessage,
  }) {
    final Widget messageWidget = MarkdownMessage(
      text: widget.message,
      textColor: iconFgColor,
      backgroundColor: isUserMessage
          ? accentColor.withValues(alpha: .8)
          : bgColor,
    );

    if (isUserMessage) {
      return messageWidget;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: messageWidget,
    );
  }
}
