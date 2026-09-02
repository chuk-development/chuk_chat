// lib/widgets/message_bubble/chrome.dart
//
// Part of message_bubble.dart — the small surrounding chrome: the AI action
// bar, the user long-press action strip, and the pending/failed status line.

// ignore_for_file: invalid_use_of_protected_member

part of '../message_bubble.dart';

extension _MessageBubbleChrome on _MessageBubbleState {
  /// Bottom bar for AI messages: action buttons (left) + a sources pill
  /// (bottom-right). The pill gathers every page the whole turn brought in
  /// into one tap-to-open list — the timeline still shows each source at the
  /// step that found it, but a reader who just wants "where did this come
  /// from" gets one place to look.
  Widget _buildBottomBar(Color iconFgColor, bool hasActions) {
    final sources = _allSources(_collectAllToolCalls());
    final bool hasSources = sources.isNotEmpty;
    if (!hasActions && !hasSources) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (hasActions) _buildActionButtons(iconFgColor, false),
        const Spacer(),
        if (hasSources) _buildSourcesBar(sources),
      ],
    );
  }

  /// Every tool call in the turn — top-level plus any nested in content
  /// blocks — so the sources pill sees the whole turn, not just the last pass.
  List<ToolCall> _collectAllToolCalls() {
    final calls = <ToolCall>[];
    final top = widget.toolCalls;
    if (top != null) calls.addAll(top);
    final blocks = widget.contentBlocks;
    if (blocks != null) {
      for (final block in blocks) {
        final blockCalls = block.toolCalls;
        if (blockCalls != null) calls.addAll(blockCalls);
      }
    }
    return calls;
  }

  /// Every web source across the turn, deduped by URL. Only the web tools
  /// count: `extractSourcesFor` will pull a URL out of any tool result (an
  /// image-generation result carries the image URL, for one), but a source is
  /// a page the model read, so the pill stays on `web_search` and `web_crawl`.
  /// Reuses the per-step extractor so the pill and the timeline chips agree.
  List<AgentActivitySource> _allSources(List<ToolCall> toolCalls) {
    final sources = <AgentActivitySource>[];
    final seen = <String>{};
    for (final call in toolCalls) {
      if (call.name != 'web_search' && call.name != 'web_crawl') continue;
      for (final source in extractSourcesFor(call)) {
        if (seen.add(source.url)) sources.add(source);
      }
    }
    return sources;
  }

  /// The bottom-right pill: a strip of up to five favicons and a "N sources"
  /// count. Tapping opens the full, scrollable list.
  Widget _buildSourcesBar(List<AgentActivitySource> sources) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    return InkWell(
      onTap: () => _showSourcesSheet(sources),
      borderRadius: BorderRadius.circular(100),
      child: Container(
        height: kPlatformMobile ? _kMobileBottomBarHeight : null,
        decoration: BoxDecoration(
          color: bgColor.lighten(0.05),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: colorScheme.onSurface.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: kPlatformMobile ? 0 : 6,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < sources.length && i < 5; i++)
              Padding(
                padding: EdgeInsets.only(right: i < 4 ? 4.0 : 0),
                child: _buildFavicon(
                  sources[i].host,
                  colorScheme,
                  kPlatformMobile ? 21 : 16,
                ),
              ),
            const SizedBox(width: 6),
            Text(
              '${sources.length} source${sources.length == 1 ? '' : 's'}',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
                fontSize: kPlatformMobile ? 15 : 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavicon(String host, ColorScheme colorScheme, double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        'https://www.google.com/s2/favicons?domain=$host&sz=32',
        width: size,
        height: size,
        errorBuilder: (context, error, stackTrace) => Icon(
          Icons.public,
          size: size,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// The expandable list behind the pill: a modal sheet of every source,
  /// each opening its page in the browser on tap.
  void _showSourcesSheet(List<AgentActivitySource> sources) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Icon(Icons.language, size: 18,
                          color: colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Text(
                        '${sources.length} source'
                        '${sources.length == 1 ? '' : 's'}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: sources.length,
                    itemBuilder: (ctx, index) {
                      final source = sources[index];
                      return ListTile(
                        leading: _buildFavicon(source.host, colorScheme, 24),
                        title: Text(
                          source.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          source.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Icon(Icons.open_in_new, size: 22,
                            color: colorScheme.onSurfaceVariant),
                        onTap: () => _openSourceUrl(source),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
