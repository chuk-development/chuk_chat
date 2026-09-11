// lib/widgets/message_bubble/layout.dart
//
// Part of message_bubble.dart — the bubble skeleton: the user/AI containers,
// the classic flat layout and the interleaved content-blocks layout, plus the
// display-preference getters they branch on and the message-body text render.

// ignore_for_file: invalid_use_of_protected_member

part of '../message_bubble.dart';

extension _MessageBubbleLayout on _MessageBubbleState {
  Future<void> _showMessengerMenu(Offset? position) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final result = await showMessengerContextMenu(
      context: context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      isUser: widget.isUser,
      // No Edit. A sent turn is already in the host's transcript and in the
      // model's context; rewriting the bubble here would only make the two
      // disagree, and the user asked for the entry to go (bead cowork-9edt).
      canEdit: false,
      canReply: widget.onReply != null,
      canReact: widget.onReaction != null,
      reaction: widget.reaction,
      preview: MessageBubble(
        message: widget.message,
        isUser: widget.isUser,
        messengerMode: true,
        sentAt: widget.sentAt,
        showToolCalls: false,
        showReasoningTokens: false,
      ),
    );
    if (!mounted) return;
    if (result == 'reply') widget.onReply?.call();
    if (result == 'copy') {
      await Clipboard.setData(ClipboardData(text: widget.message));
    }
    if (result != null && result.startsWith('reaction:')) {
      widget.onReaction?.call(result.substring('reaction:'.length));
    }
  }

  Widget _withMessengerMenu(Widget child) {
    if (widget.message.trim().isEmpty) return child;
    return Semantics(
      onLongPress: () => _showMessengerMenu(null),
      child: GestureDetector(
        onLongPressStart: (details) =>
            _showMessengerMenu(details.globalPosition),
        child: child,
      ),
    );
  }

  /// Returns the user-selected chat font family, falling back to the historic
  /// Arimo default when the user has explicitly picked the system font.
  String get _chatFontFamily {
    if (widget.messengerMode &&
        MobileChatPreferences.instance.messengerTypography) {
      return _kAiResponseFontFamilyDefault;
    }
    final resolved = resolveChatFontFamily(
      AppThemeService.instance.chatFontFamily,
    );
    return resolved ?? _kAiResponseFontFamilyDefault;
  }

  double get _chatFontSize =>
      widget.messengerMode && MobileChatPreferences.instance.messengerTypography
      ? 15.0
      : AppThemeService.instance.chatFontSize;

  bool get _hasReasoning {
    if (widget.messengerMode && widget.showReasoningTokens != true) {
      return false;
    }
    // Prioritize widget prop, then loaded preference, then cached, then default
    final show =
        widget.showReasoningTokens ??
        _showReasoningTokens ??
        _cachedShowReasoningTokens ??
        kDefaultShowReasoningTokens;
    return show &&
        widget.reasoning != null &&
        widget.reasoning!.trim().isNotEmpty;
  }

  bool get _hasModelInfo {
    if (widget.messengerMode && widget.showModelInfo != true) return false;
    // Prioritize widget prop, then loaded preference, then cached, then default
    final show =
        widget.showModelInfo ??
        _showModelInfo ??
        _cachedShowModelInfo ??
        kDefaultShowModelInfo;
    return show && widget.modelLabel != null && widget.modelLabel!.isNotEmpty;
  }

  bool get _shouldShowTps {
    if (widget.messengerMode && widget.showTps != true) return false;
    final show = widget.showTps ?? kDefaultShowTps;
    return show && widget.tps != null && widget.tps! > 0;
  }

  bool get _isQrImageMessage {
    bool hasQrTool(Iterable<ToolCall> calls) {
      return calls.any(
        (call) => call.name.trim().toLowerCase() == 'generate_qr',
      );
    }

    final topLevelCalls = widget.toolCalls;
    if (topLevelCalls != null && hasQrTool(topLevelCalls)) {
      return true;
    }

    final blocks = widget.contentBlocks;
    if (blocks != null) {
      for (final block in blocks) {
        final calls = block.toolCalls;
        if (calls != null && hasQrTool(calls)) {
          return true;
        }
      }
    }

    return false;
  }

  String get _strippedMessage {
    if (_strippedMessageCache == null ||
        _strippedMessageSource != widget.message) {
      _strippedMessageSource = widget.message;
      _strippedMessageCache = _stripForPresentation(widget.message);
    }
    return _strippedMessageCache!;
  }

  String _stripForPresentation(String text) {
    final cleaned = stripToolCallBlocksForDisplay(text);
    // The sanitizer historically trims both ends. When it removed no tool
    // markup, preserve Markdown-significant indentation and hard line breaks.
    final preserved = widget.messengerMode && cleaned == text.trim()
        ? text
        : cleaned;
    return widget.messengerMode && !widget.isUser
        ? presentIncompleteMarkdownLinks(
            preserved,
            streaming: widget.isStreamingMessage,
          )
        : preserved;
  }

  /// Where this bubble sits in a run of messages from the same sender. Drives
  /// which corners are rounded, so a run reads as one connected group.
  BubblePosition get _bubblePosition => bubblePositionFromFlags(
    startsNewGroup: widget.startsNewGroup,
    endsGroup: widget.endsGroup,
  );

  /// The wall clock of the turn as `HH:mm`, or null when the row carries no
  /// timestamp. Older rows and rows replayed from the host have none, and
  /// stamping them with "now" would show a time that never happened.
  String? get _clockLabel {
    final DateTime? when = (widget.sentAt ?? widget.turnStartedAt)?.toLocal();
    if (when == null) return null;
    final String hh = when.hour.toString().padLeft(2, '0');
    final String mm = when.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// The stamp in the bubble's bottom-right corner: the time, plus the queue
  /// mark on a user message that has not gone out yet. No delivery ticks — see
  /// message_stamp.dart for why a coworker makes them meaningless.
  Widget? _buildBubbleFooter({
    required BuildContext context,
    required bool isUser,
    required Color fill,
    required Color onFill,
  }) {
    final QueueMark mark = isUser
        ? queueMarkFor(widget.status)
        : QueueMark.none;
    // Only the LAST bubble of a run carries the time, the way a messenger does
    // it: a stamp under every line of a burst is noise. A queue mark always
    // shows — it is about this one message.
    final String? label = widget.endsGroup ? _clockLabel : null;
    if (label == null && mark == QueueMark.none) return null;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final stamp = MessageStamp(
      time: label ?? '',
      mark: mark,
      fg: onFill.withValues(alpha: 0.75),
      errorColor: isUser ? onFill : scheme.error,
    );
    return Padding(
      padding: EdgeInsets.only(top: widget.messengerMode ? 0 : 3),
      child: widget.messengerMode && !_isPlainMessengerText
          ? Align(alignment: Alignment.centerRight, child: stamp)
          : stamp,
    );
  }

  /// The kind of a coworker's message, which decides the bubble colour.
  AgentBubbleKind get _agentBubbleKind {
    final bool hasMedia =
        (widget.images?.isNotEmpty ?? false) ||
        (widget.attachments?.isNotEmpty ?? false);
    final bool hasToolRuns =
        (widget.toolCalls?.isNotEmpty ?? false) ||
        (widget.contentBlocks?.any(
              (ContentBlock block) => block.toolCalls?.isNotEmpty ?? false,
            ) ??
            false);
    return agentBubbleKindFor(
      hasProblem: widget.status == ChatMessageStatus.interrupted,
      hasMedia: hasMedia,
      hasToolRuns: hasToolRuns,
      textLength: _strippedMessage.trim().length,
    );
  }

  /// The entire on-screen trace of a fired automation: one quiet line.
  ///
  /// The wake's prompt text also carries the operator's instructions and the
  /// payload the watcher observed, and neither belongs in the thread — the
  /// reader did not write them, and the payload is a raw JSON blob from a
  /// watched page. Only the fact that the automation fired is shown.
  Widget _buildAutomationWakeLine(BuildContext context, AutomationWake wake) {
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    final TextStyle style =
        (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
          color: color,
        );
    final DateTime? when = widget.turnStartedAt?.toLocal();
    return Padding(
      padding: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 4, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(Icons.bolt_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              wake.name.isEmpty ? 'Automation' : 'Automation · ${wake.name}',
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (when != null) ...[
            const SizedBox(width: 6),
            Text(
              '${when.hour.toString().padLeft(2, '0')}:'
              '${when.minute.toString().padLeft(2, '0')}',
              style: style,
            ),
          ],
        ],
      ),
    );
  }

  /// A turn that really did work but has nothing left to read: one quiet
  /// line, in the automation wake's style.
  ///
  /// The quiet toggles can filter every block of a turn away — the steps are
  /// hidden, the thinking is hidden, and the turn said nothing on top of them.
  /// Drawing the bubble around that leaves the unexplained empty block the
  /// reader sees on the phone, and drawing nothing at all drops the fact that
  /// the coworker worked. So the fact gets a line, and a tap on it turns the
  /// details back on. Typography and padding are the wake line's, so the two
  /// system lines read as one family.
  Widget _buildQuietWorkLine(BuildContext context, List<ToolCall> calls) {
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    final TextStyle style =
        (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
          color: color,
        );
    final int steps = calls.length;
    final int failed = calls
        .where((ToolCall call) => call.status == ToolCallStatus.error)
        .length;
    final String label =
        'Worked · $steps ${steps == 1 ? 'step' : 'steps'}'
        '${failed > 0 ? ' · $failed failed' : ''}';
    return Padding(
      padding: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 4, bottom: 4),
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => MobileChatPreferences.instance.setActivity(true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(Icons.bolt_outlined, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: style,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserBubble(BuildContext context) {
    const bool isUserMessage = true;
    const bool alignRight = true;

    // A fired automation reaches the thread as a user turn because that is how
    // the host submits it. It is not a person talking, so it never gets a
    // bubble.
    final AutomationWake? wake = parseAutomationWake(widget.message);
    if (wake != null) return _buildAutomationWakeLine(context, wake);

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ??
        MediaQuery.of(context).size.width * (widget.messengerMode ? 0.72 : 0.8);

    final EdgeInsetsGeometry containerPadding = EdgeInsets.symmetric(
      horizontal: widget.messengerMode ? 15 : 14,
      vertical: widget.messengerMode ? 9 : 10,
    );

    // Expressive geometry: big rounding everywhere, a small radius only where
    // the next bubble of the same sender is stacked against it.
    final Color fill = accentColor;
    final Color onFill = Theme.of(context).colorScheme.onPrimary;
    final BoxDecoration decoration = BoxDecoration(
      color: fill,
      borderRadius: bubbleRadius(true, _bubblePosition),
    );

    final Widget bubbleContent = Container(
      margin: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 2, bottom: 2),
      padding: containerPadding,
      decoration: decoration,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          // The body is painted ON the accent, so its foreground is the
          // scheme's on-primary, not the page's icon colour — otherwise the
          // text sits dark on a dark accent.
          ..._buildClassicLayout(
            iconFgColor: onFill,
            accentColor: accentColor,
            bgColor: fill,
            isUserMessage: isUserMessage,
            alignRight: alignRight,
            hasInfoStatusBar: false,
            hasVisibleToolCalls: false,
          ),
          // Time + ticks, in the corner of the bubble itself.
          if (!_isPlainMessengerText)
            ?_buildBubbleFooter(
              context: context,
              isUser: true,
              fill: fill,
              onFill: onFill,
            ),
        ],
      ),
    );

    final bool hasUserActions = widget.userMessageActions.isNotEmpty;
    final Widget userBubble = widget.messengerMode
        ? _withMessengerMenu(bubbleContent)
        : hasUserActions
        ? GestureDetector(
            onTap: () => setState(() => _showUserActions = !_showUserActions),
            onLongPress: widget.messengerMode
                ? () => setState(() => _showUserActions = !_showUserActions)
                : null,
            child: bubbleContent,
          )
        : bubbleContent;

    final bool hasUserImages =
        widget.images != null && widget.images!.isNotEmpty;
    final bool hideEmptyUserBubble =
        hasUserImages &&
        _stripAttachmentHeaderForUser(widget.message).trim().isEmpty;

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (hasUserImages) ...[
              _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
              const SizedBox(height: 2),
            ],
            if (!hideEmptyUserBubble) userBubble,
            if (!widget.messengerMode && hasUserActions && _showUserActions)
              _buildUserActionButtons(iconFgColor),
            // The stamp in the bubble already marks a queued or failed send.
            // The row below stays only for a failure, because it carries the
            // Retry action and the error text.
            if (widget.status == ChatMessageStatus.failed)
              _buildStatusIndicator(context),
          ],
        ),
      ),
    );
  }

  Widget _buildAiBubble(BuildContext context) {
    const bool isUserMessage = false;
    const bool alignRight = false;
    final working =
        widget.messengerMode &&
        (widget.isStreamingMessage || widget.isReasoningStreaming);
    final hasContent =
        (_strippedMessage.trim().isNotEmpty &&
            widget.message != 'Thinking...') ||
        (widget.contentBlocks?.any(
              (block) =>
                  block.type == ContentBlockType.sandboxArtifact ||
                  (block.type == ContentBlockType.text &&
                      stripToolCallBlocksForDisplay(
                        block.text ?? '',
                      ).trim().isNotEmpty &&
                      block.text != 'Thinking...'),
            ) ??
            false) ||
        (widget.images?.isNotEmpty ?? false) ||
        (widget.attachments?.isNotEmpty ?? false) ||
        // A callback is not a question. `ask_user` reaches the bubble with a
        // handler attached even when the call carries no options, and then
        // there is no card to read — ask the builder, which is the thing that
        // decides whether a card exists at all.
        _buildAskUserOptions().isNotEmpty ||
        _buildMcpConnectOptions().isNotEmpty ||
        _collectAllToolCalls().any(
          (call) => call.status == ToolCallStatus.error,
        ) ||
        _buildArtifactCards(_collectAllToolCalls()).isNotEmpty;

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ??
        MediaQuery.of(context).size.width * (widget.messengerMode ? 1 : 0.8);

    final bool hasActions = widget.actions.isNotEmpty;

    final bool useContentBlocks =
        !_isPlainMessengerText &&
        widget.contentBlocks != null &&
        widget.contentBlocks!.isNotEmpty;

    final bool hasVisibleToolCalls =
        !useContentBlocks &&
        widget.showToolCalls &&
        widget.toolCalls != null &&
        widget.toolCalls!.isNotEmpty;

    final bool isWaitingForFirstTokens =
        widget.isReasoningStreaming &&
        (widget.message == 'Thinking...' || widget.message.isEmpty);
    final bool hasInfoStatusBar =
        !useContentBlocks &&
        (_hasReasoning ||
            _hasModelInfo ||
            (isWaitingForFirstTokens && !widget.messengerMode)) &&
        !hasVisibleToolCalls;

    // A coworker's turn gets a real bubble now, and its colour says what the
    // turn IS: prose, work, a delivery, or a break-off (see bubble_kind.dart).
    final AgentBubbleColors colors = agentBubbleColors(
      Theme.of(context).colorScheme,
      widget.messengerMode && widget.status != ChatMessageStatus.interrupted
          ? AgentBubbleKind.answer
          : _agentBubbleKind,
    );

    // The body is built BEFORE the bubble, because the body is what decides
    // whether there is a bubble at all. The quiet toggles filter blocks out
    // inside these builders — reasoning when Thinking is off, the whole tool
    // round when Activity is off, text that strips to nothing — and a second,
    // hand-kept list of "does this turn count" conditions up here could never
    // stay in step with them. It did not: an Activity-on/Thinking-off turn, a
    // failed tool, an ask_user with no options and a reasoning row that also
    // carried content blocks all walked past it and drew the empty block the
    // reader sees. Now nothing rendered means no bubble, by construction.
    _artifactMessages.clear();
    final List<Widget> bodyChildren = useContentBlocks
        ? _buildContentBlocksLayout(
            iconFgColor: colors.onFill,
            accentColor: accentColor,
            bgColor: colors.fill,
            alignRight: alignRight,
          )
        : _buildClassicLayout(
            iconFgColor: colors.onFill,
            accentColor: accentColor,
            bgColor: colors.fill,
            isUserMessage: isUserMessage,
            alignRight: alignRight,
            hasInfoStatusBar: hasInfoStatusBar,
            hasVisibleToolCalls: hasVisibleToolCalls,
          );

    if (working && bodyChildren.isEmpty && _artifactMessages.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(
            top: widget.startsNewGroup ? 10 : 2,
            bottom: 2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MessengerTypingIndicator(),
              // A regenerate's earlier versions remain reachable while waiting.
              _buildBottomBar(Theme.of(context).resolvedIconColor, false),
            ],
          ),
        ),
      );
    }

    // Nothing rendered, nothing still running, and no break-off to explain:
    // this turn has no chat message in it. Either it did work the reader may
    // still want to reach — then it gets the one quiet line — or it did
    // nothing at all and leaves the thread untouched.
    // A turn whose whole content is a file is not an empty turn: the file was
    // lifted out of `bodyChildren` on purpose and is drawn below the bubble.
    if (widget.messengerMode &&
        bodyChildren.isEmpty &&
        _artifactMessages.isEmpty &&
        !working &&
        widget.status != ChatMessageStatus.interrupted) {
      final List<ToolCall> calls = _collectAllToolCalls();
      if (calls.isEmpty) return const SizedBox.shrink();
      return _buildQuietWorkLine(context, calls);
    }

    // With the files pulled out, an answer that was nothing but a file would
    // leave an empty bubble carrying a timestamp. Then the file is the message.
    final bool bubbleCarriesContent =
        bodyChildren.isNotEmpty || _artifactMessages.isEmpty;
    final Widget bubbleContent = Container(
      // Incoming messages use the readable lane; outgoing messages retain
      // their compact messenger silhouette.
      key: widget.messengerMode
          ? const ValueKey('messenger-answer-bubble')
          : null,
      width: widget.messengerMode ? double.infinity : null,
      margin: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 2, bottom: 2),
      padding: EdgeInsets.symmetric(
        horizontal: widget.messengerMode ? 15 : 14,
        vertical: widget.messengerMode ? 9 : 10,
      ),
      decoration: BoxDecoration(
        color: colors.fill,
        borderRadius: bubbleRadius(false, _bubblePosition),
      ),
      clipBehavior: Clip.none,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ...bodyChildren,
          // A tool call that failed is the coworker's business, not the
          // user's: the turn routes around it and answers anyway. A banner
          // under a good answer only reads as "something is broken" (bead
          // cowork-wsev). The failure stays in the tool list, which the user
          // opens when they want it.
          // The time only: a coworker's bubble carries no ticks.
          if (!_isPlainMessengerText)
            ?_buildBubbleFooter(
              context: context,
              isUser: false,
              fill: colors.fill,
              onFill: colors.onFill,
            ),
        ],
      ),
    );

    final bool showContinueButton =
        !widget.isUser &&
        !widget.isStreamingMessage &&
        widget.status == ChatMessageStatus.interrupted &&
        widget.onContinueGeneration != null;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: effectiveMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (bubbleCarriesContent)
              widget.messengerMode
                  ? _withMessengerMenu(bubbleContent)
                  : bubbleContent,
            for (final Widget artifact in _artifactMessages)
              Padding(
                padding: EdgeInsets.only(
                  top: bubbleCarriesContent ? 4 : 2,
                  bottom: 2,
                ),
                child: artifact,
              ),
            // Dots mean "nothing to read yet". The moment the first token is
            // on screen the answer speaks for itself, and a second indicator
            // under it just hangs there (bead cowork-i7sd).
            if (working && !hasContent)
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 2),
                child: MessengerTypingIndicator(connectedAbove: true),
              ),
            if (showContinueButton) _buildContinueButton(context, accentColor),
            _buildBottomBar(iconFgColor, hasActions && !widget.messengerMode),
          ],
        ),
      ),
    );
  }

  Widget _buildContinueButton(BuildContext context, Color accentColor) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Tooltip(
        message:
            'This response was cut off. Tap to ask the model to keep going.',
        child: Material(
          color: accentColor.withValues(alpha: .10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: accentColor.withValues(alpha: .35)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: widget.onContinueGeneration,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    Icons.play_arrow_outlined,
                    size: 16,
                    color: accentColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Continue generation',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Classic flat layout: single tool calls bar + single text block.
  /// Used when no [ContentBlock]s are present (backward compat).
  List<Widget> _buildClassicLayout({
    required Color iconFgColor,
    required Color accentColor,
    required Color bgColor,
    required bool isUserMessage,
    required bool alignRight,
    required bool hasInfoStatusBar,
    required bool hasVisibleToolCalls,
  }) {
    final bool hasImages = widget.images != null && widget.images!.isNotEmpty;
    final bool placeQrImageAboveResponse = hasImages && _isQrImageMessage;
    // User messages render images above the bubble (see build()).
    final bool renderImagesInBubble = hasImages && !isUserMessage;

    // When streaming AND the model emitted text before any tool call started
    // (text is visible while tools are still pending/running), render the
    // text body above the tool-calls bar so chronological order is preserved.
    final bool streamingTextBeforeTools =
        hasVisibleToolCalls &&
        widget.isStreamingMessage &&
        _strippedMessage.trim().isNotEmpty &&
        widget.toolCalls!.any(
          (t) =>
              t.status == ToolCallStatus.pending ||
              t.status == ToolCallStatus.running,
        );

    final Widget toolBarSection = !hasVisibleToolCalls
        ? const SizedBox.shrink()
        : Builder(
            builder: (_) {
              final cards = _buildArtifactCards(widget.toolCalls!);
              // Classic layout renders arrived images separately above, so the
              // loader grid here shows loaders only (includeArrived: false).
              final generatingGrid = _buildGeneratingImagesGrid(
                widget.toolCalls!,
                includeArrived: false,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildActivityTimeline(widget.toolCalls!, live: true),
                  if (cards.isNotEmpty) ...[
                    const SizedBox(height: _kArtifactGap),
                    ..._stackArtifactCards(cards),
                  ],
                  if (generatingGrid != null) ...[
                    const SizedBox(height: _kArtifactGap),
                    generatingGrid,
                  ],
                  const SizedBox(height: _kBlockGap),
                ],
              );
            },
          );

    // Null when the turn's text strips to nothing. It used to be a
    // `SizedBox.shrink()`, which made the layout look non-empty to any caller
    // and kept an empty bubble alive around it.
    final Widget? messageBody = _buildMessageBody(
      iconFgColor: iconFgColor,
      bgColor: bgColor,
      isUserMessage: isUserMessage,
    );

    return [
      if (hasInfoStatusBar) ...[
        SizedBox(
          width: double.infinity,
          child: _buildInfoStatusBar(iconFgColor, accentColor),
        ),
        // Match the legacy 6-px gap that used to live inside the
        // info status bar's bottom margin. Caller owns the gap now.
        const SizedBox(height: _kCardStackGap),
      ],
      if (renderImagesInBubble && !placeQrImageAboveResponse) ...[
        _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
        const SizedBox(height: _kBlockGap),
      ],
      if (widget.attachments != null && widget.attachments!.isNotEmpty) ...[
        _buildAttachmentsChips(widget.attachments!),
        const SizedBox(height: _kBlockGap),
      ],
      if (streamingTextBeforeTools && messageBody != null) messageBody,
      if (hasVisibleToolCalls) toolBarSection,
      if (widget.messengerMode && !hasVisibleToolCalls && !isUserMessage)
        ..._stackArtifactCards(_buildArtifactCards(_collectAllToolCalls())),
      if (renderImagesInBubble && placeQrImageAboveResponse) ...[
        _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
        const SizedBox(height: _kBlockGap),
      ],
      if (!streamingTextBeforeTools && messageBody != null) messageBody,
      ..._buildAskUserOptions(),
      ..._buildMcpConnectOptions(),
    ];
  }

  Widget _buildFramedUserImageGrid(Widget child) {
    // No frame on user-uploaded images: the thumbnail already has its own
    // rounded border and an outer frame made the bubble look cluttered.
    return child;
  }

  /// Interleaved content blocks layout: renders text, tool calls, and
  /// reasoning blocks in the order they were produced across streaming passes.
  List<Widget> _buildContentBlocksLayout({
    required Color iconFgColor,
    required Color accentColor,
    required Color bgColor,
    required bool alignRight,
  }) {
    final blocks = widget.contentBlocks!;
    final children = <Widget>[];

    // Images render just above the first text block (after tool calls),
    // so they appear in visual order with the tool that generated them.
    final bool hasImages = widget.images != null && widget.images!.isNotEmpty;

    var insertedImage = false;

    // Document attachments
    if (widget.attachments != null && widget.attachments!.isNotEmpty) {
      children.add(_buildAttachmentsChips(widget.attachments!));
      children.add(const SizedBox(height: _kBlockGap));
    }

    // Collect tool call IDs already inside content blocks so we can detect
    // "live" (not-yet-in-blocks) tool calls for the current streaming pass.
    final blockToolCallIds = <String>{};
    for (final block in blocks) {
      if (block.type == ContentBlockType.toolCalls && block.toolCalls != null) {
        for (final tc in block.toolCalls!) {
          blockToolCallIds.add(tc.id);
        }
      }
    }

    final finalizedTextPrefix = blocks
        .where(
          (block) =>
              block.type == ContentBlockType.text &&
              block.text != null &&
              block.text!.trim().isNotEmpty,
        )
        .map((block) => block.text!.trim())
        .join('\n\n')
        .trim();

    // Live tool calls from the current streaming pass that aren't in blocks.
    final liveToolCalls =
        (widget.showToolCalls || widget.messengerMode) &&
            widget.toolCalls != null &&
            widget.toolCalls!.isNotEmpty
        ? widget.toolCalls!
              .where((tc) => !blockToolCallIds.contains(tc.id))
              .map((tc) => ToolCall.fromJson(tc.toJson()))
              .toList()
        : <ToolCall>[];

    // Pre-process blocks into render segments. Text blocks act as separators.
    // Between any two text blocks, ALL reasoning blocks merge into one string
    // and ALL tool-calls collect into one list — so a run of reasoning+tool
    // emissions with no text between them renders as ONE collapsible bar.
    final segments = <_RenderSegment>[];
    _RenderSegment current = _RenderSegment.round();

    // A round holds everything between two real text blocks — all reasoning
    // and all tool calls, in source order. Reasoning is NEVER a separator
    // (only real, non-empty text is), so the final pass's reasoning *about*
    // the tool results stays in the round and renders as the last card inside
    // the one bar — not a peeled-out standalone card between the bar and the
    // answer. Empty rounds add nothing.
    void closeCurrentRound() {
      if (current.hasContent) segments.add(current);
      current = _RenderSegment.round();
    }

    // Trailing widget.message (streaming or finalized tail like an error)
    // computed up front so we know whether trailing text "ends" the last
    // round before live tools or appears after.
    var trailingText = widget.messengerMode
        ? _strippedMessage
        : _strippedMessage.trim();
    if (widget.messengerMode && trailingText == 'Thinking...') {
      trailingText = '';
    }
    if (trailingText.isNotEmpty && finalizedTextPrefix.isNotEmpty) {
      if (trailingText == finalizedTextPrefix ||
          // The flat text field usually holds only the LAST pass, while the
          // blocks hold every pass. Printing it again put the final answer
          // — map card and all — on screen twice.
          finalizedTextPrefix.endsWith(trailingText)) {
        trailingText = '';
      } else if (trailingText.startsWith('$finalizedTextPrefix\n\n')) {
        trailingText = trailingText
            .substring(finalizedTextPrefix.length)
            .trim();
      }
    }

    for (final block in blocks) {
      switch (block.type) {
        case ContentBlockType.reasoning:
          if (widget.messengerMode && widget.showReasoningTokens != true) {
            break;
          }
          final r = block.text?.trim() ?? '';
          if (r.isNotEmpty) {
            // Reasoning that arrives AFTER tool calls in the same open round is
            // a later streaming pass thinking *about the tool results*
            // (buildRoundBlocks always emits a pass's reasoning BEFORE its
            // tools, so reasoning-after-tools can only come from a subsequent
            // pass / the appended final-pass reasoning). We keep it in the SAME
            // round — appended to the ordered timeline — so a run of
            // reasoning+tool emissions renders as ONE bar with cards in true
            // order, instead of one bar per pass. The trailing final-pass
            // reasoning stays here too, so it renders as the last card inside
            // the bar rather than as a separate card after it.
            current.timeline.add(_ToolTimelineEntry.reasoning(r));
          }
        case ContentBlockType.toolCalls:
          if (block.toolCalls != null && block.toolCalls!.isNotEmpty) {
            for (final raw in block.toolCalls!) {
              final tc = ToolCall.fromJson(raw.toJson());
              current.toolCalls.add(tc);
              current.timeline.add(_ToolTimelineEntry.tool(tc));
            }
          }
        case ContentBlockType.text:
          // Strip Kimi tool-call special tokens / dangling `<` at RENDER time,
          // exactly like the trailing-text path above. The desktop send path
          // strips before committing the block, but mobile (and any block
          // already persisted raw in the cache) can still carry a lone `<`
          // text block — this guarantees it never renders as a stray `<`
          // line above a tool-call bar, on every platform.
          final cleaned = _stripForPresentation(block.text ?? '');
          final t = widget.messengerMode ? cleaned : cleaned.trim();
          // A text block that strips to nothing (e.g. a lone `<` junk block a
          // Kimi multiplex leaks between two tool-call sections) is NOT a real
          // separator. Closing the round on it would split one logical tool
          // round into several bars — round 1 of `web_search ×4 → text → …`
          // rendering as four bars instead of one `web_search (4×)`. Skip it
          // (mirroring the trailing-text `isNotEmpty` guard) so adjacent
          // tool-call blocks still merge into a single bar.
          if (t.trim().isEmpty) break;
          closeCurrentRound();
          segments.add(_RenderSegment.text(t));
        case ContentBlockType.sandboxArtifact:
          // Sandbox artifacts are first-class inline blocks. Close the
          // current reasoning/tool round so the artifact appears between
          // the round above it and any subsequent text, in source order.
          closeCurrentRound();
          final p = block.sandboxArtifact;
          if (p != null) segments.add(_RenderSegment.sandboxArtifact(p));
      }
    }

    // Trailing text acts as a separator before any live tool calls, just
    // like a text content block would.
    if (trailingText.isNotEmpty) {
      closeCurrentRound();
      segments.add(_RenderSegment.text(trailingText));
    }

    if (liveToolCalls.isNotEmpty) {
      current.toolCalls.addAll(liveToolCalls);
      for (final tc in liveToolCalls) {
        current.timeline.add(_ToolTimelineEntry.tool(tc));
      }
    }
    closeCurrentRound();

    // Render segments.
    var hasRenderedMainContent = false;

    void renderRound(_RenderSegment seg, {bool live = false}) {
      if (!seg.hasContent) return;
      // Reasoning-only round: standalone collapsible reasoning card.
      // _buildBlockReasoning has no margin, so the trailing gap below
      // the card lives here. `_kCardStackGap` matches the legacy baked-
      // in 6 px tail.
      if (seg.toolCalls.isEmpty) {
        final reasoning = seg.reasoningTexts.join('\n\n');
        if (reasoning.isEmpty) return;
        children.add(_buildBlockReasoning(reasoning, accentColor));
        children.add(const SizedBox(height: _kCardStackGap));
        hasRenderedMainContent = true;
        return;
      }
      // Tool-calls round: one bar with merged reasoning + all tools.
      if (!widget.showToolCalls) {
        final reasoning = seg.reasoningTexts.join('\n\n');
        if (reasoning.isNotEmpty) {
          children.add(_buildBlockReasoning(reasoning, accentColor));
          children.add(const SizedBox(height: _kCardStackGap));
          hasRenderedMainContent = true;
        }
        if (widget.messengerMode) {
          final cards = _buildArtifactCards(seg.toolCalls);
          if (cards.isNotEmpty) {
            children.addAll(_stackArtifactCards(cards));
            children.add(const SizedBox(height: _kArtifactGap));
            hasRenderedMainContent = true;
          }
        }
        return;
      }
      // The ordered timeline (reasoning/tool interleaved in source order) drives
      // the bar's cards, so they render in the order they happened — including
      // the trailing final-pass reasoning as the last card.
      final timeline = seg.timeline;
      if (hasRenderedMainContent) {
        children.add(const SizedBox(height: _kBlockGap));
      }
      children.add(
        _buildActivityTimeline(
          seg.toolCalls,
          contentBlockTimeline: timeline,
          live: live,
        ),
      );
      // Match the gap above the bar (`_kBlockGap`) — only insert the
      // `_kArtifactGap` bar→artifacts spacer when there ARE artifacts,
      // so the gap below the bar stays symmetric with the gap above
      // when no artifacts are attached. (Previously a 6-px spacer always
      // sat between the bar and the artifact slot AND an 8-px spacer
      // sat after, stacking to 14 px below while the gap above stayed
      // at 8 — see commits ce91f6b + b8e4414.)
      final artifactCards = _buildArtifactCards(seg.toolCalls);
      if (artifactCards.isNotEmpty) {
        children.add(const SizedBox(height: _kArtifactGap));
        children.addAll(_stackArtifactCards(artifactCards));
      }
      // While any generate_image call in this round is still running, render a
      // single unified grid (arrived images + loader tiles) in place of the
      // normal image grid, so the images don't reflow as loaders are replaced.
      final generatingGrid = _buildGeneratingImagesGrid(
        seg.toolCalls,
        includeArrived: true,
      );
      if (generatingGrid != null) {
        children.add(const SizedBox(height: _kArtifactGap));
        children.add(generatingGrid);
        children.add(const SizedBox(height: _kBlockGap));
        hasRenderedMainContent = true;
        insertedImage = true;
        return;
      }
      children.add(const SizedBox(height: _kBlockGap));
      hasRenderedMainContent = true;
      // Image insertion right after the round that produced it.
      if (hasImages && !insertedImage) {
        final hasImageResult = seg.toolCalls.any((tc) {
          final r = tc.result;
          return r != null &&
              (r.startsWith('IMAGE:') || r.startsWith('IMAGE_DATA:'));
        });
        if (hasImageResult) {
          children.add(_buildImagesGrid(widget.images!));
          children.add(const SizedBox(height: _kBlockGap));
          insertedImage = true;
        }
      }
    }

    // The last tool-bearing round is the one still open while the message
    // streams — including the Deep Research gaps where the model reasons
    // between tool rounds and every tool reads `completed`. Only that round
    // keeps the live counter running; without this the ticker is cancelled
    // in each gap and "Worked for …" freezes until the next tool starts.
    int lastRoundIndex = -1;
    for (int i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (!s.isText && !s.isSandboxArtifact && s.toolCalls.isNotEmpty) {
        lastRoundIndex = i;
      }
    }

    for (int i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg.isText) {
        children.addAll(
          _buildTextParagraphs(
            text: seg.text!,
            textColor: iconFgColor,
            bgColor: bgColor,
          ),
        );
        hasRenderedMainContent = true;
      } else if (seg.isSandboxArtifact) {
        // A file the coworker produced is its own message, hung after the
        // text, the way a messenger sends a file: inside the answer bubble it
        // read as a footnote to the prose, and a 20 KB document is not a
        // footnote. Collected here, rendered under the bubble by `build`.
        _artifactMessages.add(
          SandboxArtifactBlock(payload: seg.sandboxArtifact!),
        );
      } else {
        renderRound(
          seg,
          live: widget.isStreamingMessage && i == lastRoundIndex,
        );
      }
    }

    if (hasImages && !insertedImage) {
      children.add(_buildImagesGrid(widget.images!));
      children.add(const SizedBox(height: _kBlockGap));
    }

    // ask_user interactive options.
    children.addAll(_buildAskUserOptions());
    // Inline MCP Connect card.
    children.addAll(_buildMcpConnectOptions());

    // No placeholder. An empty list is the honest answer, and the caller uses
    // it to decide there is no bubble to draw (see `_buildAiBubble`).
    return children;
  }

  String _stripAttachmentHeaderForUser(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    final separatorIndex = trimmed.indexOf('\n\n');
    if (separatorIndex < 0) {
      if (_attachmentHeaderRe.hasMatch(trimmed) ||
          trimmed.startsWith('Documents: ')) {
        return '';
      }
      return text;
    }
    final header = trimmed.substring(0, separatorIndex).trim();
    if (_attachmentHeaderRe.hasMatch(header) ||
        header.startsWith('Documents: ')) {
      return trimmed.substring(separatorIndex + 2).trim();
    }
    return text;
  }

  bool get _isPlainMessengerText {
    // Assistant output always uses the canonical Markdown/rich renderer.
    // A punctuation regex cannot recognise the complete Markdown grammar
    // (setext headings, indented code, entities and strikethrough, for example).
    if (!widget.isUser ||
        !widget.messengerMode ||
        widget.message.trim().isEmpty ||
        widget.message == 'Thinking...' ||
        _hasReasoning ||
        _hasModelInfo ||
        (!widget.isUser && widget.showToolCalls) ||
        (widget.images?.isNotEmpty ?? false) ||
        (widget.attachments?.isNotEmpty ?? false) ||
        widget.onAskUserAnswer != null ||
        widget.onConnectMcpServer != null) {
      return false;
    }
    final blocks = widget.contentBlocks;
    if (blocks == null || blocks.isEmpty) return true;
    if (blocks.any((block) => block.type == ContentBlockType.sandboxArtifact)) {
      return false;
    }
    final text = blocks
        .where((block) => block.type == ContentBlockType.text)
        .map((block) => block.text?.trim() ?? '')
        .where((text) => text.isNotEmpty)
        .join('\n\n');
    return text.isEmpty || text == widget.message.trim();
  }

  Widget _buildMessengerText(String text, Color foreground, Color background) {
    final style = TextStyle(
      color: foreground,
      fontSize: _chatFontSize,
      fontFamily: _chatFontFamily,
      fontWeight: FontWeight.w400,
      height: 1.38,
    );
    final footer = _buildBubbleFooter(
      context: context,
      isUser: widget.isUser,
      fill: background,
      onFill: foreground,
    );
    if (footer == null) return Text(text, style: style);
    // The invisible trailing span reserves exactly the time's footprint on
    // the final line. The visible footer is pinned inside the lower corner.
    return Stack(
      children: [
        Text.rich(
          TextSpan(
            style: style,
            children: [
              TextSpan(text: text),
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: ExcludeSemantics(
                  child: Opacity(
                    opacity: 0,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: footer,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(right: 0, bottom: 0, child: footer),
      ],
    );
  }

  /// The turn's own text, or null when it has none to show. Null — not an
  /// empty box — so the caller can leave the slot out entirely.
  Widget? _buildMessageBody({
    required Color iconFgColor,
    required Color bgColor,
    required bool isUserMessage,
  }) {
    final displayText = isUserMessage
        ? _stripAttachmentHeaderForUser(widget.message)
        : _strippedMessage;

    if (!isUserMessage &&
        (displayText.trim().isEmpty || displayText == 'Thinking...')) {
      return null;
    }
    if (isUserMessage && displayText.trim().isEmpty) {
      return null;
    }
    final reply = isUserMessage && widget.messengerMode
        ? ChatReply.parse(displayText)
        : null;
    if (reply != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconFgColor.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(
                  color: iconFgColor.withValues(alpha: 0.5),
                  width: 3,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reply.reply.author,
                  style: TextStyle(
                    color: iconFgColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  reply.reply.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: iconFgColor.withValues(alpha: 0.8),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          _buildMessengerText(reply.message, iconFgColor, bgColor),
        ],
      );
    }
    if (_isPlainMessengerText) {
      return _buildMessengerText(displayText, iconFgColor, bgColor);
    }

    if (isUserMessage) {
      final List<Widget> children = <Widget>[];

      // Use plain Text so taps pass through to the GestureDetector
      // that toggles the action bar. Copy is available via the action bar.
      children.add(
        Text(
          displayText,
          style: TextStyle(
            color: iconFgColor,
            fontSize: _chatFontSize,
            fontFamily: _chatFontFamily,
            height: 1.38,
          ),
        ),
      );

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      );
    }

    final List<Widget> aiParagraphs = _buildTextParagraphs(
      text: displayText,
      textColor: iconFgColor,
      bgColor: bgColor,
    );
    if (aiParagraphs.isEmpty) {
      return null;
    }
    if (aiParagraphs.length == 1) {
      return aiParagraphs.first;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: aiParagraphs,
    );
  }
}
