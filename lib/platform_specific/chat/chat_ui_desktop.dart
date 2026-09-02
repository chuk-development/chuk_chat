// lib/platform_specific/chat/chat_ui_desktop.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:math' as math; // For min/max
import 'dart:async';
import 'dart:convert';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/services/mcp/mcp_availability.dart';
import 'package:chuk_chat/services/chat_runtime.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/artifact_tag_processor.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/widgets/message_bubble.dart'
    show MessageBubble, MessageBubbleAction, DocumentAttachment;
import 'package:chuk_chat/widgets/measure_size.dart';
import 'package:chuk_chat/widgets/message_fly_in.dart';
import 'package:chuk_chat/widgets/selection_copy_area.dart';
import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/tool_image_result_service.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/widgets/workspace_panel.dart';
import 'package:chuk_chat/utils/shift_key_tracker.dart';
import 'package:chuk_chat/widgets/workspace_selection_dropdown.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/artifact_context_service.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/services/round_content_block_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:uuid/uuid.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/audio_recording_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:chuk_chat/utils/desktop_drop_stub.dart'
    if (dart.library.io) 'package:desktop_drop/desktop_drop.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/desktop_clipboard_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/desktop_file_handler.dart';

part 'desktop_send_logic.dart';

class ChukChatUIDesktop extends StatefulWidget {
  // RENAMED CLASS
  final VoidCallback onToggleSidebar;
  final String? selectedChatId;
  final Function(String?) onChatIdChanged;
  final bool isSidebarExpanded;
  final bool isCompactMode;
  final bool showReasoningTokens;
  final bool showModelInfo;
  final bool showTps;
  final String? workspaceId;
  final VoidCallback? onExitProject;
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
  final bool allowMarkdownToolCalls;
  // Voice transcription settings
  final bool autoSendVoiceTranscription;

  /// Opens the model section of the new settings modal. When set, the
  /// composer's "More models" uses it instead of pushing the standalone model
  /// screen, so both paths land in the same redesigned settings surface.
  final Future<void> Function()? onOpenModelSettings;

  const ChukChatUIDesktop({
    // RENAMED CONSTRUCTOR
    super.key,
    required this.onToggleSidebar,
    required this.selectedChatId,
    required this.onChatIdChanged,
    required this.isSidebarExpanded,
    required this.isCompactMode,
    required this.showReasoningTokens,
    required this.showModelInfo,
    required this.showTps,
    this.workspaceId,
    this.onExitProject,
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
    this.allowMarkdownToolCalls = true,
    this.autoSendVoiceTranscription = false,
    this.onOpenModelSettings,
  });

  @override
  State<ChukChatUIDesktop> createState() => ChukChatUIDesktopState(); // RENAMED STATE
}

class ChukChatUIDesktopState extends State<ChukChatUIDesktop>
    with
        SingleTickerProviderStateMixin,
        ChatScrollMixin,
        ModelProviderResolutionMixin {
  // RENAMED STATE
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  String? _activeChatId;
  final ScrollController _composerScrollController = ScrollController();
  late ChatApiService _chatApiService;
  late final FocusNode _textFieldFocusNode;
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();

  /// Focus of the message-list selection region. Held here so a pointer down on
  /// the message list can hand the focus to the selection instead of leaving it
  /// on the composer.
  final FocusNode _messageSelectionFocusNode = FocusNode(
    debugLabel: 'chat-message-selection',
  );

  late AnimationController _animCtrl;
  String _selectedModelId = ''; // Will be loaded from user preferences
  String? _selectedProviderSlug;

  /// UI key of the message that was just sent, so its list item plays the
  /// fly-up entrance once. Transient, never persisted.
  String? _flyInKey;

  // Bridge the private fields above to ModelProviderResolutionMixin.
  @override
  String get selectedModelId => _selectedModelId;
  @override
  String? get selectedProviderSlug => _selectedProviderSlug;
  @override
  set selectedProviderSlug(String? value) => _selectedProviderSlug = value;

  ChatMode _chatMode = ChatModeService.fallbackMode;

  /// The active mode's reasoning level (`none` … `xhigh`, `none` = off).
  /// Loaded from the mode's config; each mode remembers its own.
  String _reasoningEffort =
      ChatModeService.defaultConfig(ChatModeService.fallbackMode).reasoningEffort;

  /// Human name of the selected model, for the mode menu. Null until the
  /// model list has been cached — the menu then shows the raw id.
  String? _selectedModelName;

  /// Models the reader picked on the model screen, shown one level deeper.
  List<ChatModelChoice> _pickedModels = const <ChatModelChoice>[];

  /// Human name of the model Custom last ran, remembered across mode switches
  /// so the third point in the mode menu names it even under Fast or Thinking.
  /// Null until Custom has been used at least once.
  String? _customModelName;
  String? _systemPrompt;
  String? _selectedWorkspaceId;
  late final VoidCallback _modelSelectionListener;

  late final AudioRecordingHandler _audioHandler;
  late final MessageActionsHandler _messageActionsHandler;
  late final ChatPersistenceHandler _persistenceHandler;

  /// Per-chat send-in-flight flag, backed by the ChatRuntime for the
  /// currently visible chat. See chat_ui_mobile.dart for rationale.
  /// Required for multi-chat parallel sends.
  bool get _isSending {
    final cid = _activeChatId;
    if (cid == null) return false;
    return ChatRuntimeRegistry.instance.lookup(cid)?.isSending.value ?? false;
  }

  set _isSending(bool value) {
    final cid = _activeChatId;
    if (cid == null) return;
    ChatRuntimeRegistry.instance.get(cid).isSending.value = value;
  }

  int _sendOperationCounter = 0;
  int? _activeSendOperationId;
  int? _cancelledSendOperationId;

  /// Queued message text — when the user sends while AI is still streaming,
  /// the text is parked here and dispatched after the current response ends.
  String? _pendingMessageText;

  /// When a new chat is started from a workspace, this holds the assistant ID
  /// until the chat is created and linked in the database.
  String? _pendingWorkspaceId;

  bool _isLoadingChat = false; // Loading indicator for chat switching
  StreamSubscription<void>? _providerRefreshSubscription;
  final StreamingManager _streamingManager = StreamingManager();
  final ToolCallHandler _toolCallHandler = ToolCallHandler();

  // Computed property - checks if CURRENT chat is streaming
  bool get _isStreaming =>
      _activeChatId != null && _streamingManager.isStreaming(_activeChatId!);
  Timer? _autoSaveTimer;
  Timer? _audioVisualizerTimer;

  late final DesktopFileHandler _fileHandler;

  /// IDs of attachments restored into the composer when an edit started. These
  /// belong to the saved message, so removing them must NOT delete from storage
  /// (the original survives if the edit is cancelled); attachments uploaded
  /// fresh during the edit are not in this set and ARE deleted on removal.
  final Set<String> _restoredAttachmentIds = <String>{};
  final Uuid _uuid = Uuid();
  late final DesktopClipboardHandler _clipboardHandler;
  bool get _isLinuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  final Map<String, List<String>?> _decodedImagesCache =
      <String, List<String>?>{};
  final Map<String, List<DocumentAttachment>?> _decodedAttachmentsCache =
      <String, List<DocumentAttachment>?>{};
  final Map<String, List<ToolCall>?> _decodedToolCallsCache =
      <String, List<ToolCall>?>{};
  final Map<String, List<ContentBlock>?> _decodedContentBlocksCache =
      <String, List<ContentBlock>?>{};

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kSearchBarContentHeight = 135.0;
  static const double _kAttachmentBarHeight = 40.0;
  static const double _kAttachmentBarMarginBottom =
      8.0; // Margin between attachment bar and search bar
  static const double _kQueuedBannerHeight =
      26.0; // Queued-message banner row height (icon + text + bottom padding)
  static const double _kHorizontalPaddingLarge = 16.0;
  static const double _kHorizontalPaddingSmall = 8.0;
  static const double _kMessageListBottomLift = 40.0;

  Widget _buildComposerContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) => _clipboardHandler.buildComposerContextMenu(context, editableTextState);

  Widget _buildMessageContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) =>
      _clipboardHandler.buildMessageContextMenu(context, selectableRegionState);

  @override
  void initState() {
    super.initState();
    initShiftKeyTracker();
    // Mode + its config (model, provider, reasoning) restore once, via
    // _loadSavedModelPreference in the post-frame pass below — the single
    // entry point, so startup writes and picked-model refreshes run once.
    _audioHandler = AudioRecordingHandler();
    _messageActionsHandler = MessageActionsHandler()
      ..onShowSnackBar = _showSnackBar
      ..onSubmitEdit = (index, newText) {
        unawaited(
          _submitEditedMessage(
            index,
            newText,
            removeFollowingAssistant: false,
            clearMessagesBelow: true,
          ),
        );
      }
      ..onResend = _resendMessageAt;
    _persistenceHandler = ChatPersistenceHandler()
      ..onShowSnackBar = _showSnackBar
      ..onChatIdAssigned = (chatId) {
        if (mounted && _activeChatId != chatId) {
          setState(() {
            _activeChatId = chatId;
          });
          widget.onChatIdChanged(chatId);
          unawaited(MultiplexSession.openForChat(chatId).catchError((e) {
            if (kDebugMode) {
              debugPrint('⚠️ MultiplexSession.openForChat failed: $e');
            }
          }));
        }
      };
    _textFieldFocusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        // Note: Cmd+V / Ctrl+V is NOT intercepted here. It's handled via an
        // `Actions` override of `PasteTextIntent` wrapped around the TextField
        // below. That routes through Flutter's normal text-input pipeline, so
        // external text-insertion tools (macOS dictation, WhisperFlow, etc.)
        // keep working whether they simulate Cmd+V or use NSTextInputClient
        // directly.

        // Escape: cancel editing mode
        if (event.logicalKey == LogicalKeyboardKey.escape &&
            _messageActionsHandler.isEditing) {
          _cancelEditMessage();
          return KeyEventResult.handled;
        }

        if (event.logicalKey != LogicalKeyboardKey.enter) {
          return KeyEventResult.ignored;
        }

        // Shift+Enter: insert newline manually
        if (isShiftKeyPressed) {
          final text = _controller.text;
          final sel = _controller.selection;
          final newText = text.replaceRange(sel.start, sel.end, '\n');
          _controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: sel.start + 1),
          );
          return KeyEventResult.handled;
        }

        // Bare Enter: send message (or submit edit), consume to prevent newline.
        // Route through _sendOrSubmitEdit so an edit keeps its (possibly
        // modified) attachment set instead of dropping the user's changes.
        unawaited(_sendOrSubmitEdit());
        return KeyEventResult.handled;
      },
    );
    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fileHandler = DesktopFileHandler()
      ..onShowSnackBar = _showSnackBar
      ..onUpdate = () {
        if (mounted) setState(() {});
      }
      ..onScrollToBottom = () => scrollChatToBottom(force: true);
    _chatApiService = ChatApiService(
      onUploadStatusUpdate: _fileHandler.handleFileUploadUpdate,
    );
    _fileHandler.initialize(_chatApiService);
    _clipboardHandler = DesktopClipboardHandler(
      onProcessFilePaths: _fileHandler.processFilePaths,
    );
    scrollController.addListener(onScrollChanged);
    _selectedWorkspaceId = widget.workspaceId;
    _loadChatById(widget.selectedChatId);
    unawaited(_clipboardHandler.cleanupOldPasteTempDirectories());

    // Defer network-dependent loading to after first frame for faster startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      unawaited(
        Future<void>.delayed(Duration.zero, () async {
          if (!mounted) return;
          await _loadSavedModelPreference();
        }),
      );
      unawaited(
        Future<void>.delayed(Duration.zero, () async {
          if (!mounted) return;
          await _loadSystemPrompt();
        }),
      );
    });

    _modelSelectionListener = () {
      final String newModelId =
          ModelSelectionDropdown.selectedModelNotifier.value;
      if (newModelId != _selectedModelId) {
        setState(() {
          _selectedModelId = newModelId;
        });
      }
      unawaited(_refreshSelectedModelName(newModelId));
      unawaited(loadProviderSlugForModel(newModelId));
    };
    ModelSelectionDropdown.selectedModelListenable.addListener(
      _modelSelectionListener,
    );

    // Listen for provider changes from model selector page
    _providerRefreshSubscription = ModelSelectionEventBus().refreshStream
        .listen((_) {
          // Reload provider slug when settings are changed —
          // skip dropdown cache (may be stale) and read from prefs directly
          unawaited(loadProviderSlugForModel(_selectedModelId, forceFromPrefs: true));
        });
  }

  @override
  void didUpdateWidget(covariant ChukChatUIDesktop oldWidget) {
    // RENAMED WIDGET TYPE
    super.didUpdateWidget(oldWidget);

    // Sync workspace ID from parent if it changes
    if (widget.workspaceId != oldWidget.workspaceId) {
      setState(() {
        _selectedWorkspaceId = widget.workspaceId;
      });
    }

    // ID-BASED: Only react when the actual chat ID changes
    if (widget.selectedChatId != oldWidget.selectedChatId) {
      if (kDebugMode) {
        debugPrint('');
      }
      if (kDebugMode) {
        debugPrint(
          '┌─────────────────────────────────────────────────────────────',
        );
      }
      if (kDebugMode) {
        debugPrint('│ 🔄 [CHAT-UI-DESKTOP] didUpdateWidget triggered');
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-DESKTOP] OLD widget.selectedChatId: ${oldWidget.selectedChatId}',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-DESKTOP] NEW widget.selectedChatId: ${widget.selectedChatId}',
        );
      }
      if (kDebugMode) {
        debugPrint('│ 🔄 [CHAT-UI-DESKTOP] _activeChatId: $_activeChatId');
      }
      if (kDebugMode) {
        debugPrint(
          '└─────────────────────────────────────────────────────────────',
        );
      }

      // Skip if we're already on this chat
      if (widget.selectedChatId == _activeChatId) {
        if (kDebugMode) {
          debugPrint('⚠️ [CHAT-UI-DESKTOP] SKIP - already on this chat');
        }
        return;
      }

      // CRITICAL FIX: Don't clear an active chat just because parent sent null
      // This can happen due to stale parent rebuilds. If we have an active chat
      // with messages, keep it instead of switching to a blank "new" chat.
      if (widget.selectedChatId == null &&
          _activeChatId != null &&
          _messages.isNotEmpty) {
        if (kDebugMode) {
          debugPrint(
            '⚠️ [CHAT-UI-DESKTOP] IGNORING null from parent - we have active chat: $_activeChatId',
          );
        }
        // Sync the parent back to our active chat after this build pass.
        final activeChatId = _activeChatId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (activeChatId == null) return;
          widget.onChatIdChanged(activeChatId);
        });
        return;
      }

      // CRITICAL: NO persist during chat switch!
      // Persisting here causes data corruption because _messages may already contain
      // the NEW chat's content by the time didUpdateWidget fires (due to async timing).
      // Instead, we rely on:
      // 1. Immediate persist after message send/receive (via _persistenceHandler)
      // 2. Auto-save timer
      // 3. Persist in newChat() before clearing
      // 4. Chats are already saved to Supabase during message operations
      if (kDebugMode) {
        debugPrint(
          '│ 📝 [CHAT-UI-DESKTOP] Chat switch - NOT persisting (already saved on message ops)',
        );
      }

      _loadChatById(widget.selectedChatId);
      // Trigger rebuild to reflect new chat's streaming status
      // _isStreaming getter will automatically check the new _activeChatId
      setState(() {});
    }
  }

  @override
  void dispose() {
    // CRITICAL: Clear loading lock if we're disposed while loading
    // This prevents the flag from getting stuck
    if (_isLoadingChat) {
      ChatStorageService.isLoadingChat = false;
    }
    if (_activeChatId != null) {
      MultiplexSession.closeForChat(_activeChatId!);
    }
    // Don't cancel streams - they continue in background
    // _streamingManager handles all streams globally
    _autoSaveTimer?.cancel();
    _audioVisualizerTimer?.cancel();
    _audioHandler.onLevelsChanged = null;
    _providerRefreshSubscription?.cancel();
    scrollController.removeListener(onScrollChanged);
    _controller.dispose();
    scrollController.dispose();
    _composerScrollController.dispose();
    _textFieldFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    _messageSelectionFocusNode.dispose();
    _animCtrl.dispose();
    unawaited(_audioHandler.dispose());
    _persistenceHandler.dispose();
    ModelSelectionDropdown.selectedModelListenable.removeListener(
      _modelSelectionListener,
    );
    super.dispose();
  }

  void _loadChatById(String? chatId) {
    _pendingWorkspaceId = null;
    if (kDebugMode) {
      debugPrint('');
    }
    if (kDebugMode) {
      debugPrint(
        '┌─────────────────────────────────────────────────────────────',
      );
    }
    if (kDebugMode) {
      debugPrint('│ 📂 [LOAD-CHAT-DESKTOP] _loadChatById called');
    }
    if (kDebugMode) {
      debugPrint('│ 📂 [LOAD-CHAT-DESKTOP] chatId param: $chatId');
    }
    if (kDebugMode) {
      debugPrint(
        '│ 📂 [LOAD-CHAT-DESKTOP] Current _activeChatId: $_activeChatId',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '└─────────────────────────────────────────────────────────────',
      );
    }

    // BACKGROUND STREAMING: If current chat is streaming, snapshot messages
    // to StreamingManager before switching away. This allows the stream to
    // continue in background and persist correctly when complete.
    if (_activeChatId != null &&
        _streamingManager.isStreaming(_activeChatId!)) {
      final messagesCopy = _messages
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      _streamingManager.setBackgroundMessages(
        _activeChatId!,
        messagesCopy,
        modelId: _selectedModelId,
        provider: _selectedProviderSlug,
      );
      if (kDebugMode) {
        debugPrint(
          '│ 📦 [LOAD-CHAT-DESKTOP] Snapshotted ${messagesCopy.length} messages for background stream: $_activeChatId',
        );
      }
    }

    // CRITICAL: Update _activeChatId SYNCHRONOUSLY before any async work
    // This ensures didUpdateWidget always sees the correct value when comparing
    // chatIdToSave with _activeChatId for persist logic
    _activeChatId = chatId;
    if (chatId != null) {
      unawaited(MultiplexSession.openForChat(chatId).catchError((e) {
        if (kDebugMode) {
          debugPrint('⚠️ MultiplexSession.openForChat failed: $e');
        }
      }));
    }

    _clearMessageDecodeCaches();

    // Synchronous fast path: if the requested chat is already fully cached,
    // populate inline without entering async / showing the spinner. This
    // eliminates the one-frame loading flash when switching between cached
    // chats. We still toggle the global isLoadingChat flag so sidebar
    // rate-limiting sees the transition, but the false-flip happens
    // synchronously inside _applyLoadedChat.
    if (chatId != null) {
      final StoredChat? cached = ChatStorageService.getChatById(chatId);
      if (cached != null && cached.isFullyLoaded) {
        if (kDebugMode) {
          debugPrint(
            '│ ⚡ [LOAD-CHAT-DESKTOP] Sync fast path for $chatId (${cached.messages.length} msgs)',
          );
        }
        ChatStorageService.isLoadingChat = true;
        _applyLoadedChat(cached, chatId);
        return;
      }
    }

    // CRITICAL: Set global loading lock to prevent rapid chat switching
    // Sidebar checks this flag before allowing chat selection
    ChatStorageService.isLoadingChat = true;

    // Show loading indicator immediately
    setState(() {
      _isLoadingChat = true;
    });

    // Use async function to handle lazy loading
    _loadChatByIdAsync(chatId);
  }

  /// Apply a fully-loaded [StoredChat] to UI state synchronously. Rebuilds
  /// `_messages`, runs stale-tool-call recovery, splices in any buffered
  /// streaming content, and flips both the local and global loading flags
  /// off in a single `setState`.
  ///
  /// Assumes `_activeChatId` has already been set to [chatId] by the caller
  /// and `MultiplexSession.openForChat` has been triggered.
  void _applyLoadedChat(StoredChat storedChat, String chatId) {
    if (!mounted) return;

    // Build the new message list synchronously. We deliberately do not yield
    // mid-loop here (unlike the async _populateMessagesFromStoredChat path)
    // because this fast path is only reached when the chat is already
    // resident in cache — mapping is cheap and a sync apply avoids the
    // loading flash.
    final List<Map<String, String>> mappedMessages = storedChat.messages
        .map(_messageToRawMap)
        .toList();

    // Stale-tool-call recovery (skip while a stream is in flight or just
    // completed — the streaming flow handles its own finalization).
    var recoveredStaleCalls = false;
    if (!_streamingManager.isStreaming(chatId) &&
        !_streamingManager.hasCompletedStream(chatId)) {
      for (final message in mappedMessages) {
        if (ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message)) {
          recoveredStaleCalls = true;
        }
      }
    }

    // Splice buffered streaming content (if any) into the freshly-built list
    // before it lands in _messages.
    final bool desktopChatIsStreaming = _streamingManager.isStreaming(chatId);
    final bool desktopChatHasCompleted = _streamingManager.hasCompletedStream(
      chatId,
    );
    if (desktopChatIsStreaming || desktopChatHasCompleted) {
      // Prefer the background snapshot — captured at stream start with the
      // placeholder appended and live buffer overlaid. Cache copy can be
      // missing the placeholder if user switched within the snapshot-flush
      // window. Falls back to in-place splice when no snapshot exists.
      final bgMessages = _streamingManager.getBackgroundMessages(chatId);
      if (bgMessages != null && bgMessages.isNotEmpty) {
        mappedMessages
          ..clear()
          ..addAll(
            bgMessages.map((m) {
              final converted = <String, String>{};
              m.forEach((key, value) {
                if (value == null) return;
                converted[key] = value is String ? value : value.toString();
              });
              return converted;
            }),
          );
        if (desktopChatHasCompleted) {
          _streamingManager.consumeCompletedStream(chatId);
        }
      } else {
        final bufferedContent = _streamingManager.getBufferedContent(chatId);
        final bufferedReasoning = _streamingManager.getBufferedReasoning(
          chatId,
        );
        final streamingIndex = _streamingManager.getStreamingMessageIndex(
          chatId,
        );

        if (streamingIndex != null && streamingIndex < mappedMessages.length) {
          mappedMessages[streamingIndex]['text'] =
              bufferedContent ?? 'Thinking...';
          mappedMessages[streamingIndex]['reasoning'] = bufferedReasoning ?? '';
          if (desktopChatHasCompleted) {
            _streamingManager.consumeCompletedStream(chatId);
          }
        }
      }
    }

    // Clear global loading lock — chat is fully ready.
    ChatStorageService.isLoadingChat = false;

    // Stop any active recording when switching chats.
    if (_audioHandler.isMicActive) {
      unawaited(_audioHandler.stopRecording());
    }

    setState(() {
      _messages
        ..clear()
        ..addAll(mappedMessages);
      _isLoadingChat = false;
      _isSending = _isStreaming; // Reset sending state based on current chat
      showScrollToBottom = false;
    });

    // Instant visibility — no fade-in for cached chats.
    _animCtrl.value = 1.0;

    if (recoveredStaleCalls) {
      _persistChatWithId(chatId);
    }

    scrollChatToBottom(animate: false, force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
  }

  Future<void> _loadChatByIdAsync(String? chatId) async {
    if (!mounted) return;
    final stopwatch = Stopwatch()..start();
    var lazyLoaded = false;
    var lazyLoadMs = 0;
    var mapMs = 0;

    // CRITICAL: Check for stale load - if user switched to another chat
    // while waiting, abort this load
    if (_activeChatId != chatId) {
      if (kDebugMode) {
        debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Stale load detected, aborting');
      }
      if (kDebugMode) {
        debugPrint(
          '│ ⚠️ [LOAD-CHAT-DESKTOP] Expected: $chatId, Current: $_activeChatId',
        );
      }
      return;
    }

    if (chatId == null) {
      // New chat - clear everything
      if (kDebugMode) {
        debugPrint(
          '│ 📂 [LOAD-CHAT-DESKTOP] chatId is NULL - clearing for new chat',
        );
      }
      _messages.clear();
      _animCtrl.reset();
      _fileHandler.attachedFiles.clear();
      _messageActionsHandler.cancelEdit();
    } else {
      // Find chat by ID
      StoredChat? storedChat = ChatStorageService.getChatById(chatId);

      if (storedChat != null) {
        // LAZY LOADING: Check if chat is fully loaded
        if (!storedChat.isFullyLoaded) {
          if (kDebugMode) {
            debugPrint(
              '│ 📂 [LOAD-CHAT-DESKTOP] Chat $chatId not fully loaded, fetching...',
            );
          }
          final lazyStopwatch = Stopwatch()..start();
          storedChat = await ChatStorageService.loadFullChat(chatId);
          lazyStopwatch.stop();
          lazyLoadMs = lazyStopwatch.elapsedMilliseconds;
          lazyLoaded = true;

          // Check for stale load again after async operation
          if (!mounted || _activeChatId != chatId) {
            if (kDebugMode) {
              debugPrint(
                '│ ⚠️ [LOAD-CHAT-DESKTOP] Stale after lazy load, aborting',
              );
            }
            return;
          }
        }

        if (storedChat != null && storedChat.isFullyLoaded) {
          if (kDebugMode) {
            debugPrint(
              '│ 📂 [LOAD-CHAT-DESKTOP] FOUND chat $chatId with ${storedChat.messages.length} messages',
            );
          }

          final mapStopwatch = Stopwatch()..start();
          final bool applied = await _populateMessagesFromStoredChat(
            storedChat,
            chatId,
          );
          mapStopwatch.stop();
          mapMs = mapStopwatch.elapsedMilliseconds;
          if (!applied) return;

          final bool shouldRecoverStaleToolCalls =
              !_streamingManager.isStreaming(chatId) &&
              !_streamingManager.hasCompletedStream(chatId);
          if (shouldRecoverStaleToolCalls) {
            var recoveredStaleCalls = false;
            for (final message in _messages) {
              if (ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message)) {
                recoveredStaleCalls = true;
              }
            }
            if (recoveredStaleCalls) {
              _persistChatWithId(chatId);
            }
          }
          // Instant visibility
          _animCtrl.value = 1.0;
        } else {
          // Chat load failed - treat as new chat
          if (kDebugMode) {
            debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Chat $chatId load failed!');
          }
          _messages.clear();
          _animCtrl.reset();
          _fileHandler.attachedFiles.clear();
          _messageActionsHandler.cancelEdit();
          _activeChatId = null;
        }
      } else {
        // Chat not found - treat as new chat
        if (kDebugMode) {
          debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Chat $chatId NOT FOUND!');
        }
        if (kDebugMode) {
          debugPrint(
            '│ ⚠️ [LOAD-CHAT-DESKTOP] Available chats: ${ChatStorageService.savedChats.map((c) => c.id).take(5).toList()}...',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ ⚠️ [LOAD-CHAT-DESKTOP] Treating as new chat, setting _activeChatId = null',
          );
        }
        _messages.clear();
        _animCtrl.reset();
        _fileHandler.attachedFiles.clear();
        _messageActionsHandler.cancelEdit();
        _activeChatId = null;
      }
    }

    if (!mounted) return;

    // If this chat is streaming or has completed stream data, restore buffered content
    final bool desktopChatIsStreaming =
        _activeChatId != null && _streamingManager.isStreaming(_activeChatId!);
    final bool desktopChatHasCompleted =
        _activeChatId != null &&
        _streamingManager.hasCompletedStream(_activeChatId!);

    if (_activeChatId != null &&
        (desktopChatIsStreaming || desktopChatHasCompleted)) {
      // Prefer the background snapshot — see fast-path branch for rationale.
      final bgMessages = _streamingManager.getBackgroundMessages(
        _activeChatId!,
      );
      if (bgMessages != null && bgMessages.isNotEmpty) {
        _messages
          ..clear()
          ..addAll(
            bgMessages.map((m) {
              final converted = <String, String>{};
              m.forEach((key, value) {
                if (value == null) return;
                converted[key] = value is String ? value : value.toString();
              });
              return converted;
            }),
          );
        if (desktopChatHasCompleted) {
          _streamingManager.consumeCompletedStream(_activeChatId!);
        }
      } else {
        final bufferedContent = _streamingManager.getBufferedContent(
          _activeChatId!,
        );
        final bufferedReasoning = _streamingManager.getBufferedReasoning(
          _activeChatId!,
        );
        final streamingIndex = _streamingManager.getStreamingMessageIndex(
          _activeChatId!,
        );

        if (streamingIndex != null && streamingIndex < _messages.length) {
          _messages[streamingIndex]['text'] = bufferedContent ?? 'Thinking...';
          _messages[streamingIndex]['reasoning'] = bufferedReasoning ?? '';
          if (desktopChatHasCompleted) {
            _streamingManager.consumeCompletedStream(_activeChatId!);
          }
        }
      }
    }

    // CRITICAL: Clear global loading lock - chat is now fully loaded
    ChatStorageService.isLoadingChat = false;

    // Stop any active recording when switching chats
    if (_audioHandler.isMicActive) {
      unawaited(_audioHandler.stopRecording());
    }
    setState(() {
      _isLoadingChat = false;
      _isSending = _isStreaming; // Reset sending state based on current chat
      showScrollToBottom = false;
    });
    scrollChatToBottom(animate: false, force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    stopwatch.stop();
    unawaited(
      DiagnosticsLogService.timing(
        'chat_ui',
        'load_chat_ui',
        stopwatch.elapsedMilliseconds,
        data: {
          'messages': _messages.length,
          'lazy_loaded': lazyLoaded,
          'lazy_load_ms': lazyLoadMs,
          'map_ms': mapMs,
        },
      ),
    );
  }

  Future<bool> _populateMessagesFromStoredChat(
    StoredChat storedChat,
    String chatId,
  ) async {
    const int yieldEvery = 40;
    final mappedMessages = <Map<String, String>>[];
    for (int i = 0; i < storedChat.messages.length; i++) {
      if (!mounted || _activeChatId != chatId) {
        return false;
      }
      mappedMessages.add(_messageToRawMap(storedChat.messages[i]));
      if (i > 0 && i % yieldEvery == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (!mounted || _activeChatId != chatId) {
      return false;
    }
    _messages
      ..clear()
      ..addAll(mappedMessages);
    return true;
  }

  Map<String, String> _messageToRawMap(ChatMessage message) =>
      ChatUiHelpers.messageToRawMap(message);

  /// Returns the current messages list for debug export.
  List<Map<String, String>> get debugMessages =>
      _messages.map((m) => Map<String, String>.from(m)).toList();

  /// Current resolved system prompt (workspace or user default). Debug only.
  String? get debugSystemPrompt => _systemPrompt;

  /// Current model id used for outgoing requests. Debug only.
  String get debugModelId => _selectedModelId;

  /// Current provider slug used for outgoing requests. Debug only.
  String? get debugProviderSlug => _selectedProviderSlug;

  /// Current workspace id, if any. Debug only.
  String? get debugWorkspaceId => _selectedWorkspaceId;

  /// Whether reasoning is enabled for the active mode. Debug only.
  bool get debugReasoningEnabled => _reasoningEffort != ChatModeService.reasoningOff;

  /// Effort actually sent with each request — shown in the debug export,
  /// where "true/false" hid which of the two modes was running.
  String get debugReasoningEffort => _reasoningEffort;

  /// Current active chat id. Debug only.
  String? get debugActiveChatId => _activeChatId;

  void newChat() {
    _pendingWorkspaceId = null;
    WorkspaceStorageService.selectedWorkspaceId = null;

    // Capture current chat data for background persistence
    final chatIdToSave = _activeChatId;
    final messagesToSave = _messages.isNotEmpty
        ? _messages.map((m) => Map<String, dynamic>.from(m)).toList()
        : null;

    // BACKGROUND STREAMING: If current chat is streaming, snapshot messages
    // to StreamingManager so the stream can persist correctly when complete.
    if (chatIdToSave != null && _streamingManager.isStreaming(chatIdToSave)) {
      if (messagesToSave != null) {
        _streamingManager.setBackgroundMessages(
          chatIdToSave,
          messagesToSave,
          modelId: _selectedModelId,
          provider: _selectedProviderSlug,
        );
        if (kDebugMode) {
          debugPrint(
            '[NEW-CHAT] Snapshotted ${messagesToSave.length} messages for background stream: $chatIdToSave',
          );
        }
      }
    }

    // Stop any active recording when starting new chat
    if (_audioHandler.isMicActive) {
      unawaited(_audioHandler.stopRecording());
    }
    // Clear UI immediately for instant response
    setState(() {
      _messages.clear();
      _animCtrl.reset();
      _activeChatId = null;
      _isSending = false; // Reset for new chat
      _fileHandler.attachedFiles.clear();
      _messageActionsHandler.cancelEdit();
    });

    // Notify parent that we're now on a new chat (null ID)
    widget.onChatIdChanged(null);
    scrollChatToBottom(force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

    // Persist old chat in background (don't await)
    // CRITICAL: Use silent=true to prevent persistence handler from changing
    // _activeChatId or calling widget.onChatIdChanged - we're now on a NEW chat!
    // Sidebar auto-updates via ChatStorageService.changes stream
    //
    // Also: skip persisting if the old chat was just deleted. Without this,
    // `_handleChatDeleted` → `newChat()` would schedule a save of the chat
    // we just removed, and any race against the persistence handler's own
    // `wasRecentlyDeleted` guard could resurrect it in Supabase.
    if (messagesToSave != null &&
        chatIdToSave != null &&
        !ChatStorageState.wasRecentlyDeleted(chatIdToSave)) {
      unawaited(
        _persistenceHandler.persistChat(
          messages: messagesToSave
              .map((m) => Map<String, String>.from(m))
              .toList(),
          chatId: chatIdToSave,
          silent: true,
        ),
      );
    }
  }

  /// Start a new chat with a specific assistant.
  /// The workspace's system prompt will replace the user's global prompt,
  /// and the chat will be linked to the workspace after the first message.
  void newChatWithWorkspace(String assistantId) {
    newChat();

    _pendingWorkspaceId = assistantId;
    WorkspaceStorageService.selectedWorkspaceId = assistantId;

    if (kDebugMode) {
      debugPrint('[NEW-CHAT] Starting chat with workspace: $assistantId');
    }
  }

  void _openComingSoonFeature(String featureName) {
    if (!mounted) return;
    ChatUiHelpers.openComingSoonFeature(context, featureName);
  }

  /// Load the user's saved model preference
  Future<void> _loadSavedModelPreference() async {
    // The active mode's config is the single source of truth for the model,
    // provider and reasoning level. It always yields a model (baked
    // defaults), so this simply projects it — no separate saved-vs-default
    // branch to keep in step.
    try {
      await _restoreChatMode();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading saved model preference: $e');
      }
      // Keep empty on error - user must select
    }
  }

  Future<void> _loadSystemPrompt() async {
    try {
      final systemPrompt = await UserPreferencesService.loadSystemPrompt();
      if (!mounted) return;
      setState(() {
        _systemPrompt = systemPrompt;
      });
      if (systemPrompt != null && systemPrompt.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('Loaded system prompt: ${systemPrompt.length} characters');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading system prompt: $e');
      }
    }
  }

  /// Resolve the workspace for the current chat, if any.
  /// Checks pending workspace first, then looks up by chat ID.
  Workspace? _resolveWorkspaceForCurrentChat() {
    if (_pendingWorkspaceId != null) {
      return WorkspaceStorageService.getWorkspace(_pendingWorkspaceId!);
    }
    final chatId = _activeChatId ?? ChatStorageService.selectedChatId;
    if (chatId != null) {
      return WorkspaceStorageService.getWorkspaceForChat(chatId);
    }
    return null;
  }

  Future<String?> _resolveSystemPromptForSend() async {
    // Check if this chat belongs to an assistant.
    // If so, use the assistant's system prompt instead of the user's global one.
    final workspace = _resolveWorkspaceForCurrentChat();

    String? basePrompt;
    if (workspace != null && workspace.hasCustomPrompt) {
      // Workspace's system prompt REPLACES the user's global prompt and Soul.
      basePrompt = workspace.customSystemPrompt;
      if (kDebugMode) {
        debugPrint(
          '[WORKSPACE] Using system prompt from "${workspace.name}" '
          '(${basePrompt!.length} chars)',
        );
      }
    } else {
      // Normal flow: load user's global system prompt.
      try {
        basePrompt = await UserPreferencesService.loadSystemPrompt();
        if (mounted) {
          setState(() {
            _systemPrompt = basePrompt;
          });
        } else {
          _systemPrompt = basePrompt;
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Error resolving system prompt for send: $error');
        }
        basePrompt = _systemPrompt;
      }
    }

    var resolvedPrompt = basePrompt;

    // If a workspace is active, prepend workspace context
    if (_selectedWorkspaceId != null) {
      try {
        final projectContext =
            await WorkspaceMessageService.buildProjectSystemMessage(
              _selectedWorkspaceId!,
            );
        // Combine workspace context with user's system prompt
        if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
          resolvedPrompt =
              '$projectContext\n\n---\n\nAdditional User Instructions:\n$resolvedPrompt';
        } else {
          resolvedPrompt = projectContext;
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Error building workspace system message: $error');
        }
        // Fall back to base prompt if workspace context fails
      }
    }

    // Inject active artifact context for this chat (when feature is enabled).
    if (kFeatureArtifacts) {
      final chatId = _activeChatId ?? ChatStorageService.selectedChatId;
      if (chatId != null && chatId.isNotEmpty) {
        try {
          final artifactContext =
              await ArtifactContextService.buildArtifactsSystemMessage(chatId);
          if (artifactContext != null && artifactContext.isNotEmpty) {
            if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
              resolvedPrompt = '$artifactContext\n\n---\n\n$resolvedPrompt';
            } else {
              resolvedPrompt = artifactContext;
            }
          }
        } catch (error) {
          if (kDebugMode) {
            debugPrint('Error building artifact system message: $error');
          }
        }
      }
    }

    return resolvedPrompt;
  }

  // State for drag and drop
  bool _isDraggingFiles = false;

  Future<void> _handleMicTap() async {
    if (_audioHandler.isMicActive) {
      await _audioHandler.stopRecording();
      _audioHandler.onLevelsChanged = null;
      _audioVisualizerTimer?.cancel();
      _audioVisualizerTimer = null;
      if (!mounted) return;
      setState(() {
        _audioHandler.resetAudioLevels();
      });
    } else {
      // Use the existing session token — no need to refresh first.
      final accessToken = SupabaseService.auth.currentSession?.accessToken;

      final bool started = await _audioHandler.startRecording(
        accessToken: accessToken,
      );
      if (!mounted) return;
      if (started) {
        setState(() {
          _audioHandler.resetAudioLevels();
        });
        // Drive visualiser from amplitude callback.
        _audioHandler.onLevelsChanged = () {
          if (mounted && _audioHandler.isMicActive) {
            setState(() {});
          }
        };
        // Periodic timer as backup — on some Linux audio backends,
        // onAmplitudeChanged may not emit reliably.
        _audioVisualizerTimer = Timer.periodic(
          const Duration(milliseconds: 30),
          (_) {
            if (mounted && _audioHandler.isMicActive) {
              setState(() {});
            }
          },
        );
      } else {
        _showSnackBar(AppLocalizations.of(context)!.micAccessFailed);
      }
    }
    if (kDebugMode) {
      debugPrint('Mic button toggled: ${_audioHandler.isMicActive}');
    }
  }

  Future<void> _handleAudioSend() async {
    if (!_audioHandler.isMicActive || _audioHandler.isTranscribingAudio) return;

    await _audioHandler.stopRecording(keepFile: true);
    _audioHandler.onLevelsChanged = null;
    _audioVisualizerTimer?.cancel();
    _audioVisualizerTimer = null;
    if (!mounted) return;
    setState(() {
      _audioHandler.resetAudioLevels();
    });

    final session = SupabaseService.auth.currentSession;
    if (session == null) {
      _showSnackBar(AppLocalizations.of(context)!.sessionExpired);
      return;
    }

    _audioHandler.setTranscribing(true);
    if (mounted) setState(() {});

    final result = await _audioHandler.transcribeLastRecording(
      apiService: _chatApiService,
      accessToken: session.accessToken,
    );

    if (!mounted) return;

    if (!result.success) {
      _showSnackBar(
        result.error ?? AppLocalizations.of(context)!.transcriptionFailed,
      );
      setState(() {});
      return;
    }

    if (result.text != null && result.text!.isNotEmpty) {
      // When editing, the transcription must go through the edit-submit path,
      // which guards on `_isSending` — so do NOT pre-set the flag in that case
      // or the submit would bail. _sendMessage() sets the flag itself.
      final bool editing = _messageActionsHandler.isEditing;
      setState(() {
        _controller.text = result.text!;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: result.text!.length),
        );
        // Set sending flag instantly so loading indicator shows without gap
        if (widget.autoSendVoiceTranscription && !editing) {
          _isSending = true;
        }
      });

      // If auto-send is enabled, send the message immediately. Route through
      // _sendOrSubmitEdit so a transcription produced while editing replaces the
      // edited message (and truncates below) instead of appending a new one.
      if (widget.autoSendVoiceTranscription) {
        await _sendOrSubmitEdit();
      } else {
        // Otherwise, focus the text field so user can review before sending
        Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      }
    }
  }

  void _showSnackBar(String message) {
    ChatUiHelpers.showSnackBar(context, message);
  }

  bool _isValidMessageIndex(int index) =>
      index >= 0 && index < _messages.length;

  void _editMessageAt(int index) {
    if (!_isValidMessageIndex(index)) return;
    final String text = (_messages[index]['text'] ?? '').trim();
    // Restore the message's attachments into the composer so the user can see
    // and remove them while editing. Removal is list-only (see
    // _removeComposerAttachment) so the saved message is never corrupted if the
    // edit is cancelled.
    final List<AttachedFile> attached = _reconstructAttachedFilesForResend(
      index,
    );
    if (text.isEmpty && attached.isEmpty) return;
    setState(() {
      _messageActionsHandler.startEdit(index);
      _controller.text = text;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
      _restoredAttachmentIds
        ..clear()
        ..addAll(attached.map((f) => f.id));
      _fileHandler.attachedFiles
        ..clear()
        ..addAll(attached);
    });
  }

  void _cancelEditMessage() {
    setState(() {
      _messageActionsHandler.cancelEdit();
      _controller.clear();
      // List-only clear: the restored attachments still belong to the saved
      // message until an edit is submitted, so do NOT delete them from storage.
      _fileHandler.attachedFiles.clear();
      _restoredAttachmentIds.clear();
    });
  }

  /// Remove an attachment from the composer.
  /// - While editing, attachments restored from the saved message are removed
  ///   list-only (they still belong to that message until submit, and a cancel
  ///   must leave the original intact).
  /// - Attachments uploaded fresh during the edit (not in the restored set),
  ///   and all removals outside editing, also delete the file from storage.
  void _removeComposerAttachment(String fileId) {
    if (_messageActionsHandler.isEditing &&
        _restoredAttachmentIds.contains(fileId)) {
      setState(() {
        _fileHandler.attachedFiles.removeWhere((f) => f.id == fileId);
      });
    } else {
      _fileHandler.removeAttachedFile(fileId);
    }
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
  }

  /// Sends the message, or submits an edited message if in edit mode.
  Future<void> _sendOrSubmitEdit() async {
    if (_messageActionsHandler.isEditing) {
      final editIndex = _messageActionsHandler.editingMessageIndex!;
      final newText = _controller.text.trim();
      // Snapshot the (possibly reduced) attachment set BEFORE cancel clears it.
      final attachedSnapshot = List<AttachedFile>.from(
        _fileHandler.attachedFiles,
      );
      _cancelEditMessage();
      if (newText.isNotEmpty || attachedSnapshot.isNotEmpty) {
        await _submitEditedMessage(
          editIndex,
          newText,
          attachedFilesOverride: attachedSnapshot,
          removeFollowingAssistant: false,
          clearMessagesBelow: true,
        );
      }
    } else {
      await _sendMessage();
    }
  }

  Future<void> _resendMessageAt(int index) async {
    if (!_isValidMessageIndex(index)) return;

    int sourceIndex = index;
    if (_messages[sourceIndex]['sender'] != 'user') {
      sourceIndex = -1;
      for (int i = index - 1; i >= 0; i--) {
        if (_messages[i]['sender'] == 'user') {
          sourceIndex = i;
          break;
        }
      }
    }

    if (!_isValidMessageIndex(sourceIndex)) {
      _showSnackBar('Nothing to resend.');
      return;
    }

    final String text = (_messages[sourceIndex]['text'] ?? '').trim();
    if (text.isEmpty) {
      _showSnackBar('Nothing to resend.');
      return;
    }
    // Use the same logic as editing and submitting
    await _submitEditedMessage(
      sourceIndex,
      text,
      removeFollowingAssistant: false,
      clearMessagesBelow: true,
    );
  }

  /// Returns a callback for the ask_user interactive buttons if [index] is
  /// the last AI message, is not streaming, and contains a completed
  /// ask_user tool call. Otherwise returns null.
  ValueChanged<String>? _askUserCallbackForIndex(
    int index,
    MessageRenderData data,
  ) {
    // Only the very last message, and only AI messages, and only when idle.
    if (data.isUser || data.isStreamingMessage || _isStreaming || _isSending) {
      return null;
    }
    if (index != _messages.length - 1) {
      return null;
    }

    // Check if any tool call is ask_user + completed.
    bool hasAskUser = false;
    if (data.contentBlocks != null) {
      for (final block in data.contentBlocks!) {
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
    if (!hasAskUser && data.toolCalls != null) {
      hasAskUser = data.toolCalls!.any(
        (tc) => tc.name == 'ask_user' && tc.status == ToolCallStatus.completed,
      );
    }
    if (!hasAskUser) {
      return null;
    }

    return (String answer) {
      _controller.text = answer;
      _sendMessage();
    };
  }

  /// Returns a callback for the inline MCP Connect card if [index] is the last
  /// AI message, is idle, and contains a completed request_mcp_server call.
  /// The callback resumes the same conversation with a fresh send, exactly
  /// like the ask_user resume — the rebuilt prompt now lists the server as
  /// connected, so the model continues with its tools available.
  ValueChanged<String>? _connectMcpCallbackForIndex(
    int index,
    MessageRenderData data,
  ) {
    if (data.isUser || data.isStreamingMessage || _isStreaming || _isSending) {
      return null;
    }
    if (index != _messages.length - 1) {
      return null;
    }

    bool hasRequest = false;
    if (data.contentBlocks != null) {
      for (final block in data.contentBlocks!) {
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
    if (!hasRequest && data.toolCalls != null) {
      hasRequest = data.toolCalls!.any(
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
      _controller.text =
          'Connected the $name server — its tools are now available. '
          'Continue with what I asked.';
      _sendMessage();
    };
  }

  List<MessageBubbleAction> _buildMessageActionsForIndex(
    int index,
    MessageRenderData data,
  ) {
    if (!_isValidMessageIndex(index)) {
      return const <MessageBubbleAction>[];
    }

    final Map<String, String> rawMessage = _messages[index];
    final String messageText = rawMessage['text'] ?? '';

    return _messageActionsHandler.buildActionsForMessage(
      index: index,
      messageText: messageText,
      isUser: data.isUser,
      isStreaming: data.isReasoningStreaming,
      onEdit: _editMessageAt,
      onResendMessage: _resendMessageAt,
    );
  }

  List<MessageBubbleAction> _buildUserMessageActionsForIndex(
    int index,
    MessageRenderData data,
  ) {
    if (!_isValidMessageIndex(index) || !data.isUser) {
      return const <MessageBubbleAction>[];
    }
    final String messageText = (_messages[index]['text'] ?? '');
    return _messageActionsHandler.buildUserMessageActions(
      index: index,
      messageText: messageText,
      onEdit: _editMessageAt,
      onResendMessage: _resendMessageAt,
    );
  }

  /// Wraps the composer text field so that any `PasteTextIntent` (Cmd+V,
  /// Ctrl+V, macOS dictation Cmd+V, external dictation tools like WhisperFlow,
  /// context-menu paste) is routed to our smart-paste handler, which supports
  /// image pastes and long-text-as-attachment. Flutter's default
  /// `PasteTextAction` is marked overridable, so this `Actions` override wins
  /// over the built-in behavior. Skipped on web because `handleSmartPaste`
  /// relies on `dart:io` APIs (File, Directory, Pasteboard).
  Widget _wrapWithSmartPasteActions(Widget child) {
    if (kIsWeb) return child;
    return Actions(
      actions: <Type, Action<Intent>>{
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (PasteTextIntent intent) {
            _fileHandler.modelSupportsImageInput = modelSupportsImageInput;
            unawaited(_clipboardHandler.handleSmartPaste(_controller));
            return null;
          },
        ),
      },
      child: child,
    );
  }

  Widget _buildAudioVisualizer({required Color accent, required Color iconFg}) {
    final levels = _audioHandler.audioLevels;
    // Match bar count to buffer so newest sample lands at the right edge and
    // the bars fill the row edge-to-edge instead of clustering in the middle.
    final int barCount = levels.length;

    return SizedBox(
      key: const ValueKey<String>('audio-visualizer'),
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(barCount, (index) {
          // Newest sample at right edge: index N-1 maps to last level.
          final int levelIndex = index;
          final double rawLevel = levels[levelIndex];

          // sqrt scaling — boosts quiet speech for visible response.
          final double boosted = rawLevel < 0.01 ? 0.0 : math.sqrt(rawLevel);

          // Bar height: 3px idle → 28px loud.
          final double barHeight = (boosted * 25 + 3).clamp(3.0, 28.0);
          final double opacity = (0.55 + boosted * 0.45).clamp(0.55, 1.0);

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                curve: Curves.easeOutCubic,
                height: barHeight,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.red.withValues(alpha: opacity),
                      Colors.redAccent.shade200.withValues(alpha: opacity * 0.7),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: boosted > 0.3
                      ? [
                          BoxShadow(
                            color: Colors.red.withValues(alpha: 0.45),
                            blurRadius: 5,
                            spreadRadius: 0.6,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildRecordingPill({required Color iconFg}) {
    return SizedBox(
      key: const ValueKey<String>('recording-pill'),
      height: 36,
      child: Row(
        children: [
          const SizedBox(width: 4),
          const _DesktopRecordingDot(),
          const SizedBox(width: 10),
          Expanded(
            child: _buildAudioVisualizer(
              accent: Colors.red,
              iconFg: iconFg,
            ),
          ),
        ],
      ),
    );
  }

  // In-memory cache for resolved Base64 images (storage path -> data URL)

  Future<void> _persistChat({bool waitForCompletion = false}) async {
    if (_messages.isEmpty) return;
    await _persistenceHandler.persistChat(
      messages: _messages.map((m) => Map<String, String>.from(m)).toList(),
      chatId: _activeChatId,
      waitForCompletion: waitForCompletion,
    );
  }

  /// Persist chat with a specific chatId (for background streaming to correct chat)
  void _persistChatWithId(String chatId) {
    if (_messages.isEmpty) return;
    unawaited(
      _persistenceHandler.persistChat(
        messages: _messages.map((m) => Map<String, String>.from(m)).toList(),
        chatId: chatId,
      ),
    );
  }

  /// Persist specific messages to a specific chat (for background streaming)
  /// Used when user has switched away from a streaming chat
  void _persistChatWithIdAndMessages(
    String chatId,
    List<Map<String, dynamic>> messages,
  ) {
    if (messages.isEmpty) return;
    unawaited(
      _persistenceHandler.persistChat(
        messages: messages.map((m) => Map<String, String>.from(m)).toList(),
        chatId: chatId,
        silent: true,
      ),
    );
  }

  MessageRenderData _buildMessageRenderData(int index) {
    return ChatUiHelpers.buildMessageRenderData(
      raw: _messages[index],
      index: index,
      messageCount: _messages.length,
      isStreaming: _isStreaming,
      imagesCache: _decodedImagesCache,
      attachmentsCache: _decodedAttachmentsCache,
      toolCallsCache: _decodedToolCallsCache,
      contentBlocksCache: _decodedContentBlocksCache,
    );
  }

  void _clearMessageDecodeCaches() {
    _decodedImagesCache.clear();
    _decodedAttachmentsCache.clear();
    _decodedToolCallsCache.clear();
    _decodedContentBlocksCache.clear();
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    final double effectiveHorizontalPadding = widget.isCompactMode
        ? _kHorizontalPaddingSmall
        : _kHorizontalPaddingLarge;
    final double maxPossibleChatContentWidth = math.max(
      0.0,
      screenWidth - (effectiveHorizontalPadding * 2),
    );
    final double constrainedChatContentWidth = math.min(
      _kMaxChatContentWidth,
      maxPossibleChatContentWidth,
    );

    // Define the smaller width for the centered state
    final double centeredInputWidth =
        constrainedChatContentWidth * (widget.isCompactMode ? 0.95 : 0.8);
    // Define the full width for the bottom-aligned state
    final double expandedInputWidth = constrainedChatContentWidth;

    // Calculate the total height of the input area (search bar + attachment bar + padding)
    double inputAreaVisualHeight = _kSearchBarContentHeight;
    if (_fileHandler.attachedFiles.isNotEmpty) {
      inputAreaVisualHeight +=
          _kAttachmentBarHeight + _kAttachmentBarMarginBottom;
    }
    // Queued-message banner adds a row above the text field.
    if (_pendingMessageText != null) {
      inputAreaVisualHeight += _kQueuedBannerHeight;
    }
    // Reserve the composer's real measured height when available (it grows as
    // the text field wraps to multiple lines); fall back to the constant-based
    // estimate for the first frame before MeasureSize reports. The composer is
    // offset `effectiveHorizontalPadding` from the bottom edge, plus a small
    // gap above so the last message isn't flush against the input box.
    final double inputAreaEstimate =
        inputAreaVisualHeight + (2 * effectiveHorizontalPadding);
    double inputAreaTotalHeight = composerHeight > 0
        ? composerHeight + effectiveHorizontalPadding + 8
        : inputAreaEstimate;

    // Determine if the chat is currently empty (no messages, no attached files)
    final bool isChatEmpty = _messages
        .isEmpty; // This refers to the chat history, not just text input
    // On desktop, it centers when empty.
    final bool showInputAreaCentered = isChatEmpty;

    // Determine the target width for the input area
    final double targetInputWidth = showInputAreaCentered
        ? centeredInputWidth
        : expandedInputWidth;

    // Check if we're in workspace mode
    final bool isProjectMode = widget.workspaceId != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Row(
        children: [
          // Main chat area
          Expanded(
            child: DropTarget(
              onDragDone: (detail) {
                final List<String> filePaths = detail.files
                    .map((file) => file.path)
                    .where((path) => path.isNotEmpty)
                    .toList();
                if (filePaths.isNotEmpty) {
                  _fileHandler.modelSupportsImageInput =
                      modelSupportsImageInput;
                  _fileHandler.handleDroppedFiles(filePaths);
                }
              },
              onDragEntered: (detail) {
                setState(() {
                  _isDraggingFiles = true;
                });
              },
              onDragExited: (detail) {
                setState(() {
                  _isDraggingFiles = false;
                });
              },
              child: Builder(
                builder: (context) {
                  final Color accent = Theme.of(context).colorScheme.primary;
                  final Color bg = Theme.of(context).scaffoldBackgroundColor;
                  // The composer's height is reserved as list *padding*, not by
                  // shortening the viewport. Ending the viewport above the
                  // composer cut the last line in half against a hard edge —
                  // the strip of background between the clipped text and the
                  // composer's rounded top. With a full-height viewport the
                  // content scrolls behind the composer and disappears under
                  // its rounded corners, and the padding still lets every
                  // message scroll clear of it.
                  final double messageListBottomPadding =
                      inputAreaTotalHeight + _kMessageListBottomLift;

                  return Stack(
                    children: [
                      // Visual feedback when dragging files
                      if (_isDraggingFiles)
                        Positioned.fill(
                          child: Container(
                            color: accent.withValues(alpha: 0.1),
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 32,
                                  vertical: 24,
                                ),
                                decoration: BoxDecoration(
                                  color: bg,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: accent, width: 2),
                                  boxShadow: [
                                    BoxShadow(
                                      color: accent.withValues(alpha: 0.3),
                                      blurRadius: 20,
                                      spreadRadius: 5,
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.cloud_upload,
                                      color: accent,
                                      size: 32,
                                    ),
                                    const SizedBox(width: 16),
                                    Text(
                                      'Drop files here to upload',
                                      style: TextStyle(
                                        color: iconFg,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Loading indicator when switching chats
                      if (_isLoadingChat)
                        Positioned.fill(
                          key: const ValueKey<String>(
                            'desktop-chat-loading-overlay',
                          ),
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
                      if (!isChatEmpty)
                        Positioned(
                          key: const ValueKey<String>(
                            'desktop-chat-message-list',
                          ),
                          top: 0,
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Padding(
                            padding: EdgeInsets.zero,
                            child: Align(
                              alignment: Alignment.center,
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth: expandedInputWidth,
                                ),
                                child: SelectionCopyArea(
                                  focusNode: _messageSelectionFocusNode,
                                  contextMenuBuilder: _buildMessageContextMenu,
                                  // Listener (not GestureDetector) so this does
                                  // not enter the gesture arena. A competing tap
                                  // recognizer here would beat SelectionArea's
                                  // double-tap recognizer and break
                                  // double-click-to-select-word.
                                  child: Listener(
                                    behavior: HitTestBehavior.translucent,
                                    onPointerDown: (_) {
                                      // Move the focus to the selection region
                                      // itself, so Flutter's own Ctrl+C path
                                      // targets the messages instead of the
                                      // composer. Plain `unfocus()` left the
                                      // focus nowhere, which is exactly what
                                      // broke copying. SelectionCopyArea copies
                                      // even without focus — this is the second
                                      // layer, not the only one.
                                      _messageSelectionFocusNode.requestFocus();
                                    },
                                    // Re-evaluate the scroll-to-bottom button
                                    // when layout metrics change without a
                                    // user scroll (e.g. maxScrollExtent shrinks
                                    // after a streaming message finalises).
                                    // Plain scroll listener doesn't fire in
                                    // that case and the button can get stuck.
                                    child: NotificationListener<
                                      ScrollMetricsNotification
                                    >(
                                      onNotification: (_) {
                                        onScrollChanged();
                                        return false;
                                      },
                                      child: ListView.builder(
                                        controller: scrollController,
                                      padding: EdgeInsets.only(
                                        left: effectiveHorizontalPadding,
                                        right: effectiveHorizontalPadding,
                                        top: 10,
                                        bottom: messageListBottomPadding,
                                      ),
                                      itemCount: _messages.length,
                                      addAutomaticKeepAlives:
                                          true, // Keep message widgets alive
                                      addRepaintBoundaries: true,
                                      cacheExtent: _isLinuxDesktop
                                          ? 360.0
                                          : 1200.0, // Lower Linux cache to reduce jank spikes
                                      itemBuilder: (_, int i) {
                                        final MessageRenderData data =
                                            _buildMessageRenderData(i);
                                        final String? reasoningText =
                                            data.reasoning.trim().isEmpty
                                            ? null
                                            : data.reasoning;
                                        final bool previousIsUser = i == 0
                                            ? data.isUser
                                            : (_messages[i - 1]['sender'] ??
                                                      'ai') ==
                                                  'user';
                                        final bool nextIsUser =
                                            i == _messages.length - 1
                                            ? data.isUser
                                            : (_messages[i + 1]['sender'] ??
                                                      'ai') ==
                                                  'user';
                                        final bool startsNewGroup =
                                            i == 0 ||
                                            previousIsUser != data.isUser;
                                        final bool endsGroup =
                                            i == _messages.length - 1 ||
                                            nextIsUser != data.isUser;
                                        final bool isBeingEdited =
                                            _messageActionsHandler
                                                .editingMessageIndex ==
                                            i;
                                        // Build the bubble from a (text,
                                        // reasoning) pair so the streaming
                                        // bubble can be fed live values from the
                                        // runtime notifier without a
                                        // screen-wide rebuild. Every other prop
                                        // is stable for the stream's duration.
                                        MessageBubble buildBubble(
                                          String msgText,
                                          String? msgReasoning,
                                        ) => MessageBubble(
                                          key: ValueKey(
                                            ChatUiHelpers.stableUiKey(
                                              _messages[i],
                                              _uuid,
                                            ),
                                          ),
                                          message: msgText,
                                          reasoning: msgReasoning,
                                          isUser: data.isUser,
                                          startsNewGroup: startsNewGroup,
                                          endsGroup: endsGroup,
                                          maxWidth: data.isUser
                                              ? expandedInputWidth *
                                                    0.8 // User messages: 80%
                                              : expandedInputWidth, // AI messages: 100%
                                          isReasoningStreaming:
                                              data.isReasoningStreaming,
                                          modelLabel: data.modelLabel,
                                          modelProvider: data.modelProvider,
                                          tps: data.tps,
                                          toolCalls: data.toolCalls,
                                          showToolCalls: widget.showToolCalls,
                                          contentBlocks: data.contentBlocks,
                                          isStreamingMessage:
                                              data.isStreamingMessage,
                                          turnStartedAt: data.turnStartedAt,
                                          workedFor: data.workedFor,
                                          images: data.images,
                                          imageMetas: data.imageMetas,
                                          imageCostEur: data.imageCostEur,
                                          imageGeneratedAt: data.imageGeneratedAt,
                                          attachments: data.attachments,
                                          actions: _buildMessageActionsForIndex(
                                            i,
                                            data,
                                          ),
                                          userMessageActions:
                                              _buildUserMessageActionsForIndex(
                                                i,
                                                data,
                                              ),
                                          isEditing: isBeingEdited,
                                          showReasoningTokens:
                                              widget.showReasoningTokens,
                                          showModelInfo: widget.showModelInfo,
                                          showTps: widget.showTps,
                                          onAskUserAnswer:
                                              _askUserCallbackForIndex(i, data),
                                          onConnectMcpServer:
                                              _connectMcpCallbackForIndex(
                                                i,
                                                data,
                                              ),
                                          useSharedSelectionArea: true,
                                          status: data.status,
                                          lastError: data.lastError,
                                          onRetryPending: data.isUser &&
                                                  (data.status ==
                                                          ChatMessageStatus
                                                              .pending ||
                                                      data.status ==
                                                          ChatMessageStatus
                                                              .failed)
                                              ? () => OfflineRetryManager
                                                  .instance
                                                  .retryNow()
                                              : null,
                                        );

                                        // The streaming bubble rebuilds itself
                                        // per token via the runtime's
                                        // streamingLive notifier — the rest of
                                        // the screen stays put.
                                        final ChatRuntime? runtime =
                                            _activeChatId == null
                                            ? null
                                            : ChatRuntimeRegistry.instance
                                                  .lookup(_activeChatId!);
                                        // Wrap the last AI bubble for the whole
                                        // turn (isSending), not just while a
                                        // stream is mid-flight: isStreaming
                                        // briefly flips false between tool-loop
                                        // passes and we must keep the live
                                        // wrapper across that gap.
                                        final bool wrapForStream =
                                            runtime != null &&
                                            !data.isUser &&
                                            i == _messages.length - 1 &&
                                            (data.isStreamingMessage ||
                                                runtime.isSending.value);
                                        if (wrapForStream) {
                                          return RepaintBoundary(
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
                                                        : data.displayText;
                                                    final String reasoningRaw =
                                                        match
                                                        ? live.reasoning
                                                        : data.reasoning;
                                                    final String? msgReasoning =
                                                        reasoningRaw
                                                            .trim()
                                                            .isEmpty
                                                        ? null
                                                        : reasoningRaw;
                                                    return buildBubble(
                                                      msgText,
                                                      msgReasoning,
                                                    );
                                                  },
                                                ),
                                          );
                                        }
                                        final String uiKey =
                                            ChatUiHelpers.stableUiKey(
                                          _messages[i],
                                          _uuid,
                                        );
                                        if (data.isUser &&
                                            uiKey == _flyInKey) {
                                          return RepaintBoundary(
                                            child: MessageFlyIn(
                                              key: ValueKey('flyin_$uiKey'),
                                              child: buildBubble(
                                                data.displayText,
                                                reasoningText,
                                              ),
                                            ),
                                          );
                                        }
                                        return RepaintBoundary(
                                          child: buildBubble(
                                            data.displayText,
                                            reasoningText,
                                          ),
                                        );
                                      },
                                    ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Scroll-to-bottom button (centered above input)
                      if (showScrollToBottom && !isChatEmpty)
                        Positioned(
                          key: const ValueKey<String>(
                            'desktop-chat-scroll-to-bottom',
                          ),
                          bottom: inputAreaTotalHeight + 12,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Builder(
                              builder: (context) {
                                final t = Theme.of(context);
                                return Material(
                                  elevation: 4,
                                  shape: const CircleBorder(),
                                  color: t.colorScheme.surfaceContainerHighest,
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () =>
                                        scrollChatToBottom(force: true),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.keyboard_arrow_down,
                                        size: 24,
                                        color: t.colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      Positioned(
                        key: const ValueKey<String>('desktop-chat-input-area'),
                        left: 0,
                        right: 0,
                        // Position at the bottom if not empty, otherwise calculate center position
                        bottom: showInputAreaCentered
                            ? (MediaQuery.of(context).size.height / 2 -
                                  (inputAreaVisualHeight / 2))
                            : effectiveHorizontalPadding, // Always keep padding from bottom edge
                        child: Center(
                          // Centers horizontally
                          child: SizedBox(
                            width:
                                targetInputWidth, // Dynamically changes width
                            child: MeasureSize(
                              onChange: onComposerHeightChanged,
                              child: Column(
                                mainAxisSize: MainAxisSize
                                    .min, // Crucial for column inside AnimatedPositioned/Center
                                children: [
                                  // Search Bar (attachment bar is now inside)
                                  _buildSearchBar(
                                    isCompactMode: widget.isCompactMode,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          // Workspace panel (right side) - shown in workspace mode until first message
          if (isProjectMode && widget.workspaceId != null && _messages.isEmpty)
            WorkspacePanel(
              workspaceId: widget.workspaceId!,
              onClose: widget.onExitProject,
            ),
        ],
      ),
    );
  }

  // NEW: Extracted Attachment Bar Widget
  Widget _buildSearchBar({required bool isCompactMode}) {
    const btnH = 36.0, btnW = 44.0;
    const containerRadius = 23.0;
    const buttonRadius = 18.0;
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    final bool hasAttachments = _fileHandler.attachedFiles.isNotEmpty;

    return Container(
      width:
          double.infinity, // Occupy full width of its parent AnimatedContainer
      constraints: const BoxConstraints(minHeight: _kSearchBarContentHeight),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(containerRadius),
        border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 2),
      ),
      padding: const EdgeInsets.all(14),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          // Main content column
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Attachment previews inside the textbox (right-padded so cards don't go under send button)
              if (_fileHandler.attachedFiles.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: 14,
                    left: 2,
                    right: btnW + 8,
                  ),
                  child: AttachmentPreviewBar(
                    files: _fileHandler.attachedFiles,
                    onRemove: _removeComposerAttachment,
                  ),
                ),
              // Editing indicator
              if (_messageActionsHandler.isEditing)
                Padding(
                  // Clear the floating top-right send button so the "Cancel"
                  // action isn't hidden underneath it.
                  padding: EdgeInsets.only(bottom: 6, right: btnW + 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.edit,
                        size: 14,
                        color: iconFg.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Editing message',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.6),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _cancelEditMessage,
                        child: Text(
                          'Cancel',
                          style: TextStyle(
                            color: accent.withValues(alpha: 0.8),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // Queued message indicator — shown when the user sent a message
              // while the AI was still streaming. It auto-sends on completion.
              if (_pendingMessageText != null)
                Padding(
                  // Clear the floating top-right send/stop button.
                  padding: EdgeInsets.only(bottom: 6, right: btnW + 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 14,
                        color: iconFg.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${AppLocalizations.of(context)!.queuedLabel}: '
                          '"${_pendingMessageText!}"',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: iconFg.withValues(alpha: 0.6),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _cancelPendingMessage,
                        child: Icon(
                          Icons.close,
                          size: 16,
                          color: accent.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              // Text field with right padding to avoid send button overlap
              Padding(
                padding: EdgeInsets.only(right: btnW + 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: _wrapWithSmartPasteActions(
                    Scrollbar(
                      controller: _composerScrollController,
                      child: KeyedSubtree(
                        key: TourKeyRegistry.instance.keyFor(
                          TourSlots.chatInput,
                        ),
                        child: TextField(
                        controller: _controller,
                        focusNode: _textFieldFocusNode,
                        contextMenuBuilder: _buildComposerContextMenu,
                        autofocus: true,
                        showCursor: true,
                        minLines: 1,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.done,
                        scrollController: _composerScrollController,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(
                          color: iconFg,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                        decoration: InputDecoration(
                          hintText: _messageActionsHandler.isEditing
                              ? AppLocalizations.of(context)!.editYourMessage
                              : hasAttachments
                              ? AppLocalizations.of(context)!.addMessageOrDocs
                              : AppLocalizations.of(context)!.askMeAnything,
                          hintStyle: TextStyle(
                            color: iconFg.withValues(alpha: 0.8),
                            fontWeight: FontWeight.w600,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          filled: false,
                          fillColor: Colors.transparent,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 0,
                          ),
                          isDense: true,
                        ),
                        cursorColor: accent,
                        cursorWidth: 2,
                        cursorRadius: const Radius.circular(1),
                      ),
                      ),
                    ),
                  ),
                ),
              ),
              // Extra breathing room between text field and toolbar when attachments push content down
              if (hasAttachments) const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _audioHandler.isMicActive
                          ? _buildRecordingPill(iconFg: iconFg)
                          : Row(
                              key: const ValueKey<String>(
                                'default-mic-controls',
                              ),
                              children: [
                                // Add Button (File Upload).
                                // Rebuilds when model capabilities load, so a
                                // vision model's button reflects image support
                                // live on cold start without a second tap.
                                ValueListenableBuilder<int>(
                                  valueListenable:
                                      ModelCapabilitiesService.revision,
                                  builder: (context, _, _) => _buildIconBtn(
                                    icon: Icons.add_rounded,
                                    iconSize: 24,
                                    onTap: () {
                                      _fileHandler.modelSupportsImageInput =
                                          modelSupportsImageInput;
                                      _fileHandler.uploadFiles();
                                    },
                                    isActive: false,
                                    debugLabel: 'Add button',
                                  ),
                                ),
                                // Workspace Selection Dropdown (only when feature enabled)
                                if (kFeatureWorkspaces) ...[
                                  const SizedBox(width: 8),
                                  WorkspaceSelectionDropdown(
                                    selectedWorkspaceId: _selectedWorkspaceId,
                                    onWorkspaceSelected: (workspaceId) {
                                      if (kDebugMode) {
                                        debugPrint(
                                          '📁 onWorkspaceSelected callback: $workspaceId (was: $_selectedWorkspaceId)',
                                        );
                                      }
                                      setState(() {
                                        _selectedWorkspaceId = workspaceId;
                                      });
                                      if (kDebugMode) {
                                        debugPrint(
                                          '📁 After setState: $_selectedWorkspaceId',
                                        );
                                      }
                                    },
                                    textFieldFocusNode: _textFieldFocusNode,
                                  ),
                                ],
                                Expanded(
                                  // Expanded gives the FittedBox a bounded
                                  // width, so the pill stays right-aligned at
                                  // natural size and only scales DOWN when the
                                  // toolbar is too narrow — no overflow, and it
                                  // does not drift to the centre.
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerRight,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Active assistant indicator
                                        Builder(
                                          builder: (context) {
                                            final a =
                                                _resolveWorkspaceForCurrentChat();
                                            if (a == null) {
                                              return const SizedBox.shrink();
                                            }
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                right: 6,
                                              ),
                                              child: Tooltip(
                                                message: 'Workspace: ${a.name}',
                                                child: _buildIconBtn(
                                                  icon: a.displayIcon,
                                                  onTap: () {},
                                                  isActive: true,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        // Reasoning toggle + model selector,
                                        // merged into one rounded segmented pill
                                        // when the model supports reasoning.
                                        _buildModelControlPill(
                                          isCompactMode: isCompactMode,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Mic Button (acts as record/stop toggle)
                  _buildIconBtn(
                    icon: _audioHandler.isMicActive
                        ? Icons.stop_rounded
                        : Icons.mic,
                    iconSize: 22,
                    onTap: _handleMicTap,
                    isActive: _audioHandler.isMicActive,
                    debugLabel: 'Mic button',
                  ),
                  // Voice Mode button (only when feature enabled, hidden during recording)
                  if (!_audioHandler.isMicActive && kFeatureVoiceMode) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      key: const ValueKey<String>('voice-mode-button'),
                      onTap: () => _openComingSoonFeature('Voice Mode'),
                      child: Container(
                        width: 44,
                        height: 36,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(buttonRadius),
                        ),
                        child: const Icon(
                          Icons.graphic_eq,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          // Send / Stop button pinned to top-right of container
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: _audioHandler.isTranscribingAudio
                  ? null
                  : () {
                      if (_isStreaming || _isSending) {
                        _cancelCurrentOperation();
                      } else if (_audioHandler.isMicActive) {
                        _handleAudioSend();
                      } else {
                        _sendOrSubmitEdit();
                      }
                    },
              child: Container(
                width: btnW,
                height: btnH,
                decoration: BoxDecoration(
                  color: (_isStreaming || _isSending) ? Colors.red : accent,
                  borderRadius: BorderRadius.circular(buttonRadius),
                ),
                child: _audioHandler.isTranscribingAudio
                    ? Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.black,
                            ),
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.2,
                            ),
                          ),
                        ),
                      )
                    : (_isStreaming || _isSending)
                    ? const Icon(
                        Icons.stop_rounded,
                        color: Colors.black,
                        size: 22,
                      )
                    : Transform(
                        transform: Matrix4.diagonal3Values(1, 0.95, 1),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.arrow_upward_rounded,
                          color: Colors.black,
                          size: 26,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The model selector, merged with the reasoning toggle into a single
  /// rounded segmented pill — `[ 🧠 | # Model ]` — sharing one outer border.
  /// The left segment toggles reasoning; the right opens the model dropdown.
  /// Falls back to a plain dropdown (no merge) for non-reasoning models, and
  /// to the legacy toggle-beside-dropdown layout in compact mode.
  /// The composer's mode control: Fast or Thinking, with the model list
  /// one level deeper inside its sheet. Same control as the mobile
  /// composer, so a reader moving between the two finds the same thing.
  Widget _buildModelControlPill({required bool isCompactMode}) {
    // Rebuild when capability data hydrates: the reasoning levels below are
    // read synchronously, so a cold start would otherwise keep the graded
    // ladder for a binary/non-reasoning model until an unrelated rebuild.
    return ValueListenableBuilder<int>(
      valueListenable: ModelCapabilitiesService.revision,
      builder: (context, _, _) => KeyedSubtree(
        key: TourKeyRegistry.instance.keyFor(TourSlots.modelDropdown),
        child: ChatModeSelector(
          mode: _chatMode,
        // Match the round composer icon buttons (mic, voice, attach) beside
        // it — the default 40 made the pill stand taller than the row.
        height: 36,
        // Always upwards here: the composer sits at the bottom of a tall
        // window, and a menu dropping down covers the box it belongs to.
        menuAbove: true,
        selectedModelId: _selectedModelId,
        modelLabel: _selectedModelName ??
            (_selectedModelId.isEmpty ? null : _selectedModelId),
        customModelLabel: _customModelName,
        pickedModels: _pickedModels,
        reasoningEffort: ChatModeService.sanitizeReasoningForModel(
          _reasoningEffort,
          modelId: _selectedModelId,
          providerSlug: _selectedProviderSlug ?? '',
        ),
        // The picker options come straight from the server's per-model
        // `supported_efforts` (derived list only as a cold-start fallback),
        // so a level the model does not support can never be offered.
        reasoningLevels: ChatModeService.reasoningLevelsForModel(
          modelId: _selectedModelId,
          // Before the provider resolves, use the mode's own default provider
          // so the derived fallback never briefly offers a wrong ladder.
          providerSlug: (_selectedProviderSlug?.isNotEmpty ?? false)
              ? _selectedProviderSlug!
              : ChatModeService.defaultConfig(_chatMode).providerSlug,
        ),
          onReasoningEffortChanged: _setReasoningEffort,
          onModeChanged: _setChatMode,
          onModelSelected: _applyModelSelection,
          onOpenModelScreen: _openModelScreen,
        ),
      ),
    );
  }

  /// Resolve the selected model's human name for the mode sheet.
  ///
  /// Pass the id explicitly when reacting to a change, so a slow lookup for
  /// a model the reader has already moved on from cannot overwrite the
  /// name of the current one.
  Future<void> _refreshSelectedModelName([String? modelId]) async {
    final target = modelId ?? _selectedModelId;
    final name = await ModelCacheService.displayNameFor(target);
    if (!mounted || target != _selectedModelId || name == _selectedModelName) {
      return;
    }
    setState(() {
      _selectedModelName = name;
    });
  }

  /// Resolve the name of the model Custom last ran, so the third point in the
  /// mode menu can name it even while Fast or Thinking is active. Stays null
  /// until Custom has a stored config (has been used at least once), so a fresh
  /// install shows the neutral "Choose model" instead of the seed default.
  Future<void> _refreshCustomModelName() async {
    final bool used = await ChatModeService.hasStoredConfig(ChatMode.custom);
    if (!used) {
      if (mounted && _customModelName != null) {
        setState(() => _customModelName = null);
      }
      return;
    }
    final config = await ChatModeService.loadConfig(ChatMode.custom);
    final name = await ModelCacheService.displayNameFor(config.modelId) ??
        prettyModelId(config.modelId);
    if (!mounted || name == _customModelName) return;
    setState(() => _customModelName = name);
  }

  /// The models this reader has picked, for the composer's second menu.
  ///
  /// Source of truth is `user_model_providers` in Supabase: a model lands
  /// there as soon as a provider is pinned for it on the model screen, so
  /// "picked" needs no second table. The mode default and the model in use
  /// are always included — a menu that cannot show what is running would
  /// be worse than useless.
  Future<void> _refreshPickedModels() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;

    // Offline first: the device snapshot paints the menu straight away,
    // even with no network and before the first sync of a cold start.
    final local = await ModelCacheService.loadProviderPreferences(user.id);
    await _applyPickedModels(local);

    // Then the truth. `loadAllProviderPreferences` writes the snapshot back
    // on success, so a model unpinned on another device disappears here on
    // the next look instead of lingering until something else rewrote the
    // cache — which is how it lingered before.
    try {
      final remote = await UserPreferencesService.loadAllProviderPreferences();
      if (!mapEquals(remote, local)) await _applyPickedModels(remote);
    } catch (_) {
      // No network: the snapshot already on screen is the best answer.
    }
  }

  /// Turn provider preferences into the menu's model list.
  Future<void> _applyPickedModels(Map<String, String> prefs) async {
    final ids = <String>{
      // Each mode's own default model, so both stay reachable in the menu.
      ChatModeService.defaultConfig(ChatMode.fast).modelId,
      ChatModeService.defaultConfig(ChatMode.thinking).modelId,
      if (_selectedModelId.isNotEmpty) _selectedModelId,
      // Only models that still have a provider pinned. An empty slug means
      // the pin was taken away, and the model is no longer picked.
      for (final entry in prefs.entries)
        if (entry.value.trim().isNotEmpty) entry.key,
    };

    var catalogue = await ModelCacheService.loadAvailableModels();
    bool namesMissing(List<Map<String, dynamic>> list) {
      final known = {
        for (final model in list)
          if (model['id'] is String) model['id'] as String,
      };
      return ids.any((id) => !known.contains(id));
    }

    // A name the catalogue does not carry would be shown as the raw
    // OpenRouter slug. Fetch the list once instead of printing the id.
    if (catalogue.isEmpty || namesMissing(catalogue)) {
      await ModelPrefetchService.prefetch();
      catalogue = await ModelCacheService.loadAvailableModels();
    }

    final names = <String, String>{
      for (final model in catalogue)
        if (model['id'] is String && model['name'] is String)
          model['id'] as String: model['name'] as String,
    };

    final picked = <ChatModelChoice>[
      for (final id in ids)
        ChatModelChoice(id: id, name: names[id] ?? prettyModelId(id)),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (!mounted) return;
    setState(() {
      _pickedModels = picked;
    });
  }

  /// The full model screen: add models, pin providers. Prefer the redesigned
  /// settings modal (model section) so "More models" and the settings menu
  /// land in the same place; fall back to the standalone page if no modal
  /// opener was wired.
  Future<void> _openModelScreen() async {
    // Only a genuinely new pick should flip the composer into Custom. Merely
    // browsing the screen — pinning a provider, retuning Fast/Thinking — must
    // leave the active mode untouched, so compare against the model in use.
    final String before = _selectedModelId;
    if (widget.onOpenModelSettings != null) {
      await widget.onOpenModelSettings!.call();
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ModelSelectorPage()),
      );
    }
    if (!mounted) return;
    final selected = await UserPreferencesService.loadSelectedModel();
    if (mounted &&
        selected != null &&
        selected.isNotEmpty &&
        selected != before) {
      await _applyModelSelection(selected);
    }
    await _refreshPickedModels();
  }

  /// Switch mode, swapping in that mode's own model, provider and reasoning
  /// level. The next send uses them.
  Future<void> _setChatMode(ChatMode mode) async {
    await ChatModeService.save(mode);
    final config = await ChatModeService.loadConfig(mode);
    await _applyModeConfig(mode, config);
  }

  /// Set the reasoning level for the active mode. The store clamps it to what
  /// the mode's stored provider allows and hands back the result, which is
  /// the single source of truth — adopt it rather than a locally clamped copy.
  Future<void> _setReasoningEffort(String level) async {
    final config = await ChatModeService.setReasoningForMode(_chatMode, level);
    if (!mounted) return;
    setState(() {
      _reasoningEffort = config.reasoningEffort;
    });
  }

  /// The reasoning effort to actually send, clamped to what [modelId]'s real
  /// server-provided ladder allows. The stored `_reasoningEffort` is already
  /// clamped whenever the model or level changes, but the catalog cache can
  /// hydrate after a send is queued (cold start) or the send may target a
  /// different model than the composer's (resend/continue), so clamp again at
  /// the send site — a level the model does not support must never leave here.
  String _clampedReasoningEffort(String modelId, String? providerSlug) =>
      ChatModeService.sanitizeReasoningForModel(
        _reasoningEffort,
        modelId: modelId,
        providerSlug: providerSlug ?? '',
      );

  /// Apply a model the reader picked directly. Picking a specific model IS the
  /// Custom mode — an arbitrary model at its own reasoning level. Fast and
  /// Thinking keep the models set on the model screen and are never
  /// overwritten from here, so the pick records against Custom and switches to
  /// it. Reload the pinned provider so model and provider cannot drift apart on
  /// the next send.
  Future<void> _applyModelSelection(String modelId) async {
    setState(() {
      _selectedModelId = modelId;
      _chatMode = ChatMode.custom;
    });
    await ChatModeService.save(ChatMode.custom);
    ModelSelectionDropdown.selectedModelNotifier.value = modelId;
    await UserPreferencesService.saveSelectedModel(modelId);
    if (!mounted) return;
    await loadProviderSlugForModel(modelId, forceFromPrefs: true);
    final config = await ChatModeService.setModelForMode(
      ChatMode.custom,
      modelId: modelId,
      providerSlug: _selectedProviderSlug ?? '',
    );
    if (mounted && config.reasoningEffort != _reasoningEffort) {
      setState(() {
        _reasoningEffort = config.reasoningEffort;
      });
    }
    await _refreshSelectedModelName(modelId);
    await _refreshCustomModelName();
    await _refreshPickedModels();
  }

  /// Bring back the mode the reader last used, and with it that mode's own
  /// model, provider and reasoning level. The mode config is the single
  /// source of truth for what a send uses; this projects it into the live
  /// fields and keeps the shared selected-model plumbing in step.
  Future<void> _restoreChatMode() async {
    final mode = await ChatModeService.load();
    final config = await ChatModeService.loadConfig(mode);
    await _applyModeConfig(mode, config);
  }

  /// Project [config] for [mode] into the live fields and the shared
  /// selected-model plumbing, then refresh the derived UI. Safe to call more
  /// than once — it is idempotent.
  Future<void> _applyModeConfig(ChatMode mode, ModeConfig config) async {
    if (!mounted) return;
    setState(() {
      _chatMode = mode;
      _reasoningEffort = config.reasoningEffort;
      _selectedModelId = config.modelId;
      _selectedProviderSlug = config.providerSlug;
    });
    ModelSelectionDropdown.selectedModelNotifier.value = config.modelId;
    await UserPreferencesService.saveSelectedModel(config.modelId);
    // The per-model provider pin is owned by the model screen. Read it here
    // rather than overwrite it, and fall back to the mode's stored provider
    // only when nothing is pinned. Awaited so it cannot race the unawaited
    // read the model-selection listener starts from the notifier above.
    if (!mounted) return;
    await loadProviderSlugForModel(config.modelId, forceFromPrefs: true);
    if (mounted && (_selectedProviderSlug ?? '').isEmpty) {
      setState(() {
        _selectedProviderSlug = config.providerSlug;
      });
    }
    if (!mounted) return;
    await _refreshSelectedModelName(config.modelId);
    await _refreshCustomModelName();
    await _refreshPickedModels();
  }

  Widget _buildIconBtn({
    IconData? icon,
    String? svgAssetPath,
    double iconSize = 20,
    required VoidCallback onTap,
    required bool isActive,
    String? debugLabel,
  }) {
    assert(
      icon != null || svgAssetPath != null,
      'Either icon or svgAssetPath must be provided.',
    );

    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        splashFactory: InkRipple.splashFactory,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: ValueListenableBuilder<bool>(
          valueListenable: isHovered,
          builder: (context, hovered, child) {
            final Color effectiveBgColor = isActive ? iconFg : bg;
            final Color effectiveIconColor = isActive ? bg : iconFg;

            final Color effectiveBorderColor = hovered
                ? iconFg
                : isActive
                ? iconFg.withValues(alpha: 0.6)
                : iconFg.withValues(alpha: 0.3);

            final double effectiveBorderWidth = hovered
                ? 2.2
                : isActive
                ? 2.0
                : 1.8;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              width: 44,
              height: 36,
              decoration: BoxDecoration(
                color: effectiveBgColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: effectiveBorderColor,
                  width: effectiveBorderWidth,
                ),
              ),
              child: svgAssetPath != null
                  ? SvgPicture.asset(
                      svgAssetPath,
                      width: iconSize,
                      height: iconSize,
                      colorFilter: ColorFilter.mode(
                        effectiveIconColor,
                        BlendMode.srcIn,
                      ),
                    )
                  : Icon(icon!, color: effectiveIconColor, size: iconSize),
            );
          },
        ),
      ),
    );
  }
}

class _DesktopRecordingDot extends StatefulWidget {
  const _DesktopRecordingDot();

  @override
  State<_DesktopRecordingDot> createState() => _DesktopRecordingDotState();
}

class _DesktopRecordingDotState extends State<_DesktopRecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: _animation.value),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.red.withValues(alpha: _animation.value * 0.6),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}
