// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';
import 'dart:math' as math;
import 'package:cowork/ui/expressive/day_divider.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/constants.dart';
import 'package:cowork/platform_config.dart';
import 'package:cowork/models/content_block.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/offline_retry_manager.dart';
import 'package:cowork/services/chat_runtime.dart';
import 'package:cowork/models/chat_reply.dart';
import 'package:cowork/services/mcp/mcp_availability.dart';
import 'package:cowork/services/chat_runtime_registry.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/network_status_service.dart';
import 'package:cowork/services/multiplex_session.dart';
import 'package:cowork/services/app_lifecycle_service.dart';
import 'package:cowork/core/model_selection_events.dart';
import 'package:cowork/services/chat_model_selection_service.dart';
import 'package:cowork/services/chat_reaction_service.dart';
import 'package:cowork/widgets/message_bubble.dart';
import 'package:cowork/widgets/chat_reply_preview.dart';
import 'package:cowork/widgets/messenger_typing_indicator.dart';
import 'package:cowork/widgets/message_fly_in.dart';
import 'package:cowork/widgets/measure_size.dart';
import 'package:cowork/widgets/selection_copy_area.dart';
import 'package:cowork/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:cowork/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:cowork/widgets/attachment_preview_bar.dart';
import 'package:cowork/services/chat_mode_service.dart';
import 'package:cowork/services/model_capabilities_service.dart';
import 'package:cowork/widgets/model_selection_dropdown.dart';
import 'package:cowork/services/tour_key_registry.dart';
import 'package:cowork/platform_specific/chat/chat_api_service.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

// Import new handlers
import 'package:cowork/platform_specific/chat/handlers/audio_recording_handler.dart';
import 'package:cowork/platform_specific/chat/handlers/file_attachment_handler.dart';
import 'package:cowork/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:cowork/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:cowork/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:cowork/platform_specific/chat/widgets/mobile_chat_widgets.dart';
import 'package:cowork/platform_specific/chat/chat_ui_helpers.dart';
import 'package:cowork/platform_specific/chat/regen_variant_seed.dart';
import 'package:cowork/platform_specific/chat/widgets/fullscreen_composer.dart';
import 'package:cowork/services/workspace_storage_service.dart';
import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/platform_specific/chat/composer_queue.dart';
import 'package:cowork/platform_specific/chat/chat_metrics_observer.dart';
import 'package:cowork/platform_specific/chat/message_decode_cache.dart';
import 'package:cowork/platform_specific/chat/composer_metrics.dart';
import 'package:cowork/platform_specific/chat/mobile_model_selection_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_attach_mixin.dart';
import 'package:cowork/platform_specific/chat/assistant_message_write_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_send_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_message_edit_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_chat_loading_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_recording_mixin.dart';
import 'package:cowork/platform_specific/chat/payment_required_dialog.dart';

/// What the plus menu can start.
class ChukChatUIMobile extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final String? selectedChatId;
  final Function(String?) onChatIdChanged;
  final bool isSidebarExpanded;
  final bool showReasoningTokens;
  final bool showModelInfo;
  final bool showTps;
  final bool autoSendVoiceTranscription;

  /// Extra top padding for the message list so its first row scrolls under
  /// the host's floating, translucent top bar instead of starting behind it.
  /// The bar overlays the chat (rather than sitting in its own solid band),
  /// which is what lets the chat show through the frosted chrome.
  final double topInset;
  // Image generation settings
  final bool imageGenEnabled;
  final String imageGenDefaultSize;
  final int imageGenCustomWidth;
  final int imageGenCustomHeight;
  final bool imageGenUseCustomSize;
  // AI context settings
  final bool includeRecentImagesInHistory;
  final bool includeAllImagesInHistory;
  final bool includeReasoningInHistory;
  final bool includeToolResultsInHistory;
  // Tool-calling settings
  final bool toolCallingEnabled;
  final bool toolDiscoveryMode;
  final bool showToolCalls;

  /// Messenger presentation only; does not change model or reasoning settings.
  final bool messengerMode;

  /// Host activity survives the lifetime of a local streaming subscription.
  /// Only set from an observed live run, never inferred from offline history.
  final bool hostRunActive;

  const ChukChatUIMobile({
    super.key,
    required this.onToggleSidebar,
    required this.selectedChatId,
    required this.onChatIdChanged,
    required this.isSidebarExpanded,
    required this.showReasoningTokens,
    required this.showModelInfo,
    required this.showTps,
    required this.autoSendVoiceTranscription,
    this.topInset = 0,
    this.imageGenEnabled = false,
    this.imageGenDefaultSize = 'landscape_4_3',
    this.imageGenCustomWidth = 1024,
    this.imageGenCustomHeight = 768,
    this.imageGenUseCustomSize = false,
    this.includeRecentImagesInHistory = true,
    this.includeAllImagesInHistory = false,
    this.includeReasoningInHistory = false,
    this.includeToolResultsInHistory = kDefaultIncludeToolResultsInHistory,
    this.toolCallingEnabled = true,
    this.toolDiscoveryMode = true,
    this.showToolCalls = true,
    this.messengerMode = false,
    this.hostRunActive = false,
  });

  @override
  State<ChukChatUIMobile> createState() => ChukChatUIMobileState();
}

/// Serialize a [ChatMessageStatus] into the wire-format string used inside
/// the chat message map (kept in sync with the values consumed by the
/// inline parser further down). `null` returns `null` so historic
/// messages stay status-less on disk.
class ChukChatUIMobileState extends State<ChukChatUIMobile>
    with
        ChatScrollMixin,
        ModelProviderResolutionMixin,
        MobileModelSelectionMixin,
        MobileAttachMixin,
        RegenVariantSeedMixin<ChukChatUIMobile>,
        AssistantMessageWriteMixin,
        MobileSendMixin,
        MobileMessageEditMixin,
        MobileChatLoadingMixin,
        MobileRecordingMixin {
  // Controllers and basic state
  final TextEditingController composerController = TextEditingController();
  final List<Map<String, String>> messages = [];

  // Per-payload decode caches keyed by the raw JSON string. The list
  // itemBuilder previously re-ran jsonDecode + model construction for images,
  // attachments, tool calls and content blocks on every build — i.e. every
  // frame a bubble scrolled into view. Caching by the exact JSON string makes
  // scrolling a static chat allocation-free. Cleared on chat switch.
  // Keyed by message index; each entry holds the last-seen JSON string and its
  // decoded value. A payload rewritten during a turn (tool call
  // pending→running→completed, streamed content-block updates) overwrites the
  // one prior entry instead of accumulating a permanent copy per intermediate
  // JSON value, so a long tool-heavy chat can hold at most one stale entry per
  // message per type.
  final MessageDecodeCache decodeCache = MessageDecodeCache();

  /// Drop every decoded side-car. The message list has been rewritten, so the
  /// indices the cache is keyed by now mean different messages.
  @override
  void clearDecodeCaches() => decodeCache.clear();
  String? activeChatId;

  // Answer-version pager plumbing (seed stash/restore/fold) lives in
  // RegenVariantSeedMixin, shared with the desktop State. This State supplies
  // the two hooks it needs via [variantActiveChatId] and [variantChatIsLive].

  final ScrollController _composerScrollController = ScrollController();

  /// Keeps the newest message above the composer when the keyboard resizes
  /// the chat. See [_initializeListeners].
  late final ChatMetricsObserver _viewInsetRepin = ChatMetricsObserver(
    pinToBottomDuringStream,
  );

  final FocusNode composerFocusNode = FocusNode();

  /// Rebuilds the composer when the field takes or loses focus, so the AI
  /// disclaimer under it can go with the keyboard.
  void _onTextFieldFocusChanged() {
    if (mounted) setState(() {});
  }
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();
  final Uuid uuid = const Uuid();
  bool _lastTextWasEmpty = true;
  bool _showFullscreenButton = false;

  // Services and handlers
  late ChatApiService chatApiService;
  late final AudioRecordingHandler audioHandler;
  late final FileAttachmentHandler fileHandler;
  late final MessageActionsHandler messageActionsHandler;
  late final ChatPersistenceHandler persistenceHandler;
  late final StreamingMessageHandler streamingHandler;

  // Model and provider state
  String _selectedModelId = ''; // Will be loaded from user preferences
  final Map<String, ChatReply> replyDrafts = {};
  void _onReactionsChanged() {
    if (mounted) setState(() {});
  }

  String _reactionKeyAt(int index) {
    final key = ChatReactionService.messageKey(messages[index]);
    if (!key.startsWith('legacy:') ||
        (messages[index]['sentAt']?.isNotEmpty ?? false) ||
        (messages[index]['startedAt']?.isNotEmpty ?? false)) {
      return key;
    }
    // Distinguish identical undated legacy messages without using absolute
    // list indices, so inserting unrelated history does not move reactions.
    var occurrence = 0;
    for (var i = 0; i < index; i++) {
      if (ChatReactionService.messageKey(messages[i]) == key) occurrence++;
    }
    return '$key:$occurrence';
  }

  Future<void> _toggleReaction(
    String chatId,
    String messageId,
    String emoji,
  ) async {
    try {
      await ChatReactionService.instance.toggle(chatId, messageId, emoji);
    } catch (_) {
      if (mounted) {
        ChatUiHelpers.showSnackBar(
          context,
          'Could not save reaction. Please try again.',
        );
      }
    }
  }

  String get replyChatKey =>
      widget.selectedChatId ?? activeChatId ?? 'default';
  String? _selectedProviderSlug;

  /// UI key of the message that was just sent, so its list item plays the
  /// fly-up entrance once. Transient, never persisted.
  String? flyInKey;

  // Bridge the private fields above to ModelProviderResolutionMixin.
  @override
  String get selectedModelId => _selectedModelId;
  @override
  set selectedModelId(String value) => _selectedModelId = value;
  @override
  String? get selectedProviderSlug => _selectedProviderSlug;
  @override
  set selectedProviderSlug(String? value) => _selectedProviderSlug = value;
  @override
  String? get modelSelectionChatId => widget.selectedChatId ?? activeChatId;

  late final VoidCallback _modelSelectionListener;

  // Stream subscriptions
  StreamSubscription<void>? _providerRefreshSubscription;

  // Network and UI state
  bool isOffline = false;

  /// The composer's outbox: every message the user fired while the coworker
  /// was still working, oldest first. Drained one per finished run.
  bool isAppInBackground = false;
  late final VoidCallback _networkStatusListener;


  // Computed property - checks if CURRENT chat is streaming
  bool get isCurrentChatStreaming =>
      activeChatId != null &&
      streamingHandler.isChatStreaming(activeChatId!);

  /// Per-chat send-in-flight flag, backed by the ChatRuntime for the
  /// currently visible chat. Reads return false for chats with no runtime
  /// yet (no send ever attempted). Writes are no-ops when there is no
  /// active chat (the caller has nowhere to record state).
  ///
  /// Per-chat semantics are required for multi-chat parallel sends: a
  /// send in chat A must not block a send in chat B.
  bool get isSendingMessage {
    final cid = activeChatId;
    if (cid == null) return false;
    return ChatRuntimeRegistry.instance.lookup(cid)?.isSending.value ?? false;
  }

  set isSendingMessage(bool value) {
    final cid = activeChatId;
    if (cid == null) return;
    ChatRuntimeRegistry.instance.get(cid).isSending.value = value;
  }

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kHorizontalPaddingSmall = 8.0;

  @override
  void initState() {
    super.initState();
    _initializeHandlers();
    _initializeListeners();
    composerFocusNode.addListener(_onTextFieldFocusChanged);
    ChatModelSelectionService.instance.addListener(onChatModelChanged);
    ChatReactionService.instance.addListener(_onReactionsChanged);
    AppLifecycleService.instance.addOnResumeCallback(_handleAppResumed);
    AppLifecycleService.instance.addOnPauseCallback(_handleAppPaused);
    // Mode + its config (model, provider, reasoning) restore once, via
    // _loadSavedModelPreference in _loadInitialData's post-frame pass — the
    // single entry point, so startup writes and picked-model refreshes run
    // only once.
    _loadInitialData();
  }

  void _initializeHandlers() {
    chatApiService = ChatApiService(
      onUploadStatusUpdate: handleFileUploadUpdate,
    );

    audioHandler = AudioRecordingHandler();

    fileHandler = FileAttachmentHandler()
      ..initialize(chatApiService)
      ..onError = showChatSnackBar
      ..onUpdate = () {
        if (audioHandler.isMicActive) {
          // Defer rebuild while mic visualizer is active to avoid flicker.
        } else {
          setState(() {});
        }
      };

    messageActionsHandler = MessageActionsHandler()
      ..onShowSnackBar = showChatSnackBar
      ..onSubmitEdit = (index, newText) {
        unawaited(
          submitEditedMessage(
            index,
            newText,
            removeFollowingAssistant: false,
            clearMessagesBelow: true,
          ),
        );
      }
      ..onResend = resendMessageAt;

    persistenceHandler = ChatPersistenceHandler()
      ..onShowSnackBar = showChatSnackBar
      ..onChatIdAssigned = (chatId) {
        if (mounted && activeChatId != chatId) {
          setState(() {
            activeChatId = chatId;
          });
          unawaited(
            MultiplexSession.openForChat(chatId).catchError((e) {
              if (kDebugMode) {
                debugPrint('⚠️ MultiplexSession.openForChat failed: $e');
              }
            }),
          );
        }
      };

    streamingHandler = StreamingMessageHandler()
      ..onShowSnackBar = showChatSnackBar
      ..onUpdateUI = () {
        if (mounted) setState(() {});
      }
      ..onMessageUpdate = updateAiMessage
      ..onMessageFinalize = finalizeAiMessage
      ..onToolCallsUpdate = updateToolCallsForMessage
      ..onToolImagesProcessed = handleToolImagesProcessed
      ..onContentBlocksUpdate = updateContentBlocksForMessage
      ..onRequestPayloadUpdate = updateRequestPayloadForMessage
      ..onBackgroundUpdate = (chatId, index, content, reasoning) {
        if (activeChatId != chatId || isAppInBackground) {
          unawaited(
            persistenceHandler
                .updateBackgroundChatMessage(
                  chatId: chatId,
                  messageIndex: index,
                  content: content,
                  reasoning: reasoning,
                  immediate: isAppInBackground,
                )
                .catchError((error) {
                  if (kDebugMode) {
                    debugPrint(
                      'updateBackgroundChatMessage (onBackgroundUpdate) failed: $error',
                    );
                  }
                }),
          );
        }
      }
      ..onStreamInterrupted = markAssistantMessageInterrupted
      ..onStreamTick = persistStreamTick
      ..onPaymentRequired = () {
        // The `mounted` guard the dialog used to carry itself: the callback
        // can fire after this screen is gone.
        if (!mounted) return;
        showPaymentRequiredDialog(context);
      };
  }

  void _handleAppResumed() {
    isAppInBackground = false;
  }

  void _handleAppPaused() {
    isAppInBackground = true;

    // Snapshot active chat state so streaming/tool loops can persist updates
    // while the app is backgrounded or the device is locked.
    if (activeChatId != null &&
        streamingHandler.isChatStreaming(activeChatId!)) {
      final messagesCopy = messages
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      streamingHandler.setBackgroundMessages(activeChatId!, messagesCopy);
    }
  }

  void _initializeListeners() {
    // Scroll listener for scroll-to-bottom button
    scrollController.addListener(onScrollChanged);

    // The soft keyboard does not pad this subtree, it SHRINKS it: the hosting
    // Scaffold resizes the body (this one runs `resizeToAvoidBottomInset:
    // false`). A top-anchored list keeps its offset when its viewport shrinks,
    // so without this the newest message walks down behind the composer the
    // moment the keyboard opens. The pin bails out by itself when the reader
    // has scrolled up into the history.
    WidgetsBinding.instance.addObserver(_viewInsetRepin);

    // Text field focus listener — collapse mic & model buttons while typing

    // Text controller listener
    composerController.addListener(_onControllerChanged);

    // Request focus if sidebar closed — never on a phone, see
    // [mayAutoFocusComposer].
    if (mayAutoFocusComposer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!widget.isSidebarExpanded) {
          composerFocusNode.requestFocus();
        }
      });
    }

    // Model selection listener
    _modelSelectionListener = () {
      final scopedId = modelSelectionChatId;
      if (scopedId != null) {
        unawaited(hydrateChatModel());
        return;
      }
      final String newModelId =
          ModelSelectionDropdown.selectedModelNotifier.value;
      if (newModelId != selectedModelId) {
        setState(() {
          selectedModelId = newModelId;
        });
      }
      unawaited(refreshSelectedModelName(newModelId));
      unawaited(loadProviderSlugForModel(newModelId));
    };
    ModelSelectionDropdown.selectedModelListenable.addListener(
      _modelSelectionListener,
    );

    // Provider refresh listener
    _providerRefreshSubscription = ModelSelectionEventBus().refreshStream
        .listen((_) {
          // Skip dropdown cache (may be stale) and read from prefs directly
          unawaited(
            loadProviderSlugForModel(selectedModelId, forceFromPrefs: true),
          );
        });

    // Network status listener
    _networkStatusListener = () {
      final bool isOnline = NetworkStatusService.isOnline;
      if (isOffline != !isOnline) {
        setState(() {
          isOffline = !isOnline;
        });
        showChatSnackBar(isOnline ? 'Back online' : 'You are offline');
      }
    };
    NetworkStatusService.isOnlineListenable.addListener(_networkStatusListener);
  }

  void _onControllerChanged() {
    final bool currentTextIsEmpty = composerController.text.trim().isEmpty;
    final String text = composerController.text;

    final int newlineCount = '\n'.allMatches(text).length;
    final bool shouldShowFullscreen = text.length > 66 || newlineCount >= 2;

    if (currentTextIsEmpty != _lastTextWasEmpty ||
        shouldShowFullscreen != _showFullscreenButton) {
      setState(() {
        _lastTextWasEmpty = currentTextIsEmpty;
        _showFullscreenButton = shouldShowFullscreen;
      });
    }
  }

  void _loadInitialData() {
    // Load chat synchronously (uses microtask internally)
    loadChatById(widget.selectedChatId);

    // Defer all network-dependent loading to after first frame
    // This ensures the UI renders immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Load model preference first (needed for sending)
      unawaited(_loadSavedModelPreference());
      // These can load in parallel after UI is shown
      unawaited(loadSystemPrompt());
      unawaited(NetworkStatusService.quickCheck());
      // Load projects for workspace selection feature
      if (kFeatureWorkspaces) {
        unawaited(WorkspaceStorageService.loadFromCache());
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChukChatUIMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ID-BASED: Only react when the actual chat ID changes
    if (widget.selectedChatId != oldWidget.selectedChatId) {
      unawaited(_loadSavedModelPreference());
      if (kDebugMode) {
        debugPrint('');
      }
      if (kDebugMode) {
        debugPrint(
          '┌─────────────────────────────────────────────────────────────',
        );
      }
      if (kDebugMode) {
        debugPrint('│ 🔄 [CHAT-UI-MOBILE] didUpdateWidget triggered');
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] OLD widget.selectedChatId: ${oldWidget.selectedChatId}',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] NEW widget.selectedChatId: ${widget.selectedChatId}',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] Current activeChatId: $activeChatId',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] isSendingMessage: $isSendingMessage',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] streamingHandler.isStreaming: ${streamingHandler.isStreaming}',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '└─────────────────────────────────────────────────────────────',
        );
      }

      // Skip if we're already on this chat
      if (widget.selectedChatId == activeChatId) {
        if (kDebugMode) {
          debugPrint('⚠️ [CHAT-UI-MOBILE] SKIP - already on this chat');
        }
        return;
      }

      // CRITICAL FIX: Don't clear an active chat just because parent sent null
      // This can happen due to stale parent rebuilds. If we have an active chat
      // with messages, keep it instead of switching to a blank "new" chat.
      if (widget.selectedChatId == null &&
          activeChatId != null &&
          messages.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '⚠️ [CHAT-UI-MOBILE] IGNORING null from parent - we have active chat: $activeChatId',
          );
        }
        // Sync the parent back to our active chat after this build pass.
        final String? keptChatId = activeChatId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (keptChatId == null) return;
          widget.onChatIdChanged(keptChatId);
        });
        return;
      }

      // CRITICAL: NO persist during chat switch!
      // Persisting here causes data corruption because messages may already contain
      // the NEW chat's content by the time didUpdateWidget fires (due to async timing).
      // Instead, we rely on:
      // 1. Immediate persist after message send/receive
      // 2. Persist in newChat() before clearing
      // 3. Chats are already saved to Supabase during message operations
      if (kDebugMode) {
        debugPrint(
          '│ 📝 [CHAT-UI-MOBILE] Chat switch - NOT persisting (already saved on message ops)',
        );
      }

      // BACKGROUND STREAMING: If current chat is streaming, snapshot messages
      // to StreamingManager before clearing. This ensures the stream can
      // continue in background and persist correctly when complete.
      if (activeChatId != null &&
          streamingHandler.isChatStreaming(activeChatId!)) {
        final messagesCopy = messages
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        streamingHandler.setBackgroundMessages(activeChatId!, messagesCopy);
        if (kDebugMode) {
          debugPrint(
            '│ 📦 [CHAT-UI-MOBILE] Snapshotted ${messagesCopy.length} messages for background stream: $activeChatId',
          );
        }
      }

      setState(() {
        messages.clear();
        decodeCache.clear();
        fileHandler.clearAll();
        composerController.clear();
        messageActionsHandler.cancelEdit();
      });

      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] About to call loadChatById(${widget.selectedChatId})',
        );
      }
      loadChatById(widget.selectedChatId);
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] After loadChatById, activeChatId: $activeChatId',
        );
      }

      final bool newChatIsStreaming =
          activeChatId != null &&
          streamingHandler.isChatStreaming(activeChatId!);

      if (newChatIsStreaming != streamingHandler.isStreaming) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_viewInsetRepin);
    ChatReactionService.instance.removeListener(_onReactionsChanged);
    ChatModelSelectionService.instance.removeListener(onChatModelChanged);
    AppLifecycleService.instance.removeOnResumeCallback(_handleAppResumed);
    AppLifecycleService.instance.removeOnPauseCallback(_handleAppPaused);
    if (activeChatId != null) {
      streamingHandler.cancelStream(activeChatId);
      MultiplexSession.closeForChat(activeChatId!);
    }
    // Tear down the streaming handler so its lifecycle observer
    // unregisters and the periodic snapshot timer is cancelled. Without
    // this each rebuild of the chat State leaks a registered pause
    // callback — and `dispose()` is also our last chance to flush the
    // in-flight snapshot to disk.
    streamingHandler.dispose();
    persistenceHandler.dispose();
    audioVisualizerTimer?.cancel();
    _providerRefreshSubscription?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      _networkStatusListener,
    );
    scrollController.removeListener(onScrollChanged);
    composerController.removeListener(_onControllerChanged);
    composerController.dispose();
    scrollController.dispose();
    _composerScrollController.dispose();
    composerFocusNode.removeListener(_onTextFieldFocusChanged);
    composerFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    ModelSelectionDropdown.selectedModelListenable.removeListener(
      _modelSelectionListener,
    );
    audioHandler.onLevelsChanged = null;
    audioHandler.dispose();
    super.dispose();
  }

  // --- CHAT MANAGEMENT ---

  List<Map<String, String>> get debugMessages =>
      messages.map((m) => Map<String, String>.from(m)).toList();

  /// Current resolved system prompt (workspace or user default). Debug only.
  String? get debugSystemPrompt => systemPrompt;

  /// Current model id used for outgoing requests. Debug only.
  String get debugModelId => selectedModelId;

  /// Current provider slug used for outgoing requests. Debug only.
  String? get debugProviderSlug => selectedProviderSlug;

  /// Current workspace id, if any. Debug only.
  String? get debugWorkspaceId => selectedWorkspaceId;

  /// Whether reasoning is enabled for the active mode. Debug only.
  bool get debugReasoningEnabled =>
      reasoningEffort != ChatModeService.reasoningOff;

  /// Effort actually sent with each request — shown in the debug export,
  /// where "true/false" hid which of the two modes was running.
  String get debugReasoningEffort => reasoningEffort;

  /// Current active chat id. Debug only.
  String? get debugActiveChatId => activeChatId;

  /// Fork the conversation into a brand-new chat, up to and including the
  /// message at [index]. The current chat is left untouched in storage; the
  /// new chat becomes the active one.
  Future<void> _branchFromIndex(int index) async {
    if (index < 0 || index >= messages.length) return;
    final List<Map<String, String>> branchMessages = messages
        .sublist(0, index + 1)
        .map((m) => Map<String, String>.from(m))
        .toList();
    if (branchMessages.isEmpty) return;

    final StoredChat? created = await persistenceHandler.persistChat(
      messages: branchMessages,
      chatId: null,
      waitForCompletion: true,
      silent: true,
    );
    if (created == null) {
      showChatSnackBar('Could not branch chat');
      return;
    }
    if (!mounted) return;
    setState(() {
      messages
        ..clear()
        ..addAll(branchMessages);
      activeChatId = created.id;
      messageActionsHandler.cancelEdit();
    });
    widget.onChatIdChanged(created.id);
    scrollChatToBottom(force: true);
    showChatSnackBar('Branched into a new chat');
  }

  // ---------------------------------------------------------------------------
  // Answer-version pager (OpenAI-style ‹ k/n › on regenerated answers).
  // ---------------------------------------------------------------------------

  /// Capture the answer(s) about to be discarded by a regenerate at
  /// [userIndex] (the preceding user message), to seed the fresh answer's
  /// variant archive. Reuses the old answer's own archive when it already has
  /// one (repeated regenerates keep stacking), else a single snapshot. Returns
  /// null when there is no assistant answer to preserve.
  List<Map<String, dynamic>>? captureRegenSeed(int userIndex) {
    final int aiIndex = userIndex + 1;
    if (aiIndex >= messages.length) return null;
    final Map<String, String> old = messages[aiIndex];
    if (old['sender'] != 'ai') return null;
    final existing = ChatUiHelpers.decodeVariants(old['variants']);
    if (existing.isNotEmpty) return existing;
    return <Map<String, dynamic>>[ChatUiHelpers.variantSnapshotOf(old)];
  }

  // RegenVariantSeedMixin hook: the seed logic is shared with desktop; this
  // State only has to name the chat that owns the visible message list.
  @override
  String? get variantActiveChatId => activeChatId;

  /// Switch the answer shown by the message at [index] to variant [newIndex]
  /// and persist. Wired to the pager arrows.
  void _switchVariantAt(int index, int newIndex) {
    if (index < 0 || index >= messages.length) return;
    if (!ChatUiHelpers.switchVariant(messages[index], newIndex)) return;
    setState(() {});
    persistChat();
  }

  @override
  void startNewChatWithProject(String? workspaceId) {
    // Clear current chat and set workspace
    setState(() {
      activeChatId = null;
      messages.clear();
      decodeCache.clear();
      messageActionsHandler.cancelEdit();
      selectedWorkspaceId = workspaceId;
      composerController.clear();
    });
    widget.onChatIdChanged(null);
    if (workspaceId != null) {
      final workspace = WorkspaceStorageService.getWorkspace(workspaceId);
      if (workspace != null) {
        showChatSnackBar('New chat with workspace: ${workspace.name}');
      }
    }
  }

  ValueChanged<String>? _askUserCallbackForMessage({
    required int index,
    required bool isUser,
    required bool isStreaming,
    required List<ToolCall>? toolCalls,
    required List<ContentBlock>? contentBlocks,
  }) {
    if (isUser || isStreaming || isCurrentChatStreaming || isSendingMessage) {
      return null;
    }
    if (index != messages.length - 1) {
      return null;
    }

    bool hasAskUser = false;
    if (contentBlocks != null) {
      for (final block in contentBlocks) {
        if (block.type == ContentBlockType.toolCalls &&
            block.toolCalls != null) {
          hasAskUser = block.toolCalls!.any(
            (tc) =>
                tc.name == 'ask_user' && tc.status == ToolCallStatus.completed,
          );
          if (hasAskUser) break;
        }
      }
    }
    if (!hasAskUser && toolCalls != null) {
      hasAskUser = toolCalls.any(
        (tc) => tc.name == 'ask_user' && tc.status == ToolCallStatus.completed,
      );
    }
    if (!hasAskUser) {
      return null;
    }

    return (String answer) {
      composerController.text = answer;
      sendMessage();
    };
  }

  /// Returns a callback for the inline MCP Connect card if [index] is the last
  /// AI message, is idle, and contains a completed request_mcp_server call.
  /// Resumes the same conversation with a fresh send once the server is live.
  ValueChanged<String>? _connectMcpCallbackForMessage({
    required int index,
    required bool isUser,
    required bool isStreaming,
    required List<ToolCall>? toolCalls,
    required List<ContentBlock>? contentBlocks,
  }) {
    if (isUser || isStreaming || isCurrentChatStreaming || isSendingMessage) {
      return null;
    }
    if (index != messages.length - 1) {
      return null;
    }

    bool hasRequest = false;
    if (contentBlocks != null) {
      for (final block in contentBlocks) {
        if (block.type == ContentBlockType.toolCalls &&
            block.toolCalls != null) {
          hasRequest = block.toolCalls!.any(
            (tc) =>
                tc.name == 'request_mcp_server' &&
                tc.status == ToolCallStatus.completed,
          );
          if (hasRequest) break;
        }
      }
    }
    if (!hasRequest && toolCalls != null) {
      hasRequest = toolCalls.any(
        (tc) =>
            tc.name == 'request_mcp_server' &&
            tc.status == ToolCallStatus.completed,
      );
    }
    if (!hasRequest) {
      return null;
    }

    return (String id) {
      final name = catalogueEntryById(id)?.name ?? 'the';
      composerController.text =
          'Connected the $name server — its tools are now available. '
          'Continue with what I asked.';
      sendMessage();
    };
  }

  Future<void> _openFullscreenEditor() async {
    final result = await showFullscreenComposer(
      context,
      initialText: composerController.text,
    );
    if (result != null) {
      setState(() {
        composerController.text = result;
        composerController.selection = TextSelection.fromPosition(
          TextPosition(offset: result.length),
        );
      });
    }
  }

  // --- UTILITY METHODS ---

  /// Load the user's saved model preference
  Future<void> _loadSavedModelPreference() async {
    // The active mode's config is the single source of truth for the model,
    // provider and reasoning level. It always yields a model (baked
    // defaults), so this simply projects it — no separate saved-vs-default
    // branch to keep in step.
    try {
      await restoreChatMode();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading saved model preference: $e');
      }
    }
  }

  void _openComingSoonFeature(String featureName) {
    if (!mounted) return;
    ChatUiHelpers.openComingSoonFeature(context, featureName);
  }

  @override
  void showChatSnackBar(String message) {
    ChatUiHelpers.showSnackBar(context, message);
  }

  Future<StoredChat?> persistChat({bool waitForCompletion = false}) async {
    return await persistenceHandler.persistChat(
      messages: messages,
      chatId: activeChatId,
      waitForCompletion: waitForCompletion,
      isOffline: isOffline,
    );
  }

  String? _formatModelInfo(String? modelId, String? provider) =>
      ChatUiHelpers.formatModelInfo(modelId, provider);

  /// The turn's recorded length, or null on a message saved before it was
  /// written down — the header then counts from the tool stamps as before.
  static Duration? _workedForOf(Map<String, String> raw, bool isAiMessage) {
    if (!isAiMessage) return null;
    final ms = int.tryParse(raw['generationMs'] ?? '');
    if (ms == null || ms < 0) return null;
    return Duration(milliseconds: ms);
  }

  // --- BUILD METHOD ---

  @override
  Widget build(BuildContext context) {
    const bool isCompactModeForModelDropdown = true;
    final theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;

    // No LayoutBuilder here. The hosting Scaffold resizes its body while the
    // keyboard slides up, so a screen-wide LayoutBuilder re-ran this whole
    // subtree — composer, list, mode selector — during the layout phase of
    // every animation frame, for a value (the width) that never changes.
    //
    // sizeOf/paddingOf subscribe to one aspect each; MediaQuery.of would
    // subscribe to viewInsets too and bring the per-frame rebuild back.
    final double availableWidth = MediaQuery.sizeOf(context).width;
    final double bottomPadding = MediaQuery.paddingOf(context).bottom;

    const double effectiveHorizontalPadding = _kHorizontalPaddingSmall;
    final double maxPossibleChatContentWidth = math.max(
      0.0,
      availableWidth - (effectiveHorizontalPadding * 2),
    );
    final double constrainedChatContentWidth = math.min(
      _kMaxChatContentWidth,
      maxPossibleChatContentWidth,
    );

    return _buildChatContent(
      context: context,
      bottomPadding: bottomPadding,
      theme: theme,
      iconFg: iconFg,
      expandedInputWidth: constrainedChatContentWidth,
      effectiveHorizontalPadding: effectiveHorizontalPadding,
      isCompactModeForModelDropdown: isCompactModeForModelDropdown,
    );
  }

  Widget _buildChatContent({
    required BuildContext context,
    required double bottomPadding,
    required ThemeData theme,
    required Color iconFg,
    required double expandedInputWidth,
    required double effectiveHorizontalPadding,
    required bool isCompactModeForModelDropdown,
  }) {
    final bool hasAttachments = fileHandler.hasAttachments;
    final bool hasMessages = messages.isNotEmpty;
    final bool hasLocalTypingBubble =
        hasMessages &&
        messages.last['sender'] != 'user' &&
        (isCurrentChatStreaming || isSendingMessage);
    final bool showHostTyping =
        widget.messengerMode && widget.hostRunActive && !hasLocalTypingBubble;
    // Fallback estimate, used only for the first frame before MeasureSize
    // reports the composer's real height. Kept close to the real value so
    // there's no visible jump when the measured height lands.
    final double composerEstimate =
        // 46 pill + 8 gap + ~10 disclaimer. Was 153 while the composer was the
        // tall boxed variant; leaving it there over-reserved the first frame.
        64.0 +
        (hasAttachments ? 80.0 : 0.0) +
        (pendingMessages.isNotEmpty ? 28.0 : 0.0) +
        ((isCurrentChatStreaming || isSendingMessage) ? 28.0 : 0.0) +
        bottomPadding;
    // Distance from the bottom edge to the top of the composer, plus a small
    // gap so the last message never sits flush against the input box. The
    // composer is offset `effectiveHorizontalPadding` from the bottom edge.
    // The measured height stops at the composer's own column: the SafeArea
    // that lifts it above the gesture bar sits outside MeasureSize, so its
    // inset has to be added here. Without it the last card of a message
    // ends up behind the input box.
    final double composerReservedSpace =
        effectiveHorizontalPadding +
        (composerHeight > 0
            ? composerHeight + bottomPadding
            : composerEstimate) +
        16.0;
    final EdgeInsets listPadding = EdgeInsets.fromLTRB(
      effectiveHorizontalPadding,
      10 + widget.topInset,
      effectiveHorizontalPadding,
      composerReservedSpace,
    );

    final Color accent = theme.colorScheme.primary;
    final Color bg = theme.scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // No manual keyboard padding: the hosting Scaffold already strips
          // viewInsets from this subtree and resizes the body, so the old
          // EdgeInsets.only(bottom: keyboardInset) was always zero — it only
          // forced this widget to depend on an animating value.
          Builder(
            builder: (context) => GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                FocusScope.of(context).unfocus();
              },
              child: Stack(
                children: [
                  (hasMessages || showHostTyping)
                      ? Align(
                          alignment: Alignment.center,
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth: expandedInputWidth,
                            ),
                            child: SelectionCopyArea(
                              child: ListView.builder(
                                controller: scrollController,
                                padding: listPadding,
                                itemCount:
                                    messages.length + (showHostTyping ? 1 : 0),
                                addAutomaticKeepAlives: false,
                                // Each item already wraps itself in a
                                // RepaintBoundary below; letting the list add
                                // a second one around it doubled the layers
                                // for no gain.
                                addRepaintBoundaries: false,
                                // 1000 px built roughly two extra tall
                                // bubbles off each end of the viewport, and
                                // the viewport resizes while the keyboard
                                // animates.
                                cacheExtent: 400.0,
                                itemBuilder: (_, int i) {
                                  if (i == messages.length) {
                                    return const Padding(
                                      key: ValueKey('host-run-typing'),
                                      padding: EdgeInsets.only(
                                        top: 8,
                                        bottom: 8,
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: MessengerTypingIndicator(),
                                      ),
                                    );
                                  }
                                  final Map<String, String> raw = messages[i];
                                  final String sender = raw['sender'] ?? 'ai';
                                  final bool isAiMessage = sender != 'user';
                                  final bool isStreamingMessage =
                                      isCurrentChatStreaming &&
                                      i == messages.length - 1 &&
                                      isAiMessage;
                                  final String displayText = (raw['text'] ?? '')
                                      .trimRight();
                                  final String reasoning =
                                      raw['reasoning'] ?? '';
                                  final String? modelLabel = isAiMessage
                                      ? _formatModelInfo(
                                          raw['modelId'],
                                          raw['provider'],
                                        )
                                      : null;
                                  final String? modelProvider = isAiMessage
                                      ? (raw['provider'] ?? '').trim()
                                      : null;
                                  final String? reasoningText =
                                      reasoning.trim().isEmpty
                                      ? null
                                      : reasoning;
                                  final bool isBeingEdited =
                                      messageActionsHandler
                                          .editingMessageIndex ==
                                      i;
                                  final bool isUser = sender == 'user';
                                  // The run this row belongs to. Sender,
                                  // day break and pause all break a run, and
                                  // the day divider below reads the same rule
                                  // — otherwise a divider lands INSIDE a
                                  // connected group (see chat_ui_helpers).
                                  final bool startsNewGroup = messageStartsRun(
                                    messages,
                                    i,
                                  );
                                  final bool endsGroup = messageEndsRun(
                                    messages,
                                    i,
                                  );

                                  // Decode payloads via per-JSON-string caches
                                  // so scrolling a static chat doesn't re-parse
                                  // (see _decode* helpers).
                                  final List<String>? images = decodeCache.images(
                                    i,
                                    raw['images'],
                                  );
                                  final List<DocumentAttachment>? attachments =
                                      decodeCache.attachments(i, raw['attachments']);

                                  // Parse TPS value from message
                                  final tpsStr = raw['tps'];
                                  double? tps;
                                  if (tpsStr != null && tpsStr.isNotEmpty) {
                                    tps = double.tryParse(tpsStr);
                                  }

                                  final List<ToolCall>? toolCalls =
                                      decodeCache.toolCalls(i, raw['toolCalls']);

                                  // Content blocks for interleaved tool
                                  // call / text display.
                                  final List<ContentBlock>?
                                  parsedContentBlocks = decodeCache.contentBlocks(
                                    i,
                                    raw['contentBlocks'],
                                  );

                                  final String? imageCostStr =
                                      raw['imageCostEur'];
                                  final double? imageCostEur =
                                      imageCostStr != null &&
                                          imageCostStr.isNotEmpty
                                      ? double.tryParse(imageCostStr)
                                      : null;
                                  final String? imageGeneratedAtStr =
                                      raw['imageGeneratedAt'];
                                  final DateTime? imageGeneratedAt =
                                      imageGeneratedAtStr != null &&
                                          imageGeneratedAtStr.isNotEmpty
                                      ? DateTime.tryParse(imageGeneratedAtStr)
                                      : null;
                                  final List<ImageMeta>? imageMetas =
                                      ImageMeta.decode(raw['imageMetas']);

                                  final statusRaw = raw['status'];
                                  ChatMessageStatus? status;
                                  if (statusRaw == 'pending') {
                                    status = ChatMessageStatus.pending;
                                  } else if (statusRaw == 'failed') {
                                    status = ChatMessageStatus.failed;
                                  } else if (statusRaw == 'sent') {
                                    status = ChatMessageStatus.sent;
                                  } else if (statusRaw == 'interrupted') {
                                    status = ChatMessageStatus.interrupted;
                                  }
                                  final lastError = raw['lastError'];

                                  // Answer-version pager: how many variants
                                  // this regenerated answer has and which is
                                  // shown.
                                  int variantCount = 0;
                                  int variantIndex = 0;
                                  if (isAiMessage) {
                                    final variants =
                                        ChatUiHelpers.decodeVariants(
                                          raw['variants'],
                                        );
                                    variantCount = variants.length;
                                    if (variantCount > 0) {
                                      variantIndex =
                                          (int.tryParse(
                                                    raw['activeVariant'] ?? '',
                                                  ) ??
                                                  0)
                                              .clamp(0, variantCount - 1);
                                    }
                                  }

                                  // The day break: a messenger puts a date chip
                                  // between two days. A row with no timestamp
                                  // gets none — an undated message is no
                                  // evidence of a day.
                                  final DateTime? rowDay = messageRowTime(raw);
                                  final bool opensDay = messageOpensDay(
                                    i == 0 ? null : messages[i - 1],
                                    raw,
                                  );
                                  Widget withDay(Widget bubble) =>
                                      opensDay && rowDay != null
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: <Widget>[
                                            ChatDayDivider(
                                              when: rowDay.toLocal(),
                                            ),
                                            bubble,
                                          ],
                                        )
                                      : bubble;

                                  // Build the bubble from a (text, reasoning)
                                  // pair so the streaming bubble can be fed live
                                  // values from the runtime notifier without a
                                  // screen-wide rebuild. All other props are
                                  // stable for the duration of a stream.
                                  final reactionChatId = replyChatKey;
                                  final reactionMessageId = _reactionKeyAt(i);
                                  MessageBubble buildBubble(
                                    String msgText,
                                    String? msgReasoning,
                                  ) => MessageBubble(
                                    key: ValueKey(
                                      ChatUiHelpers.stableUiKey(
                                        messages[i],
                                        uuid,
                                      ),
                                    ),
                                    message: msgText,
                                    messengerMode: widget.messengerMode,
                                    reaction: ChatReactionService.instance.peek(
                                      reactionChatId,
                                      reactionMessageId,
                                    ),
                                    onReaction:
                                        widget.messengerMode &&
                                            !isStreamingMessage
                                        ? (emoji) => unawaited(
                                            _toggleReaction(
                                              reactionChatId,
                                              reactionMessageId,
                                              emoji,
                                            ),
                                          )
                                        : null,
                                    reasoning: msgReasoning,
                                    isUser: isUser,
                                    startsNewGroup: startsNewGroup,
                                    endsGroup: endsGroup,
                                    maxWidth: widget.messengerMode
                                        ? expandedInputWidth *
                                              (isUser ? 0.72 : 1)
                                        : isUser
                                        ? expandedInputWidth * 0.8
                                        : expandedInputWidth,
                                    isReasoningStreaming: isStreamingMessage,
                                    modelLabel: modelLabel,
                                    modelProvider: modelProvider,
                                    tps: tps,
                                    toolCalls: toolCalls,
                                    showToolCalls: widget.showToolCalls,
                                    contentBlocks: parsedContentBlocks,
                                    isStreamingMessage:
                                        isStreamingMessage ||
                                        (widget.messengerMode &&
                                            isAiMessage &&
                                            i == messages.length - 1 &&
                                            isSendingMessage),
                                    // Both senders carry it now: the
                                    // assistant's drives the live counter,
                                    // the user's only its bubble clock.
                                    turnStartedAt: DateTime.tryParse(
                                      raw['startedAt'] ?? '',
                                    ),
                                    sentAt: DateTime.tryParse(
                                      raw['sentAt'] ?? '',
                                    ),
                                    workedFor: _workedForOf(raw, isAiMessage),
                                    images: images,
                                    imageMetas: imageMetas,
                                    attachments: attachments,
                                    imageCostEur: imageCostEur,
                                    imageGeneratedAt: imageGeneratedAt,
                                    actions: messageActionsHandler
                                        .buildActionsForMessage(
                                          index: i,
                                          messageText: msgText,
                                          isUser: isUser,
                                          isStreaming: isStreamingMessage,
                                          onEdit: editMessageAt,
                                          onResendMessage: resendMessageAt,
                                          onBranch: _branchFromIndex,
                                        ),
                                    onReply:
                                        widget.messengerMode &&
                                            msgText.trim().isNotEmpty
                                        ? () => replyToMessage(i)
                                        : null,
                                    onEditRequested:
                                        widget.messengerMode &&
                                            isUser &&
                                            !isCurrentChatStreaming
                                        ? () => editMessageAt(i)
                                        : null,
                                    userMessageActions: isUser
                                        ? messageActionsHandler
                                              .buildUserMessageActions(
                                                index: i,
                                                messageText: msgText,
                                                onEdit: editMessageAt,
                                                onResendMessage:
                                                    resendMessageAt,
                                              )
                                        : const [],
                                    isEditing: isBeingEdited,
                                    showReasoningTokens:
                                        widget.showReasoningTokens,
                                    showModelInfo: widget.showModelInfo,
                                    showTps: widget.showTps,
                                    onAskUserAnswer: _askUserCallbackForMessage(
                                      index: i,
                                      isUser: isUser,
                                      isStreaming: isStreamingMessage,
                                      toolCalls: toolCalls,
                                      contentBlocks: parsedContentBlocks,
                                    ),
                                    onConnectMcpServer:
                                        _connectMcpCallbackForMessage(
                                          index: i,
                                          isUser: isUser,
                                          isStreaming: isStreamingMessage,
                                          toolCalls: toolCalls,
                                          contentBlocks: parsedContentBlocks,
                                        ),
                                    useSharedSelectionArea: true,
                                    variantIndex: variantIndex,
                                    variantCount: variantCount,
                                    onPrevVariant: variantCount > 1
                                        ? () => _switchVariantAt(
                                            i,
                                            variantIndex - 1,
                                          )
                                        : null,
                                    onNextVariant: variantCount > 1
                                        ? () => _switchVariantAt(
                                            i,
                                            variantIndex + 1,
                                          )
                                        : null,
                                    status: status,
                                    lastError: lastError,
                                    onRetryPending:
                                        isUser &&
                                            (status ==
                                                    ChatMessageStatus.pending ||
                                                status ==
                                                    ChatMessageStatus.failed)
                                        ? () => OfflineRetryManager.instance
                                              .retryNow()
                                        : null,
                                    onContinueGeneration:
                                        !isUser &&
                                            status ==
                                                ChatMessageStatus.interrupted &&
                                            !isCurrentChatStreaming
                                        ? () => continueGenerationAt(i)
                                        : null,
                                  );

                                  // The streaming bubble rebuilds itself per
                                  // token via the runtime's streamingLive
                                  // notifier — the rest of the screen stays put.
                                  final ChatRuntime? runtime =
                                      activeChatId == null
                                      ? null
                                      : ChatRuntimeRegistry.instance.lookup(
                                          activeChatId!,
                                        );
                                  // Wrap the last AI bubble in the live notifier
                                  // for the whole turn (isSending), not just
                                  // while a stream is mid-flight: isStreaming
                                  // briefly flips false between tool-loop passes,
                                  // and we must not lose the live wrapper (and
                                  // its per-token updates) during that gap.
                                  final bool wrapForStream =
                                      runtime != null &&
                                      isAiMessage &&
                                      i == messages.length - 1 &&
                                      (isStreamingMessage ||
                                          runtime.isSending.value);
                                  if (wrapForStream) {
                                    return withDay(
                                      RepaintBoundary(
                                        child:
                                            ValueListenableBuilder<
                                              StreamingLive?
                                            >(
                                              valueListenable:
                                                  runtime.streamingLive,
                                              builder: (context, live, _) {
                                                final bool match =
                                                    live != null &&
                                                    live.index == i;
                                                final String msgText = match
                                                    ? live.text.trimRight()
                                                    : displayText;
                                                final String reasoningRaw =
                                                    match
                                                    ? live.reasoning
                                                    : reasoning;
                                                final String? msgReasoning =
                                                    reasoningRaw.trim().isEmpty
                                                    ? null
                                                    : reasoningRaw;
                                                return buildBubble(
                                                  msgText,
                                                  msgReasoning,
                                                );
                                              },
                                            ),
                                      ),
                                    );
                                  }
                                  final String uiKey =
                                      ChatUiHelpers.stableUiKey(
                                        messages[i],
                                        uuid,
                                      );
                                  if (isUser && uiKey == flyInKey) {
                                    return withDay(
                                      RepaintBoundary(
                                        child: MessageFlyIn(
                                          key: ValueKey('flyin_$uiKey'),
                                          child: buildBubble(
                                            displayText,
                                            reasoningText,
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  return withDay(
                                    RepaintBoundary(
                                      child: buildBubble(
                                        displayText,
                                        reasoningText,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        )
                      : SizedBox.expand(
                          child: Align(
                            alignment: const Alignment(0.0, -0.3),
                            // The alpha lives in the tint colour instead of
                            // an Opacity widget: Opacity pushes an offscreen
                            // save layer on every paint, and cacheWidth stops
                            // a 512 px asset being rescaled to 180 each time.
                            // On an empty chat this watermark is the only
                            // thing on screen while the keyboard animates.
                            child: RepaintBoundary(
                              child: Image.asset(
                                'web/icons/Icon-512.png',
                                width: 180,
                                height: 180,
                                cacheWidth: 360,
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.08,
                                ),
                              ),
                            ),
                          ),
                        ),
                  // Scroll-to-bottom button (centered above input)
                  if (showScrollToBottom && hasMessages)
                    Positioned(
                      bottom: composerReservedSpace + 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Material(
                          elevation: 4,
                          shape: const CircleBorder(),
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => scrollChatToBottom(force: true),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: AppIcon(
                                Icons.keyboard_arrow_down,
                                size: 24,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: effectiveHorizontalPadding,
                    right: effectiveHorizontalPadding,
                    bottom: effectiveHorizontalPadding,
                    // SafeArea OUTSIDE MeasureSize: opening the keyboard drives
                    // MediaQuery.padding.bottom to 0, so with SafeArea inside
                    // the measured height changed on every keyboard-animation
                    // frame, and each change ran setState over the whole chat
                    // screen. That is what made the composer lag behind the
                    // keyboard instead of rising with it.
                    child: SafeArea(
                      top: false,
                      child: MeasureSize(
                        onChange: onComposerHeightChanged,
                        child: Center(
                          child: SizedBox(
                            width: expandedInputWidth,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildSearchBar(
                                  isCompactMode: isCompactModeForModelDropdown,
                                  theme: theme,
                                  iconFg: iconFg,
                                ),
                                // The disclaimer is for the reader who is
                                // looking at the thread, not for the one who is
                                // typing: with the keyboard up it eats a line
                                // of the little room that is left. It goes with
                                // the keyboard and comes back with it.
                                //
                                // Focus, not viewInsets: the hosting Scaffold
                                // strips viewInsets from this subtree (see the
                                // Scaffold below), so the inset here is always
                                // zero and cannot say whether the keyboard is
                                // up.
                                AnimatedSize(
                                  duration: kExpressiveShort,
                                  curve: kExpressiveDecelerate,
                                  alignment: Alignment.topCenter,
                                  child: composerFocusNode.hasFocus
                                      ? const SizedBox(
                                          width: double.infinity,
                                          height: 0,
                                        )
                                      : Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                          ),
                                          child: Text(
                                            AppLocalizations.of(
                                              context,
                                            )!.aiDisclaimer,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: iconFg.withValues(
                                                alpha: 0.7,
                                              ),
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Loading indicator when switching chats
          if (isLoadingChat)
            Positioned.fill(
              child: Container(
                color: bg.withValues(alpha: 0.7),
                child: Center(
                  child: CircularProgressIndicator(
                    color: accent,
                    strokeWidth: 3,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The composer's mode control: Fast or Thinking.
  ///
  /// The model list is one level deeper, inside the mode sheet. A reader
  /// who has never heard of DeepSeek should not have to choose between
  /// twenty model names before they can ask a question — and the merged
  /// `[bulb | #model]` pill it replaces showed a bare `#` on a narrow
  /// screen, which told them nothing at all.
  // NOTE: this is the pre-aef13a5 composer, restored deliberately.
  //
  // The 'one tall desktop-style box' redesign made the composer's height
  // content-driven, which put it back into the MeasureSize -> setState ->
  // full-screen rebuild loop on every keyboard frame (SafeArea sits inside
  // MeasureSize, so the keyboard's inset change re-measures it). That is why
  // it stopped rising instantly. It also deleted the AnimatedSize around the
  // left pill, which is the animation that felt broken afterwards.
  //
  // The merged model/reasoning pill (buildModelControl) is kept — only the
  // layout is reverted.
  /// The composer: one rounded box, two rows.
  ///
  /// Row one is the text, row two the actions — the same shape the desktop
  /// composer has, so the two platforms stop looking like different apps.
  /// The mode control shows only its icon here; the words live in its menu,
  /// where there is room for them.
  ///
  /// Height is driven by the number of text lines and nothing else. An
  /// earlier version of this box measured itself through SafeArea, so every
  /// keyboard-animation frame re-measured and rebuilt the whole screen and
  /// the composer lagged behind the keyboard. SafeArea stays outside the
  /// MeasureSize at the call site — do not move it back in.
  Widget _buildSearchBar({
    required bool isCompactMode,
    required ThemeData theme,
    required Color iconFg,
  }) {
    final Color bg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final bool hasAttachments = fileHandler.hasAttachments;
    final bool isWorking = isCurrentChatStreaming || isSendingMessage;
    final bool hasTypedText = composerController.text.trim().isNotEmpty;
    final bool hasText = hasTypedText || hasAttachments;
    final bool isRecording = audioHandler.isMicActive;
    // The primary target is the send target, always. Working is said by the
    // dots above the field, never by turning this into a red stop.
    final ComposerAction sendAction = composerActionFor(
      isRecording: isRecording,
      isWorking: isWorking,
      hasText: hasText,
      voiceModeEnabled: kFeatureVoiceMode,
    );

    final Color borderColor = isRecording
        ? Colors.red.withValues(alpha: 0.4)
        : iconFg.withValues(alpha: 0.25);

    return Container(
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: borderColor, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasAttachments)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 6),
              child: AttachmentPreviewBar(
                files: fileHandler.attachedFiles,
                onRemove: removeComposerAttachment,
              ),
            ),
          if (messageActionsHandler.isEditing)
            ChatEditNotice(onCancel: cancelEditMessage),
          if (replyDrafts[replyChatKey] case final reply?)
            ChatReplyPreview(
              reply: reply,
              onCancel: () =>
                  setState(() => replyDrafts.remove(replyChatKey)),
            ),
          // No working indicator here. The thread already says it twice — the
          // coworker's own typing line in the transcript and the header — and a
          // third copy in the composer was noise, not news.
          if (pendingMessages.isNotEmpty)
            _buildComposerNotice(
              theme: theme,
              icon: Icons.schedule,
              label: pendingMessages.length == 1
                  ? '${AppLocalizations.of(context)!.queuedLabel}: '
                        '"${pendingMessages.next!}"'
                  : AppLocalizations.of(
                      context,
                    )!.queuedMessagesCount('${pendingMessages.length}'),
              actionLabel: AppLocalizations.of(context)!.cancel,
              onAction: cancelPendingMessages,
            ),

          // ── Row one: what you are saying ──
          //
          // The waveform is drawn over the text field, not above it: the field
          // keeps its place in the layout, so the composer is exactly as tall
          // while recording as it is at rest and the thread does not jump.
          ComposerInputRow(
            isRecording: isRecording,
            audioLevels: audioHandler.audioLevels,
            accentColor: Colors.red,
            timeColor: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            child: buildKeyboardListener(
              focusNode: _rawKeyboardListenerFocusNode,
              controller: composerController,
              onSend: sendOrSubmitEdit,
              child: KeyedSubtree(
                key: TourKeyRegistry.instance.keyFor(TourSlots.chatInput),
                // Hidden composer scrollbar (reads as clutter); the field grows
                // to ~8 lines before it scrolls.
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: Semantics(
                    identifier: 'message_input',
                    child: TextField(
                      controller: composerController,
                      focusNode: composerFocusNode,
                      autofocus: false,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      scrollController: _composerScrollController,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 15,
                        height: 1.35,
                      ),
                      minLines: 1,
                      maxLines: 8,
                      decoration: InputDecoration(
                        hintText: messageActionsHandler.isEditing
                            ? AppLocalizations.of(context)!.editYourMessage
                            : AppLocalizations.of(context)!.askMeAnything,
                        hintStyle: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.5,
                          ),
                          fontSize: 15,
                        ),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.only(
                          left: 8,
                          top: 6,
                          bottom: 6,
                          right: 6,
                        ),
                        isDense: true,
                        suffixIcon: _showFullscreenButton
                            ? GestureDetector(
                                onTap: _openFullscreenEditor,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: AppIcon(
                                    Icons.open_in_full_rounded,
                                    size: 14,
                                    color: iconFg.withValues(alpha: 0.4),
                                  ),
                                ),
                              )
                            : null,
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                      ),
                      cursorColor: accent,
                      cursorWidth: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 4),

          // ── Row two: what you can do about it ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Rebuilds when model capabilities load, so the attach menu
              // reflects image support live on cold start without a second tap.
              ValueListenableBuilder<int>(
                valueListenable: ModelCapabilitiesService.revision,
                builder: (context, _, _) => Builder(
                  builder: (anchorContext) => buildTinyIconButton(
                    icon: Icons.add_rounded,
                    iconSize: 22,
                    buttonSize: ComposerMetrics.targetSize,
                    // Round, so the tap ink is a circle and not a square
                    // patch behind a round icon.
                    cornerRadius: ComposerMetrics.targetSize / 2,
                    onTap: () => handleAddAttachmentTap(anchorContext),
                    isActive: hasAttachments,
                    color: iconFg,
                  ),
                ),
              ),
              const SizedBox(width: ComposerMetrics.targetGap),
              buildModelControl(isCompactMode: isCompactMode, iconFg: iconFg),
              if (kFeatureWorkspaces && selectedWorkspaceId != null) ...[
                const SizedBox(width: ComposerMetrics.targetGap),
                Flexible(child: buildWorkspaceChip(iconFg)),
              ],
              const Spacer(),
              if (isRecording) ...[
                buildTinyIconButton(
                  icon: Icons.stop_rounded,
                  iconSize: 20,
                  buttonSize: ComposerMetrics.targetSize,
                  cornerRadius: ComposerMetrics.targetSize / 2,
                  onTap: handleMicTap,
                  isActive: true,
                  color: Colors.red,
                  semanticsId: 'mic_button',
                ),
                const SizedBox(width: ComposerMetrics.targetGap),
              ] else if (!hasTypedText) ...[
                buildTinyIconButton(
                  icon: Icons.mic,
                  iconSize: 20,
                  buttonSize: ComposerMetrics.targetSize,
                  cornerRadius: ComposerMetrics.targetSize / 2,
                  onTap: handleMicTap,
                  isActive: false,
                  color: iconFg,
                  semanticsId: 'mic_button',
                ),
                const SizedBox(width: ComposerMetrics.targetGap),
              ],
              buildTinyActionButton(
                icon: sendAction == ComposerAction.voiceMode
                    ? Icons.graphic_eq_rounded
                    : Icons.north_rounded,
                buttonSize: ComposerMetrics.targetSize,
                iconSize: 18,
                onTap: switch (sendAction) {
                  ComposerAction.sendAudio => handleAudioSend,
                  ComposerAction.voiceMode => () => _openComingSoonFeature(
                    'Voice Mode',
                  ),
                  ComposerAction.send => sendOrSubmitEdit,
                },
                color: accent,
                isLoading: audioHandler.isTranscribingAudio,
                semanticsId: 'send_button',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A one-line notice inside the composer: what is queued, or that the
  /// coworker is working. [leading] replaces the icon where a live indicator
  /// says it better; a notice without an action has no button.
  Widget _buildComposerNotice({
    required ThemeData theme,
    required String label,
    IconData? icon,
    Widget? leading,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    assert(icon != null || leading != null, 'a notice needs a leading mark');
    final Color color = theme.colorScheme.primary.withValues(alpha: 0.75);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4, right: 6),
      child: Row(
        children: [
          leading ?? AppIcon(icon!, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onAction,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  actionLabel,
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

