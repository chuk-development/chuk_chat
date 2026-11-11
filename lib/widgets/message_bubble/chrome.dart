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
  ///
  /// [topGap] is air above the bar, added only when there is a bar to draw.
  Widget _buildBottomBar(
    Color iconFgColor,
    bool hasActions, {
    double topGap = 0,
  }) {
    final sources = _allSources(_collectAllToolCalls());
    final bool hasSources = sources.isNotEmpty;
    final bool hasPager = widget.variantCount > 1;
    if (!hasActions && !hasSources && !hasPager) {
      return const SizedBox.shrink();
    }
    if (topGap > 0) {
      return Padding(
        padding: EdgeInsets.only(top: topGap),
        child: _buildBottomBar(iconFgColor, hasActions),
      );
    }

    // The left cluster (actions + pager) can grow with many actions and
    // several variants; on a narrow bubble that plus a five-icon sources pill
    // would overflow the Row. Let the left cluster take the remaining width and
    // scroll horizontally instead of overflowing, keeping the sources pill
    // pinned at the right.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasActions) _buildActionButtons(iconFgColor, false),
                if (hasPager) ...[
                  const SizedBox(width: 6),
                  _buildVariantPager(iconFgColor),
                ],
              ],
            ),
          ),
        ),
        if (hasSources) ...[
          const SizedBox(width: 6),
          // On a phone the full five-icon pill leaves the pager too little
          // room and clips its next arrow, so show fewer icons next to it.
          _buildSourcesBar(
            sources,
            maxIcons: hasPager && kPlatformMobile ? 2 : 5,
          ),
        ],
      ],
    );
  }

  /// The OpenAI-style ‹ k/n › pager: a compact previous / index / next
  /// control that steps through a regenerated answer's variants. Styled to
  /// match the action-bar pill next to it.
  Widget _buildVariantPager(Color iconFgColor) {
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final int count = widget.variantCount;
    final int index = widget.variantIndex.clamp(0, count - 1);
    final bool canPrev = index > 0 && widget.onPrevVariant != null;
    final bool canNext = index < count - 1 && widget.onNextVariant != null;

    Widget arrow(IconData icon, bool enabled, VoidCallback? onTap) {
      return IconButton(
        icon: AppIcon(
          icon,
          color: enabled ? iconFgColor : iconFgColor.withValues(alpha: 0.38),
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
        onPressed: enabled ? onTap : null,
      );
    }

    return Container(
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
        horizontal: kPlatformMobile ? 2 : 4,
        vertical: kPlatformMobile ? 0 : 4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Previous answer',
            child: arrow(Icons.chevron_left, canPrev, widget.onPrevVariant),
          ),
          Text(
            '${index + 1}/$count',
            style: TextStyle(
              color: iconFgColor,
              fontWeight: FontWeight.w500,
              fontSize: kPlatformMobile ? 14 : 12,
            ),
          ),
          Tooltip(
            message: 'Next answer',
            child: arrow(Icons.chevron_right, canNext, widget.onNextVariant),
          ),
        ],
      ),
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

  /// The bottom-right pill: a strip of up to [maxIcons] favicons and a
  /// "N sources" count. Tapping opens the full, scrollable list.
  Widget _buildSourcesBar(
    List<AgentActivitySource> sources, {
    int maxIcons = 5,
  }) {
    final int iconCount = sources.length < maxIcons ? sources.length : maxIcons;
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
            for (int i = 0; i < iconCount; i++)
              Padding(
                padding: EdgeInsets.only(right: i < iconCount - 1 ? 4.0 : 0),
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
    return FaviconImage(
      host: host,
      size: size,
      fallbackColor: colorScheme.onSurfaceVariant,
      borderRadius: 4,
      fallbackIcon: Icons.public,
    );
  }

  /// The expandable list behind the pill: a modal sheet of every source,
  /// each opening its page in the browser on tap.
  void _showSourcesSheet(List<AgentActivitySource> sources) {
    final colorScheme = Theme.of(context).colorScheme;
    final String label =
        '${sources.length} source${sources.length == 1 ? '' : 's'}';
    unawaited(
      showMenuSheet<void>(
        context,
        header: Row(
          children: [
            AppIcon(
              Icons.language,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
        groups: <List<Widget>>[
          <Widget>[
            for (final AgentActivitySource source in sources)
              MenuActionRow(
                label: source.title,
                maxLines: 2,
                subtitle: source.host,
                leading: _buildFavicon(source.host, colorScheme, 24),
                trailing: AppIcon(
                  Icons.open_in_new,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                onTap: () => _openSourceUrl(source),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildUserActionButtons(Color iconFgColor) => _buildActionBar(
    actions: widget.userMessageActions,
    iconFgColor: iconFgColor,
    alignRight: true,
    dimDisabledIcon: true,
  );

  /// The AI action bar.
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
    Widget? trailing,
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
            children: [
              ...actions.map((action) {
                return Tooltip(
                  message: action.tooltip,
                  child: IconButton(
                    icon: action.isLoading
                        ? SizedBox.square(
                            dimension: 18,
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: iconFgColor,
                              ),
                            ),
                          )
                        : AppIcon(
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
              }),
              ?trailing,
            ],
          ),
        ),
      ],
    );
  }

  /// The outbox line under a user bubble (waiting, sending, failed, held).
  /// See [OutboxStatusLine]; only that line listens to the outbox.
  Widget _buildStatusIndicator(BuildContext context) => OutboxStatusLine(
    status: widget.status,
    queueId: widget.queueId,
    lastError: widget.lastError,
    onRetryFallback: widget.onRetryPending,
  );
}
