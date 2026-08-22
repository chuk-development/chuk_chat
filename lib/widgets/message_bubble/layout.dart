// lib/widgets/message_bubble/layout.dart
//
// Part of message_bubble.dart — the bubble skeleton: the user/AI containers,
// the classic flat layout and the interleaved content-blocks layout, plus the
// display-preference getters they branch on and the message-body text render.

// ignore_for_file: invalid_use_of_protected_member

part of '../message_bubble.dart';

extension _MessageBubbleLayout on _MessageBubbleState {
  /// Returns the user-selected chat font family, falling back to the historic
  /// Arimo default when the user has explicitly picked the system font.
  String get _chatFontFamily {
    final resolved = resolveChatFontFamily(
      AppThemeService.instance.chatFontFamily,
    );
    return resolved ?? _kAiResponseFontFamilyDefault;
  }

  bool get _hasReasoning {
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
    // Prioritize widget prop, then loaded preference, then cached, then default
    final show =
        widget.showModelInfo ??
        _showModelInfo ??
        _cachedShowModelInfo ??
        kDefaultShowModelInfo;
    return show && widget.modelLabel != null && widget.modelLabel!.isNotEmpty;
  }

  bool get _shouldShowTps {
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
      _strippedMessageCache = stripToolCallBlocksForDisplay(widget.message);
    }
    return _strippedMessageCache!;
  }

  Widget _buildUserBubble(BuildContext context) {
    const bool isUserMessage = true;
    const bool alignRight = true;

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.8;

    final EdgeInsetsGeometry containerPadding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 10,
    );

    final BoxDecoration decoration = BoxDecoration(
      color: accentColor.withValues(alpha: .8),
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(16),
        topRight: const Radius.circular(16),
        bottomLeft: const Radius.circular(16),
        bottomRight: Radius.circular(widget.endsGroup ? 5 : 16),
      ),
      border: Border.all(color: iconFgColor.withValues(alpha: .3)),
    );

    final Widget bubbleContent = Container(
      margin: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 2, bottom: 2),
      padding: containerPadding,
      decoration: decoration,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: _buildClassicLayout(
          iconFgColor: iconFgColor,
          accentColor: accentColor,
          bgColor: bgColor,
          isUserMessage: isUserMessage,
          alignRight: alignRight,
          hasInfoStatusBar: false,
          hasVisibleToolCalls: false,
        ),
      ),
    );

    final bool hasUserActions = widget.userMessageActions.isNotEmpty;
    final Widget userBubble = hasUserActions
        ? GestureDetector(
            onTap: () => setState(() => _showUserActions = !_showUserActions),
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
            if (hasUserActions && _showUserActions)
              _buildUserActionButtons(iconFgColor),
            if (widget.status == ChatMessageStatus.pending ||
                widget.status == ChatMessageStatus.failed)
              _buildStatusIndicator(context),
          ],
        ),
      ),
    );
  }

  Widget _buildAiBubble(BuildContext context) {
    const bool isUserMessage = false;
    const bool alignRight = false;

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.of(context).size.width * 0.8;

    final bool hasActions = widget.actions.isNotEmpty;

    final bool useContentBlocks =
        widget.contentBlocks != null && widget.contentBlocks!.isNotEmpty;

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
        (_hasReasoning || _hasModelInfo || isWaitingForFirstTokens) &&
        !hasVisibleToolCalls;

    final EdgeInsetsGeometry containerPadding = const EdgeInsets.symmetric(
      horizontal: 0,
      vertical: 2,
    );

    final Widget bubbleContent = Container(
      margin: EdgeInsets.only(top: widget.startsNewGroup ? 10 : 2, bottom: 2),
      padding: containerPadding,
      decoration: null,
      clipBehavior: Clip.none,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: useContentBlocks
            ? _buildContentBlocksLayout(
                iconFgColor: iconFgColor,
                accentColor: accentColor,
                bgColor: bgColor,
                alignRight: alignRight,
              )
            : _buildClassicLayout(
                iconFgColor: iconFgColor,
                accentColor: accentColor,
                bgColor: bgColor,
                isUserMessage: isUserMessage,
                alignRight: alignRight,
                hasInfoStatusBar: hasInfoStatusBar,
                hasVisibleToolCalls: hasVisibleToolCalls,
              ),
      ),
    );

    final bool showContinueButton = !widget.isUser &&
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
            bubbleContent,
            if (showContinueButton) _buildContinueButton(context, accentColor),
            _buildBottomBar(iconFgColor, hasActions),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
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

    final Widget messageBody = _buildMessageBody(
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
      if (streamingTextBeforeTools) messageBody,
      if (hasVisibleToolCalls) toolBarSection,
      if (renderImagesInBubble && placeQrImageAboveResponse) ...[
        _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
        const SizedBox(height: _kBlockGap),
      ],
      if (!streamingTextBeforeTools) messageBody,
      ..._buildAskUserOptions(),
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
    final liveToolCalls = widget.showToolCalls &&
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
    var trailingText = _strippedMessage.trim();
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
          final t = stripToolCallBlocksForDisplay(block.text ?? '').trim();
          // A text block that strips to nothing (e.g. a lone `<` junk block a
          // Kimi multiplex leaks between two tool-call sections) is NOT a real
          // separator. Closing the round on it would split one logical tool
          // round into several bars — round 1 of `web_search ×4 → text → …`
          // rendering as four bars instead of one `web_search (4×)`. Skip it
          // (mirroring the trailing-text `isNotEmpty` guard) so adjacent
          // tool-call blocks still merge into a single bar.
          if (t.isEmpty) break;
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

    void renderRound(_RenderSegment seg) {
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

    for (final seg in segments) {
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
        if (hasRenderedMainContent) {
          children.add(const SizedBox(height: _kArtifactGap));
        }
        children.add(SandboxArtifactBlock(payload: seg.sandboxArtifact!));
        children.add(const SizedBox(height: _kArtifactGap));
        hasRenderedMainContent = true;
      } else {
        renderRound(seg);
      }
    }

    if (hasImages && !insertedImage) {
      children.add(_buildImagesGrid(widget.images!));
      children.add(const SizedBox(height: _kBlockGap));
    }

    // ask_user interactive options.
    children.addAll(_buildAskUserOptions());

    if (children.isEmpty) {
      children.add(const SizedBox.shrink());
    }

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

  Widget _buildMessageBody({
    required Color iconFgColor,
    required Color bgColor,
    required bool isUserMessage,
  }) {
    final displayText = isUserMessage
        ? _stripAttachmentHeaderForUser(widget.message)
        : _strippedMessage;

    if (!isUserMessage &&
        (displayText.trim().isEmpty || displayText == 'Thinking...')) {
      return const SizedBox.shrink();
    }
    if (isUserMessage && displayText.trim().isEmpty) {
      return const SizedBox.shrink();
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
            fontSize: AppThemeService.instance.chatFontSize,
            fontFamily: resolveChatFontFamily(
              AppThemeService.instance.chatFontFamily,
            ),
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
      return const SizedBox.shrink();
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
