import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';
import 'package:cowork/models/chat_reply.dart';

class ChatEditNotice extends StatelessWidget {
  const ChatEditNotice({super.key, required this.onCancel});
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          AppIcon(Icons.edit_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Editing message',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onCancel,
            icon: const AppIcon(Icons.close_rounded, size: 18),
            label: const Text('Cancel'),
            style: TextButton.styleFrom(
              foregroundColor: scheme.onSurface,
              minimumSize: const Size(48, 48),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A quiet quote above the composer, not a transport/status notification.
class ChatReplyPreview extends StatelessWidget {
  const ChatReplyPreview({
    super.key,
    required this.reply,
    required this.onCancel,
  });
  final ChatReply reply;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 0, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: scheme.primary, width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reply to ${reply.author}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    reply.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: 'Cancel reply',
            icon: AppIcon(
              Icons.close_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
