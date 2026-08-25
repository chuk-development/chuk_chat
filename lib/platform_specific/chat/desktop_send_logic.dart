// lib/platform_specific/chat/desktop_send_logic.dart
//
// Part of chat_ui_desktop.dart — contains message sending and streaming logic.
//
// This file is a `part of` chat_ui_desktop.dart. All methods are defined as an
// extension on ChukChatUIDesktopState. Because this is the same library (via
// the `part` directive), private members (_messages, _activeChatId, etc.) are
// fully accessible.
//
// Methods in this file:
//   - _submitEditedMessage (edit/resend flow with streaming + tool loop)
//   - _reconstructAttachedFilesForResend, _extractResendUserQueryFromDisplayText,
//     _buildResendUserPrompt (resend helpers)
//   - _beginSendOperation, _isSendOperationCancelled, _clearSendOperation
//   - _markLastAssistantMessageCancelled, _cancelPendingSendOperation,
//     _cancelStream, _cancelCurrentOperation
//   - _showPaymentRequiredDialog
//   - _sendMessage (main send flow with streaming, tool loop, auto-save)
//   - _detectImageMimeType
//   - _buildApiHistoryWithPendingMessage
//   - _resolveHistoryImages
//   - _updateAiMessage, _updateToolCallsForMessage, _appendDebugRequestForMessage
//   - _processToolImages
//   - _finalizeAiMessage

// ignore_for_file: invalid_use_of_protected_member

part of 'chat_ui_desktop.dart';

/// Extension on [ChukChatUIDesktopState] containing the large send/streaming
/// methods extracted from the main file to reduce its size.
///
/// Static members [ChukChatUIDesktopState._imageBase64Cache] and
/// [ChukChatUIDesktopState._maxImageCacheSize] remain in the class body.
extension DesktopSendLogic on ChukChatUIDesktopState {
  Future<void> _submitEditedMessage(
    int index,
    String newText, {
    bool removeFollowingAssistant = true,
    bool clearMessagesBelow = false,
    List<AttachedFile>? attachedFilesOverride,
  }) async {
    if (!_isValidMessageIndex(index)) return;
    final String trimmedText = newText.trim();
    final bool hasOverrideAttachments =
        attachedFilesOverride != null && attachedFilesOverride.isNotEmpty;
    if (trimmedText.isEmpty && !hasOverrideAttachments) {
      _showSnackBar('Message cannot be empty.');
      return;
    }
    if (_isStreaming) {
      _showSnackBar('Please wait for the current response to finish.');
      return;
    }
    if (_isSending) {
      _showSnackBar('Please wait for the current send to finish.');
      return;
    }

    if (_activeChatId == null && widget.selectedChatId != null) {
      _activeChatId = widget.selectedChatId;
    }
    if (_activeChatId == null) {
      _showSnackBar('Cannot resend message without an active chat.');
      return;
    }

    // Keep builtin tools (artifact_manager, typst_compile) pointing at this
    // chat even if widget.selectedChatId is transiently null during the
    // async resend flow. Without this, the tool handler sees no active
    // chat and aborts with "No active chat. Start or select a chat first."
    ChatStorageService.activeMessageChatId = _activeChatId;
    ChatStorageService.selectedChatId ??= _activeChatId;

    final int sendOperationId = _beginSendOperation();

    try {
      // Store the edited message
      setState(() {
        _messages[index]['text'] = trimmedText;
        _messageActionsHandler.cancelEdit();
      });

      // For resend flows on older messages, reset the chat branch from this
      // point by clearing everything below the resent message. Before removing
      // AI messages, collect:
      //   * artifact ids they created (legacy fallback — pre-instrumentation
      //     chats where the version snapshots aren't stamped with message_id),
      //   * message ids so we can roll back the artifact versions those
      //     messages produced (new chats: only the versions belonging to
      //     the discarded turn are removed, prior history survives).
      final artifactIdsToDelete = <String>{};
      final discardedMessageIds = <String>{};
      void collectArtifactsFrom(int start, int end) {
        for (int i = start; i < end && i < _messages.length; i++) {
          if (_messages[i]['sender'] != 'ai') continue;
          artifactIdsToDelete.addAll(
            ChatUiHelpers.extractArtifactIdsFromRawMessage(_messages[i]),
          );
          final mid = _messages[i]['messageId'];
          if (mid != null && mid.isNotEmpty) {
            discardedMessageIds.add(mid);
          }
        }
      }

      if (clearMessagesBelow && index + 1 < _messages.length) {
        collectArtifactsFrom(index + 1, _messages.length);
        setState(() {
          _messages.removeRange(index + 1, _messages.length);
        });
      } else if (removeFollowingAssistant &&
          index + 1 < _messages.length &&
          _messages[index + 1]['sender'] == 'ai') {
        collectArtifactsFrom(index + 1, index + 2);
        setState(() {
          _messages.removeAt(index + 1);
        });
      }

      // Roll back per-message version history first so prior snapshots
      // survive and `artifacts.content/version` is reset to the latest
      // remaining snapshot. Artifacts that have no remaining snapshot
      // (created by a discarded message) are deleted in the same call.
      if (discardedMessageIds.isNotEmpty) {
        await ArtifactStorageService.rollbackArtifactsForMessages(
          discardedMessageIds,
        );
      }

      // Legacy fallback for chats whose versions pre-date message_id
      // stamping. `deleteArtifactsByIds` is idempotent for already-deleted
      // rows, so it's safe to call after the rollback above.
      if (artifactIdsToDelete.isNotEmpty) {
        // MUST await. deleteArtifactsByIds prunes the in-memory cache
        // only after the Supabase round-trip, and the new AI turn
        // starts immediately below — firing this unawaited lets the
        // next loadArtifactsForChat return the ghost artifact, which
        // ends up in the system prompt as a "still active" item the
        // model then tries to update instead of creating fresh.
        await ArtifactStorageService.deleteArtifactsByIds(artifactIdsToDelete);
      }

      // Reflect the (possibly reduced) attachment set chosen during editing so
      // the saved bubble, the resend payload (images/attachedFilesJson are read
      // back below), and any future edit all match what the user kept. Must run
      // before the image/attached-file reconstruction further down.
      if (attachedFilesOverride != null) {
        ChatUiHelpers.writeAttachmentsToMessage(
          _messages[index],
          attachedFilesOverride,
        );
      }

      _persistChat();

      // Prepare to send the edited message
      final String originalUserInput = trimmedText;
      String messageForSend = originalUserInput;
      late int placeholderIndex;

      // Always use the currently selected model and provider for resend
      // This allows users to switch models and resend with the new selection
      final String modelIdToUse = _selectedModelId;
      final String? providerToUse = _selectedProviderSlug;

      // Update the user message with the new model/provider
      _messages[index]['modelId'] = modelIdToUse;
      _messages[index]['provider'] = providerToUse ?? '';

      // Reconstruct images from stored JSON for resend
      List<String>? imagesForResend;
      final String? imagesJson = _messages[index]['images'];
      if (imagesJson != null && imagesJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(imagesJson);
          if (decoded is List) {
            final storedImages = decoded.whereType<String>().toList();
            if (kDebugMode) {
              debugPrint(
                '🔄 [ResendDebug] Found ${storedImages.length} images for resend',
              );
            }

            // Convert encrypted storage paths to base64 data URLs
            imagesForResend = [];
            for (final img in storedImages) {
              if (img.endsWith('.enc') && img.contains('/')) {
                // This is a storage path - download, decrypt, and convert to base64
                try {
                  if (kDebugMode) {
                    debugPrint(
                      '🔄 [ResendDebug] Converting storage path to base64: $img',
                    );
                  }
                  final imageBytes =
                      await ImageStorageService.downloadAndDecryptImage(img);
                  final base64Image = base64Encode(imageBytes);
                  final mimeType = _detectImageMimeType(imageBytes);
                  final dataUrl = 'data:$mimeType;base64,$base64Image';
                  imagesForResend.add(dataUrl);
                  if (kDebugMode) {
                    debugPrint(
                      '🔄 [ResendDebug] Successfully converted image to base64',
                    );
                  }
                } catch (e) {
                  if (kDebugMode) {
                    debugPrint('🔄 [ResendDebug] Failed to convert image: $e');
                  }
                }
              } else if (img.startsWith('data:image')) {
                // Already a base64 data URL
                imagesForResend.add(img);
              }
            }
            if (kDebugMode) {
              debugPrint(
                '🔄 [ResendDebug] Converted ${imagesForResend.length} images for AI',
              );
            }
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('🔄 [ResendDebug] Failed to parse images JSON: $e');
          }
        }
      }

      // Reconstruct attached files from stored JSON for resend.
      final attachedFilesForResend = _reconstructAttachedFilesForResend(index);
      if (attachedFilesForResend.isNotEmpty) {
        final resendUserQuery = _extractResendUserQueryFromDisplayText(
          originalUserInput,
          attachedFilesForResend,
        );
        messageForSend = _buildResendUserPrompt(
          resendUserQuery,
          attachedFilesForResend,
        );
        if (kDebugMode) {
          final documentCount = attachedFilesForResend
              .where(
                (file) =>
                    !file.isImage &&
                    file.markdownContent != null &&
                    file.markdownContent!.isNotEmpty,
              )
              .length;
          debugPrint(
            '🔄 [ResendDebug] Reconstructed ${attachedFilesForResend.length} attached files ($documentCount documents) for resend',
          );
        }
      }

      // Stamp the new assistant turn with a stable messageId so any
      // artifact versions it produces (create / rewrite / inline tag) are
      // tied to this turn for future regenerate rollbacks.
      final String assistantMessageId = _uuid.v4();
      ArtifactStorageService.currentMessageId = assistantMessageId;
      setState(() {
        _isSending = true;
        _messages.add({
          'sender': 'ai',
          'text': 'Thinking...',
          'reasoning': '',
          'modelId': modelIdToUse,
          'provider': providerToUse ?? '',
          'messageId': assistantMessageId,
          // The turn's clock starts here — at the request, not at the first
          // token. The wait before the first token is the one the reader
          // feels most, and it used to be counted as nothing.
          'startedAt': DateTime.now().toIso8601String(),
        });
        placeholderIndex = _messages.length - 1;
      });

      // Don't persist "Thinking..." placeholder - wait for actual response
      // _persistChat(); // Removed - will persist after streaming completes
      scrollChatToBottom(force: true);

      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;
      if (session == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Session expired. Please sign in again.',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 2),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        if (mounted) {
          setState(() {
            _isSending = false;
          });
        }
        _finalizeAiMessage(
          placeholderIndex,
          'Session expired. Please sign in again.',
        );
        return;
      }

      final String accessToken = session.accessToken;
      if (accessToken.isEmpty) {
        if (mounted) {
          setState(() {
            _isSending = false;
          });
        }
        _finalizeAiMessage(
          placeholderIndex,
          'Authentication failed. Please sign in again.',
        );
        return;
      }

      // Build conversation history up to the edited message.
      //
      // This was a third hand-rolled copy of the history builder, and it had
      // drifted: its assistant branch inlined only `text` + reasoning, so
      // every prior tool result was stripped from history on an edit/resend
      // and the model re-ran searches it had already done. It also dropped
      // `sender == 'assistant'` rows entirely.
      final List<Map<String, dynamic>> conversationHistory =
          await ChatHistoryBuilder.build(
            messages: _messages.sublist(0, index),
            // The edited turn is passed separately as `message`; the slice
            // above already excludes it, so nothing needs dropping here.
            pendingUserText: '',
            includeRecentImages: widget.includeRecentImagesInHistory,
            includeAllImages: widget.includeAllImagesInHistory,
            includeReasoning: widget.includeReasoningInHistory,
            includeToolResults: widget.includeToolResultsInHistory,
          );

      if (_isSendOperationCancelled(sendOperationId)) {
        return;
      }

      final String? systemPrompt = await _resolveSystemPromptForSend();
      final assistant = _resolveWorkspaceForCurrentChat();
      final skipIdentity = assistant != null && !assistant.memoryEnabled;

      if (_isSendOperationCancelled(sendOperationId)) {
        return;
      }

      // Same budget the normal send path uses. Hardcoding 4096 here overshot
      // any model with a lower completion cap (provider 400) and ignored how
      // much of the window the history had already eaten.
      final resendBudget = MessageCompositionService.resolveResponseTokenBudget(
        selectedModelId: modelIdToUse,
        apiHistory: conversationHistory,
        aiPromptContent: messageForSend,
        systemPrompt: systemPrompt,
      );
      if (resendBudget.error != null) {
        _showSnackBar(resendBudget.error!);
        return;
      }
      final int resendMaxTokens = resendBudget.maxResponseTokens ?? 512;

      var toolSession = _toolCallHandler.createSession(
        initialUserMessage: messageForSend,
        history: conversationHistory,
        accessToken: accessToken,
        discoveryContextKey: _activeChatId,
        baseSystemPrompt: systemPrompt,
        modelId: _selectedModelId,
        toolCallingEnabled: widget.toolCallingEnabled,
        discoveryMode: widget.toolDiscoveryMode,
        allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
        skipIdentity: skipIdentity,
      );
      final initialSystemPrompt = await _toolCallHandler
          .buildInitialSystemPrompt(toolSession);

      // Capture chatId for this streaming operation
      final String chatIdForStream = _activeChatId!;

      // Message-level auto-retry: if the final answer is empty after all
      // tool-loop retries, re-send the last user message once more.
      const int kMaxMessageLevelRetries = 1;
      int messageLevelRetries = 0;

      // Accumulates display text across all streaming passes so that AI text
      // from earlier passes is never lost when a new pass begins.
      final accumulatedText = StringBuffer();
      // Ordered content blocks built across streaming passes.
      final contentBlocks = <ContentBlock>[];
      int previousToolCallCount = 0;

      Future<void> startStreamPass({
        required String message,
        required List<Map<String, dynamic>> history,
        required String? passSystemPrompt,
        List<String>? passImages,
        int currentPass = 0,
      }) async {
        if (_isSendOperationCancelled(sendOperationId)) {
          return;
        }

        final requestPayload = <String, dynamic>{
          'pass': currentPass + 1,
          'message': message,
          'history_count': history.length,
          'history': history,
          if (passSystemPrompt != null && passSystemPrompt.trim().isNotEmpty)
            'system_prompt': passSystemPrompt,
          if (passImages != null && passImages.isNotEmpty) 'images': passImages,
        };
        _appendDebugRequestForMessage(
          placeholderIndex,
          jsonEncode(requestPayload),
          chatIdForStream,
        );

        final eventStream = WebSocketChatService.sendStreamingChat(
          accessToken: accessToken,
          message: message,
          modelId: modelIdToUse,
          providerSlug: providerToUse ?? 'openai',
          history: history,
          systemPrompt: passSystemPrompt,
          maxTokens: resendMaxTokens,
          images: passImages,
          reasoningEffort: _reasoningEffort,
          // Pin the chat id so MultiplexSession enforces single-stream-
          // per-chat and cancels any racing concurrent send (e.g. an
          // overlapping title generation call) before this pass starts.
          chatId: chatIdForStream,
        );

        await _streamingManager.startStream(
          chatId: chatIdForStream,
          messageIndex: placeholderIndex,
          stream: eventStream,
          onUpdate: (content, reasoning) {
            if (mounted &&
                _isValidMessageIndex(placeholderIndex) &&
                _activeChatId == chatIdForStream) {
              // Structural, no text matching: the streamed content is the
              // model working (not the answer) whenever we're mid tool-loop
              // (a prior round already produced blocks) OR a tool-call token
              // has appeared in this round's stream. In those cases it stays
              // out of the answer body and folds into the round's reasoning on
              // completion. A plain round with no tool calls streams live.
              final isWorkingRound =
                  contentBlocks.isNotEmpty || hasToolCallStartMarker(content);
              final displayContent =
                  isWorkingRound ? '' : stripToolCallBlocksForDisplay(content);
              final prefix = accumulatedText.toString();
              final fullDisplay = prefix.isEmpty
                  ? displayContent
                  : '$prefix$displayContent';

              _updateAiMessage(placeholderIndex, fullDisplay, reasoning);
              // Follow the answer as it streams in, but only while pinned.
              pinToBottomDuringStream();
            }
          },
          onComplete: (finalContent, finalReasoning, tps) {
            unawaited(
              (() async {
                final turnSignals = ToolTurnSignals.fromMeta(
                  _streamingManager.getLatestMeta(chatIdForStream),
                );
                final loopResult = await _toolCallHandler
                    .processAssistantResponse(
                      session: toolSession,
                      content: finalContent,
                      reasoning: finalReasoning,
                      turnSignals: turnSignals,
                      onToolCallsUpdated: (toolCalls) {
                        _updateToolCallsForMessage(
                          placeholderIndex,
                          toolCalls,
                          chatIdForStream,
                        );
                      },
                    );

                if (loopResult.shouldContinue && loopResult.nextStep != null) {
                  final interimText = loopResult.interimContent?.trim() ?? '';

                  // Build content blocks for this completed pass.
                  final allToolCalls = loopResult.toolCalls;
                  final newToolCalls =
                      allToolCalls.length > previousToolCallCount
                      ? allToolCalls.sublist(previousToolCallCount)
                      : <ToolCall>[];
                  previousToolCallCount = allToolCalls.length;

                  final roundResult = RoundContentBlockService.buildRoundBlocks(
                    interimText: interimText,
                    providerReasoning: finalReasoning,
                    newToolCalls: newToolCalls,
                    interimBeforeToolCalls: loopResult.interimBeforeToolCalls,
                    // Never fold content into reasoning: reasoning is a
                    // toggleable channel, so folded prose vanishes when the user
                    // hides reasoning. The content channel is the answer and is
                    // always shown verbatim.
                  );
                  contentBlocks.addAll(roundResult.blocks);

                  // Append side-effect blocks produced by tools this round
                  // (e.g. send_file_to_user -> sandboxArtifact).
                  if (loopResult.producedBlocks.isNotEmpty) {
                    contentBlocks.addAll(loopResult.producedBlocks);
                  }

                  // Interim text is folded into reasoning above, so it must
                  // not accumulate into the answer field.

                  final contentBlocksJson = jsonEncode(
                    contentBlocks.map((b) => b.toJson()).toList(),
                  );

                  if (_activeChatId == chatIdForStream) {
                    final persistedInterim = accumulatedText.toString();
                    if (placeholderIndex >= 0 &&
                        placeholderIndex < _messages.length) {
                      _messages[placeholderIndex]['text'] = persistedInterim;
                      _messages[placeholderIndex]['reasoning'] = finalReasoning;
                      _messages[placeholderIndex]['contentBlocks'] =
                          contentBlocksJson;
                    }
                    if (mounted) {
                      setState(() {});
                    }
                    _persistChatWithId(chatIdForStream);
                  } else {
                    final backgroundMsgs = _streamingManager
                        .getBackgroundMessages(chatIdForStream);
                    if (backgroundMsgs != null &&
                        placeholderIndex < backgroundMsgs.length) {
                      backgroundMsgs[placeholderIndex]['text'] = accumulatedText
                          .toString();
                      backgroundMsgs[placeholderIndex]['reasoning'] =
                          finalReasoning;
                      backgroundMsgs[placeholderIndex]['contentBlocks'] =
                          contentBlocksJson;
                      _persistChatWithIdAndMessages(
                        chatIdForStream,
                        backgroundMsgs,
                      );
                    }
                  }

                  final next = loopResult.nextStep!;
                  await Future<void>.delayed(Duration.zero);
                  await startStreamPass(
                    message: next.message,
                    history: next.history,
                    passSystemPrompt: next.systemPrompt,
                    passImages: imagesForResend,
                    currentPass: currentPass + 1,
                  );
                  return;
                }

                final resolvedContent = loopResult.finalContent ?? finalContent;
                final resolvedReasoning =
                    loopResult.finalReasoning ?? finalReasoning;

                // Message-level auto-retry: if the model returned an empty
                // response after all tool-loop retries, re-send the original
                // user message once more so the model gets a fresh chance.
                if (resolvedContent.trim().isEmpty &&
                    messageLevelRetries < kMaxMessageLevelRetries &&
                    mounted) {
                  messageLevelRetries++;

                  if (kDebugMode) {
                    debugPrint(
                      '[Desktop] Empty response after tool loop — '
                      'auto-retrying (attempt $messageLevelRetries/$kMaxMessageLevelRetries)',
                    );
                  }

                  toolSession = _toolCallHandler.createSession(
                    initialUserMessage: messageForSend,
                    history: conversationHistory,
                    accessToken: accessToken,
                    discoveryContextKey: chatIdForStream,
                    baseSystemPrompt: systemPrompt,
                    modelId: _selectedModelId,
                    toolCallingEnabled: widget.toolCallingEnabled,
                    discoveryMode: widget.toolDiscoveryMode,
                    allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
                    skipIdentity: skipIdentity,
                  );
                  final retryPrompt = await _toolCallHandler
                      .buildInitialSystemPrompt(toolSession);

                  contentBlocks.clear();
                  accumulatedText.clear();
                  previousToolCallCount = 0;

                  await Future<void>.delayed(const Duration(milliseconds: 500));
                  if (!mounted) return;

                  await startStreamPass(
                    message: messageForSend,
                    history: conversationHistory,
                    passSystemPrompt: retryPrompt,
                    passImages: imagesForResend,
                    currentPass: currentPass + 1,
                  );
                  return;
                }

                final rawContent = resolvedContent.isEmpty
                    ? 'The model returned an empty response. Tap resend on your last message to continue.'
                    : resolvedContent;

                // Prepend accumulated text from previous passes so nothing is lost.
                final effectiveContent = accumulatedText.isEmpty
                    ? rawContent
                    : '$accumulatedText$rawContent';

                // Defensive: finalize any tool calls that are still
                // running/pending (e.g. due to background race conditions).
                final finalToolCalls = loopResult.toolCalls;
                finalizeStaleToolCalls(finalToolCalls);

                // Also finalize stale tool calls inside content blocks.
                for (final block in contentBlocks) {
                  if (block.type == ContentBlockType.toolCalls &&
                      block.toolCalls != null) {
                    finalizeStaleToolCalls(block.toolCalls!);
                  }
                }

                // Process inline <artifact> tags emitted in assistant text.
                // Each tag becomes a synthetic artifact_manager ToolCall so
                // the existing inline-card render path picks it up, and the
                // tag is persisted via ArtifactStorageService (create or
                // rewrite) for version history.
                final syntheticArtifactCalls =
                    await ArtifactTagProcessor.processTags(
                      content: effectiveContent,
                      chatId: chatIdForStream,
                    );
                if (syntheticArtifactCalls.isNotEmpty) {
                  finalToolCalls.addAll(syntheticArtifactCalls);
                }

                // Notify UI with finalized tool calls.
                if (finalToolCalls.isNotEmpty) {
                  _updateToolCallsForMessage(
                    placeholderIndex,
                    finalToolCalls,
                    chatIdForStream,
                  );
                }

                // Append side-effect blocks (e.g. sandboxArtifact) produced
                // in the final-answer pass.
                if (loopResult.producedBlocks.isNotEmpty) {
                  contentBlocks.addAll(loopResult.producedBlocks);
                }

                // Build final content blocks.
                if (contentBlocks.isNotEmpty) {
                  // Only use the final pass's text for the text block —
                  // interim text from earlier passes is already in content
                  // blocks.
                  final finalText = stripToolCallBlocksForDisplay(
                    rawContent,
                  ).trim();
                  if (finalText.isNotEmpty) {
                    contentBlocks.add(ContentBlock.text(finalText));
                  }
                }
                final contentBlocksJson = contentBlocks.isNotEmpty
                    ? jsonEncode(contentBlocks.map((b) => b.toJson()).toList())
                    : null;

                // Persist tool-generated images to encrypted storage
                await _processToolImages(
                  loopResult.toolCalls,
                  placeholderIndex,
                  chatIdForStream,
                );

                if (_activeChatId == chatIdForStream) {
                  if (mounted) {
                    setState(() {
                      _isSending = false;
                    });
                  }
                  _finalizeAiMessage(
                    placeholderIndex,
                    effectiveContent,
                    reasoning: resolvedReasoning,
                    tps: tps,
                  );
                  if (contentBlocksJson != null &&
                      placeholderIndex >= 0 &&
                      placeholderIndex < _messages.length) {
                    _messages[placeholderIndex]['contentBlocks'] =
                        contentBlocksJson;
                  }
                  _persistChatWithId(chatIdForStream);
                } else {
                  final backgroundMsgs = _streamingManager
                      .getBackgroundMessages(chatIdForStream);
                  if (backgroundMsgs != null &&
                      placeholderIndex < backgroundMsgs.length) {
                    backgroundMsgs[placeholderIndex]['text'] = effectiveContent;
                    backgroundMsgs[placeholderIndex]['reasoning'] =
                        resolvedReasoning;
                    if (contentBlocksJson != null) {
                      backgroundMsgs[placeholderIndex]['contentBlocks'] =
                          contentBlocksJson;
                    }
                    if (tps != null) {
                      backgroundMsgs[placeholderIndex]['tps'] = tps.toString();
                    }
                    _persistChatWithIdAndMessages(
                      chatIdForStream,
                      backgroundMsgs,
                    );
                  }
                }
              })().catchError((Object error, StackTrace stackTrace) {
                if (kDebugMode) {
                  debugPrint(
                    '⚠️ [Desktop-Edit] onComplete async error: $error\n$stackTrace',
                  );
                }

                if (_activeChatId == chatIdForStream) {
                  if (mounted) {
                    setState(() {
                      _isSending = false;
                    });
                  }
                  _finalizeAiMessage(placeholderIndex, 'Error: $error');
                  _persistChatWithId(chatIdForStream);
                } else {
                  final backgroundMsgs = _streamingManager
                      .getBackgroundMessages(chatIdForStream);
                  if (backgroundMsgs != null &&
                      placeholderIndex < backgroundMsgs.length) {
                    backgroundMsgs[placeholderIndex]['text'] = 'Error: $error';
                    backgroundMsgs[placeholderIndex]['reasoning'] = '';
                    _persistChatWithIdAndMessages(
                      chatIdForStream,
                      backgroundMsgs,
                    );
                  }
                }
              }),
            );
          },
          onError: (errorMessage, {String? code}) {
            if (errorMessage == '__PAYMENT_REQUIRED__') {
              final paymentMessage =
                  'You have used all free messages. Please subscribe to continue chatting.';
              if (_activeChatId == chatIdForStream) {
                _finalizeAiMessage(placeholderIndex, paymentMessage);
                if (mounted) {
                  setState(() {
                    _isSending = false;
                  });
                }
                _persistChatWithId(chatIdForStream);
              } else {
                final backgroundMsgs = _streamingManager.getBackgroundMessages(
                  chatIdForStream,
                );
                if (backgroundMsgs != null &&
                    placeholderIndex < backgroundMsgs.length) {
                  backgroundMsgs[placeholderIndex]['text'] = paymentMessage;
                  backgroundMsgs[placeholderIndex]['reasoning'] = '';
                  _persistChatWithIdAndMessages(
                    chatIdForStream,
                    backgroundMsgs,
                  );
                }
              }
              _showPaymentRequiredDialog();
              return;
            }

            if (_activeChatId == chatIdForStream) {
              if (mounted) {
                setState(() {
                  _isSending = false;
                });
              }
              _finalizeAiMessage(placeholderIndex, 'Error: $errorMessage');
              _persistChatWithId(chatIdForStream);
            } else {
              final backgroundMsgs = _streamingManager.getBackgroundMessages(
                chatIdForStream,
              );
              if (backgroundMsgs != null &&
                  placeholderIndex < backgroundMsgs.length) {
                backgroundMsgs[placeholderIndex]['text'] =
                    'Error: $errorMessage';
                backgroundMsgs[placeholderIndex]['reasoning'] = '';
                _persistChatWithIdAndMessages(chatIdForStream, backgroundMsgs);
              }
            }
          },
        );

        // Snapshot the current message list (with placeholder appended) so
        // getBackgroundMessages has an authoritative recovery source from
        // t=0. Only do this on the first pass — `_messages` may have been
        // mutated by the user switching chats by the time later tool-loop
        // passes start. The buffer overlay applies live tokens on top, so
        // one snapshot at start is enough for the duration of the turn.
        if (currentPass == 0 && _activeChatId == chatIdForStream) {
          _streamingManager.setBackgroundMessages(
            chatIdForStream,
            _messages.map((m) => Map<String, dynamic>.from(m)).toList(),
          );
        }
      }

      if (_isSendOperationCancelled(sendOperationId)) {
        return;
      }

      try {
        await startStreamPass(
          message: messageForSend,
          history: conversationHistory,
          passSystemPrompt: initialSystemPrompt,
          passImages: imagesForResend,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Streaming error: $e');
        }
        _finalizeAiMessage(placeholderIndex, 'Error: $e');
        if (mounted) {
          setState(() {
            _isSending = false;
          });
        }
        _persistChatWithId(chatIdForStream);
      }
    } finally {
      _clearSendOperation(sendOperationId);
    }
  }

  List<AttachedFile> _reconstructAttachedFilesForResend(int index) {
    if (!_isValidMessageIndex(index)) return <AttachedFile>[];
    return ChatUiHelpers.reconstructAttachedFilesForResend(
      _messages[index],
      _uuid,
    );
  }

  String _extractResendUserQueryFromDisplayText(
    String displayText,
    List<AttachedFile> attachedFiles,
  ) => ChatUiHelpers.extractResendUserQuery(displayText, attachedFiles);

  String _buildResendUserPrompt(
    String userQuery,
    List<AttachedFile> attachedFiles,
  ) => ChatUiHelpers.buildResendUserPrompt(userQuery, attachedFiles);

  int _beginSendOperation() {
    final operationId = ++_sendOperationCounter;
    _activeSendOperationId = operationId;
    _cancelledSendOperationId = null;
    return operationId;
  }

  bool _isSendOperationCancelled(int operationId) =>
      _cancelledSendOperationId == operationId;

  void _clearSendOperation(int operationId) {
    if (_activeSendOperationId == operationId) {
      _activeSendOperationId = null;
    }
    if (_cancelledSendOperationId == operationId) {
      _cancelledSendOperationId = null;
    }
  }

  void _markLastAssistantMessageCancelled() {
    if (_messages.isEmpty) {
      return;
    }
    final lastMessage = _messages.last;
    if (lastMessage['sender'] != 'ai' && lastMessage['sender'] != 'assistant') {
      return;
    }

    final updatedLastMessage = Map<String, String>.from(lastMessage);
    final currentText = updatedLastMessage['text'] ?? '';
    if (currentText.isEmpty || currentText == 'Thinking...') {
      updatedLastMessage['text'] = '[Cancelled]';
    } else if (!currentText.contains('[Response cancelled]')) {
      updatedLastMessage['text'] = '$currentText\n\n[Response cancelled]';
    }
    _messages[_messages.length - 1] = updatedLastMessage;
  }

  void _cancelPendingSendOperation() {
    final operationId = _activeSendOperationId;
    if (operationId != null) {
      _cancelledSendOperationId = operationId;
    }

    _autoSaveTimer?.cancel();

    if (ChatStorageService.isMessageOperationInProgress) {
      ChatStorageService.isMessageOperationInProgress = false;
    }

    if (mounted) {
      setState(() {
        _isSending = false;
        _markLastAssistantMessageCancelled();
      });
    } else {
      _isSending = false;
      _markLastAssistantMessageCancelled();
    }

    if (_activeChatId != null) {
      _persistChatWithId(_activeChatId!);
    } else {
      _persistChat();
    }

    _showSnackBar('Response cancelled');
  }

  Future<void> _cancelStream() async {
    if (_activeChatId != null && _isStreaming) {
      if (kDebugMode) {
        debugPrint('Cancelling stream for chat $_activeChatId...');
      }
      await _streamingManager.cancelStream(_activeChatId!);

      if (!mounted) return;

      setState(() {
        _isSending = false;
        _markLastAssistantMessageCancelled();
      });

      _persistChat();
      _showSnackBar('Response cancelled');
    }
  }

  /// Cancel any ongoing operation (streaming or sending)
  Future<void> _cancelCurrentOperation() async {
    // Explicit cancel discards any queued follow-up message too.
    _pendingMessageText = null;

    if (_isStreaming) {
      // Stream is active - cancel via existing method
      await _cancelStream();
    } else if (_isSending) {
      // Request cancellation for in-flight send setup.
      _cancelPendingSendOperation();
    }
  }

  /// Show dialog when API returns 402 (free messages exhausted)
  void _showPaymentRequiredDialog() {
    if (!mounted) return;
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              Icons.chat_bubble_outline,
              color: theme.colorScheme.primary,
              size: 28,
            ),
            const SizedBox(width: 12),
            const Text('Free Messages Used'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You\'ve used all your free messages.',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: theme.textTheme.bodyLarge?.color,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Subscribe to get €16 in monthly AI credits for chat messages and image generation.',
              style: TextStyle(
                fontSize: 14,
                color: theme.textTheme.bodyMedium?.color?.withValues(
                  alpha: 0.8,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Maybe Later'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.rocket_launch, size: 18),
            label: const Text('Subscribe Now'),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: kBorderRadiusPill,
              ),
            ),
            onPressed: () {
              Navigator.pop(dialogContext);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PricingPage()),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _sendMessage() async {
    final int sendOperationId = _beginSendOperation();

    try {
      // SET GLOBAL LOCK IMMEDIATELY - before any async operations
      // This prevents didUpdateWidget from switching chats during the entire operation
      ChatStorageService.isMessageOperationInProgress = true;
      if (kDebugMode) {
        debugPrint('🔒 [SendMessage] GLOBAL LOCK SET');
      }

      if (_isStreaming) {
        // AI is still streaming — queue the message instead of cancelling.
        final text = _controller.text.trim();
        if (text.isNotEmpty) {
          if (mounted) {
            setState(() {
              _pendingMessageText = text;
            });
          } else {
            _pendingMessageText = text;
          }
          _controller.clear();
          if (kDebugMode) {
            debugPrint(
              '📋 [SendMessage] Queued pending message '
              '(${text.length} chars)',
            );
          }
        }
        // Do NOT release the global lock — the original streaming operation
        // is still in progress and will release it upon completion.
        return;
      }

      if (_fileHandler.attachedFiles.any((f) => f.isUploading)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Please wait for file uploads to finish.',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 2),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        ChatStorageService.isMessageOperationInProgress = false;
        if (kDebugMode) {
          debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (uploading)');
        }
        return;
      }

      // Check if a model is selected
      if (_selectedModelId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Please select a model first.',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 3),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        ChatStorageService.isMessageOperationInProgress = false;
        if (kDebugMode) {
          debugPrint(
            '🔓 [SendMessage] GLOBAL LOCK RELEASED (no model selected)',
          );
        }
        return;
      }

      // Credit/free message checks are handled server-side (API returns 402)

      final String originalUserInput = _controller.text.trim();

      // Use MessageCompositionService to prepare the message
      final List<Map<String, dynamic>> apiHistory =
          await _buildApiHistoryWithPendingMessage(originalUserInput);
      final String? resolvedSystemPrompt = await _resolveSystemPromptForSend();

      final result = await MessageCompositionService.prepareMessage(
        userInput: originalUserInput,
        attachedFiles: _fileHandler.attachedFiles,
        selectedModelId: _selectedModelId,
        apiHistory: apiHistory,
        systemPrompt: resolvedSystemPrompt,
        getProviderSlug: ensureProviderSlugForCurrentModel,
      );

      if (!result.isValid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.errorMessage ?? 'Invalid message',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 2),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        ChatStorageService.isMessageOperationInProgress = false;
        if (kDebugMode) {
          debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (invalid message)');
        }
        return;
      }

      if (_isSendOperationCancelled(sendOperationId)) {
        return;
      }

      // Check if widget was disposed during async operation
      if (!mounted) {
        ChatStorageService.isMessageOperationInProgress = false;
        if (kDebugMode) {
          debugPrint(
            '🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during prepareMessage)',
          );
        }
        return;
      }

      // Extract prepared values
      final String displayMessageText = result.displayMessageText!;
      final String aiPromptContent = result.aiPromptContent!;
      final String accessToken = result.accessToken!;
      final String providerSlug = result.providerSlug!;
      final int maxResponseTokens = result.maxResponseTokens!;
      final String? systemPrompt = result.effectiveSystemPrompt;
      final workspaceForChat = _resolveWorkspaceForCurrentChat();
      final skipIdentity =
          workspaceForChat != null && !workspaceForChat.memoryEnabled;
      final List<String>? imageDataUrls = result.images;

      final bool hasAttachments = _fileHandler.attachedFiles.any(
        (f) => f.markdownContent != null || f.encryptedImagePath != null,
      );

      final bool firstMessageInChat = _messages.isEmpty;

      // CRITICAL FIX: Sync _activeChatId with widget.selectedChatId if out of sync
      // This handles cases where _activeChatId was cleared but user is still on existing chat
      if (_activeChatId == null && widget.selectedChatId != null) {
        _activeChatId = widget.selectedChatId;
        if (kDebugMode) {
          debugPrint('');
        }
        if (kDebugMode) {
          debugPrint(
            '┌─────────────────────────────────────────────────────────────',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ ⚠️ [SEND-DESKTOP] SYNCED _activeChatId with widget.selectedChatId',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ ⚠️ [SEND-DESKTOP] _activeChatId was null, now: $_activeChatId',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '└─────────────────────────────────────────────────────────────',
          );
        }
      }

      // Generate chat ID ONCE at the start for truly NEW chats only
      // This prevents race conditions where multiple _persistChat calls
      // each generate their own UUID before the first one completes
      if (_activeChatId == null) {
        _activeChatId = _uuid.v4();
        if (kDebugMode) {
          debugPrint(
            '🔗 [SEND-DESKTOP] Generated chat id for new chat: $_activeChatId',
          );
        }
        if (kDebugMode) {
          debugPrint('');
          debugPrint(
            '┌─────────────────────────────────────────────────────────────',
          );
          debugPrint(
            '│ 🆔 [SEND-DESKTOP] PRE-GENERATED Chat ID: $_activeChatId',
          );
          debugPrint(
            '│ 🆔 [SEND-DESKTOP] This ID will be used for all persist calls',
          );
          debugPrint(
            '└─────────────────────────────────────────────────────────────',
          );
        }

        // Link new chat to workspace if one is pending
        if (_pendingWorkspaceId != null) {
          final workspaceId = _pendingWorkspaceId!;
          _pendingWorkspaceId = null;
          // Fire-and-forget — the link is created in the background
          unawaited(
            WorkspaceStorageService.linkChatToWorkspace(
              workspaceId,
              _activeChatId!,
            ).catchError((error) {
              if (kDebugMode) {
                debugPrint(
                  '⚠️ [SEND-DESKTOP] Failed to link chat to workspace: $error',
                );
              }
            }),
          );
          if (kDebugMode) {
            debugPrint(
              '🤖 [SEND-DESKTOP] Linked chat to workspace $workspaceId',
            );
          }
        }
      }

      // Keep builtin tools (artifact_manager, typst_compile) pointing at
      // this chat for the entire send. Without this, the very first
      // turn of a freshly-created chat races the parent widget's
      // `selectedChatId` propagation and `artifact_manager` aborts with
      // "No active chat". Applies to normal send AND resend paths.
      if (_activeChatId != null) {
        ChatStorageService.activeMessageChatId = _activeChatId;
        ChatStorageService.selectedChatId ??= _activeChatId;
        if (kDebugMode) {
          debugPrint(
            '🔗 [SEND-DESKTOP] ChatStorageService.activeMessageChatId = $_activeChatId (selectedChatId=${ChatStorageService.selectedChatId})',
          );
        }
      }

      int placeholderIndex = -1;
      setState(() {
        // Store message with images and attachments (if any)
        final userMessage = {
          'sender': 'user',
          'text': displayMessageText,
          'reasoning': '',
          'modelId': _selectedModelId,
          'provider': providerSlug,
        };

        // Store images as JSON-encoded string if present
        if (imageDataUrls != null && imageDataUrls.isNotEmpty) {
          userMessage['images'] = jsonEncode(imageDataUrls);
        }

        // Store document attachments as JSON-encoded string if present
        final documentAttachments = _fileHandler.attachedFiles
            .where((f) => !f.isImage && f.markdownContent != null)
            .map(
              (f) => {
                'fileName': f.fileName,
                'markdownContent': f.markdownContent!,
              },
            )
            .toList();

        if (documentAttachments.isNotEmpty) {
          userMessage['attachments'] = jsonEncode(documentAttachments);
          if (kDebugMode) {
            debugPrint(
              '📄 [AttachmentDebug] Storing ${documentAttachments.length} attachments',
            );
          }
        }

        // Store original AttachedFile objects for resend functionality
        if (_fileHandler.attachedFiles.isNotEmpty) {
          userMessage['attachedFilesJson'] = jsonEncode(
            _fileHandler.attachedFiles.map((f) => f.toJson()).toList(),
          );
          if (kDebugMode) {
            debugPrint(
              '💾 [AttachmentDebug] Storing ${_fileHandler.attachedFiles.length} attached files for resend',
            );
          }
        }

        _messages.add(userMessage);
        if (kDebugMode) {
          debugPrint(
            '💾 [MessageDebug] Message added to _messages list. Total messages: ${_messages.length}',
          );
        }

        _controller.clear();
        _isSending = true;
        if (hasAttachments) {
          _fileHandler.attachedFiles.clear();
        }
        _messages.add({
          'sender': 'ai',
          'text': 'Thinking...',
          'reasoning': '',
          'modelId': _selectedModelId,
          'provider': providerSlug,
          'startedAt': DateTime.now().toIso8601String(),
        });
        placeholderIndex = _messages.length - 1;
      });

      // ── Offline short-circuit ──────────────────────────────────────
      // If we're offline at send time, enqueue the payload, flip the user
      // bubble to "pending", remove the "Thinking..." placeholder, persist
      // and bail out before contacting the WebSocket.  The retry manager
      // will replay the send once connectivity returns.
      if (!NetworkStatusService.isOnline) {
        final userMsgIndex = placeholderIndex - 1;
        final enqueued = await _enqueueOfflineSend(
          chatId: _activeChatId!,
          userMsgIndex: userMsgIndex,
          placeholderIndex: placeholderIndex,
          messageText: aiPromptContent,
          displayText: displayMessageText,
          providerSlug: providerSlug,
          systemPrompt: systemPrompt,
          imagesJson: imageDataUrls != null && imageDataUrls.isNotEmpty
              ? jsonEncode(imageDataUrls)
              : null,
          maxTokens: maxResponseTokens,
          reasoningEffort: _reasoningEffort,
        );
        ChatStorageService.isMessageOperationInProgress = false;
        if (enqueued) return;
        // Enqueue failed — flip the user message to failed, drop placeholder,
        // notify the user. They can retry manually.
        if (mounted) {
          setState(() {
            if (userMsgIndex >= 0 && userMsgIndex < _messages.length) {
              _messages[userMsgIndex]['status'] = 'failed';
              _messages[userMsgIndex]['lastError'] = 'Failed to queue message';
            }
            if (placeholderIndex >= 0 &&
                placeholderIndex < _messages.length &&
                _messages[placeholderIndex]['text'] == 'Thinking...') {
              _messages.removeAt(placeholderIndex);
            }
            _isSending = false;
          });
        }
        _persistChatWithId(_activeChatId!);
        return;
      }

      // Don't persist "Thinking..." placeholder - wait for actual response
      // _persistChat(); // Removed - will persist after streaming completes

      if (_isSendOperationCancelled(sendOperationId)) {
        return;
      }

      if (firstMessageInChat) _animCtrl.forward();
      scrollChatToBottom(force: true);
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

      // Capture chatId for this streaming operation - ensures correct persistence even if user switches chats
      final String chatIdForStream = _activeChatId!;

      // Auto-generate title for new chats (fire and forget)
      if (firstMessageInChat) {
        unawaited(
          TitleGenerationService.generateAndApplyTitle(
            chatIdForStream,
            displayMessageText,
          ).catchError((error) {
            if (kDebugMode) {
              debugPrint('Title generation failed: $error');
            }
          }),
        );
      }

      // Start auto-save timer during streaming (uses captured chatId)
      _autoSaveTimer?.cancel();
      _autoSaveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        // Only persist if still viewing the same chat
        // If user switched, _messages belongs to a different chat!
        if (_activeChatId == chatIdForStream) {
          _persistChatWithId(chatIdForStream);
        } else {
          // Get background messages and persist those instead
          final backgroundMsgs = _streamingManager.getBackgroundMessages(
            chatIdForStream,
          );
          if (backgroundMsgs != null) {
            _persistChatWithIdAndMessages(chatIdForStream, backgroundMsgs);
          }
        }
      });

      var toolSession = _toolCallHandler.createSession(
        initialUserMessage: aiPromptContent,
        history: apiHistory,
        accessToken: accessToken,
        discoveryContextKey: chatIdForStream,
        baseSystemPrompt: systemPrompt,
        modelId: _selectedModelId,
        toolCallingEnabled: widget.toolCallingEnabled,
        discoveryMode: widget.toolDiscoveryMode,
        allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
        skipIdentity: skipIdentity,
      );
      final initialSystemPrompt = await _toolCallHandler
          .buildInitialSystemPrompt(toolSession);

      if (_isSendOperationCancelled(sendOperationId)) {
        return;
      }

      // Message-level auto-retry for the second streaming path.
      const int kMaxMessageLevelRetries2 = 1;
      int messageLevelRetries2 = 0;

      // Accumulates display text across all streaming passes so that AI text
      // from earlier passes is never lost when a new pass begins.
      final accumulatedText2 = StringBuffer();
      // Ordered content blocks built across streaming passes.
      final contentBlocks2 = <ContentBlock>[];
      int previousToolCallCount2 = 0;

      Future<void> startStreamPass({
        required String message,
        required List<Map<String, dynamic>> history,
        required String? passSystemPrompt,
        List<String>? passImages,
        int currentPass = 0,
      }) async {
        if (_isSendOperationCancelled(sendOperationId)) {
          return;
        }

        final requestPayload = <String, dynamic>{
          'pass': currentPass + 1,
          'message': message,
          'history_count': history.length,
          'history': history,
          if (passSystemPrompt != null && passSystemPrompt.trim().isNotEmpty)
            'system_prompt': passSystemPrompt,
          if (passImages != null && passImages.isNotEmpty) 'images': passImages,
        };
        _appendDebugRequestForMessage(
          placeholderIndex,
          jsonEncode(requestPayload),
          chatIdForStream,
        );

        final stream = WebSocketChatService.sendStreamingChat(
          accessToken: accessToken,
          message: message,
          modelId: _selectedModelId,
          providerSlug: providerSlug,
          history: history.isEmpty ? null : history,
          systemPrompt: passSystemPrompt,
          maxTokens: maxResponseTokens,
          images: passImages,
          reasoningEffort: _reasoningEffort,
          // Pin the chat id so MultiplexSession enforces single-stream-
          // per-chat and cancels any racing concurrent send (e.g. an
          // overlapping title generation call) before this pass starts.
          chatId: chatIdForStream,
        );

        await _streamingManager.startStream(
          chatId: chatIdForStream,
          messageIndex: placeholderIndex,
          stream: stream,
          onUpdate: (content, reasoning) {
            if (mounted && _activeChatId == chatIdForStream) {
              // Structural working-round suppression (see site above): keep
              // mid-loop / tool-call content out of the answer body.
              final isWorkingRound =
                  contentBlocks2.isNotEmpty || hasToolCallStartMarker(content);
              final displayContent =
                  isWorkingRound ? '' : stripToolCallBlocksForDisplay(content);
              if (placeholderIndex >= 0 &&
                  placeholderIndex < _messages.length) {
                _messages[placeholderIndex]['text'] = displayContent;
                _messages[placeholderIndex]['reasoning'] = reasoning;
              }
              _updateAiMessage(placeholderIndex, displayContent, reasoning);
            }
          },
          onComplete: (finalContent, finalReasoning, tps) {
            unawaited(
              (() async {
                if (kDebugMode) {
                  debugPrint('Stream completed for chat $chatIdForStream');
                }

                try {
                  final turnSignals = ToolTurnSignals.fromMeta(
                    _streamingManager.getLatestMeta(chatIdForStream),
                  );
                  final loopResult = await _toolCallHandler
                      .processAssistantResponse(
                        session: toolSession,
                        content: finalContent,
                        reasoning: finalReasoning,
                        turnSignals: turnSignals,
                        onToolCallsUpdated: (toolCalls) {
                          _updateToolCallsForMessage(
                            placeholderIndex,
                            toolCalls,
                            chatIdForStream,
                          );
                        },
                      );

                  if (loopResult.shouldContinue &&
                      loopResult.nextStep != null) {
                    final interimText = loopResult.interimContent?.trim() ?? '';

                    // Build content blocks for this completed pass.
                    final allToolCalls = loopResult.toolCalls;
                    final newToolCalls =
                        allToolCalls.length > previousToolCallCount2
                        ? allToolCalls.sublist(previousToolCallCount2)
                        : <ToolCall>[];
                    previousToolCallCount2 = allToolCalls.length;

                    final roundResult =
                        RoundContentBlockService.buildRoundBlocks(
                          interimText: interimText,
                          providerReasoning: finalReasoning,
                          newToolCalls: newToolCalls,
                          interimBeforeToolCalls:
                              loopResult.interimBeforeToolCalls,
                          // Never fold content into reasoning; see site above.
                        );
                    contentBlocks2.addAll(roundResult.blocks);

                    // Append side-effect blocks (e.g. sandboxArtifact)
                    // produced by tools this round.
                    if (loopResult.producedBlocks.isNotEmpty) {
                      contentBlocks2.addAll(loopResult.producedBlocks);
                    }

                    // Interim text folded into reasoning — do not accumulate
                    // it into the answer field.

                    final contentBlocksJson = jsonEncode(
                      contentBlocks2.map((b) => b.toJson()).toList(),
                    );

                    if (_activeChatId == chatIdForStream) {
                      if (placeholderIndex >= 0 &&
                          placeholderIndex < _messages.length) {
                        _messages[placeholderIndex]['text'] = '';
                        _messages[placeholderIndex]['reasoning'] =
                            finalReasoning;
                        _messages[placeholderIndex]['contentBlocks'] =
                            contentBlocksJson;
                      }
                      if (mounted) {
                        setState(() {});
                      }
                      _persistChatWithId(chatIdForStream);
                    } else {
                      final backgroundMsgs = _streamingManager
                          .getBackgroundMessages(chatIdForStream);
                      if (backgroundMsgs != null &&
                          placeholderIndex < backgroundMsgs.length) {
                        backgroundMsgs[placeholderIndex]['text'] = '';
                        backgroundMsgs[placeholderIndex]['reasoning'] =
                            finalReasoning;
                        backgroundMsgs[placeholderIndex]['contentBlocks'] =
                            contentBlocksJson;
                        _persistChatWithIdAndMessages(
                          chatIdForStream,
                          backgroundMsgs,
                        );
                      }
                    }

                    final next = loopResult.nextStep!;
                    await Future<void>.delayed(Duration.zero);
                    await startStreamPass(
                      message: next.message,
                      history: next.history,
                      passSystemPrompt: next.systemPrompt,
                      passImages: imageDataUrls,
                      currentPass: currentPass + 1,
                    );
                    return;
                  }

                  _autoSaveTimer?.cancel();
                  ChatStorageService.isMessageOperationInProgress = false;
                  if (kDebugMode) {
                    debugPrint(
                      '🔓 [SendMessage] GLOBAL LOCK RELEASED (stream done)',
                    );
                  }

                  final resolvedContent =
                      loopResult.finalContent ?? finalContent;
                  final resolvedReasoning =
                      loopResult.finalReasoning ?? finalReasoning;

                  // Message-level auto-retry: if the model returned empty.
                  if (resolvedContent.trim().isEmpty &&
                      messageLevelRetries2 < kMaxMessageLevelRetries2 &&
                      mounted) {
                    messageLevelRetries2++;

                    if (kDebugMode) {
                      debugPrint(
                        '[Desktop-Send] Empty response — auto-retrying '
                        '(attempt $messageLevelRetries2/$kMaxMessageLevelRetries2)',
                      );
                    }

                    toolSession = _toolCallHandler.createSession(
                      initialUserMessage: aiPromptContent,
                      history: apiHistory,
                      accessToken: accessToken,
                      discoveryContextKey: chatIdForStream,
                      baseSystemPrompt: systemPrompt,
                      modelId: _selectedModelId,
                      toolCallingEnabled: widget.toolCallingEnabled,
                      discoveryMode: widget.toolDiscoveryMode,
                      allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
                      skipIdentity: skipIdentity,
                    );
                    final retryPrompt = await _toolCallHandler
                        .buildInitialSystemPrompt(toolSession);

                    contentBlocks2.clear();
                    accumulatedText2.clear();
                    previousToolCallCount2 = 0;

                    await Future<void>.delayed(
                      const Duration(milliseconds: 500),
                    );
                    if (!mounted) return;

                    await startStreamPass(
                      message: aiPromptContent,
                      history: apiHistory,
                      passSystemPrompt: retryPrompt,
                      passImages: imageDataUrls,
                      currentPass: currentPass + 1,
                    );
                    return;
                  }

                  final rawContent = resolvedContent.isEmpty
                      ? 'The model returned an empty response. Tap resend on your last message to continue.'
                      : resolvedContent;

                  // Prepend accumulated text from previous passes so nothing is lost.
                  final effectiveContent = accumulatedText2.isEmpty
                      ? rawContent
                      : '$accumulatedText2$rawContent';

                  // Defensive: finalize stale tool calls.
                  final finalToolCalls = loopResult.toolCalls;
                  finalizeStaleToolCalls(finalToolCalls);
                  for (final block in contentBlocks2) {
                    if (block.type == ContentBlockType.toolCalls &&
                        block.toolCalls != null) {
                      finalizeStaleToolCalls(block.toolCalls!);
                    }
                  }

                  // Process inline <artifact> tags emitted in assistant text.
                  // Each tag becomes a synthetic artifact_manager ToolCall so
                  // the existing inline-card render path picks it up, and
                  // the tag is persisted via ArtifactStorageService (create
                  // or rewrite) for version history.
                  final syntheticArtifactCalls =
                      await ArtifactTagProcessor.processTags(
                        content: effectiveContent,
                        chatId: chatIdForStream,
                      );
                  if (syntheticArtifactCalls.isNotEmpty) {
                    finalToolCalls.addAll(syntheticArtifactCalls);
                  }

                  if (finalToolCalls.isNotEmpty) {
                    _updateToolCallsForMessage(
                      placeholderIndex,
                      finalToolCalls,
                      chatIdForStream,
                    );
                  }

                  // Append side-effect blocks (e.g. sandboxArtifact) produced
                  // in the final-answer pass.
                  if (loopResult.producedBlocks.isNotEmpty) {
                    contentBlocks2.addAll(loopResult.producedBlocks);
                  }

                  // Build final content blocks.
                  if (contentBlocks2.isNotEmpty) {
                    // Only use the final pass's text for the text block —
                    // interim text from earlier passes is already in content
                    // blocks.
                    final finalText = stripToolCallBlocksForDisplay(
                      rawContent,
                    ).trim();
                    if (finalText.isNotEmpty) {
                      contentBlocks2.add(ContentBlock.text(finalText));
                    }
                  }
                  final contentBlocksJson = contentBlocks2.isNotEmpty
                      ? jsonEncode(
                          contentBlocks2.map((b) => b.toJson()).toList(),
                        )
                      : null;

                  // Persist tool-generated images to encrypted storage
                  await _processToolImages(
                    loopResult.toolCalls,
                    placeholderIndex,
                    chatIdForStream,
                  );

                  if (_activeChatId == chatIdForStream) {
                    if (placeholderIndex >= 0 &&
                        placeholderIndex < _messages.length) {
                      _messages[placeholderIndex]['text'] = effectiveContent;
                      _messages[placeholderIndex]['reasoning'] =
                          resolvedReasoning;
                      if (contentBlocksJson != null) {
                        _messages[placeholderIndex]['contentBlocks'] =
                            contentBlocksJson;
                      }
                      if (tps != null) {
                        _messages[placeholderIndex]['tps'] = tps.toString();
                      }
                    }
                    if (mounted) {
                      setState(() {
                        _isSending = false;
                      });
                    }
                    _finalizeAiMessage(
                      placeholderIndex,
                      effectiveContent,
                      reasoning: resolvedReasoning,
                      tps: tps,
                    );
                    _persistChatWithId(chatIdForStream);
                  } else {
                    final backgroundMsgs = _streamingManager
                        .getBackgroundMessages(chatIdForStream);
                    if (backgroundMsgs != null &&
                        placeholderIndex < backgroundMsgs.length) {
                      backgroundMsgs[placeholderIndex]['text'] =
                          effectiveContent;
                      backgroundMsgs[placeholderIndex]['reasoning'] =
                          resolvedReasoning;
                      if (contentBlocksJson != null) {
                        backgroundMsgs[placeholderIndex]['contentBlocks'] =
                            contentBlocksJson;
                      }
                      if (tps != null) {
                        backgroundMsgs[placeholderIndex]['tps'] = tps
                            .toString();
                      }
                      _persistChatWithIdAndMessages(
                        chatIdForStream,
                        backgroundMsgs,
                      );
                    }
                  }
                } catch (error) {
                  _autoSaveTimer?.cancel();
                  ChatStorageService.isMessageOperationInProgress = false;

                  final errorText = 'Error: $error';
                  if (_activeChatId == chatIdForStream) {
                    if (mounted) {
                      setState(() {
                        _isSending = false;
                      });
                    }
                    _finalizeAiMessage(placeholderIndex, errorText);
                    _persistChatWithId(chatIdForStream);
                  } else {
                    final backgroundMsgs = _streamingManager
                        .getBackgroundMessages(chatIdForStream);
                    if (backgroundMsgs != null &&
                        placeholderIndex < backgroundMsgs.length) {
                      backgroundMsgs[placeholderIndex]['text'] = errorText;
                      _persistChatWithIdAndMessages(
                        chatIdForStream,
                        backgroundMsgs,
                      );
                    }
                  }
                }
              })().catchError((Object error, StackTrace stackTrace) {
                if (kDebugMode) {
                  debugPrint(
                    '⚠️ [Desktop-Send] onComplete async error: $error\n$stackTrace',
                  );
                }
              }),
            );
          },
          onError: (errorMessage, {String? code}) async {
            if (kDebugMode) {
              debugPrint(
                'Stream error for chat $chatIdForStream: $errorMessage',
              );
            }
            _autoSaveTimer?.cancel();
            ChatStorageService.isMessageOperationInProgress = false;
            if (kDebugMode) {
              debugPrint(
                '🔓 [SendMessage] GLOBAL LOCK RELEASED (stream error)',
              );
            }

            if (errorMessage == '__PAYMENT_REQUIRED__') {
              final paymentMessage =
                  'You have used all free messages. Please subscribe to continue chatting.';
              if (_activeChatId == chatIdForStream) {
                _finalizeAiMessage(placeholderIndex, paymentMessage);
                if (mounted) {
                  setState(() {
                    _isSending = false;
                  });
                }
                _persistChatWithId(chatIdForStream);
              } else {
                final backgroundMsgs = _streamingManager.getBackgroundMessages(
                  chatIdForStream,
                );
                if (backgroundMsgs != null &&
                    placeholderIndex < backgroundMsgs.length) {
                  backgroundMsgs[placeholderIndex]['text'] = paymentMessage;
                  backgroundMsgs[placeholderIndex]['reasoning'] = '';
                  _persistChatWithIdAndMessages(
                    chatIdForStream,
                    backgroundMsgs,
                  );
                }
              }
              _showPaymentRequiredDialog();
              return;
            }

            // Network error → enqueue for retry instead of surfacing an
            // error message in the chat. The user message keeps its content
            // and just flips to a "pending" state; AI placeholder is removed.
            // If enqueue itself fails, fall through to the normal error
            // display path so the user always gets feedback.
            if (NetworkStatusService.isNetworkError(errorMessage) &&
                _activeChatId == chatIdForStream) {
              final userMsgIndex = placeholderIndex - 1;
              bool enqueued = false;
              try {
                enqueued = await _enqueueOfflineSend(
                  chatId: chatIdForStream,
                  userMsgIndex: userMsgIndex,
                  placeholderIndex: placeholderIndex,
                  messageText: aiPromptContent,
                  displayText: displayMessageText,
                  providerSlug: providerSlug,
                  systemPrompt: systemPrompt,
                  imagesJson: imageDataUrls != null && imageDataUrls.isNotEmpty
                      ? jsonEncode(imageDataUrls)
                      : null,
                  maxTokens: maxResponseTokens,
                  reasoningEffort: _reasoningEffort,
                );
              } catch (error) {
                if (kDebugMode) {
                  debugPrint('[Desktop-Send] enqueue failed: $error');
                }
              }
              if (enqueued) {
                if (mounted) {
                  setState(() {
                    _isSending = false;
                  });
                }
                return;
              }
              // Fall through to normal error display below.
            }

            final errorText = 'Error: $errorMessage';
            if (_activeChatId == chatIdForStream) {
              if (placeholderIndex >= 0 &&
                  placeholderIndex < _messages.length) {
                _messages[placeholderIndex]['text'] = errorText;
              }
              if (mounted) {
                setState(() {
                  _isSending = false;
                });
              }
              _finalizeAiMessage(placeholderIndex, errorText);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      errorMessage,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    behavior: SnackBarBehavior.floating,
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    duration: const Duration(seconds: 2),
                    dismissDirection: DismissDirection.horizontal,
                  ),
                );
              }
              _persistChatWithId(chatIdForStream);
            } else {
              final backgroundMsgs = _streamingManager.getBackgroundMessages(
                chatIdForStream,
              );
              if (backgroundMsgs != null &&
                  placeholderIndex < backgroundMsgs.length) {
                backgroundMsgs[placeholderIndex]['text'] = errorText;
                _persistChatWithIdAndMessages(chatIdForStream, backgroundMsgs);
              }
            }
          },
        );

        // Snapshot the current message list (with placeholder appended) so
        // getBackgroundMessages has an authoritative recovery source from
        // t=0. Only do this on the first pass — `_messages` may have been
        // mutated by the user switching chats by the time later tool-loop
        // passes start. The buffer overlay applies live tokens on top, so
        // one snapshot at start is enough for the duration of the turn.
        if (currentPass == 0 && _activeChatId == chatIdForStream) {
          _streamingManager.setBackgroundMessages(
            chatIdForStream,
            _messages.map((m) => Map<String, dynamic>.from(m)).toList(),
          );
        }
      }

      if (_isSendOperationCancelled(sendOperationId)) {
        return;
      }

      try {
        await startStreamPass(
          message: aiPromptContent,
          history: apiHistory,
          passSystemPrompt: initialSystemPrompt,
          passImages: imageDataUrls,
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Failed to start stream: $error');
        }
        _autoSaveTimer?.cancel();
        ChatStorageService.isMessageOperationInProgress = false;
        _finalizeAiMessage(
          placeholderIndex,
          'Failed to start streaming: $error',
        );
        if (mounted) {
          setState(() {
            _isSending = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Failed to start streaming: $error',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 2),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        _persistChatWithId(chatIdForStream);
      }
    } finally {
      _clearSendOperation(sendOperationId);
    }
  }

  String _detectImageMimeType(Uint8List bytes) =>
      ChatUiHelpers.detectImageMimeType(bytes);

  /// Delegates to [ChatHistoryBuilder] — see that file for why this must not
  /// be reimplemented per platform.
  Future<List<Map<String, dynamic>>> _buildApiHistoryWithPendingMessage(
    String pendingUserText,
  ) => ChatHistoryBuilder.build(
    messages: _messages,
    pendingUserText: pendingUserText,
    includeRecentImages: widget.includeRecentImagesInHistory,
    includeAllImages: widget.includeAllImagesInHistory,
    includeReasoning: widget.includeReasoningInHistory,
    includeToolResults: widget.includeToolResultsInHistory,
  );

  /// Resolve image storage paths from a JSON-encoded list to Base64 data URLs

  void _updateAiMessage(int index, String content, String reasoning) {
    if (!mounted || index < 0 || index >= _messages.length) return;
    final String? chatId = _activeChatId;
    if (chatId == null) return;

    // Keep the backing list in sync (persistence + finalize) but WITHOUT a
    // screen-wide setState per token. The single streaming bubble rebuilds
    // itself by listening to the runtime's `streamingLive` notifier (see the
    // list itemBuilder). This replaces a ~30fps rebuild of every visible
    // bubble + the composer + overlays with a rebuild of just the streaming
    // bubble's body.
    final Map<String, String> message = Map<String, String>.from(
      _messages[index],
    );
    message['text'] = content;
    message['reasoning'] = reasoning;
    _messages[index] = message;

    final ChatRuntime runtime = ChatRuntimeRegistry.instance.get(chatId);
    // First token of the turn: the placeholder was first built before the
    // stream manager flipped streaming on, so it isn't yet wrapped in its
    // scoped ValueListenableBuilder. Do exactly one setState now to install
    // the wrapper; every subsequent token updates only the notifier.
    final bool firstToken = runtime.streamingLive.value == null;
    runtime.pushStreamingText(
      index: index,
      text: content,
      reasoning: reasoning,
    );
    if (firstToken) {
      setState(() {});
    }

    // Follow the answer as it streams in, but only while the user is pinned to
    // the bottom. The edit/resend path did this and the normal send path did
    // not, so a fresh answer grew off-screen while resending the same message
    // tracked correctly. The layout's streaming slack was removed on the
    // assumption that this runs.
    pinToBottomDuringStream();
  }

  void _updateToolCallsForMessage(
    int index,
    List<ToolCall> toolCalls,
    String chatId,
  ) {
    final String toolCallsJson = jsonEncode(
      toolCalls.map((call) => call.toJson()).toList(),
    );

    final bool isActiveChat = _activeChatId == chatId;
    if (mounted && isActiveChat && index >= 0 && index < _messages.length) {
      setState(() {
        final message = Map<String, String>.from(_messages[index]);
        message['toolCalls'] = toolCallsJson;
        _messages[index] = message;
      });
      _persistChatWithId(chatId);
      return;
    }

    final backgroundMsgs = _streamingManager.getBackgroundMessages(chatId);
    if (backgroundMsgs != null && index >= 0 && index < backgroundMsgs.length) {
      backgroundMsgs[index]['toolCalls'] = toolCallsJson;
      _persistChatWithIdAndMessages(chatId, backgroundMsgs);
    }
  }

  void _appendDebugRequestForMessage(
    int index,
    String requestPayloadJson,
    String chatId,
  ) {
    final bool isActiveChat = _activeChatId == chatId;

    void appendPayload(Map<String, String> message) {
      final passPayloads = <dynamic>[];
      final existing = message['debugRequests'];
      if (existing != null && existing.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(existing);
          if (decoded is List) {
            passPayloads.addAll(decoded);
          }
        } catch (_) {}
      }

      try {
        passPayloads.add(jsonDecode(requestPayloadJson));
      } catch (_) {
        passPayloads.add({'raw': requestPayloadJson});
      }

      message['debugRequests'] = jsonEncode(passPayloads);
    }

    if (mounted && isActiveChat && index >= 0 && index < _messages.length) {
      setState(() {
        final message = Map<String, String>.from(_messages[index]);
        appendPayload(message);
        _messages[index] = message;
      });
      return;
    }

    final backgroundMsgs = _streamingManager.getBackgroundMessages(chatId);
    if (backgroundMsgs != null && index >= 0 && index < backgroundMsgs.length) {
      final message = Map<String, String>.from(backgroundMsgs[index]);
      appendPayload(message);
      backgroundMsgs[index] = message;
      _persistChatWithIdAndMessages(chatId, backgroundMsgs);
    }
  }

  /// Download tool-generated images, encrypt, and persist to Supabase storage.
  /// Updates the message's `images`, `imageCostEur`, `imageGeneratedAt`, and
  /// refreshed `toolCalls` (now containing `storage_path`).
  Future<void> _processToolImages(
    List<ToolCall> toolCalls,
    int index,
    String chatId,
  ) async {
    if (toolCalls.isEmpty) return;

    final hasImages = toolCalls.any(
      (c) =>
          c.result != null &&
          (c.result!.startsWith('IMAGE:') ||
              c.result!.startsWith('IMAGE_DATA:')),
    );
    if (!hasImages) return;

    try {
      final imageResult = await ToolImageResultService.processToolCalls(
        toolCalls,
      );

      if (imageResult.imagePaths.isEmpty) return;

      final updatedToolCallsJson = jsonEncode(
        imageResult.toolCalls.map((c) => c.toJson()).toList(),
      );
      final imageMetasJson = jsonEncode(imageResult.imageMetas);

      final isActiveChat = _activeChatId == chatId;
      if (mounted && isActiveChat && index >= 0 && index < _messages.length) {
        setState(() {
          final message = Map<String, String>.from(_messages[index]);
          message['images'] = jsonEncode(imageResult.imagePaths);
          message['imageMetas'] = imageMetasJson;
          if (imageResult.imageCostEur != null) {
            message['imageCostEur'] = imageResult.imageCostEur!;
          }
          if (imageResult.imageGeneratedAt != null) {
            message['imageGeneratedAt'] = imageResult.imageGeneratedAt!;
          }
          message['toolCalls'] = updatedToolCallsJson;
          _messages[index] = message;
        });
      } else {
        final backgroundMsgs = _streamingManager.getBackgroundMessages(chatId);
        if (backgroundMsgs != null &&
            index >= 0 &&
            index < backgroundMsgs.length) {
          backgroundMsgs[index]['images'] = jsonEncode(imageResult.imagePaths);
          backgroundMsgs[index]['imageMetas'] = imageMetasJson;
          if (imageResult.imageCostEur != null) {
            backgroundMsgs[index]['imageCostEur'] = imageResult.imageCostEur!;
          }
          if (imageResult.imageGeneratedAt != null) {
            backgroundMsgs[index]['imageGeneratedAt'] =
                imageResult.imageGeneratedAt!;
          }
          backgroundMsgs[index]['toolCalls'] = updatedToolCallsJson;
          _persistChatWithIdAndMessages(chatId, backgroundMsgs);
        }
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to process tool images: $error');
      }
    }
  }

  void _finalizeAiMessage(
    int index,
    String content, {
    String? reasoning,
    double? tps,
  }) {
    _autoSaveTimer?.cancel();
    // Streaming ended: drop the per-token live snapshot so the finalized
    // bubble renders from the persisted message text, not a stale live value.
    final String? finalizingChatId = _activeChatId;
    if (finalizingChatId != null) {
      ChatRuntimeRegistry.instance.lookup(finalizingChatId)?.streamingLive
          .value = null;
    }
    if (index < 0 || index >= _messages.length) {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      } else {
        _isSending = false;
      }
      return;
    }

    if (mounted) {
      setState(() {
        final Map<String, String> message = Map<String, String>.from(
          _messages[index],
        );
        message['text'] = content;
        message['reasoning'] = reasoning ?? '';
        if (tps != null) message['tps'] = tps.toString();
        _messages[index] = message;
        _isSending = false;
      });
    } else {
      final Map<String, String> message = Map<String, String>.from(
        _messages[index],
      );
      message['text'] = content;
      message['reasoning'] = reasoning ?? '';
      if (tps != null) message['tps'] = tps.toString();
      _messages[index] = message;
      _isSending = false;
    }

    if (mounted) {
      scrollChatToBottom();
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      _persistChat();

      // Drain the message queue — if the user typed while AI was responding.
      _drainPendingMessage();
    }
  }

  /// If a message was queued while the AI was streaming, inject it into the
  /// text field and trigger a new send cycle.
  /// Cancel a queued follow-up message and restore its text to the composer so
  /// the user can edit or discard it instead of losing it silently.
  void _cancelPendingMessage() {
    final pending = _pendingMessageText;
    if (pending == null) return;
    if (mounted) {
      setState(() {
        _pendingMessageText = null;
      });
    } else {
      _pendingMessageText = null;
    }
    if (_controller.text.trim().isEmpty) {
      _controller.text = pending;
      _controller.selection = TextSelection.collapsed(offset: pending.length);
    }
    _textFieldFocusNode.requestFocus();
  }

  void _drainPendingMessage() {
    final pending = _pendingMessageText;
    if (pending == null) return;
    if (mounted) {
      setState(() {
        _pendingMessageText = null;
      });
    } else {
      _pendingMessageText = null;
    }

    if (kDebugMode) {
      debugPrint(
        '📋 [DrainQueue] Sending queued message (${pending.length} chars)',
      );
    }

    // Put the text back into the controller so _sendMessage picks it up
    // via its normal `_controller.text.trim()` path.
    _controller.text = pending;
    _controller.selection = TextSelection.collapsed(offset: pending.length);
    unawaited(_sendMessage());
  }

  /// Enqueue an in-flight send (offline or network-error) and reflect the
  /// "pending" state in the UI + storage. Drops the trailing AI placeholder
  /// (if it's still "Thinking...") since no response will arrive until
  /// connectivity returns.
  /// Returns true if the message was successfully enqueued, false otherwise.
  /// Callers must check the return value and fall back to error display on
  /// failure.
  Future<bool> _enqueueOfflineSend({
    required String chatId,
    required int userMsgIndex,
    required int placeholderIndex,
    required String messageText,
    required String displayText,
    required String providerSlug,
    String? systemPrompt,
    String? imagesJson,
    required int maxTokens,
    String? reasoningEffort,
  }) async {
    final payload = OfflineSendPayload(
      chatId: chatId,
      messageText: messageText,
      modelId: _selectedModelId,
      providerSlug: providerSlug,
      systemPrompt: systemPrompt,
      imagesJson: imagesJson,
      maxTokens: maxTokens,
      reasoningEffort: reasoningEffort,
    );

    String queueId;
    try {
      queueId = await OfflineSendCoordinator.enqueue(payload);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Desktop-Send] enqueue failed: $e');
      }
      return false;
    }

    if (!mounted) return true;
    setState(() {
      if (userMsgIndex >= 0 && userMsgIndex < _messages.length) {
        _messages[userMsgIndex]['status'] = 'pending';
        _messages[userMsgIndex]['queueId'] = queueId;
      }
      // Drop the trailing "Thinking..." placeholder — no AI reply will come
      // until the queued send is replayed.
      if (placeholderIndex >= 0 &&
          placeholderIndex < _messages.length &&
          _messages[placeholderIndex]['text'] == 'Thinking...') {
        _messages.removeAt(placeholderIndex);
      }
      _isSending = false;
    });
    _persistChatWithId(chatId);
    return true;
  }
}
