// lib/widgets/message_bubble/tools.dart
//
// Part of message_bubble.dart — the tool-call side of a turn: the reasoning
// card + model footer, the activity timeline bar, the tap-through tool-detail
// sheet, the inline artifact cards, and the ask_user option buttons.

// ignore_for_file: invalid_use_of_protected_member

part of '../message_bubble.dart';

extension _MessageBubbleTools on _MessageBubbleState {
  /// Renders a reasoning content block as an expandable card. Renders
  /// NO external margin — callers control the gap below the card via
  /// SizedBox (typically `_kCardStackGap` or `_kBlockGap`).
  Widget _buildBlockReasoning(String text, Color accentColor) {
    // The same timeline the tool rounds use — one thinking step on the
    // rail, opened by a tap. There is no second design for reasoning.
    return AgentActivityTimeline(
      toolCalls: const <ToolCall>[],
      steps: <AgentActivityStep>[AgentActivityStep.reasoning(text)],
      isRunning: false,
    );
  }

  /// Unified status bar for reasoning and model info, matching function_calling
  /// client design: expandable cards with accent-tinted backgrounds.
  ///
  /// Renders NO external margin — callers control the gap below the bar
  /// via SizedBox using the `_kBlockGap` constant.
  Widget _buildInfoStatusBar(Color iconFgColor, Color accentColor) {
    final bool isStreaming = widget.isReasoningStreaming;
    final String reasoning = _hasReasoning ? (widget.reasoning ?? '') : '';

    // No reasoning happened and nothing is streaming: never claim "Thought".
    // A model that just answered (e.g. "Hi") produced no reasoning tokens, so
    // the collapsible "Thought for X" bar would open onto nothing. Show only
    // the quiet model footer when there is one, and otherwise render nothing.
    if (!isStreaming && reasoning.trim().isEmpty) {
      return _hasModelInfo ? _buildModelFooter() : const SizedBox.shrink();
    }

    return AgentActivityTimeline(
      toolCalls: const <ToolCall>[],
      steps: <AgentActivityStep>[
        if (reasoning.trim().isNotEmpty) AgentActivityStep.reasoning(reasoning),
      ],
      isRunning: isStreaming,
      // A turn with no tool call runs through here, so it needs the same
      // header the tool path gets: the live phase and a count from the
      // request, then the settled duration once the answer is there.
      phase: _currentPhase(isStreaming),
      startedAt: isStreaming ? widget.turnStartedAt : null,
      finalDuration: isStreaming ? null : widget.workedFor,
      footer: _hasModelInfo ? _buildModelFooter() : null,
    );
  }

  /// The phase of the running stream, taken straight from the stream rather
  /// than guessed from what has arrived so far: "no text yet" cannot tell a
  /// request still in flight from a server reading a long prompt, and those
  /// two waits fail for different reasons. Null when this message is not the
  /// one currently running.
  StreamPhase? _currentPhase(bool isRunning) {
    if (!isRunning) return null;
    final chatId = ArtifactStorageService.activeChatId;
    if (chatId == null || chatId.isEmpty) return null;
    return StreamingManager().phaseOf(chatId);
  }

  /// The model line: which model answered, on which provider, how fast.
  /// A quiet footer under the steps, not a card of its own.
  Widget _buildModelFooter() {
    final theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final parts = <String>[
      widget.modelLabel ?? '',
      if (widget.modelProvider?.isNotEmpty ?? false) widget.modelProvider!,
      if (_shouldShowTps) '${widget.tps!.toStringAsFixed(1)} tok/s',
    ].where((part) => part.trim().isNotEmpty);

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 13, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders inline artifact cards for artifact_manager tool calls, so users
  /// can re-open the artifact panel after closing it (Claude.ai style).
  ///
  /// Cards render NO external padding — callers must stack them through
  /// `_stackArtifactCards` (or insert `_kArtifactGap` spacers manually)
  /// so the artifact-to-artifact spacing lives in the layout, not in
  /// this builder. Previously every card was wrapped in
  /// `Padding(bottom: 6)`, which silently added a 6 px tail after the
  /// last card on top of whatever spacer the caller appended.
  List<Widget> _buildArtifactCards(List<ToolCall> toolCalls) {
    if (!kFeatureArtifacts) return const [];
    final cards = <Widget>[];
    for (final tc in toolCalls) {
      // Render error ToolCalls as a visible error chip so silent failures
      // (malformed tag, RLS denial, network error) surface to the user
      // instead of producing a mysteriously empty chat bubble.
      if (tc.status == ToolCallStatus.error &&
          (tc.name == 'artifact_manager' || tc.name == 'typst_compile')) {
        final result = tc.result ?? 'Unknown error';
        cards.add(_ArtifactErrorCard(toolName: tc.name, message: result));
        continue;
      }
      if (tc.status != ToolCallStatus.completed) continue;

      String artifactId = '';
      String title = '';
      String type = '';

      if (tc.name == 'artifact_manager') {
        final args = tc.arguments;
        final action = args['action'] as String? ?? '';
        if (action != 'create' && action != 'rewrite') continue;
        artifactId = args['artifact_id'] as String? ?? '';
        if (artifactId.isEmpty) continue;
        title = args['title'] as String? ?? artifactId;
        type = args['type'] as String? ?? '';
      } else if (tc.name == 'typst_compile') {
        final args = tc.arguments;
        artifactId = args['artifact_id'] as String? ?? '';
        if (artifactId.isEmpty) continue;
        final rawTitle = args['title'];
        title = (rawTitle is String && rawTitle.trim().isNotEmpty)
            ? rawTitle.trim()
            : artifactId;
        type = 'typst';
      } else {
        continue;
      }

      // Parse "version: N" from the tool result so each chip can open the
      // exact snapshot that was produced at this point in the chat.
      int? version;
      final result = tc.result;
      if (result != null) {
        final match = RegExp(r'version:\s*(\d+)').firstMatch(result);
        if (match != null) {
          version = int.tryParse(match.group(1) ?? '');
        }
      }

      cards.add(
        _ArtifactInlineCard(
          artifactId: artifactId,
          title: title,
          type: type,
          authoredVersion: version,
        ),
      );
    }
    return cards;
  }

  /// Wrap a list of artifact cards into one cohesive "artifact stack":
  /// a `_kArtifactGap` after every card, including the last one, so the
  /// stack reads as a single visual unit attached to the tool-call bar
  /// above it. Callers add a separate `_kBlockGap` AFTER the stack to
  /// separate it from the next block in the message body. Matches the
  /// legacy baked-in `Padding(bottom: 6)` per-card behaviour for visual
  /// parity with master HEAD.
  List<Widget> _stackArtifactCards(List<Widget> cards) {
    if (cards.isEmpty) return cards;
    final out = <Widget>[];
    for (final card in cards) {
      out.add(card);
      out.add(const SizedBox(height: _kArtifactGap));
    }
    return out;
  }

  /// Returns a self-contained tool-calls bar (the pill with the
  /// "Tools…" header + the expandable list of call cards). Renders NO
  /// external margin — callers must wrap with `SizedBox(height:
  /// _kBlockGap)` (and `_kArtifactGap` for any attached artifact stack)
  /// for spacing relative to sibling blocks. Re-adding a hidden margin
  /// here was the bug fixed in commit b8e4414.
  /// The round's work as a plain timeline: every step while it runs, one
  /// folded line ("Worked for 13s") once the answer is there.
  ///
  /// Tapping a step opens its arguments and result in a sheet — the raw
  /// data the old expandable bar showed inline, without the box competing
  /// with the answer for attention.
  Widget _buildActivityTimeline(
    List<ToolCall> toolCalls, {
    List<_ToolTimelineEntry>? contentBlockTimeline,
    bool live = false,
  }) {
    // The live round keeps counting while the message streams — including
    // the stretch after its last tool, where the model is writing and the
    // counter used to sit frozen at the time the tools took.
    final bool isRunning =
        widget.isStreamingMessage &&
        (live ||
            toolCalls.any(
              (t) =>
                  t.status == ToolCallStatus.running ||
                  t.status == ToolCallStatus.pending,
            ));

    final steps = contentBlockTimeline == null
        ? null
        : <AgentActivityStep>[
            for (final entry in contentBlockTimeline)
              if (entry.isReasoning)
                AgentActivityStep.reasoning(entry.reasoning!)
              else if (entry.toolCall != null)
                AgentActivityStep.tool(entry.toolCall!),
          ];

    return AgentActivityTimeline(
      toolCalls: toolCalls,
      steps: steps,
      isRunning: isRunning,
      phase: _currentPhase(isRunning),
      startedAt: isRunning ? widget.turnStartedAt : null,
      finalDuration: isRunning ? null : widget.workedFor,
      onStepTap: _showToolCallDetails,
      onSourceTap: _openSourceUrl,
    );
  }

  /// Open a source chip's page in the browser.
  Future<void> _openSourceUrl(AgentActivitySource source) async {
    final uri = Uri.tryParse(source.url);
    if (uri == null) return;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {
      // Nothing to do when the device has no handler for it.
    }
  }

  void _showToolCallDetails(ToolCall toolCall) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    toolCall.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildToolCallExpandedWidget(toolCall),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildToolCallExpandedWidget(ToolCall toolCall) {
    final sections = <Widget>[];

    final args = Map<String, dynamic>.from(toolCall.arguments);
    final rawCode = args.remove('code');
    final String? codeArg = rawCode is String && rawCode.isNotEmpty
        ? rawCode
        : null;

    // For notes updates that render a diff, the diff card already shows
    // exactly what changed — so suppress the redundant raw args
    // (action / edits / content) to avoid showing the same change twice.
    final bool hasDiffResult =
        toolCall.result != null && _diffBlockRegex.hasMatch(toolCall.result!);
    final bool suppressArgs = toolCall.name == 'notes' && hasDiffResult;

    if (codeArg != null) {
      sections.add(_buildToolSection(label: 'code', body: codeArg, mono: true));
    }

    if (!suppressArgs) {
      args.forEach((k, v) {
        if (v == null) return;
        if (v is String) {
          final mono = v.contains('\n') || v.length > 80;
          sections.add(_buildToolSection(label: k, body: v, mono: mono));
        } else if (v is num || v is bool) {
          sections.add(_buildToolSection(label: k, body: v.toString()));
        } else {
          String pretty;
          try {
            pretty = const JsonEncoder.withIndent('  ').convert(v);
          } catch (_) {
            pretty = v.toString();
          }
          sections.add(_buildToolSection(label: k, body: pretty, mono: true));
        }
      });
    }

    final result = toolCall.result;
    if (result != null && result.isNotEmpty) {
      sections.addAll(_buildToolResultSections(toolCall, result));
    } else if (toolCall.status == ToolCallStatus.running ||
        toolCall.status == ToolCallStatus.pending) {
      sections.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            'Running…',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }

    if (sections.isEmpty) {
      return Text(
        'No details.',
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }

  Widget _buildToolSection({
    required String label,
    required String body,
    bool mono = false,
  }) {
    // ignore: parameter_assignments — the body is reshaped once, in place,
    // when it turns out to be JSON.
    final colorScheme = Theme.of(context).colorScheme;
    final labelColor = colorScheme.onSurface.withValues(alpha: 0.7);
    final bodyColor = colorScheme.onSurface.withValues(alpha: 0.85);

    // Same rule as _buildExpandableCard: with a shared SelectionArea the body
    // is plain Text so it belongs to the one selection of the message list.
    Widget bodyText(TextStyle style) => widget.useSharedSelectionArea
        ? Text(body, style: style)
        : SelectableText(body, style: style);

    // A tool body is rarely prose: JSON arrives as one unbroken line, and a
    // brief arrives as markdown with its asterisks showing. Both are worth
    // recognising before falling back to monospace text.
    final classified = classifyToolBody(body);
    if (classified.kind == ToolBodyKind.markdown) {
      return _buildToolSectionFrame(
        label: label,
        labelColor: labelColor,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: MarkdownMessage(
            text: classified.text,
            textColor: bodyColor,
            backgroundColor: colorScheme.surface,
            wrapWithSelectionArea: !widget.useSharedSelectionArea,
            paragraphFontSize: 12,
          ),
        ),
      );
    }
    if (classified.kind == ToolBodyKind.json) {
      body = classified.text;
      mono = true;
    }

    final Widget bodyWidget = mono
        ? Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: colorScheme.onSurface.withValues(alpha: 0.08),
              ),
            ),
            child: bodyText(
              TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
                color: bodyColor,
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: bodyText(
              TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: bodyColor,
              ),
            ),
          );

    return _buildToolSectionFrame(
      label: label,
      labelColor: labelColor,
      child: bodyWidget,
    );
  }

  /// The label above a tool-detail body, and the spacing around the pair.
  Widget _buildToolSectionFrame({
    required String label,
    required Color labelColor,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: labelColor,
              letterSpacing: 0.3,
            ),
          ),
          child,
        ],
      ),
    );
  }

  List<Widget> _buildToolResultSections(ToolCall toolCall, String result) {
    // Extract and render any <diff> blocks inline in the expanded result area.
    final diffWidgets = <Widget>[];
    for (final match in _diffBlockRegex.allMatches(result)) {
      try {
        final data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
        diffWidgets.add(
          DiffWidget(
            before: data['before'] as String? ?? '',
            after: data['after'] as String? ?? '',
            title: data['title'] as String?,
            type: data['type'] as String?,
          ),
        );
      } catch (_) {}
    }

    // Strip <diff> blocks from the plain text portion.
    final displayResult = result.replaceAll(_diffBlockRegex, '').trim();

    // If the result is only a diff (nothing else to show), return just the widgets.
    if (displayResult.isEmpty) return diffWidgets;

    final stdoutMarker = RegExp(r'^--- stdout ---\s*$', multiLine: true);
    final stderrMarker = RegExp(r'^--- stderr ---\s*$', multiLine: true);
    final stdoutMatch = stdoutMarker.firstMatch(displayResult);
    final stderrMatch = stderrMarker.firstMatch(displayResult);

    if (stdoutMatch != null) {
      final header = displayResult.substring(0, stdoutMatch.start).trim();
      final stdoutStart = stdoutMatch.end;
      final stdoutEnd = stderrMatch?.start ?? displayResult.length;
      final stdout = displayResult.substring(stdoutStart, stdoutEnd).trim();
      final stderr = stderrMatch != null
          ? displayResult.substring(stderrMatch.end).trim()
          : '';

      final out = <Widget>[];
      if (header.isNotEmpty) {
        out.add(_buildToolSection(label: 'result', body: header));
      }
      out.add(
        _buildToolSection(
          label: 'stdout',
          body: stdout.isEmpty ? '(empty)' : stdout,
          mono: true,
        ),
      );
      if (stderr.isNotEmpty) {
        out.add(_buildToolSection(label: 'stderr', body: stderr, mono: true));
      }
      return [...out, ...diffWidgets];
    }

    final isError =
        toolCall.status == ToolCallStatus.error ||
        displayResult.startsWith('Error:');
    final textSections = displayResult.isEmpty
        ? <Widget>[]
        : [
            _buildToolSection(
              label: isError ? 'error' : 'result',
              body: displayResult,
              mono: true,
            ),
          ];
    return [...textSections, ...diffWidgets];
  }

  /// Find the last completed ask_user tool call across all tool call sources.
  ToolCall? _findAskUserToolCall() {
    ToolCall? found;

    // Check contentBlocks first (interleaved layout).
    if (widget.contentBlocks != null) {
      for (final block in widget.contentBlocks!) {
        if (block.type == ContentBlockType.toolCalls &&
            block.toolCalls != null) {
          for (final tc in block.toolCalls!) {
            if (tc.name == 'ask_user' &&
                tc.status == ToolCallStatus.completed) {
              found = tc;
            }
          }
        }
      }
    }

    // Check flat toolCalls list (classic layout).
    if (widget.toolCalls != null) {
      for (final tc in widget.toolCalls!) {
        if (tc.name == 'ask_user' && tc.status == ToolCallStatus.completed) {
          found = tc;
        }
      }
    }

    return found;
  }

  /// Build ask_user interactive option buttons if applicable. Returns
  /// a list of widgets with NO external margin between them or after
  /// them — callers control the gap to neighbouring blocks (typically
  /// the ask_user card is the last block in the bubble).
  List<Widget> _buildAskUserOptions() {
    if (widget.onAskUserAnswer == null) {
      return const [];
    }

    final askUserCall = _findAskUserToolCall();
    if (askUserCall == null) {
      return const [];
    }

    final rawOptions = askUserCall.arguments['options'];
    List<String> options;
    if (rawOptions is List) {
      options = rawOptions
          .map((o) => o.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else if (rawOptions is String) {
      try {
        final decoded = jsonDecode(rawOptions);
        if (decoded is List) {
          options = decoded
              .map((o) => o.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        } else {
          return const [];
        }
      } catch (_) {
        return const [];
      }
    } else {
      return const [];
    }

    if (options.isEmpty) {
      return const [];
    }

    return [AskUserCard(options: options, onSelect: widget.onAskUserAnswer!)];
  }

  /// Find the last completed request_mcp_server tool call across all sources.
  ToolCall? _findRequestMcpToolCall() {
    ToolCall? found;

    if (widget.contentBlocks != null) {
      for (final block in widget.contentBlocks!) {
        if (block.type == ContentBlockType.toolCalls &&
            block.toolCalls != null) {
          for (final tc in block.toolCalls!) {
            if (tc.name == 'request_mcp_server' &&
                tc.status == ToolCallStatus.completed) {
              found = tc;
            }
          }
        }
      }
    }

    if (widget.toolCalls != null) {
      for (final tc in widget.toolCalls!) {
        if (tc.name == 'request_mcp_server' &&
            tc.status == ToolCallStatus.completed) {
          found = tc;
        }
      }
    }

    return found;
  }

  /// Build the inline MCP Connect card if the last turn asked for a server.
  /// Returns an empty list when there is no callback, no completed
  /// request_mcp_server call, or no id. When the id is a real catalogue
  /// server, a [McpConnectCard] is shown; when it is not (a registry or
  /// hand-added id the model should not have named), a small fallback points
  /// the reader at the MCP servers screen.
  List<Widget> _buildMcpConnectOptions() {
    if (widget.onConnectMcpServer == null) {
      return const [];
    }

    final call = _findRequestMcpToolCall();
    if (call == null) {
      return const [];
    }

    final id = (call.arguments['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      return const [];
    }

    final entry = catalogueEntryById(id);
    if (entry == null) {
      final theme = Theme.of(context);
      return [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            'Open Settings → MCP servers to connect this server.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ];
    }

    return [
      McpConnectCard(
        entry: entry,
        onConnected: () => widget.onConnectMcpServer!(id),
      ),
    ];
  }
}
