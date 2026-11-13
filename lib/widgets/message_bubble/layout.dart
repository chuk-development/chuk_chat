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
    // A desktop Agents thread also shows react, reply and more beside the
    // bubble on hover (CHAT-52); the phone keeps the long press.
    // The phone thread (messengerMode) never hovers.
    if (!kPlatformMobile && !widget.messengerMode && _agentsBubbles) {
      child = AgentsBubbleHoverActions(
        alignEnd: widget.isUser,
        onReact: widget.onReaction == null ? null : _showMessengerMenu,
        onReply: widget.onReply,
        onMore: _showMessengerMenu,
        child: child,
      );
    }
    return Semantics(
      onLongPress: () => _showMessengerMenu(null),
      child: GestureDetector(
        onLongPressStart: (details) =>
            _showMessengerMenu(details.globalPosition),
        // A mouse: right click opens the same menu (desktop Agents thread).
        onSecondaryTapDown: (details) =>
            _showMessengerMenu(details.globalPosition),
        child: child,
      ),
    );
  }

  /// Returns the user-selected chat font family, falling back to the historic
  /// Arimo default when the user has explicitly picked the system font.
  String get _chatFontFamily {
    // An Agents thread is a messenger: its bubbles read in the app's own
    // font, not the chat font picked for answers (that can be a monospace
    // face) (CHAT-70).
    if (_agentsBubbles) {
      final String? ui = Theme.of(context).textTheme.bodyMedium?.fontFamily;
      if (ui != null && ui.isNotEmpty) return ui;
    }
    final resolved = resolveChatFontFamily(
      AppThemeService.instance.chatFontFamily,
    );
    return resolved ?? _kAiResponseFontFamilyDefault;
  }

  double get _chatFontSize => AppThemeService.instance.chatFontSize;

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

  /// The top margin of a bubble: the run gap when it opens a run, the tight
  /// in-run gap otherwise. The system lines use it too, so they keep the
  /// rhythm of the bubbles around them.
  double get _runGapAbove => widget.startsNewGroup ? 10 : 2;

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
      padding: EdgeInsets.only(top: _runGapAbove, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // A webhook fire gets its own glyph, and a merged burst says so.
          AppIcon(
            wake.webhook ? Icons.link : Icons.bolt_outlined,
            key: wake.webhook
                ? const ValueKey<String>('automation-wake-webhook')
                : null,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              <String>[
                if (wake.webhook)
                  AppLocalizations.of(context)?.automationKindWebhook ??
                      'Webhook'
                else
                  'Automation',
                if (wake.name.isNotEmpty) wake.name,
                if (wake.merged > 1)
                  AppLocalizations.of(context)
                          ?.webhookMerged('${wake.merged}') ??
                      '${wake.merged} calls merged',
              ].join(' · '),
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
  /// the agent worked. So the fact gets a line, and a tap on it turns the
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
      padding: EdgeInsets.only(top: _runGapAbove, bottom: 4),
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

  /// An Agents thread (the phone messenger view or the desktop thread): every
  /// message is its own bubble, the answer included (CHAT-52).
  bool get _agentsBubbles =>
      widget.messengerMode || ChatOrigin.isAgentsThread(widget.chatId);

  /// A dictated message whose recording waits in the outbox: no text yet.
  bool get _isVoiceSavedOffline =>
      widget.isVoiceInput &&
      widget.message.trim().isEmpty &&
      OutboxStatusLine.applies(widget.status, widget.queueId);

  Widget _buildVoiceSavedOffline(Color foreground) {
    final loc = AppLocalizations.of(context);
    final Color color = foreground.withValues(alpha: .8);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AppIcon(Icons.mic, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            loc?.voiceSavedOffline ??
                'Recording saved — will transcribe when online',
            style: TextStyle(
              fontSize: 14,
              fontStyle: FontStyle.italic,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUserBubble(BuildContext context) {
    const bool isUserMessage = true;
    const bool alignRight = true;

    // A fired automation reaches the thread as a user turn because that is how
    // the Agents host submits it. It is not a person talking, so it never gets
    // a bubble. Agents threads and rooms only: a chuk_chat chat has no host.
    final AutomationWake? wake =
        ChatOrigin.isAgentsThread(widget.chatId) || widget.messengerMode
        ? parseAutomationWake(widget.message)
        : null;
    if (wake != null) return _buildAutomationWakeLine(context, wake);

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.sizeOf(context).width * 0.8;

    final EdgeInsetsGeometry containerPadding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 10,
    );

    // The theme decides the bubble: the accent at 80 % over the page for
    // most packs, a neutral grey for Plane (see buildAppTheme). Its text is
    // the theme's readable colour for that fill.
    // In an Agents thread the user's bubble takes the agent's colour, like a
    // messenger gives every contact its own (CHAT-52).
    final Color? agentFill = _agentsBubbles
        ? AgentThreadAccent.colorOf(context)
        : null;
    final Color bubbleFill = agentFill ?? Theme.of(context).m3.userBubble;
    final Color bubbleTextColor = agentFill == null
        ? Theme.of(context).m3.onUserBubble
        : readableOnFill(agentFill, Colors.white);

    final BoxDecoration decoration = BoxDecoration(
      color: bubbleFill,
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(16),
        topRight: const Radius.circular(16),
        bottomLeft: const Radius.circular(16),
        bottomRight: Radius.circular(widget.endsGroup ? 5 : 16),
      ),
      border: agentFill == null
          ? Border.all(color: Theme.of(context).m3.userBubbleBorder)
          : null,
    );

    // A voice message saved offline has no transcript yet: say what
    // happens to the recording in place of the empty text.
    final Widget userText = _isVoiceSavedOffline
        ? _buildVoiceSavedOffline(bubbleTextColor)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: _buildClassicLayout(
              iconFgColor: bubbleTextColor,
              accentColor: accentColor,
              bgColor: bgColor,
              isUserMessage: isUserMessage,
              alignRight: alignRight,
              hasInfoStatusBar: false,
              hasVisibleToolCalls: false,
            ),
          );
    final bool hasUserActions = widget.userMessageActions.isNotEmpty;
    // A dictated message: the voice bubble owns the tap (open / fold the
    // transcript) and shows the action bar while it is open.
    final bool asVoice =
        widget.isVoiceInput && widget.message.trim().isNotEmpty;
    final Widget bubbleContent = asVoice
        ? VoiceMessageBubble(
            text: widget.message,
            transcript: userText,
            duration: widget.voiceInputDuration,
            foregroundColor: bubbleTextColor,
            decoration: decoration,
            margin: EdgeInsets.only(top: _runGapAbove, bottom: 2),
            padding: containerPadding,
            onExpandedChanged: hasUserActions && !widget.messengerMode
                ? (bool open) => setState(() => _showUserActions = open)
                : null,
          )
        : Container(
            margin: EdgeInsets.only(top: _runGapAbove, bottom: 2),
            padding: containerPadding,
            decoration: decoration,
            clipBehavior: Clip.antiAlias,
            child: userText,
          );

    // The messenger thread keeps its long-press menu (reply, react, copy) in
    // place of the tap-to-open action bar.
    final Widget userBubble = _agentsBubbles
        ? _withMessengerMenu(bubbleContent)
        : asVoice
        ? bubbleContent
        : hasUserActions
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
            if (!_agentsBubbles && hasUserActions && _showUserActions)
              _buildUserActionButtons(iconFgColor),
            if (OutboxStatusLine.applies(widget.status, widget.queueId))
              _buildStatusIndicator(context),
          ],
        ),
      ),
    );
  }

  /// An Agents answer whose turn failed after the host's retries: the
  /// message as one quiet line, like the other status lines of the thread.
  /// No bubble and no Resend: the host already tried (CHAT-64).
  Widget _buildFailedTurnLine(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    final TextStyle style =
        (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
          color: color,
          height: 1.35,
        );
    return Padding(
      key: const ValueKey<String>('agents-failed-turn-line'),
      padding: EdgeInsets.only(top: _runGapAbove + 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // One text line high, so the glyph sits on the first line.
          SizedBox(
            height: (style.fontSize ?? 12) * (style.height ?? 1.35),
            child: Center(
              child: AppIcon(Icons.error_outline, size: 14, color: color),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(child: Text(widget.message.trim(), style: style)),
        ],
      ),
    );
  }

  Widget _buildAiBubble(BuildContext context) {
    const bool isUserMessage = false;
    const bool alignRight = false;
    if (widget.turnFailed &&
        _agentsBubbles &&
        !widget.isStreamingMessage &&
        widget.message.trim().isNotEmpty) {
      return _buildFailedTurnLine(context);
    }
    // Only the messenger thread swaps an empty running turn for typing dots;
    // the relay may stay silent for a while before the first token.
    final bool working =
        widget.messengerMode &&
        (widget.isStreamingMessage || widget.isReasoningStreaming);

    final Color accentColor = Theme.of(context).colorScheme.primary;
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).resolvedIconColor;

    final double effectiveMaxWidth =
        widget.maxWidth ?? MediaQuery.sizeOf(context).width * 0.8;

    // Inside an Agents answer bubble the body takes the bubble's text colour;
    // the action row under the bubble keeps the page's (CHAT-52).
    final Color bodyFgColor = _agentsBubbles
        ? Theme.of(context).m3.onUserBubble
        : iconFgColor;

    // An Agents thread keeps copy and the rest in the messenger menu
    // (long press, right click); no pill under every bubble.
    final bool hasActions = widget.actions.isNotEmpty && !_agentsBubbles;

    final bool useContentBlocks =
        widget.contentBlocks != null && widget.contentBlocks!.isNotEmpty;

    // A running Agents turn draws its work as one panel behind the typing
    // dots (`_buildAgentsLivePanel`), so neither the tool bar nor the
    // reasoning bar draws a second header for it.
    final bool agentsLive = _agentsLive != null;

    final bool hasVisibleToolCalls =
        !useContentBlocks &&
        !agentsLive &&
        widget.showToolCalls &&
        widget.toolCalls != null &&
        widget.toolCalls!.isNotEmpty;

    // The bar also carries the "took 4s" line on a turn with neither
    // reasoning nor a model line, which is why a known duration counts as a
    // reason to build it. A running turn always gets it: the header is what
    // says the turn is alive, and it must not vanish the moment the first
    // answer token replaces the placeholder.
    final bool hasWorkedFor = widget.workedFor != null;
    final bool hasInfoStatusBar =
        !useContentBlocks &&
        !agentsLive &&
        (_hasReasoning ||
            _hasModelInfo ||
            hasWorkedFor ||
            widget.isReasoningStreaming) &&
        !hasVisibleToolCalls;

    // The body is built BEFORE the bubble, because the body is what decides
    // whether there is a bubble at all. The quiet toggles filter blocks out
    // inside these builders — reasoning when Thinking is off, the whole tool
    // round when Activity is off, text that strips to nothing — and a second,
    // hand-kept list of "does this turn count" conditions up here could never
    // stay in step with them. Now nothing rendered means no bubble, by
    // construction.
    _artifactPayloads.clear();
    _metaBelowFiles = null;
    _agentsAnswerStart = null;
    final List<Widget> bodyChildren = useContentBlocks
        ? _buildContentBlocksLayout(
            iconFgColor: bodyFgColor,
            accentColor: accentColor,
            bgColor: bgColor,
            alignRight: alignRight,
          )
        : _buildClassicLayout(
            // No answer text: the body is work outside the bubble, in the
            // page's colour.
            iconFgColor: _strippedMessage.trim().isEmpty
                ? iconFgColor
                : bodyFgColor,
            accentColor: accentColor,
            bgColor: bgColor,
            isUserMessage: isUserMessage,
            alignRight: alignRight,
            hasInfoStatusBar: hasInfoStatusBar,
            hasVisibleToolCalls: hasVisibleToolCalls,
          );

    if (working && bodyChildren.isEmpty && _artifactPayloads.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(top: _runGapAbove),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MessengerTypingIndicator(),
              // A regenerate's earlier versions remain reachable while waiting.
              _buildBottomBar(iconFgColor, false),
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
    // An Agents answer's pictures are tiles under the bubble, so a picture
    // alone is still a message (CHAT-52).
    final bool hasImageTiles =
        _agentsBubbles && (widget.images?.isNotEmpty ?? false);
    if (widget.messengerMode &&
        bodyChildren.isEmpty &&
        _artifactPayloads.isEmpty &&
        !hasImageTiles &&
        !working &&
        widget.status != ChatMessageStatus.interrupted) {
      final List<ToolCall> calls = _collectAllToolCalls();
      if (calls.isEmpty) return const SizedBox.shrink();
      return _buildQuietWorkLine(context, calls);
    }

    // With the files pulled out, an answer that was nothing but a file would
    // leave an empty block. Then the file is the message.
    // An Agents answer splits in two: the turn's work (thinking, tools,
    // interim text), folded and outside the bubble, and the final answer
    // text, the only thing in the bubble. No answer text, no bubble: an
    // empty grey capsule under a run was the result (CHAT-67, CHAT-69).
    final int? answerStart = !_agentsBubbles
        ? 0
        : useContentBlocks
        ? _agentsAnswerStart
        // The placeholder of a turn that has not written yet is no answer:
        // its typing dots stand alone, like the dots of a host run.
        : (_strippedMessage.trim().isEmpty || _strippedMessage == 'Thinking...'
              ? null
              : 0);
    final List<Widget> workKids = answerStart == null
        ? bodyChildren
        : bodyChildren.sublist(0, answerStart);
    final List<Widget> answerKids = answerStart == null
        ? const <Widget>[]
        : bodyChildren.sublist(answerStart);
    final bool bubbleCarriesContent = _agentsBubbles
        ? answerKids.isNotEmpty
        : bodyChildren.isNotEmpty ||
              (_artifactPayloads.isEmpty && !hasImageTiles);

    // An Agents thread draws every answer as its own bubble on the left, in
    // the shape and colours of chuk_chat's user bubble (CHAT-52). A
    // chuk_chat chat keeps the answer straight on the page.
    final bool answerBubble = _agentsBubbles;
    final ThemeData pageTheme = Theme.of(context);
    final Widget answerBody = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: answerKids,
    );
    final Widget bubbleContent = Container(
      // A sender label opens the run and carries its gap (see
      // [MessageBubble.senderLabel]).
      margin: EdgeInsets.only(
        top: widget.senderLabel != null
            ? 0
            : workKids.isNotEmpty
            ? 4
            : _runGapAbove,
        bottom: 2,
      ),
      padding: answerBubble
          ? const EdgeInsets.fromLTRB(14, 6, 14, 6)
          : const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
      decoration: answerBubble
          ? BoxDecoration(
              color: pageTheme.m3.userBubble,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(widget.endsGroup ? 5 : 16),
                bottomRight: const Radius.circular(16),
              ),
              border: Border.all(color: pageTheme.m3.userBubbleBorder),
            )
          : null,
      clipBehavior: answerBubble ? Clip.antiAlias : Clip.none,
      child: answerBubble
          // The answer's text reads the theme's foreground; inside the
          // bubble that is the bubble's own text colour.
          ? Theme(
              data: pageTheme.copyWith(
                colorScheme: pageTheme.colorScheme.copyWith(
                  onSurface: pageTheme.m3.onUserBubble,
                ),
                // List markers fall back to the title colour.
                textTheme: pageTheme.textTheme.apply(
                  bodyColor: pageTheme.m3.onUserBubble,
                  displayColor: pageTheme.m3.onUserBubble,
                ),
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: pageTheme.m3.onUserBubble),
                child: answerBody,
              ),
            )
          : answerBody,
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
            // Only a group room names the sender. The label opens the run
            // with the room's own run gap, the one its face gutter and its
            // system lines use, so the face stands level with the name.
            if (widget.senderLabel case final Widget label?)
              Padding(
                padding: const EdgeInsets.only(
                  top: kBubbleGapBetweenGroups,
                  left: 4,
                  bottom: 3,
                ),
                child: label,
              ),
            // The Agents turn's work, folded, above its answer bubble.
            if (workKids.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  top: widget.senderLabel != null ? 0 : _runGapAbove,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: workKids,
                ),
              ),
            if (bubbleCarriesContent)
              _agentsBubbles
                  ? _withMessengerMenu(bubbleContent)
                  : bubbleContent,
            // A file an agent hands over (an Agents host delivery) is its
            // own block under the answer. This is the only renderer for those
            // files; the card takes the app's card radius.
            for (int i = 0; i < _artifactPayloads.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  top: i > 0
                      ? _kArtifactGap
                      : bubbleCarriesContent
                      // The body already ends in the file gap of its own: a
                      // text block's 4 px, its last line's 4 px margin and
                      // the bubble's 2 + 2 px.
                      ? 0
                      : _runGapAbove,
                ),
                child: SandboxArtifactBlock(
                  payload: _artifactPayloads[i],
                  borderRadius: kBorderRadiusCard,
                ),
              ),
            // An Agents answer's pictures: their own tiles under the bubble
            // (CHAT-52).
            if (hasImageTiles)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _buildImagesGrid(widget.images ?? const <String>[]),
              ),
            // The meta line draws 2 px of air above itself.
            if (_metaBelowFiles case final Widget meta?)
              Padding(
                padding: const EdgeInsets.only(top: _kFileGap - 2),
                child: meta,
              ),
            if (showContinueButton) _buildContinueButton(context, accentColor),
            _buildBottomBar(
              iconFgColor,
              hasActions && !widget.messengerMode,
              // Under a file with no meta line between them, the action row
              // keeps the file gap; the meta line carries its own rhythm.
              topGap: _artifactPayloads.isNotEmpty && _metaBelowFiles == null
                  ? _kFileGap
                  : 0,
            ),
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
    // User messages render images above the bubble (see build()); an
    // Agents answer draws them as tiles under its bubble.
    final bool renderImagesInBubble =
        hasImages && !isUserMessage && !_agentsBubbles;

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
      if (!isUserMessage && _agentsLive != null) ...[
        _buildAgentsLivePanel(),
        const SizedBox(height: _kInfoBarGap),
      ],
      if (hasInfoStatusBar) ...[
        SizedBox(
          width: double.infinity,
          child: _buildInfoStatusBar(iconFgColor, accentColor),
        ),
        const SizedBox(height: _kInfoBarGap),
      ],
      if (renderImagesInBubble && !placeQrImageAboveResponse) ...[
        _buildFramedUserImageGrid(_buildImagesGrid(widget.images!)),
        const SizedBox(height: _kBlockGap),
      ],
      if (widget.attachments != null && widget.attachments!.isNotEmpty) ...[
        _buildAttachmentsChips(widget.attachments!),
        const SizedBox(height: _kBlockGap),
      ],
      if (widget.agentsAttachments?.isNotEmpty ?? false) ...[
        AgentsAttachmentChips(
          items: widget.agentsAttachments ?? const <AgentsAttachmentInfo>[],
          alignEnd: isUserMessage,
        ),
        const SizedBox(height: _kBlockGap),
      ],
      if (streamingTextBeforeTools && messageBody != null) messageBody,
      if (hasVisibleToolCalls) toolBarSection,
      if (!isUserMessage && _agentsLive == null)
        ...() {
          final List<Widget> rows = _buildApprovalRows(
            widget.toolCalls ?? const <ToolCall>[],
          );
          return rows.isEmpty
              ? const <Widget>[]
              : <Widget>[...rows, const SizedBox(height: _kBlockGap)];
        }(),
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
    // so they appear in visual order with the tool that generated them. An
    // Agents answer draws them as tiles under its bubble instead.
    final bool hasImages =
        widget.images != null && widget.images!.isNotEmpty && !_agentsBubbles;

    var insertedImage = false;

    // Document attachments
    if (widget.attachments != null && widget.attachments!.isNotEmpty) {
      children.add(_buildAttachmentsChips(widget.attachments!));
      children.add(const SizedBox(height: _kBlockGap));
    }
    final List<AgentsAttachmentInfo>? agentsFiles = widget.agentsAttachments;
    if (agentsFiles != null && agentsFiles.isNotEmpty) {
      children.add(
        AgentsAttachmentChips(items: agentsFiles, alignEnd: widget.isUser),
      );
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
    var trailingText = _strippedMessage.trim();
    // A host turn streams its blocks while the flat text is still the
    // placeholder; the placeholder is not answer text.
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

    // An Agents thread shows only the final answer in its bubble. Text that
    // came BEFORE the turn's last piece of work (a tool call or thinking),
    // like "I'll check the mailbox.", is interim and folds into the work
    // block (CHAT-69). Text after the last work is the answer, all of it.
    int lastWorkBlock = -1;
    if (_agentsBubbles) {
      for (int i = blocks.length - 1; i >= 0; i--) {
        final ContentBlockType type = blocks[i].type;
        if (type == ContentBlockType.toolCalls ||
            type == ContentBlockType.reasoning) {
          lastWorkBlock = i;
          break;
        }
      }
    }
    int blockIndex = -1;

    for (final block in blocks) {
      blockIndex++;
      switch (block.type) {
        case ContentBlockType.reasoning:
          // The phone thread's "Show thinking" switch (see tools.dart).
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
          final t = stripToolCallBlocksForDisplay(block.text ?? '').trim();
          // A text block that strips to nothing (e.g. a lone `<` junk block a
          // Kimi multiplex leaks between two tool-call sections) is NOT a real
          // separator. Closing the round on it would split one logical tool
          // round into several bars — round 1 of `web_search ×4 → text → …`
          // rendering as four bars instead of one `web_search (4×)`. Skip it
          // (mirroring the trailing-text `isNotEmpty` guard) so adjacent
          // tool-call blocks still merge into a single bar.
          if (t.isEmpty) break;
          if (_agentsBubbles && blockIndex < lastWorkBlock) {
            // Interim text: part of the work, folded with it.
            current.timeline.add(_ToolTimelineEntry.reasoning(t));
            break;
          }
          closeCurrentRound();
          segments.add(_RenderSegment.text(t));
        case ContentBlockType.sandboxArtifact:
          // Sandbox artifacts are first-class inline blocks. Close the
          // current reasoning/tool round so the artifact appears between
          // the round above it and any subsequent text, in source order.
          closeCurrentRound();
          final p = block.sandboxArtifact;
          if (p != null) segments.add(_RenderSegment.sandboxArtifact(p));
        case ContentBlockType.steer:
          // A message the user sent while the turn ran: it splits the
          // rounds, the same way it split the model's work.
          final s = block.text?.trim() ?? '';
          if (s.isEmpty) break;
          closeCurrentRound();
          segments.add(_RenderSegment.steer(s));
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
    final bool agentsLive = _agentsLive != null;

    void renderRound(
      _RenderSegment seg, {
      bool live = false,
      bool carriesTurnStatus = false,
    }) {
      if (!seg.hasContent) return;
      // A running Agents turn shows its rounds in the live panel behind the
      // typing dots; drawing them here as well would print the work twice.
      if (agentsLive) return;
      // Reasoning-only round: standalone collapsible reasoning card.
      // _buildBlockReasoning has no margin, so the trailing gap below
      // the card lives here. `_kCardStackGap` matches the legacy baked-
      // in 6 px tail.
      if (seg.toolCalls.isEmpty) {
        final reasoning = seg.reasoningTexts.join('\n\n');
        if (reasoning.isEmpty) return;
        children.add(
          _buildBlockReasoning(
            reasoning,
            accentColor,
            live: live,
            carriesTurnStatus: carriesTurnStatus,
          ),
        );
        children.add(const SizedBox(height: _kCardStackGap));
        hasRenderedMainContent = true;
        return;
      }
      // Tool-calls round: one bar with merged reasoning + all tools.
      if (!widget.showToolCalls) {
        final reasoning = seg.reasoningTexts.join('\n\n');
        if (reasoning.isNotEmpty) {
          children.add(
            _buildBlockReasoning(
              reasoning,
              accentColor,
              live: live,
              carriesTurnStatus: carriesTurnStatus,
            ),
          );
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
          carriesTurnStatus: carriesTurnStatus,
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
    // The turn's clock and model line hang off exactly one round — the last
    // one of any kind, reasoning included. Without this a message whose last
    // round is pure reasoning showed a bare "Thought" with no time at all,
    // and its counter stopped the moment the round stopped running tools.
    int statusRoundIndex = -1;
    for (int i = 0; i < segments.length && !agentsLive; i++) {
      final s = segments[i];
      if (s.isText || s.isSandboxArtifact || s.isSteer || !s.hasContent) {
        continue;
      }
      // A round the reader never sees cannot carry the status: with tool
      // calls switched off, a tools-only round renders nothing at all.
      final bool rendersSomething =
          s.reasoningTexts.any((text) => text.trim().isNotEmpty) ||
          (widget.showToolCalls && s.toolCalls.isNotEmpty);
      if (rendersSomething) statusRoundIndex = i;
    }

    for (int i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg.isText) {
        _agentsAnswerStart ??= children.length;
        children.addAll(
          _buildTextParagraphs(
            text: seg.text!,
            textColor: iconFgColor,
            bgColor: bgColor,
          ),
        );
        hasRenderedMainContent = true;
      } else if (seg.steer case final String steer) {
        children.add(_buildSteerNote(steer, iconFgColor, bgColor));
        children.add(const SizedBox(height: _kBlockGap));
        hasRenderedMainContent = true;
      } else if (seg.isSandboxArtifact) {
        // A file the agent produced is its own message, hung after the
        // text, the way a messenger sends a file: inside the answer bubble it
        // read as a footnote to the prose, and a 20 KB document is not a
        // footnote. Collected here, rendered under the bubble by `build`.
        _artifactPayloads.add(seg.sandboxArtifact!);
      } else {
        renderRound(
          seg,
          live: widget.isStreamingMessage && i == statusRoundIndex,
          carriesTurnStatus: i == statusRoundIndex,
        );
        // An answered approval stays where it happened, as one small row.
        if (!agentsLive) {
          final List<Widget> rows = _buildApprovalRows(seg.toolCalls);
          if (rows.isNotEmpty) {
            children.addAll(rows);
            children.add(const SizedBox(height: _kBlockGap));
            hasRenderedMainContent = true;
          }
        }
      }
    }

    if (hasImages && !insertedImage) {
      children.add(_buildImagesGrid(widget.images!));
      children.add(const SizedBox(height: _kBlockGap));
    }

    // A turn with no round of its own — a plain answer with no reasoning and
    // no tool call — still owes the reader the status: the counting header
    // while it runs, the quiet "12s · model" line once it is done.
    // In the messenger thread a settled turn that drew nothing stays empty
    // here: its bubble decides on the quiet work line instead.
    if (statusRoundIndex < 0 &&
        (!widget.messengerMode ||
            children.isNotEmpty ||
            widget.isStreamingMessage)) {
      final status = _buildTurnStatusOnly();
      if (widget.isStreamingMessage) {
        children.insert(0, status);
        children.insert(1, const SizedBox(height: _kInfoBarGap));
      } else if (_artifactPayloads.isNotEmpty) {
        // The files follow the text; the settled line goes under them.
        if (_metaFooterParts().isNotEmpty) _metaBelowFiles = status;
      } else {
        children.add(status);
      }
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

  /// A steer inside the answer: the user's message, right-aligned in the
  /// user-bubble fill, a little smaller than a real user bubble.
  Widget _buildSteerNote(String text, Color iconFgColor, Color bgColor) {
    // The same bubble as the user's own message (theme tokens).
    final Color fill = Theme.of(context).m3.userBubble;
    final Color textColor = Theme.of(context).m3.onUserBubble;
    return Align(
      key: const ValueKey<String>('message-steer-note'),
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Theme.of(context).m3.userBubbleBorder),
        ),
        child: _buildUserText(text, textColor),
      ),
    );
  }

  /// A user's text as chuk_chat draws it: plain [Text], so taps pass through
  /// to the gesture that opens the actions. Copy lives in those actions.
  ///
  /// A pasted credential (API key, token, JWT) is drawn masked with an eye
  /// toggle (`MaskedSecretText`); copy still copies [widget.message] as sent.
  Widget _buildUserText(String text, Color color) {
    final TextStyle style = TextStyle(
      color: color,
      fontSize: _chatFontSize,
      fontFamily: _agentsBubbles
          ? _chatFontFamily
          : resolveChatFontFamily(AppThemeService.instance.chatFontFamily),
      height: 1.38,
    );
    final List<SecretMatch> secrets = findSecrets(text);
    if (secrets.isNotEmpty) {
      return MaskedSecretText(text: text, style: style, matches: secrets);
    }
    return Text(text, style: style);
  }

  /// The quote a reply carries above its own text: a plain bar, the author
  /// and a muted excerpt, drawn in the bubble's own text colour.
  Widget _buildReplyQuote(ChatReply reply, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: color.withValues(alpha: 0.5), width: 3),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reply.author,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            reply.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color.withValues(alpha: 0.8),
              fontSize: 13,
              height: 1.3,
            ),
          ),
        ],
      ),
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
        VoicePlaybackDetails.parse(widget.voicePlayback)?.interrupted == true &&
        VoicePlaybackDetails.parse(widget.voicePlayback)
                ?.appliesTo(displayText) ==
            true) {
      return VoicePlaybackCaption(
        heard: displayText,
        metadata: widget.voicePlayback,
        textStyle: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: iconFgColor),
      );
    }

    if (!isUserMessage &&
        (displayText.trim().isEmpty || displayText == 'Thinking...')) {
      return null;
    }
    if (isUserMessage && displayText.trim().isEmpty) {
      return null;
    }
    // A reply sent from the messenger thread carries the quoted message.
    final reply = isUserMessage && widget.messengerMode
        ? ChatReply.parse(displayText)
        : null;
    if (reply != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildReplyQuote(reply.reply, iconFgColor),
          _buildUserText(reply.message, iconFgColor),
        ],
      );
    }

    if (isUserMessage) {
      return _buildUserText(displayText, iconFgColor);
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
