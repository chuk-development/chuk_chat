// lib/widgets/message_bubble/chrome.dart
//
// Part of message_bubble.dart — the small surrounding chrome: the AI action
// bar, the user long-press action strip, and the pending/failed status line.

// ignore_for_file: invalid_use_of_protected_member

part of '../message_bubble.dart';

extension _MessageBubbleChrome on _MessageBubbleState {
  /// Bottom bar for AI messages: action buttons (left) + sources (right).
  Widget _buildBottomBar(Color iconFgColor, bool hasActions) {
    // No sources pill any more: every step in the timeline shows the pages
    // it brought in, right where it found them. Repeating them all in one
    // pill under the answer said the same thing twice and buried the
    // buttons next to it.
    if (!hasActions) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildActionButtons(iconFgColor, false),
        const Spacer(),
      ],
    );
  }

  Widget _buildUserActionButtons(Color iconFgColor) => _buildActionBar(
        actions: widget.userMessageActions,
        iconFgColor: iconFgColor,
        alignRight: true,
        dimDisabledIcon: true,
      );

  Widget _buildActionButtons(Color iconFgColor, bool alignRight) =>
      _buildActionBar(
        actions: widget.actions,
        iconFgColor: iconFgColor,
        alignRight: alignRight,
        dimDisabledIcon: false,
      );

  /// Shared pill of icon action buttons behind [_buildUserActionButtons]
  /// (user long-press strip) and [_buildActionButtons] (AI action bar). Both
  /// differ only in the action list, the row alignment, and whether a disabled
  /// icon is dimmed — everything else is identical, so it lives here once.
  Widget _buildActionBar({
    required List<MessageBubbleAction> actions,
    required Color iconFgColor,
    required bool alignRight,
    required bool dimDisabledIcon,
  }) {
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignRight
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        Container(
          // Fixed height on mobile so the user and AI strips match in size.
          height: kPlatformMobile ? _kMobileBottomBarHeight : null,
          decoration: BoxDecoration(
            color: bgColor.lighten(0.05),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: iconFgColor.withValues(alpha: 0.15),
              width: 1,
            ),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: kPlatformMobile ? 4 : 8,
            vertical: kPlatformMobile ? 0 : 4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: actions.map((action) {
              return Tooltip(
                message: action.tooltip,
                child: IconButton(
                  icon: Icon(
                    action.icon,
                    color: (action.isEnabled || !dimDisabledIcon)
                        ? iconFgColor
                        : iconFgColor.withValues(alpha: 0.38),
                    size: 18,
                  ),
                  padding: EdgeInsets.all(kPlatformMobile ? 5 : 8),
                  visualDensity: VisualDensity.compact,
                  constraints: BoxConstraints(
                    minWidth: kPlatformMobile ? 28 : 30,
                    minHeight: kPlatformMobile ? 28 : 30,
                  ),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: action.isEnabled ? action.onPressed : null,
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusIndicator(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final t = Theme.of(context);
    final isFailed = widget.status == ChatMessageStatus.failed;
    final color = isFailed
        ? t.colorScheme.error
        : t.colorScheme.onSurface.withValues(alpha: .6);
    final icon = isFailed ? Icons.error_outline : Icons.schedule;
    final label = isFailed
        ? (loc?.messageFailed ?? 'Failed to send')
        : (loc?.messagePending ?? 'Will send when online');
    final tooltip = isFailed && widget.lastError != null
        ? '$label: ${widget.lastError}'
        : label;

    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 2),
      child: Tooltip(
        message: tooltip,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
            if (isFailed && widget.onRetryPending != null) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: widget.onRetryPending,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    loc?.messageRetry ?? 'Retry',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
