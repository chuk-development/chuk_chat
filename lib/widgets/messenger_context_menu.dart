import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';

/// A focused message above a separate action sheet, like a messenger's
/// long-press menu. The transcript remains in place beneath a soft scrim.
Future<String?> showMessengerContextMenu({
  required BuildContext context,
  required Rect anchor,
  required Widget preview,
  required bool canEdit,
  required bool canReply,
  required bool isUser,
  bool canReact = false,
  String? reaction,
}) {
  return showGeneralDialog<String>(
    context: context,
    requestFocus: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.24),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220),
    transitionBuilder: (context, animation, secondary, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    ),
    pageBuilder: (context, _, secondary) {
      final media = MediaQuery.of(context);
      final scheme = Theme.of(context).colorScheme;
      final bottomInset = math.max(
        media.padding.bottom,
        media.viewInsets.bottom,
      );
      final usable = math.max(
        0.0,
        media.size.height - media.padding.top - bottomInset - 32,
      );
      final rowHeight = math.max(52.0, media.textScaler.scale(17) + 28);
      final actionHeight =
          rowHeight * (1 + (canEdit ? 1 : 0) + (canReply ? 1 : 0));
      final reactionHeight = canReact ? 58.0 : 0.0;
      final previewHeight = math.min(
        280.0,
        math.max(48.0, usable - actionHeight - reactionHeight - 16),
      );
      final totalHeight =
          math.min(anchor.height, previewHeight) +
          actionHeight +
          reactionHeight +
          12;
      final top = (anchor.top - reactionHeight).clamp(
        media.padding.top + 16,
        math.max(
          media.padding.top + 16,
          media.size.height - bottomInset - totalHeight - 16,
        ),
      );
      Widget action(String value, String label, IconData icon) => InkWell(
        onTap: () => Navigator.of(context).pop(value),
        child: SizedBox(
          height: rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                AppIcon(icon, size: 22),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Positioned(
            top: top.toDouble(),
            left: 16,
            right: 16,
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canReact) ...[
                  Material(
                    key: const ValueKey('context_reactions'),
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(28),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: math.min(320, media.size.width - 32),
                      height: 48,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final emoji in const [
                              '👍',
                              '👎',
                              '❤️',
                              '😂',
                              '😮',
                              '🙏',
                              '🔥',
                              '🎉',
                              '✅',
                              '💡',
                              '🤔',
                              '👀',
                              '💯',
                              '🙌',
                              '😊',
                              '😍',
                              '🥳',
                              '😢',
                              '😅',
                              '🤝',
                              '🚀',
                              '⭐',
                              '🫶',
                              '🤯',
                            ])
                              Semantics(
                                label: 'React $emoji',
                                selected: reaction == emoji,
                                child: InkWell(
                                  onTap: () => Navigator.of(
                                    context,
                                  ).pop('reaction:$emoji'),
                                  child: Container(
                                    width: 48,
                                    height: 48,
                                    color: reaction == emoji
                                        ? scheme.primary.withValues(alpha: 0.14)
                                        : null,
                                    alignment: Alignment.center,
                                    child: Text(
                                      emoji,
                                      style: const TextStyle(fontSize: 25),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                ConstrainedBox(
                  key: const ValueKey('context_message_preview'),
                  constraints: BoxConstraints(maxHeight: previewHeight),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: SingleChildScrollView(
                      child: Material(
                        type: MaterialType.transparency,
                        child: IgnorePointer(child: preview),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: math.min(248, media.size.width - 32),
                  child: Material(
                    key: const ValueKey('context_message_actions'),
                    color: scheme.surfaceContainerHigh,
                    surfaceTintColor: Colors.transparent,
                    elevation: 8,
                    shadowColor: Colors.black26,
                    borderRadius: BorderRadius.circular(22),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (canEdit)
                          action('edit', 'Edit', Icons.edit_outlined),
                        if (canEdit && canReply)
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            color: scheme.outlineVariant,
                          ),
                        if (canReply)
                          action('reply', 'Reply', Icons.reply_rounded),
                        if (canReply || canEdit)
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            color: scheme.outlineVariant,
                          ),
                        action('copy', 'Copy', Icons.copy_outlined),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
