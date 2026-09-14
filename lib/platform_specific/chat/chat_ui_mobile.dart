// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'dart:convert';
import 'dart:math' as math;
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/services/mcp/mcp_availability.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/services/app_lifecycle_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/widgets/composer_recording.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/measure_size.dart';
import 'package:chuk_chat/widgets/selection_copy_area.dart';
import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/chat_message_edit_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/chat_model_selection_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/tool_history_formatter.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:async';

// Import new handlers
import 'package:chuk_chat/platform_specific/chat/handlers/audio_recording_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/file_attachment_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/chat_persistence_handler.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/mobile_chat_widgets.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/regen_variant_seed.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/mobile_workspace_handler.dart';
import 'package:chuk_chat/widgets/fullscreen_text_editor.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/chat_message_list_item.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/services/artifact_context_service.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_specific/chat/chat_debug_snapshot.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// What the plus menu can start.
enum _AttachChoice { camera, photos, files, workspace }

/// A row in the workspace menu: a workspace to switch to (null clears it),
/// or the way to make a new one.
class _WorkspaceChoice {
  const _WorkspaceChoice.pick(this.workspaceId) : create = false;
  const _WorkspaceChoice.create() : workspaceId = null, create = true;

  final String? workspaceId;
  final bool create;
}

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
        ChatModelSelectionMixin,
        ChatMessageEditMixin,
        RegenVariantSeedMixin<ChukChatUIMobile>
    implements ChatDebugSnapshot {
  // Controllers and basic state
  @override
  final TextEditingController composerController = TextEditingController();
  final List<Map<String, String>> _messages = [];

  final MessageRenderCache _messageRenderCache = MessageRenderCache();
  String? _activeChatId;

  // Answer-version pager plumbing (seed stash/restore/fold) lives in
  // RegenVariantSeedMixin, shared with the desktop State. This State supplies
  // the two hooks it needs via [variantActiveChatId] and [variantChatIsLive].

  final ScrollController _composerScrollController = ScrollController();
  @override
  final FocusNode composerFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();
  final Uuid _uuid = const Uuid();
  bool _lastTextWasEmpty = true;
  bool _showFullscreenButton = false;

  // Services and handlers
  late ChatApiService _chatApiService;
  late final AudioRecordingHandler _audioHandler;
  late final FileAttachmentHandler _fileHandler;
  @override
  late final MessageActionsHandler messageActionsHandler;
  @override
  late final ChatPersistenceHandler persistenceHandler;

  // --- ChatMessageEditMixin plumbing -------------------------------------
  // The mixin owns the edit/resend/branch/variant logic; the storage below
  // stays here because the two States hold it differently.

  @override
  List<Map<String, String>> get messages => _messages;

  @override
  String? get activeChatId => _activeChatId;

  @override
  set activeChatId(String? value) => _activeChatId = value;

  @override
  Function(String?) get onChatIdChanged => widget.onChatIdChanged;

  @override
  List<AttachedFile> get composerAttachedFiles => _fileHandler.attachedFiles;

  @override
  void deleteComposerAttachment(String fileId) =>
      _fileHandler.removeFile(fileId);

  /// Mobile focuses the composer as soon as an edit loads into it.
  @override
  void onEditStarted() => composerFocusNode.requestFocus();

  @override
  String get nothingToResendMessage =>
      AppLocalizations.of(context)!.nothingToResend;
  late final StreamingMessageHandler _streamingHandler;

  /// IDs of attachments restored into the composer when an edit started. These
  /// belong to the saved message, so removing them must NOT delete from storage
  /// (the original survives if the edit is cancelled); attachments uploaded
  /// fresh during the edit are not in this set and ARE deleted on removal.
  @override
  final Set<String> restoredAttachmentIds = <String>{};

  String? _systemPrompt;

  /// UI key of the message that was just sent, so its list item plays the
  /// fly-up entrance once. Transient, never persisted.
  String? _flyInKey;

  /// The stable ui key of the message pinned to the top of the viewport.
  /// Null when nothing is pinned. See [ChatScrollMixin.pinMessageToTop].
  String? _pinnedUiKey;

  late final VoidCallback _modelSelectionListener;

  // Stream subscriptions
  StreamSubscription<void>? _providerRefreshSubscription;

  // Network and UI state
  bool _isOffline = false;

  /// Queued message text — when the user sends while AI is still streaming,
  /// the text is parked here and dispatched after the current response ends.
  String? _pendingMessageText;
  bool _isLoadingChat = false; // Loading indicator for chat switching
  bool _isAppInBackground = false;
  late final VoidCallback _networkStatusListener;

  // Workspace state
  String? _selectedWorkspaceId;

  // Computed property - checks if CURRENT chat is streaming
  bool get _isCurrentChatStreaming =>
      _activeChatId != null &&
      _streamingHandler.isChatStreaming(_activeChatId!);

  /// Per-chat send-in-flight flag, backed by the ChatRuntime for the
  /// currently visible chat. Reads return false for chats with no runtime
  /// yet (no send ever attempted). Writes are no-ops when there is no
  /// active chat (the caller has nowhere to record state).
  ///
  /// Per-chat semantics are required for multi-chat parallel sends: a
  /// send in chat A must not block a send in chat B.
  bool get _isSendingMessage {
    final cid = _activeChatId;
    if (cid == null) return false;
    return ChatRuntimeRegistry.instance.lookup(cid)?.isSending.value ?? false;
  }

  set _isSendingMessage(bool value) {
    final cid = _activeChatId;
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
    AppLifecycleService.instance.addOnResumeCallback(_handleAppResumed);
    AppLifecycleService.instance.addOnPauseCallback(_handleAppPaused);
    // Mode + its config (model, provider, reasoning) restore once, via
    // loadSavedModelPreference in _loadInitialData's post-frame pass — the
    // single entry point, so startup writes and picked-model refreshes run
    // only once.
    _loadInitialData();
  }

  void _initializeHandlers() {
    _chatApiService = ChatApiService(
      onUploadStatusUpdate: _handleFileUploadUpdate,
    );

    _audioHandler = AudioRecordingHandler();

    _fileHandler = FileAttachmentHandler()
      ..initialize(_chatApiService)
      ..onError = showSnackBar
      ..onUpdate = () {
        if (_audioHandler.isMicActive) {
          // Defer rebuild while mic visualizer is active to avoid flicker.
        } else {
          setState(() {});
        }
      };

    messageActionsHandler = MessageActionsHandler()
      ..onShowSnackBar = showSnackBar
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
      ..onShowSnackBar = showSnackBar
      ..onChatIdAssigned = (chatId) {
        if (mounted && _activeChatId != chatId) {
          setState(() {
            _activeChatId = chatId;
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

    _streamingHandler = StreamingMessageHandler()
      ..onShowSnackBar = showSnackBar
      ..onUpdateUI = () {
        if (mounted) setState(() {});
      }
      ..onMessageUpdate = updateAiMessage
      ..onMessageFinalize = _finalizeAiMessage
      ..onToolCallsUpdate = _updateToolCallsForMessage
      ..onToolImagesProcessed = _handleToolImagesProcessed
      ..onContentBlocksUpdate = _updateContentBlocksForMessage
      ..onRequestPayloadUpdate = _updateRequestPayloadForMessage
      ..onBackgroundUpdate = (chatId, index, content, reasoning) {
        if (_activeChatId != chatId || _isAppInBackground) {
          unawaited(
            persistenceHandler
                .updateBackgroundChatMessage(
                  chatId: chatId,
                  messageIndex: index,
                  content: content,
                  reasoning: reasoning,
                  immediate: _isAppInBackground,
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
      ..onStreamInterrupted = _markAssistantMessageInterrupted
      ..onStreamTick = _persistStreamTick
      ..onPaymentRequired = _showPaymentRequiredDialog;
  }

  /// Periodic snapshot persistence — writes the current streamed body of
  /// the assistant message directly to storage every ~500ms (and on
  /// lifecycle pause). Used to defend against the OS suspending the app
  /// mid-stream and losing the tail of a response.
  ///
  /// We pipe through [persistenceHandler.updateBackgroundChatMessage]
  /// regardless of whether the chat is foregrounded — the handler
  /// debounces writes per (chatId, messageIndex) so per-tick overhead
  /// stays low.
  void _persistStreamTick(
    String chatId,
    int index,
    String content,
    String reasoning,
    String? contentBlocksJson,
    bool forceImmediate,
  ) {
    if (index < 0) return;
    unawaited(
      persistenceHandler
          .updateBackgroundChatMessage(
            chatId: chatId,
            messageIndex: index,
            content: content,
            reasoning: reasoning,
            contentBlocksJson: contentBlocksJson,
            // Force-write on app-background OR when the handler explicitly
            // asked for an immediate flush (lifecycle pause / dispose /
            // cancel). Otherwise let the debounce coalesce per-token churn.
            immediate: forceImmediate || _isAppInBackground,
          )
          .catchError((error) {
            if (kDebugMode) {
              debugPrint('persistStreamTick failed: $error');
            }
          }),
    );
  }

  /// Tag an assistant message with `interrupted` status when its stream was
  /// torn down before the final-answer event ran (app suspended, widget
  /// disposed mid-stream, user-cancel, etc). The UI uses this flag to show
  /// the "Continue generation" button.
  void _markAssistantMessageInterrupted(String chatId, int index) {
    if (index < 0) return;
    if (_activeChatId == chatId && mounted && index < _messages.length) {
      setState(() {
        final message = Map<String, String>.from(_messages[index]);
        message['status'] = 'interrupted';
        _messages[index] = message;
      });
    }
    // Always pipe through the debounced background persistence path so the
    // status hits storage even during widget dispose (where setState +
    // persistChat may race the tear-down). The persistence handler also
    // coalesces with any concurrent snapshot tick into a single write.
    unawaited(
      persistenceHandler
          .updateBackgroundChatMessage(
            chatId: chatId,
            messageIndex: index,
            status: 'interrupted',
            immediate: true,
          )
          .catchError((error) {
            if (kDebugMode) {
              debugPrint(
                'updateBackgroundChatMessage (markInterrupted) failed: $error',
              );
            }
          }),
    );
  }

  void _handleAppResumed() {
    _isAppInBackground = false;
  }

  void _handleAppPaused() {
    _isAppInBackground = true;

    // Snapshot active chat state so streaming/tool loops can persist updates
    // while the app is backgrounded or the device is locked.
    if (_activeChatId != null &&
        _streamingHandler.isChatStreaming(_activeChatId!)) {
      final messagesCopy = _messages
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      _streamingHandler.setBackgroundMessages(_activeChatId!, messagesCopy);
    }
  }

  void _showPaymentRequiredDialog() {
    if (!mounted) return;
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            AppIcon(
              Icons.chat_bubble_outline,
              color: theme.colorScheme.primary,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(l.freeMessagesUsed)),
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
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  AppIcon(
                    Icons.computer,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Visit Chuk Chat on desktop to subscribe and get €16 in monthly AI credits.',
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.ok),
          ),
        ],
      ),
    );
  }

  void _initializeListeners() {
    // Scroll listener for scroll-to-bottom button
    scrollController.addListener(onScrollChanged);

    // Text field focus listener — collapse mic & model buttons while typing

    // Text controller listener
    composerController.addListener(_onControllerChanged);

    // Request focus if sidebar closed
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.isSidebarExpanded) {
        composerFocusNode.requestFocus();
      }
    });

    // Model selection listener
    _modelSelectionListener = () {
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
      if (_isOffline != !isOnline) {
        setState(() {
          _isOffline = !isOnline;
        });
        showSnackBar(isOnline ? 'Back online' : 'You are offline');
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
    _loadChatById(widget.selectedChatId);

    // Defer all network-dependent loading to after first frame
    // This ensures the UI renders immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Load model preference first (needed for sending)
      unawaited(loadSavedModelPreference());
      // These can load in parallel after UI is shown
      unawaited(_loadSystemPrompt());
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
          '│ 🔄 [CHAT-UI-MOBILE] Current _activeChatId: $_activeChatId',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] _isSendingMessage: $_isSendingMessage',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] _streamingHandler.isStreaming: ${_streamingHandler.isStreaming}',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '└─────────────────────────────────────────────────────────────',
        );
      }

      // Skip if we're already on this chat
      if (widget.selectedChatId == _activeChatId) {
        if (kDebugMode) {
          debugPrint('⚠️ [CHAT-UI-MOBILE] SKIP - already on this chat');
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
            '⚠️ [CHAT-UI-MOBILE] IGNORING null from parent - we have active chat: $_activeChatId',
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
      if (_activeChatId != null &&
          _streamingHandler.isChatStreaming(_activeChatId!)) {
        final messagesCopy = _messages
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        _streamingHandler.setBackgroundMessages(_activeChatId!, messagesCopy);
        if (kDebugMode) {
          debugPrint(
            '│ 📦 [CHAT-UI-MOBILE] Snapshotted ${messagesCopy.length} messages for background stream: $_activeChatId',
          );
        }
      }

      setState(() {
        _messages.clear();
        _messageRenderCache.clear();
        _fileHandler.clearAll();
        composerController.clear();
        messageActionsHandler.cancelEdit();
      });

      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] About to call _loadChatById(${widget.selectedChatId})',
        );
      }
      _loadChatById(widget.selectedChatId);
      if (kDebugMode) {
        debugPrint(
          '│ 🔄 [CHAT-UI-MOBILE] After _loadChatById, _activeChatId: $_activeChatId',
        );
      }

      final bool newChatIsStreaming =
          _activeChatId != null &&
          _streamingHandler.isChatStreaming(_activeChatId!);

      if (newChatIsStreaming != _streamingHandler.isStreaming) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    AppLifecycleService.instance.removeOnResumeCallback(_handleAppResumed);
    AppLifecycleService.instance.removeOnPauseCallback(_handleAppPaused);
    if (_activeChatId != null) {
      _streamingHandler.cancelStream(_activeChatId);
      MultiplexSession.closeForChat(_activeChatId!);
    }
    // Tear down the streaming handler so its lifecycle observer
    // unregisters and the periodic snapshot timer is cancelled. Without
    // this each rebuild of the chat State leaks a registered pause
    // callback — and `dispose()` is also our last chance to flush the
    // in-flight snapshot to disk.
    _streamingHandler.dispose();
    persistenceHandler.dispose();
    _providerRefreshSubscription?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      _networkStatusListener,
    );
    scrollController.removeListener(onScrollChanged);
    composerController.removeListener(_onControllerChanged);
    composerController.dispose();
    scrollController.dispose();
    _composerScrollController.dispose();
    composerFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    ModelSelectionDropdown.selectedModelListenable.removeListener(
      _modelSelectionListener,
    );
    _audioHandler.onLevelsChanged = null;
    _audioHandler.dispose();
    super.dispose();
  }

  // --- CHAT MANAGEMENT ---

  void _loadChatById(String? chatId) {
    // The pin belongs to the chat we are leaving, and so does the room it
    // reserved: carried into another chat it would open that one on a screen
    // of blank space.
    hasTopPin = false;
    pinnedExtraSpace = 0;
    _pinnedUiKey = null;

    // The regenerate seed belongs to the chat we are leaving. If its turn is
    // still running it keeps going in the background, so hand the seed over
    // instead of dropping it — otherwise the background completion cannot fold
    // and the previous answer is lost from the pager.
    stashVariantSeedForBackground();
    if (kDebugMode) {
      debugPrint('');
    }
    if (kDebugMode) {
      debugPrint(
        '┌─────────────────────────────────────────────────────────────',
      );
    }
    if (kDebugMode) {
      debugPrint('│ 📂 [LOAD-CHAT-MOBILE] _loadChatById called');
    }
    if (kDebugMode) {
      debugPrint('│ 📂 [LOAD-CHAT-MOBILE] chatId param: $chatId');
    }
    if (kDebugMode) {
      debugPrint(
        '│ 📂 [LOAD-CHAT-MOBILE] Current _activeChatId: $_activeChatId',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '│ 📂 [LOAD-CHAT-MOBILE] Sidebar expanded: ${widget.isSidebarExpanded}',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '└─────────────────────────────────────────────────────────────',
      );
    }

    // Capture sidebar state NOW - before any async operations
    final bool sidebarWasExpanded = widget.isSidebarExpanded;

    // Synchronous fast path: if the requested chat is already in cache and
    // fully loaded, populate inline without entering async / showing the
    // spinner. This avoids a one-frame loading flash when switching between
    // already-loaded chats.
    if (chatId != null) {
      final StoredChat? cached = ChatStorageService.getChatById(chatId);
      if (cached != null && cached.isFullyLoaded) {
        if (kDebugMode) {
          debugPrint(
            '│ ⚡ [LOAD-CHAT-MOBILE] Sync fast path for $chatId (${cached.messages.length} msgs)',
          );
        }
        _activeChatId = cached.id;
        // Returning to a chat whose regenerate was still running in the
        // background: re-arm its seed so the now-foreground answer folds.
        restoreVariantSeedForChat(cached.id);
        unawaited(
          MultiplexSession.openForChat(cached.id).catchError((e) {
            if (kDebugMode) {
              debugPrint('⚠️ MultiplexSession.openForChat failed: $e');
            }
          }),
        );
        _applyLoadedChat(cached, sidebarWasExpanded);
        return;
      }
    }

    // Slow path: cache miss or stale → show spinner, go async
    setState(() {
      _isLoadingChat = true;
    });

    // Use async function to handle lazy loading
    _loadChatByIdAsync(chatId, sidebarWasExpanded);
  }

  /// Apply a fully-loaded [StoredChat] to UI state synchronously: rebuild
  /// `_messages`, run stale-tool-call recovery, splice in any buffered
  /// streaming content, and clear `_isLoadingChat` in a single `setState`.
  ///
  /// Assumes `_activeChatId` has already been set to `chat.id` by the caller
  /// and `MultiplexSession.openForChat` has been triggered.
  void _applyLoadedChat(StoredChat chat, bool sidebarWasExpanded) {
    if (!mounted) return;

    // Use the shared ChatMessage->raw-map bridge so mobile and desktop stay in
    // lockstep (it carries modelId/provider/images/attachments/toolCalls/
    // contentBlocks AND the local-only messageId/status/queueId needed to keep
    // stable bubble identity + the "Continue generation" affordance on reload).
    final List<Map<String, String>> newMessages = chat.messages
        .map(ChatUiHelpers.messageToRawMap)
        .toList();

    final String? activeChatId = _activeChatId;

    // Stale-tool-call recovery (skip if a stream is in flight or just
    // completed — the streaming flow handles its own finalization).
    var recoveredStaleCalls = false;
    if (activeChatId != null &&
        !_streamingHandler.isChatStreaming(activeChatId) &&
        !_streamingHandler.hasCompletedStream(activeChatId)) {
      for (final message in newMessages) {
        if (ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message)) {
          recoveredStaleCalls = true;
        }
      }
    }

    // Splice buffered streaming content (if any) into the freshly-built list
    // before it lands in _messages, so the user never sees a stale snapshot.
    final bool chatIsStreaming =
        activeChatId != null && _streamingHandler.isChatStreaming(activeChatId);
    final bool chatHasCompletedStream =
        activeChatId != null &&
        _streamingHandler.hasCompletedStream(activeChatId);

    if (activeChatId != null && (chatIsStreaming || chatHasCompletedStream)) {
      // Prefer the StreamingManager's background snapshot — captured at
      // stream start (placeholder appended) with the live buffer overlaid by
      // getBackgroundMessages. The cache copy can be stale or even missing
      // the placeholder entirely if the user switched chats within the
      // first snapshot-flush window (the "Thinking..." placeholder is not
      // persisted synchronously). Falling back to in-place splice when no
      // background snapshot exists.
      final bgMessages = _streamingHandler.getBackgroundMessages(activeChatId);
      if (bgMessages != null && bgMessages.isNotEmpty) {
        newMessages
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
        if (chatHasCompletedStream) {
          _streamingHandler.consumeCompletedStream(activeChatId);
        }
      } else {
        final int? streamingMsgIndex = _streamingHandler
            .getStreamingMessageIndex(activeChatId);
        if (streamingMsgIndex != null &&
            streamingMsgIndex >= 0 &&
            streamingMsgIndex < newMessages.length) {
          final String? bufferedContent = _streamingHandler.getBufferedContent(
            activeChatId,
          );
          final String? bufferedReasoning = _streamingHandler
              .getBufferedReasoning(activeChatId);

          if (bufferedContent != null) {
            final Map<String, String> updatedMessage = Map<String, String>.from(
              newMessages[streamingMsgIndex],
            );
            updatedMessage['text'] = bufferedContent;
            updatedMessage['reasoning'] = bufferedReasoning ?? '';
            newMessages[streamingMsgIndex] = updatedMessage;
            if (chatHasCompletedStream) {
              _streamingHandler.consumeCompletedStream(activeChatId);
            }
          }
        }
      }
    }

    setState(() {
      _messages
        ..clear()
        ..addAll(newMessages);
      _isLoadingChat = false;
      showScrollToBottom = false;
    });

    if (recoveredStaleCalls) {
      unawaited(
        persistenceHandler
            .persistChat(
              messages: _messages
                  .map((m) => Map<String, String>.from(m))
                  .toList(),
              chatId: activeChatId,
              waitForCompletion: false,
              isOffline: _isOffline,
              silent: true,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint('persistChat (recover stale) failed: $error');
              }
              return null;
            }),
      );
    }

    // Opening an existing chat should *start* at the bottom, not animate.
    scrollChatToBottom(force: true, animate: false);
    // Use captured sidebar state to prevent focus when sidebar was open
    if (!sidebarWasExpanded && !widget.isSidebarExpanded) {
      composerFocusNode.requestFocus();
    }
  }

  Future<void> _loadChatByIdAsync(
    String? chatId,
    bool sidebarWasExpanded,
  ) async {
    if (!mounted) return;

    if (chatId == null) {
      // New chat - clear everything
      if (kDebugMode) {
        debugPrint(
          '│ 📂 [LOAD-CHAT-MOBILE] chatId is NULL - clearing for new chat',
        );
      }
      setState(() {
        _messages.clear();
        _messageRenderCache.clear();
        _fileHandler.clearAll();
        messageActionsHandler.cancelEdit();
        _activeChatId = null;
        _isLoadingChat = false;
        showScrollToBottom = false;
      });
      scrollChatToBottom(force: true, animate: false);
      if (!sidebarWasExpanded && !widget.isSidebarExpanded) {
        composerFocusNode.requestFocus();
      }
      return;
    }

    // Find chat by ID
    StoredChat? storedChat = ChatStorageService.getChatById(chatId);

    if (storedChat != null) {
      // LAZY LOADING: Check if chat is fully loaded
      if (!storedChat.isFullyLoaded) {
        if (kDebugMode) {
          debugPrint(
            '│ 📂 [LOAD-CHAT-MOBILE] Chat $chatId not fully loaded, fetching...',
          );
        }
        storedChat = await ChatStorageService.loadFullChat(chatId);

        // Check for stale load after async operation
        if (!mounted) return;
      }

      if (storedChat != null && storedChat.isFullyLoaded) {
        if (kDebugMode) {
          debugPrint(
            '│ 📂 [LOAD-CHAT-MOBILE] FOUND chat $chatId with ${storedChat.messages.length} messages',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ 📂 [LOAD-CHAT-MOBILE] Setting _activeChatId = ${storedChat.id}',
          );
        }
        _activeChatId = storedChat.id;
        // Returning to a chat whose regenerate was still running in the
        // background: re-arm its seed so the now-foreground answer folds.
        restoreVariantSeedForChat(storedChat.id);
        unawaited(
          MultiplexSession.openForChat(storedChat.id).catchError((e) {
            if (kDebugMode) {
              debugPrint('⚠️ MultiplexSession.openForChat failed: $e');
            }
          }),
        );
        _applyLoadedChat(storedChat, sidebarWasExpanded);
        return;
      }

      // Chat load failed - treat as new chat
      if (kDebugMode) {
        debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Chat $chatId load failed!');
      }
    } else {
      // Chat not found - treat as new chat
      if (kDebugMode) {
        debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Chat $chatId NOT FOUND!');
      }
      if (kDebugMode) {
        debugPrint(
          '│ ⚠️ [LOAD-CHAT-MOBILE] Available chats: ${ChatStorageService.savedChats.map((c) => c.id).take(5).toList()}...',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '│ ⚠️ [LOAD-CHAT-MOBILE] Treating as new chat, setting _activeChatId = null',
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _messages.clear();
      _messageRenderCache.clear();
      _fileHandler.clearAll();
      messageActionsHandler.cancelEdit();
      _activeChatId = null;
      _isLoadingChat = false;
      showScrollToBottom = false;
    });
    scrollChatToBottom(force: true, animate: false);
    if (!sidebarWasExpanded && !widget.isSidebarExpanded) {
      composerFocusNode.requestFocus();
    }
  }

  /// Returns the current messages list for debug export.
  @override
  List<Map<String, String>> get debugMessages =>
      _messages.map((m) => Map<String, String>.from(m)).toList();

  /// Current resolved system prompt (workspace or user default). Debug only.
  String? get debugSystemPrompt => _systemPrompt;

  /// Current model id used for outgoing requests. Debug only.
  @override
  String get debugModelId => selectedModelId;

  /// Current provider slug used for outgoing requests. Debug only.
  @override
  String? get debugProviderSlug => selectedProviderSlug;

  /// Current workspace id, if any. Debug only.
  @override
  String? get debugWorkspaceId => _selectedWorkspaceId;

  /// Whether reasoning is enabled for the active mode. Debug only.
  bool get debugReasoningEnabled =>
      reasoningEffort != ChatModeService.reasoningOff;

  /// Effort actually sent with each request — shown in the debug export,
  /// where "true/false" hid which of the two modes was running.
  @override
  String get debugReasoningEffort => reasoningEffort;

  /// Current active chat id. Debug only.
  @override
  String? get debugActiveChatId => _activeChatId;

  // ---------------------------------------------------------------------------
  // Answer-version pager (OpenAI-style ‹ k/n › on regenerated answers).
  // ---------------------------------------------------------------------------

  // RegenVariantSeedMixin hook: the seed logic is shared with desktop; this
  // State only has to name the chat that owns the visible message list.
  @override
  String? get variantActiveChatId => _activeChatId;

  void newChat() {
    // Preserve the seed for a still-running turn on the chat we are leaving so
    // its background completion can still fold (mirrors _loadChatById).
    stashVariantSeedForBackground();
    if (kDebugMode) {
      debugPrint(
        '🆕 [NewChat] Starting newChat(), current _activeChatId: $_activeChatId',
      );
    }

    // Capture current chat data for background persistence
    final chatIdToSave = _activeChatId;
    final messagesToSave = _messages.isNotEmpty
        ? _messages.map((m) => Map<String, String>.from(m)).toList()
        : null;

    // Nothing is pinned in an empty chat, and the room the pin reserved must
    // go with it or the fresh chat opens with a screen of blank space.
    hasTopPin = false;
    pinnedExtraSpace = 0;
    _pinnedUiKey = null;

    // Clear UI immediately for instant response
    setState(() {
      _messages.clear();
      _messageRenderCache.clear();
      _activeChatId = null;
      _fileHandler.clearAll();
      composerController.clear();
      messageActionsHandler.cancelEdit();
    });

    // Notify parent that we're now on a new chat (null ID)
    widget.onChatIdChanged(null);
    if (kDebugMode) {
      debugPrint('🆕 [NewChat] After setState, _activeChatId: $_activeChatId');
    }
    scrollChatToBottom(force: true);
    if (!widget.isSidebarExpanded) {
      composerFocusNode.requestFocus();
    }

    // Persist old chat in background (don't await).
    // CRITICAL: Use silent=true to prevent onChatIdAssigned from changing
    // the selected chat - we're now on a NEW chat!
    // No need to call loadSavedChatsForSidebar() — persistChat() updates
    // local state and fires notifyChanges(), which the sidebar picks up
    // via its changes stream listener.
    //
    // Also: skip persisting if the old chat was just deleted. Without this,
    // `_handleChatDeleted` → `newChat()` would schedule a save of the chat
    // we just removed, and any race against the persistence handler's own
    // `wasRecentlyDeleted` guard could resurrect it in Supabase.
    if (messagesToSave != null &&
        chatIdToSave != null &&
        !ChatStorageState.wasRecentlyDeleted(chatIdToSave)) {
      unawaited(
        persistenceHandler
            .persistChat(
              messages: messagesToSave,
              chatId: chatIdToSave,
              waitForCompletion: false,
              isOffline: _isOffline,
              silent: true,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint('persistChat (newChat background) failed: $error');
              }
              return null;
            }),
      );
    }
    if (kDebugMode) {
      debugPrint('🆕 [NewChat] Background operations started');
    }
  }

  // --- AUDIO HANDLERS ---

  Future<void> _handleMicTap() async {
    final change = await _audioHandler.toggleRecording(
      accessToken: SupabaseService.auth.currentSession?.accessToken,
      handleLevelsChanged: () {
        if (mounted && _audioHandler.isMicActive) setState(() {});
      },
    );
    if (!mounted) return;
    setState(() {});

    if (change == AudioRecordingChange.failed) {
      showSnackBar(AppLocalizations.of(context)!.micAccessFailed);
    }
  }

  Future<void> _handleAudioSend() async {
    if (!_audioHandler.isMicActive || _audioHandler.isTranscribingAudio) {
      return;
    }
    final l = AppLocalizations.of(context)!;

    bool sessionLookupFailed = false;
    final result = await _audioHandler.stopAndTranscribe(
      apiService: _chatApiService,
      getAccessToken: () async {
        final session = await _streamingHandler.getSessionSafely();
        sessionLookupFailed = session == null;
        return session?.accessToken;
      },
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );

    if (!mounted || result == null) return;

    if (result.requiresLogout) {
      await SupabaseService.signOut();
      if (!mounted) return;
    }

    if (!result.success) {
      if (!sessionLookupFailed) {
        showSnackBar(result.error ?? l.transcriptionFailed);
      }
      return;
    }

    if (result.text != null && result.text!.isNotEmpty) {
      setState(() {
        composerController.text = result.text!;
        composerController.selection = TextSelection.fromPosition(
          TextPosition(offset: result.text!.length),
        );
      });

      // If auto-send is enabled, send the message immediately.
      // Do NOT set _isSendingMessage here — sendMessage() guards on that flag
      // at its top and would bail before doing any work. sendMessage() sets
      // the flag itself once it passes the guard.
      // Route through sendOrSubmitEdit so a transcription produced while
      // editing replaces the edited message (and truncates below) instead of
      // being appended as a brand-new message at the end.
      if (widget.autoSendVoiceTranscription) {
        await sendOrSubmitEdit();
      } else {
        // Otherwise, focus the text field so user can review before sending
        composerFocusNode.requestFocus();
      }
    }
  }

  // --- FILE HANDLERS ---

  /// The attachment menu, anchored to the plus button in the same style as
  /// the mode menu. It used to be a sheet sliding up from the bottom edge,
  /// which looked like a different app every time it appeared.
  Future<void> _handleAddAttachmentTap(BuildContext anchorContext) async {
    if (!mounted) return;
    final bool supportsImages = modelSupportsImageInput;
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final l10n = AppLocalizations.of(context)!;

    final choice = await _showAnchoredComposerMenu<_AttachChoice>(
      anchorContext: anchorContext,
      items: <PopupMenuEntry<_AttachChoice>>[
        _composerMenuRow(
          value: _AttachChoice.camera,
          iconFg: iconFg,
          icon: Icons.photo_camera_outlined,
          label: l10n.camera,
          isEnabled: supportsImages,
        ),
        _composerMenuRow(
          value: _AttachChoice.photos,
          iconFg: iconFg,
          icon: Icons.photo_library_outlined,
          label: l10n.photos,
          isEnabled: supportsImages,
        ),
        _composerMenuRow(
          value: _AttachChoice.files,
          iconFg: iconFg,
          icon: Icons.attach_file,
          label: l10n.files,
        ),
        if (kFeatureWorkspaces)
          _composerMenuRow(
            value: _AttachChoice.workspace,
            iconFg: iconFg,
            icon: Icons.folder_outlined,
            label: _selectedWorkspaceId == null
                ? 'Workspace'
                : 'Change workspace',
          ),
      ],
    );

    if (!mounted || choice == null) return;

    switch (choice) {
      case _AttachChoice.camera:
        if (!supportsImages) return;
        unawaited(
          _fileHandler.pickImageFromSource(
            ImageSource.camera,
            supportsImages: supportsImages,
          ),
        );
      case _AttachChoice.photos:
        if (!supportsImages) return;
        unawaited(
          _fileHandler.pickImagesFromGallery(supportsImages: supportsImages),
        );
      case _AttachChoice.files:
        unawaited(_fileHandler.uploadFiles(supportsImages: supportsImages));
      case _AttachChoice.workspace:
        if (!anchorContext.mounted) return;
        await _openWorkspaceMenu(anchorContext);
    }
  }

  /// One row of a composer menu — same metrics as the mode menu.
  PopupMenuItem<T> _composerMenuRow<T>({
    required T value,
    required Color iconFg,
    required IconData icon,
    required String label,
    bool isEnabled = true,
    bool isSelected = false,
  }) {
    final Color color = isEnabled ? iconFg : iconFg.withValues(alpha: 0.35);

    return PopupMenuItem<T>(
      value: value,
      enabled: isEnabled,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          AppIcon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          if (isSelected) ...[
            const SizedBox(width: 12),
            AppIcon(Icons.check, size: 18, color: color),
          ],
        ],
      ),
    );
  }

  /// One size for every target in the composer action row: the plus, the
  /// mode pill, the microphone and send. The row reads as one family only if
  /// they share a number — a 36 here and a 38 there is visible, and the
  /// microphone turning into the stop target must not resize anything.
  /// Change this one constant, never a single call site.
  static const double _composerTargetSize = 38;

  /// The gap between two targets of that row. One number, so the spacing is
  /// even from the plus to send.
  static const double _composerTargetGap = 6;

  /// Open a menu anchored to a composer button. It leaves the focus and
  /// so the keyboard alone.
  Future<T?> _showAnchoredComposerMenu<T>({
    required BuildContext anchorContext,
    required List<PopupMenuEntry<T>> items,
  }) {
    final theme = Theme.of(anchorContext);
    return showAnchoredMenu<T>(
      anchorContext,
      items: items,
      color: theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
      borderColor: theme.resolvedIconColor.withValues(alpha: 0.3),
      // The attach and workspace menus are read against the chat behind
      // them, the same as the model picker, so they keep the frame that says
      // where the list ends.
      outlined: true,
    );
  }

  /// The workspace in use, shown beside the mode pill — not floating over
  /// the middle of the chat, where it covered the conversation. Tapping it
  /// opens the same workspace menu the plus button does.
  Widget _buildWorkspaceChip(Color iconFg) {
    final workspace = WorkspaceStorageService.getWorkspace(
      _selectedWorkspaceId!,
    );
    if (workspace == null) return const SizedBox.shrink();

    return Builder(
      builder: (anchorContext) => InkWell(
        onTap: () => _openWorkspaceMenu(anchorContext),
        borderRadius: BorderRadius.circular(19),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: iconFg.withValues(alpha: 0.3),
              width: 1.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                Icons.folder_outlined,
                size: 17,
                color: workspace.displayColor,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  workspace.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: iconFg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The workspace picker: the same anchored menu one level deeper, not a
  /// sheet from the bottom of the screen.
  Future<void> _openWorkspaceMenu(BuildContext anchorContext) async {
    final Color iconFg = Theme.of(anchorContext).resolvedIconColor;
    final workspaces = WorkspaceStorageService.activeProjects;

    final choice = await _showAnchoredComposerMenu<_WorkspaceChoice>(
      anchorContext: anchorContext,
      items: <PopupMenuEntry<_WorkspaceChoice>>[
        _composerMenuRow(
          value: const _WorkspaceChoice.pick(null),
          iconFg: iconFg,
          icon: Icons.close,
          label: 'No workspace',
          isSelected: _selectedWorkspaceId == null,
        ),
        for (final workspace in workspaces)
          _composerMenuRow(
            value: _WorkspaceChoice.pick(workspace.id),
            iconFg: iconFg,
            icon: Icons.folder_outlined,
            label: workspace.name,
            isSelected: workspace.id == _selectedWorkspaceId,
          ),
        _composerMenuRow(
          value: const _WorkspaceChoice.create(),
          iconFg: iconFg,
          icon: Icons.add,
          label: 'New workspace',
        ),
      ],
    );

    if (!mounted || choice == null) return;

    if (choice.create) {
      await MobileWorkspaceHandler.createNewProject(
        context: context,
        onShowSnackBar: showSnackBar,
        onOpenWorkspaceManagement: _openProjectManagement,
      );
      return;
    }

    final String? id = choice.workspaceId;
    setState(() => _selectedWorkspaceId = id);
    showSnackBar(
      id == null
          ? 'Workspace cleared'
          : 'Workspace selected: '
                '${WorkspaceStorageService.getWorkspace(id)?.name ?? id}',
    );
  }

  void _openProjectManagement(String workspaceId) {
    MobileWorkspaceHandler.openProjectManagement(
      context: context,
      workspaceId: workspaceId,
      onStartNewChat: _startNewChatWithProject,
    );
  }

  /// Public entry point for starting a new chat with a workspace context.
  void startNewChatWithWorkspace(String workspaceId) =>
      _startNewChatWithProject(workspaceId);

  void _startNewChatWithProject(String? workspaceId) {
    // Clear current chat and set workspace
    setState(() {
      _activeChatId = null;
      _messages.clear();
      _messageRenderCache.clear();
      messageActionsHandler.cancelEdit();
      _selectedWorkspaceId = workspaceId;
      composerController.clear();
    });
    widget.onChatIdChanged(null);
    if (workspaceId != null) {
      final workspace = WorkspaceStorageService.getWorkspace(workspaceId);
      if (workspace != null) {
        showSnackBar('New chat with workspace: ${workspace.name}');
      }
    }
  }

  /// Build the slim floating pill shown at the top of the chat while a
  /// workspace is selected.
  void _handleFileUploadUpdate(
    String fileId,
    String? markdownContent,
    bool isUploading,
    String? snackBarMessage, {
    List<String>? pageImages,
  }) {
    if (!mounted) return;
    _fileHandler.handleUploadStatusUpdate(
      fileId,
      markdownContent,
      isUploading,
      pageImages: pageImages,
    );
    if (snackBarMessage != null) {
      showSnackBar(snackBarMessage);
    }
    scrollChatToBottom();
  }

  // --- MESSAGE HANDLERS ---

  void _updateToolCallsForMessage(
    int index,
    List<ToolCall> toolCalls,
    String chatId,
  ) {
    final String toolCallsJson = ChatUiHelpers.encodeToolCalls(toolCalls);

    final bool isActiveChat = _activeChatId == chatId;
    if (mounted && isActiveChat && index >= 0 && index < _messages.length) {
      setState(() {
        ChatUiHelpers.replaceMessageField(
          _messages,
          index,
          'toolCalls',
          toolCallsJson,
        );
      });
      unawaited(persistChat());
      return;
    }

    if (!isActiveChat) {
      final bool hasInFlightCalls = toolCalls.any(
        (call) =>
            call.status == ToolCallStatus.running ||
            call.status == ToolCallStatus.pending,
      );
      unawaited(
        persistenceHandler
            .updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: index,
              toolCallsJson: toolCallsJson,
              immediate: !hasInFlightCalls,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint(
                  'updateBackgroundChatMessage (toolCalls) failed: $error',
                );
              }
            }),
      );
    }
  }

  void _handleToolImagesProcessed(
    int index,
    List<String> imagePaths,
    String imageMetasJson,
    String? imageCostEur,
    String? imageGeneratedAt,
    String toolCallsJson,
    String chatId,
  ) {
    if (imagePaths.isEmpty) return;

    final isActiveChat = _activeChatId == chatId;
    if (mounted && isActiveChat && index >= 0 && index < _messages.length) {
      setState(() {
        final message = Map<String, String>.from(_messages[index]);
        message['images'] = jsonEncode(imagePaths);
        message['imageMetas'] = imageMetasJson;
        if (imageCostEur != null) {
          message['imageCostEur'] = imageCostEur;
        }
        if (imageGeneratedAt != null) {
          message['imageGeneratedAt'] = imageGeneratedAt;
        }
        message['toolCalls'] = toolCallsJson;
        _messages[index] = message;
      });
      unawaited(persistChat());
    } else if (!isActiveChat) {
      unawaited(
        persistenceHandler
            .updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: index,
              toolCallsJson: toolCallsJson,
              images: jsonEncode(imagePaths),
              imageMetas: imageMetasJson,
              imageCostEur: imageCostEur,
              imageGeneratedAt: imageGeneratedAt,
              immediate: true,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint(
                  'updateBackgroundChatMessage (toolImages) failed: $error',
                );
              }
            }),
      );
    }
  }

  void _updateContentBlocksForMessage(
    int index,
    String contentBlocksJson,
    String chatId,
  ) {
    final bool isActiveChat = _activeChatId == chatId;
    if (mounted && isActiveChat && index >= 0 && index < _messages.length) {
      setState(() {
        final message = Map<String, String>.from(_messages[index]);
        message['contentBlocks'] = contentBlocksJson;
        _messages[index] = message;
      });
      return;
    }

    if (!isActiveChat) {
      unawaited(
        persistenceHandler
            .updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: index,
              contentBlocksJson: contentBlocksJson,
            )
            .catchError((error) {
              if (kDebugMode) {
                debugPrint(
                  'updateBackgroundChatMessage (contentBlocks) failed: $error',
                );
              }
            }),
      );
    }
  }

  void _updateRequestPayloadForMessage(
    int index,
    String requestPayloadJson,
    String chatId,
  ) {
    final bool isActiveChat = _activeChatId == chatId;
    if (!(mounted && isActiveChat && index >= 0 && index < _messages.length)) {
      return;
    }

    setState(() {
      ChatUiHelpers.replaceMessageField(
        _messages,
        index,
        'debugRequests',
        ChatUiHelpers.appendDebugRequest(
          _messages[index]['debugRequests'],
          requestPayloadJson,
        ),
      );
    });
  }

  Future<void> _finalizeAiMessage(
    int index,
    String content,
    String reasoning,
    String chatId,
    double? tps,
  ) async {
    if (kDebugMode) {
      debugPrint(
        '✅ [FinalizeMessage] chatId: $chatId, index: $index, _activeChatId: $_activeChatId',
      );
    }

    // CRITICAL: Clear flags now that streaming is complete
    // This allows realtime updates and didUpdateWidget to proceed
    if (_isSendingMessage) {
      _isSendingMessage = false;
      if (kDebugMode) {
        debugPrint('✅ [FinalizeMessage] Cleared _isSendingMessage flag');
      }
    }
    // RELEASE GLOBAL LOCK when streaming completes
    if (ChatStorageService.isMessageOperationInProgress) {
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint(
          '🔓 [FinalizeMessage] GLOBAL LOCK RELEASED (stream complete)',
        );
      }
    }

    // Streaming ended: drop the per-token live snapshot so the finalized
    // bubble renders from the persisted message text, not a stale live value.
    ChatRuntimeRegistry.instance.lookup(chatId)?.streamingLive.value = null;

    // Check if this is the active chat (for UI updates)
    final bool isActiveChat = _activeChatId == chatId;

    if (mounted && isActiveChat) {
      // Only check bounds for active chat (where _messages belongs to this chat)
      if (index < 0 || index >= _messages.length) return;

      // Update UI only for active chat
      setState(() {
        final Map<String, String> message = Map<String, String>.from(
          _messages[index],
        );
        message['text'] = content;
        message['reasoning'] = reasoning;
        if (tps != null) message['tps'] = tps.toString();
        // Clear any prior `interrupted` flag — a clean finalize means the
        // assistant body is complete now, so we drop the Continue button.
        if (message['status'] == 'interrupted') {
          message.remove('status');
        }
        // Answer-version pager: on a regenerate, append this fresh answer as a
        // new variant. Content blocks / tool calls / images are written into
        // the message before finalize on mobile, so the snapshot is complete.
        foldRegenVariantOnto(message);
        _messages[index] = message;
      });

      scrollChatToBottom();
      unawaited(persistChat());
      if (_isAppInBackground) {
        unawaited(
          persistenceHandler
              .updateBackgroundChatMessage(
                chatId: chatId,
                messageIndex: index,
                content: content,
                reasoning: reasoning,
                tps: tps?.toString(),
                status: 'sent',
                immediate: true,
              )
              .catchError((error) {
                if (kDebugMode) {
                  debugPrint(
                    'updateBackgroundChatMessage (background-final) failed: $error',
                  );
                }
              }),
        );
      }

      // Drain the message queue — if the user typed while AI was responding.
      _drainPendingMessage();
    } else if (!isActiveChat) {
      // User switched to a different chat - _messages belongs to the OTHER chat!
      // DO NOT check _messages.length - it's the wrong chat's message list.
      //
      // Persist the FULL message list from the streaming snapshot (captured at
      // send start, with the live buffer overlaid) and inject the final answer.
      // This reliably inserts/updates the chat even if it was never persisted
      // yet — the previous single-index update silently dropped the answer when
      // the chat (or its placeholder row) wasn't in storage at flush time,
      // which is exactly the race when you start a NEW chat mid-stream.
      final List<Map<String, dynamic>>? bgMessages = _streamingHandler
          .getBackgroundMessages(chatId);
      if (bgMessages != null && index >= 0 && index < bgMessages.length) {
        final List<Map<String, String>> fullMessages = bgMessages.map((m) {
          final converted = <String, String>{};
          m.forEach((key, value) {
            if (value == null) return;
            converted[key] = value is String ? value : value.toString();
          });
          return converted;
        }).toList();
        fullMessages[index]['text'] = content;
        fullMessages[index]['reasoning'] = reasoning;
        if (tps != null) fullMessages[index]['tps'] = tps.toString();
        if (fullMessages[index]['status'] == 'interrupted') {
          fullMessages[index].remove('status');
        }
        // Answer-version pager: fold the previous answer into this background
        // turn's row from the seed stashed when the user switched away, so a
        // regenerate that finishes off-screen keeps its pager (writes the
        // variants directly into fullMessages[index]).
        foldBackgroundVariantOnto(chatId, fullMessages[index]);
        unawaited(
          persistenceHandler
              .persistChat(
                messages: fullMessages,
                chatId: chatId,
                isOffline: _isOffline,
                silent: true,
              )
              .catchError((error) {
                if (kDebugMode) {
                  debugPrint('persistChat (chat-switched full) failed: $error');
                }
                return null;
              }),
        );
      } else {
        // Fallback: no snapshot available — best-effort single-index update.
        unawaited(
          persistenceHandler
              .updateBackgroundChatMessage(
                chatId: chatId,
                messageIndex: index,
                content: content,
                reasoning: reasoning,
                status: 'sent',
                immediate: true,
              )
              .catchError((error) {
                if (kDebugMode) {
                  debugPrint(
                    'updateBackgroundChatMessage (chat-switched) failed: $error',
                  );
                }
              }),
        );
      }
    }
  }

  /// Cancel a queued follow-up message and restore its text to the composer so
  /// the user can edit or discard it instead of losing it silently.
  void _cancelPendingMessage() {
    final pending = _pendingMessageText;
    if (pending == null) return;
    final bool restore = composerController.text.trim().isEmpty;
    if (mounted) {
      setState(() {
        _pendingMessageText = null;
        if (restore) {
          composerController.text = pending;
          composerController.selection = TextSelection.collapsed(
            offset: pending.length,
          );
        }
      });
    } else {
      _pendingMessageText = null;
    }
  }

  /// If a message was queued while the AI was streaming, inject it into the
  /// text field and trigger a new send cycle.
  void _drainPendingMessage() {
    final pending = _pendingMessageText;
    if (pending == null) return;

    if (kDebugMode) {
      debugPrint(
        '📋 [DrainQueue] Sending queued message (${pending.length} chars)',
      );
    }

    setState(() {
      _pendingMessageText = null;
      composerController.text = pending;
      composerController.selection = TextSelection.collapsed(
        offset: pending.length,
      );
    });
    unawaited(sendMessage());
  }

  @override
  Future<void> sendMessage() async {
    // Prevent double-send on slow network (user tapping send repeatedly)
    if (_isSendingMessage) return;

    // SET GLOBAL LOCK IMMEDIATELY - before any async operations or early returns
    // This prevents didUpdateWidget from loading a different chat during send
    ChatStorageService.isMessageOperationInProgress = true;
    if (kDebugMode) {
      debugPrint('🔒 [SendMessage] GLOBAL LOCK SET');
    }

    if (_isCurrentChatStreaming) {
      // AI is still streaming — queue the message instead of cancelling.
      final text = composerController.text.trim();
      if (text.isNotEmpty) {
        if (mounted) {
          setState(() {
            _pendingMessageText = text;
          });
        } else {
          _pendingMessageText = text;
        }
        composerController.clear();
        if (kDebugMode) {
          debugPrint(
            '📋 [SendMessage] Queued pending message (${text.length} chars)',
          );
        }
      }
      // Do NOT release the global lock — the original streaming operation
      // is still in progress and will release it upon completion.
      return;
    }

    // Offline check happens after the user message is added below so we can
    // enqueue + reflect "pending" in the UI.

    if (_fileHandler.hasUploading) {
      showSnackBar('Upload in progress');
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (uploading)');
      }
      return;
    }

    // Check if a model is selected
    if (selectedModelId.isEmpty) {
      showSnackBar('Please select a model first');
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (no model selected)');
      }
      return;
    }

    // Set flag to block realtime updates during send operation
    _isSendingMessage = true;
    if (kDebugMode) {
      debugPrint(
        '📨 [SendMessage] Starting send, _activeChatId BEFORE: $_activeChatId',
      );
    }

    // CRITICAL FIX: Sync _activeChatId with widget.selectedChatId if out of sync
    // This handles cases where _activeChatId was cleared but user is still on existing chat
    if (_activeChatId == null && widget.selectedChatId != null) {
      _activeChatId = widget.selectedChatId;
      // May be a return to a chat with a background regenerate still running.
      restoreVariantSeedForChat(widget.selectedChatId);
      if (kDebugMode) {
        debugPrint(
          '⚠️ [SendMessage] SYNCED _activeChatId with widget.selectedChatId: $_activeChatId',
        );
      }
    }

    // Credit/free message checks are handled server-side (API returns 402)

    final String originalUserInput = composerController.text.trim();
    final bool hasAttachments = _fileHandler.getUploadedFiles().isNotEmpty;

    if (originalUserInput.isEmpty && !hasAttachments) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (empty input)');
      }
      return;
    }

    // Validate message using MessageCompositionService
    final List<Map<String, dynamic>> apiHistory = _buildApiHistory();
    final MessageCompositionResult validationResult =
        await MessageCompositionService.prepareMessage(
          userInput: originalUserInput,
          attachedFiles: _fileHandler.attachedFiles,
          selectedModelId: selectedModelId,
          apiHistory: apiHistory,
          systemPrompt: _systemPrompt,
          getProviderSlug: ensureProviderSlugForCurrentModel,
        );

    if (!validationResult.isValid) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (invalid message)');
      }
      showSnackBar(validationResult.errorMessage ?? 'Invalid message');
      return;
    }

    // Check if widget was disposed during async operation
    if (!mounted) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint(
          '🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during prepareMessage)',
        );
      }
      return;
    }

    // Generate chat ID if new chat and capture it immediately
    // CRITICAL: Capture the chatId in a local variable to prevent race conditions.
    // _activeChatId could be changed by callbacks during async operations below.
    final bool isNewChat = _activeChatId == null;
    _activeChatId ??= _uuid.v4();
    final String chatIdForThisMessage = _activeChatId!;
    if (kDebugMode) {
      debugPrint(
        '📨 [SendMessage] _activeChatId AFTER: $_activeChatId (isNewChat: $isNewChat)',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '📨 [SendMessage] Using chatIdForThisMessage: $chatIdForThisMessage',
      );
    }

    // Extract prepared values from validation result
    final String displayMessageText = validationResult.displayMessageText!;
    final List<String>? imageDataUrls = validationResult.images;

    // CRITICAL: Capture attached files BEFORE clearing them
    // These need to be passed to the streaming handler for the API call
    final List<AttachedFile> attachedFilesForApi = List.from(
      _fileHandler.attachedFiles,
    );
    if (kDebugMode) {
      debugPrint(
        '📎 [SendMessage] Captured ${attachedFilesForApi.length} attached files for API call',
      );
    }

    // Add user message
    setState(() {
      // Store message with images and attachments (if any)
      final userMessage = {
        'sender': 'user',
        'text': displayMessageText,
        'reasoning': '',
        'modelId': selectedModelId,
        'provider': selectedProviderSlug ?? '',
      };

      // Store images as JSON-encoded string if present
      if (imageDataUrls != null && imageDataUrls.isNotEmpty) {
        userMessage['images'] = jsonEncode(imageDataUrls);
      }

      // Store document attachments as JSON-encoded string if present
      final documentAttachments = attachedFilesForApi
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
      if (attachedFilesForApi.isNotEmpty) {
        userMessage['attachedFilesJson'] = jsonEncode(
          attachedFilesForApi.map((f) => f.toJson()).toList(),
        );
        if (kDebugMode) {
          debugPrint(
            '💾 [AttachmentDebug] Storing ${attachedFilesForApi.length} attached files for resend',
          );
        }
      }

      _messages.add(userMessage);
      // Mark this message so its list item flies up on entrance, and pin it:
      // the question goes to the top of the viewport and the answer arrives
      // underneath it, instead of the list staying glued to the bottom and
      // scrolling the question away after the first few lines.
      _flyInKey = ChatUiHelpers.stableUiKey(userMessage, _uuid);
      _pinnedUiKey = _flyInKey;
      if (kDebugMode) {
        debugPrint(
          '💾 [MessageDebug] Message added to _messages list. Total messages: ${_messages.length}',
        );
      }

      composerController.clear();
      // Always clear attachments after sending (not just uploaded ones)
      // Clear directly without relying on callback since we're already in setState
      if (_fileHandler.attachedFiles.isNotEmpty) {
        _fileHandler.attachedFiles.clear();
      }
      _messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': selectedModelId,
        'provider': selectedProviderSlug ?? '',
        'startedAt': DateTime.now().toIso8601String(),
      });
    });

    final int placeholderIndex = _messages.length - 1;
    composerFocusNode.requestFocus();
    pinMessageToTop();

    // ── Offline short-circuit ──────────────────────────────────────
    // If offline, enqueue the send, flip the user bubble to pending, drop
    // the AI placeholder, persist and bail.  The retry manager replays the
    // send when the network returns.
    if (!NetworkStatusService.isOnline) {
      // Resolve the system prompt the same way the online path does, so the
      // offline replay later behaves identically (workspace context, etc.).
      final resolvedSystemPrompt = await _resolveSystemPromptForSend();
      try {
        final queueId = await OfflineSendCoordinator.enqueue(
          OfflineSendPayload(
            chatId: chatIdForThisMessage,
            messageText: validationResult.aiPromptContent ?? displayMessageText,
            modelId: selectedModelId,
            providerSlug: selectedProviderSlug ?? '',
            systemPrompt: resolvedSystemPrompt,
            imagesJson: imageDataUrls != null && imageDataUrls.isNotEmpty
                ? jsonEncode(imageDataUrls)
                : null,
            maxTokens: validationResult.maxResponseTokens ?? 512,
            reasoningEffort: clampedReasoningEffort(
              selectedModelId,
              selectedProviderSlug,
            ),
          ),
        );
        if (mounted) {
          setState(() {
            final userIdx = placeholderIndex - 1;
            if (userIdx >= 0 && userIdx < _messages.length) {
              _messages[userIdx]['status'] = 'pending';
              _messages[userIdx]['queueId'] = queueId;
            }
            if (placeholderIndex >= 0 &&
                placeholderIndex < _messages.length &&
                _messages[placeholderIndex]['text'] == 'Thinking...') {
              _messages.removeAt(placeholderIndex);
            }
          });
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Mobile-Send] enqueue failed: $e');
        }
        if (mounted) {
          setState(() {
            final userIdx = placeholderIndex - 1;
            if (userIdx >= 0 && userIdx < _messages.length) {
              _messages[userIdx]['status'] = 'failed';
              _messages[userIdx]['lastError'] = e.toString();
            }
            if (placeholderIndex >= 0 &&
                placeholderIndex < _messages.length &&
                _messages[placeholderIndex]['text'] == 'Thinking...') {
              _messages.removeAt(placeholderIndex);
            }
          });
        }
      }
      unawaited(
        persistenceHandler.persistChat(
          messages: _messages,
          chatId: chatIdForThisMessage,
          isOffline: true,
        ),
      );
      // Propagate the new chat ID to the parent so chat-switch behavior
      // stays consistent. Without this the parent thinks selection is
      // still null while this widget already owns chatIdForThisMessage.
      if (isNewChat) {
        widget.onChatIdChanged(chatIdForThisMessage);
      }
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (queued offline)');
      }
      return;
    }

    // Immediately create chat in Supabase for reliable chat ID assignment
    // Use the captured chatIdForThisMessage to ensure consistency
    final storedChat = await persistenceHandler.persistChat(
      messages: _messages,
      chatId: chatIdForThisMessage,
      waitForCompletion: true,
      isOffline: _isOffline,
    );

    // Check if widget was disposed during persist operation
    if (!mounted) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint(
          '🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during persistChat)',
        );
      }
      return;
    }

    // Verify the stored chat ID matches what we expected
    if (storedChat != null && storedChat.id != chatIdForThisMessage) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ [ChatDebug] Chat ID mismatch! Expected: $chatIdForThisMessage, Got: ${storedChat.id}',
        );
      }
    }

    // Keep _activeChatId in sync (should already be correct, but ensure consistency)
    if (storedChat != null) {
      _activeChatId = storedChat.id;

      // ID-BASED: Notify parent when a new chat is created
      if (isNewChat) {
        if (kDebugMode) {
          debugPrint('');
        }
        if (kDebugMode) {
          debugPrint(
            '┌─────────────────────────────────────────────────────────────',
          );
        }
        if (kDebugMode) {
          debugPrint('│ 🆕 [SEND-MOBILE] NEW CHAT CREATED!');
        }
        if (kDebugMode) {
          debugPrint('│ 🆕 [SEND-MOBILE] New chat ID: ${storedChat.id}');
        }
        if (kDebugMode) {
          debugPrint(
            '│ 🆕 [SEND-MOBILE] Calling widget.onChatIdChanged(${storedChat.id})',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ 🆕 [SEND-MOBILE] This should update ChatStorageService.selectedChatId',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '└─────────────────────────────────────────────────────────────',
          );
        }
        widget.onChatIdChanged(storedChat.id);

        // Auto-generate title for new chats (fire and forget)
        unawaited(
          TitleGenerationService.generateAndApplyTitle(
            storedChat.id,
            displayMessageText,
          ).catchError((error) {
            if (kDebugMode) {
              debugPrint('Title generation failed: $error');
            }
          }),
        );
      }
    }

    // Resolve system prompt with workspace context (if any)
    final resolvedSystemPrompt = await _resolveSystemPromptForSend();

    // Send with streaming handler using the CAPTURED chatId, not _activeChatId
    // This prevents race conditions where _activeChatId could be changed by callbacks
    if (kDebugMode) {
      debugPrint(
        '📤 [ChatDebug] Sending to streaming handler with chatId: $chatIdForThisMessage',
      );
    }
    if (kDebugMode) {
      debugPrint(
        '📤 [ChatDebug] Sending ${attachedFilesForApi.length} attached files to API',
      );
    }
    if (_selectedWorkspaceId != null) {
      if (kDebugMode) {
        debugPrint(
          '📁 [ChatDebug] Workspace context included: $_selectedWorkspaceId',
        );
      }
    }
    // NOTE: _isSendingMessage is cleared in _finalizeAiMessage() when streaming completes,
    // NOT here. This prevents race conditions where didUpdateWidget fires while streaming.
    await _streamingHandler.sendMessage(
      userInput: originalUserInput,
      attachedFiles: attachedFilesForApi,
      selectedModelId: selectedModelId,
      selectedProviderSlug: selectedProviderSlug,
      messages: _messages,
      systemPrompt: resolvedSystemPrompt,
      activeChatId: chatIdForThisMessage,
      placeholderIndex: placeholderIndex,
      getProviderSlug: ensureProviderSlugForCurrentModel,
      isOffline: _isOffline,
      includeRecentImagesInHistory: widget.includeRecentImagesInHistory,
      includeAllImagesInHistory: widget.includeAllImagesInHistory,
      includeReasoningInHistory: widget.includeReasoningInHistory,
      includeToolResultsInHistory: widget.includeToolResultsInHistory,
      toolCallingEnabled: widget.toolCallingEnabled,
      toolDiscoveryMode: widget.toolDiscoveryMode,
      reasoningEffort: clampedReasoningEffort(
        selectedModelId,
        selectedProviderSlug,
      ),
    );
  }

  List<Map<String, dynamic>> _buildApiHistory() {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
    for (final Map<String, String> message in _messages) {
      final String? sender = message['sender'];
      final String? text = message['text'];

      if (sender == 'user') {
        if (text == null || text.trim().isEmpty || text == 'Thinking...') {
          continue;
        }
        history.add({'role': 'user', 'content': text});
      } else if (sender == 'ai' || sender == 'assistant') {
        // Include prior tool calls + results so the model can reuse data
        // it already fetched on a follow-up question.
        final assistantContent = formatAssistantContent(
          message,
          includeReasoning: widget.includeReasoningInHistory,
          includeToolResults: widget.includeToolResultsInHistory,
        );
        if (assistantContent == null) continue;
        history.add({'role': 'assistant', 'content': assistantContent});
      }
    }
    return history;
  }

  /// Resolve system prompt with workspace context (if any)
  Future<String?> _resolveSystemPromptForSend() async {
    // Always reload the system prompt from the database so that changes
    // made in SystemPromptPage take effect without restarting the app.
    String? basePrompt;
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
      // Fall back to cached value if reload fails (e.g. offline).
      basePrompt = _systemPrompt;
    }

    var resolvedPrompt = basePrompt;

    // If a workspace is active, prepend workspace context
    if (_selectedWorkspaceId != null && kFeatureWorkspaces) {
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

  void _updateCancelledMessage() {
    // Clear flags since stream was cancelled
    if (_isSendingMessage) {
      _isSendingMessage = false;
      if (kDebugMode) {
        debugPrint('🚫 [CancelledMessage] Cleared _isSendingMessage flag');
      }
    }
    // RELEASE GLOBAL LOCK when stream is cancelled
    if (ChatStorageService.isMessageOperationInProgress) {
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint(
          '🔓 [CancelledMessage] GLOBAL LOCK RELEASED (stream cancelled)',
        );
      }
    }

    if (mounted) {
      setState(() {
        if (_messages.isNotEmpty &&
            (_messages.last['sender'] == 'ai' ||
                _messages.last['sender'] == 'assistant')) {
          final lastMessage = Map<String, String>.from(_messages.last);
          final currentText = lastMessage['text'] ?? '';
          if (currentText.isEmpty || currentText == 'Thinking...') {
            lastMessage['text'] = '[Cancelled]';
          } else if (!currentText.contains('[Response cancelled]')) {
            // Idempotent, as on desktop: cancelling twice (or cancelling a
            // resend of an already-cancelled turn) used to stack the marker.
            lastMessage['text'] = '$currentText\n\n[Response cancelled]';
          }
          _messages[_messages.length - 1] = lastMessage;
        }
      });
      unawaited(persistChat());
    }
  }

  /// Cancel any ongoing operation (streaming or sending)
  Future<void> _cancelCurrentOperation() async {
    // Explicit cancel discards any queued follow-up message too.
    _pendingMessageText = null;

    if (_isCurrentChatStreaming) {
      // Stream is active - cancel via handler
      await _streamingHandler.cancelStream(_activeChatId);
      _updateCancelledMessage();
    } else if (_isSendingMessage) {
      // Only sending flag is set (stream not yet started) - reset state
      _streamingHandler.resetState();
      _isSendingMessage = false;
      if (ChatStorageService.isMessageOperationInProgress) {
        ChatStorageService.isMessageOperationInProgress = false;
      }
      if (mounted) {
        setState(() {});
        showSnackBar('Cancelled');
      }
    }
  }

  @override
  Future<void> submitEditedMessage(
    int index,
    String newText, {
    bool removeFollowingAssistant = true,
    bool clearMessagesBelow = false,
    List<AttachedFile>? attachedFilesOverride,
    bool isRegenerate = false,
  }) async {
    if (index < 0 || index >= _messages.length) return;
    if (_streamingHandler.isStreaming || _streamingHandler.isSending) {
      showSnackBar('Please wait');
      return;
    }
    final String? chatIdAtStart = _activeChatId;

    setState(() {
      _messages[index]['text'] = newText;
      // Reflect the attachment set chosen during editing (the user may have
      // removed images) so the saved bubble and any future edit match it.
      if (attachedFilesOverride != null) {
        ChatUiHelpers.writeAttachmentsToMessage(
          _messages[index],
          attachedFilesOverride,
        );
      }
    });

    // Answer-version pager: on a regenerate, archive the answer being
    // discarded so the fresh answer can be appended as a new variant. Must run
    // BEFORE the tail is removed below.
    final List<Map<String, dynamic>>? regenVariantSeed = isRegenerate
        ? captureRegenSeed(index)
        : null;

    // Before removing AI messages, collect:
    //   * artifact ids they created (legacy fallback for chats whose
    //     version snapshots pre-date message_id stamping),
    //   * message ids so we can roll back the artifact versions those
    //     messages produced. The rollback resets `artifacts.content` to
    //     the latest remaining snapshot, or deletes the artifact entirely
    //     if no prior snapshot exists.
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

    final editedMessagesSnapshot = _messages
        .map(Map<String, String>.from)
        .toList(growable: false);

    // Roll back per-message version history first so prior snapshots
    // survive when an AI message only updated an existing artifact.
    if (discardedMessageIds.isNotEmpty) {
      await ArtifactStorageService.rollbackArtifactsForMessages(
        discardedMessageIds,
      );
    }

    if (artifactIdsToDelete.isNotEmpty) {
      // MUST await. deleteArtifactsByIds prunes the in-memory cache
      // only after the Supabase round-trip; firing it unawaited lets
      // the next loadArtifactsForChat return the ghost artifact which
      // ends up in the system prompt as a "still active" item. Idempotent
      // for ids the rollback above already deleted.
      await ArtifactStorageService.deleteArtifactsByIds(artifactIdsToDelete);
    }

    // Artifact rollback can outlive this State or a chat switch. Never append
    // the replacement assistant row to whichever conversation is visible now.
    if (!mounted || _activeChatId != chatIdAtStart) {
      if (chatIdAtStart != null) {
        await persistenceHandler.persistChat(
          messages: editedMessagesSnapshot,
          chatId: chatIdAtStart,
          waitForCompletion: true,
          isOffline: _isOffline,
          silent: true,
        );
      }
      return;
    }

    // Resend with new text
    final String originalUserInput = newText;
    late int placeholderIndex;

    // Always use the currently selected model and provider for resend
    // This allows users to switch models and resend with the new selection
    final String modelIdToUse = selectedModelId;
    final String? providerToUse = selectedProviderSlug;

    // Update the user message with the new model/provider
    _messages[index]['modelId'] = modelIdToUse;
    _messages[index]['provider'] = providerToUse ?? '';

    final List<AttachedFile> attachedFilesForResend =
        attachedFilesOverride ??
        ChatUiHelpers.reconstructAttachedFilesForResend(
          _messages[index],
          _uuid,
        );
    if (kDebugMode) {
      debugPrint(
        '[ResendDebug] Reconstructed ${attachedFilesForResend.length} attached files for resend',
      );
    }

    // Generate chat ID if needed BEFORE persisting
    _activeChatId ??= _uuid.v4();
    final String chatId = _activeChatId!;

    // Keep builtin tools (artifact_manager, typst_compile) pointing at
    // this chat even if widget.selectedChatId is transiently null
    // during the async resend flow. Without this, the tool handler
    // aborts with "No active chat. Start or select a chat first."
    ChatStorageService.activeMessageChatId = chatId;
    ChatStorageService.selectedChatId ??= chatId;

    // Stamp the new assistant turn with a stable messageId so any
    // artifact versions it produces (create / rewrite / inline tag) are
    // tied to this turn for future regenerate rollbacks. Mirrors the
    // desktop resend path.
    final String assistantMessageId = _uuid.v4();
    ArtifactStorageService.currentMessageId = assistantMessageId;
    // Arm the variant fold for this turn (keyed by the new messageId), or
    // clear it when this is not a regenerate.
    armVariantSeed(regenVariantSeed, assistantMessageId);
    setState(() {
      _messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': modelIdToUse,
        'provider': providerToUse ?? '',
        'messageId': assistantMessageId,
        'startedAt': DateTime.now().toIso8601String(),
      });
      placeholderIndex = _messages.length - 1;
    });

    // Persist immediately after editing - chat ID is now guaranteed to exist
    unawaited(persistChat());
    scrollChatToBottom(force: true);

    // Resolve system prompt with workspace context (if any)
    final resolvedSystemPrompt = await _resolveSystemPromptForSend();

    // Send using streaming handler with preserved model/provider and attached files
    await _streamingHandler.sendMessage(
      userInput: originalUserInput,
      attachedFiles: attachedFilesForResend,
      selectedModelId: modelIdToUse,
      selectedProviderSlug: providerToUse,
      messages: _messages,
      systemPrompt: resolvedSystemPrompt,
      activeChatId: chatId,
      placeholderIndex: placeholderIndex,
      getProviderSlug: () async => providerToUse,
      isOffline: _isOffline,
      includeRecentImagesInHistory: widget.includeRecentImagesInHistory,
      includeAllImagesInHistory: widget.includeAllImagesInHistory,
      includeReasoningInHistory: widget.includeReasoningInHistory,
      includeToolResultsInHistory: widget.includeToolResultsInHistory,
      toolCallingEnabled: widget.toolCallingEnabled,
      toolDiscoveryMode: widget.toolDiscoveryMode,
      reasoningEffort: clampedReasoningEffort(modelIdToUse, providerToUse),
    );
  }

  /// Returns a callback for the ask_user interactive buttons if [index] is
  /// the last AI message, is not streaming, and contains a completed
  /// ask_user tool call. Otherwise returns null.
  ValueChanged<String>? _askUserCallbackForMessage(
    int index,
    MessageRenderData data,
  ) {
    if (data.isUser ||
        data.isStreamingMessage ||
        _isCurrentChatStreaming ||
        _isSendingMessage) {
      return null;
    }
    if (index != _messages.length - 1) {
      return null;
    }

    if (!ChatUiHelpers.hasCompletedTool(data, 'ask_user')) return null;

    return (String answer) {
      composerController.text = answer;
      sendMessage();
    };
  }

  /// Returns a callback for the inline MCP Connect card if [index] is the last
  /// AI message, is idle, and contains a completed request_mcp_server call.
  /// Resumes the same conversation with a fresh send once the server is live.
  ValueChanged<String>? _connectMcpCallbackForMessage(
    int index,
    MessageRenderData data,
  ) {
    if (data.isUser ||
        data.isStreamingMessage ||
        _isCurrentChatStreaming ||
        _isSendingMessage) {
      return null;
    }
    if (index != _messages.length - 1) {
      return null;
    }

    if (!ChatUiHelpers.hasCompletedTool(data, 'request_mcp_server')) {
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

  /// Continue an interrupted assistant message — appends new tokens onto the
  /// existing message instead of creating a fresh placeholder.
  ///
  /// Triggered by the "Continue generation" affordance the bubble renders on
  /// any AI message whose persisted status is [ChatMessageStatus.interrupted].
  Future<void> _continueGenerationAt(int aiIndex) async {
    if (_streamingHandler.isStreaming || _streamingHandler.isSending) {
      showSnackBar('Please wait');
      return;
    }
    final request = ChatUiHelpers.prepareContinuation(
      messages: _messages,
      messageIndex: aiIndex,
      fallbackModelId: selectedModelId,
      fallbackProvider: selectedProviderSlug,
    );
    if (request == null) {
      showSnackBar('Nothing to continue from');
      return;
    }

    // Persist the active chat id even if widget.selectedChatId is null
    // during this async flow — same protection as resend.
    _activeChatId ??= _uuid.v4();
    final String chatId = _activeChatId!;
    final runtime = ChatRuntimeRegistry.instance.get(chatId);
    if (runtime.isSending.value || _streamingHandler.isChatStreaming(chatId)) {
      showSnackBar('Please wait');
      return;
    }
    runtime.isSending.value = true;
    ChatStorageService.activeMessageChatId = chatId;
    ChatStorageService.selectedChatId ??= chatId;

    final continuationKey = ChatUiHelpers.stableUiKey(
      _messages[request.messageIndex],
      _uuid,
    );
    final originalStatus = _messages[request.messageIndex]['status'];
    var handedToStreamingHandler = false;
    setState(() {
      // Flip the status off immediately so the Continue button doesn't
      // double-trigger while the new stream is running.
      final m = Map<String, String>.from(_messages[request.messageIndex]);
      m.remove('status');
      _messages[request.messageIndex] = m;
    });

    try {
      final resolvedSystemPrompt = await _resolveSystemPromptForSend();
      if (!mounted ||
          _activeChatId != chatId ||
          _streamingHandler.isStreaming ||
          _streamingHandler.isSending ||
          request.messageIndex != _messages.length - 1 ||
          _messages[request.messageIndex]['sender'] != 'ai' ||
          ChatUiHelpers.stableUiKey(_messages[request.messageIndex], _uuid) !=
              continuationKey) {
        return;
      }

      handedToStreamingHandler = true;
      await _streamingHandler.sendMessage(
        userInput: ChatUiHelpers.continueGenerationPrompt,
        attachedFiles: const <AttachedFile>[],
        selectedModelId: request.modelId,
        selectedProviderSlug: request.provider,
        messages: request.historyMessages,
        systemPrompt: resolvedSystemPrompt,
        activeChatId: chatId,
        // Stream into the EXISTING assistant message instead of creating a
        // new one — the prior text is seeded into the accumulator below.
        placeholderIndex: request.messageIndex,
        getProviderSlug: () async => request.provider,
        isOffline: _isOffline,
        includeRecentImagesInHistory: widget.includeRecentImagesInHistory,
        includeAllImagesInHistory: widget.includeAllImagesInHistory,
        includeReasoningInHistory: widget.includeReasoningInHistory,
        includeToolResultsInHistory: widget.includeToolResultsInHistory,
        toolCallingEnabled: widget.toolCallingEnabled,
        toolDiscoveryMode: widget.toolDiscoveryMode,
        reasoningEffort: clampedReasoningEffort(
          request.modelId,
          request.provider,
        ),
        continuePriorText: request.priorText,
        continuePriorContentBlocksJson: request.priorContentBlocksJson,
      );
    } finally {
      runtime.isSending.value = false;
      if (!handedToStreamingHandler &&
          mounted &&
          _activeChatId == chatId &&
          request.messageIndex < _messages.length) {
        setState(() {
          final message = Map<String, String>.from(
            _messages[request.messageIndex],
          );
          if (originalStatus == null) {
            message.remove('status');
          } else {
            message['status'] = originalStatus;
          }
          _messages[request.messageIndex] = message;
        });
      }
    }

    if (kDebugMode) {
      debugPrint(
        '🔁 [Continue] resumed AI message ${request.messageIndex} '
        '(priorText chars=${request.priorText.length})',
      );
    }
  }

  // --- FULLSCREEN EDITOR ---

  Future<void> _openFullscreenEditor() async {
    final result = await showFullscreenComposer(
      context,
      initialText: composerController.text,
    );
    if (!mounted) return;
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

  Future<void> _loadSystemPrompt() async {
    try {
      final systemPrompt = await UserPreferencesService.loadSystemPrompt();
      if (!mounted) return;
      setState(() {
        _systemPrompt = systemPrompt;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading system prompt: $e');
      }
    }
  }

  void _openComingSoonFeature(String featureName) {
    if (!mounted) return;
    ChatUiHelpers.openComingSoonFeature(context, featureName);
  }

  @override
  Future<StoredChat?> persistChat({bool waitForCompletion = false}) async {
    return await persistenceHandler.persistChat(
      messages: _messages,
      chatId: _activeChatId,
      waitForCompletion: waitForCompletion,
      isOffline: _isOffline,
    );
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
    final bool hasAttachments = _fileHandler.hasAttachments;
    final bool hasMessages = _messages.isNotEmpty;
    // Fallback estimate, used only for the first frame before MeasureSize
    // reports the composer's real height. Kept close to the real value so
    // there's no visible jump when the measured height lands.
    final double composerEstimate =
        // 46 pill + 8 gap + ~10 disclaimer. Was 153 while the composer was the
        // tall boxed variant; leaving it there over-reserved the first frame.
        64.0 +
        (hasAttachments ? 80.0 : 0.0) +
        (_pendingMessageText != null ? 28.0 : 0.0) +
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
        16.0 +
        // Room for the pinned question to reach the top. Zero when nothing
        // is pinned, and dropped again once the reader has read to the end.
        pinnedExtraSpace;
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
                  hasMessages
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
                                itemCount: _messages.length,
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
                                scrollCacheExtent:
                                    const ScrollCacheExtent.pixels(400.0),
                                itemBuilder: (_, int i) {
                                  final data = _messageRenderCache.build(
                                    messages: _messages,
                                    index: i,
                                    isStreaming: _isCurrentChatStreaming,
                                  );
                                  final actions = messageActionsHandler
                                      .buildActionsForMessage(
                                        index: i,
                                        messageText: data.displayText,
                                        isUser: data.isUser,
                                        isStreaming: data.isStreamingMessage,
                                        onEdit: editMessageAt,
                                        onResendMessage: resendMessageAt,
                                        onBranch: branchFromIndex,
                                      );
                                  final userActions = data.isUser
                                      ? messageActionsHandler
                                            .buildUserMessageActions(
                                              index: i,
                                              messageText: data.displayText,
                                              onEdit: editMessageAt,
                                              onResendMessage: resendMessageAt,
                                            )
                                      : const <MessageBubbleAction>[];
                                  // The message the reader just sent carries
                                  // the pin key, so the scroll mixin can put
                                  // it at the top and hold it there while the
                                  // answer arrives underneath.
                                  final bool isPinned =
                                      hasTopPin &&
                                      _pinnedUiKey != null &&
                                      ChatUiHelpers.stableUiKey(
                                            _messages[i],
                                            _uuid,
                                          ) ==
                                          _pinnedUiKey;
                                  return ChatMessageListItem(
                                    key: isPinned ? pinnedTopKey : null,
                                    messages: _messages,
                                    index: i,
                                    data: data,
                                    uuid: _uuid,
                                    maxWidth: expandedInputWidth,
                                    activeChatId: _activeChatId,
                                    flyInKey: _flyInKey,
                                    showToolCalls: widget.showToolCalls,
                                    showReasoningTokens:
                                        widget.showReasoningTokens,
                                    showModelInfo: widget.showModelInfo,
                                    showTps: widget.showTps,
                                    isEditing:
                                        messageActionsHandler
                                            .editingMessageIndex ==
                                        i,
                                    actions: actions,
                                    userMessageActions: userActions,
                                    onAskUserAnswer: _askUserCallbackForMessage(
                                      i,
                                      data,
                                    ),
                                    onConnectMcpServer:
                                        _connectMcpCallbackForMessage(i, data),
                                    onSwitchVariant: (variant) =>
                                        switchVariantAt(i, variant),
                                    onContinueGeneration:
                                        !data.isUser &&
                                            i == _messages.length - 1 &&
                                            data.status ==
                                                ChatMessageStatus.interrupted &&
                                            !_isCurrentChatStreaming &&
                                            !_isSendingMessage
                                        ? () => _continueGenerationAt(i)
                                        : null,
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
                                // Gone while the keyboard is up: with half
                                // the screen taken by keys, the line is one
                                // more thing between the field and the
                                // conversation, and it has already been read.
                                if (MediaQuery.viewInsetsOf(context).bottom <
                                    80) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    AppLocalizations.of(context)!.aiDisclaimer,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: iconFg.withValues(alpha: 0.7),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
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
          if (_isLoadingChat)
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
  Widget _buildModelControl({
    required bool isCompactMode,
    required Color iconFg,
  }) {
    // Rebuild when capability data hydrates: the reasoning levels below are
    // read synchronously, so a cold start would otherwise keep the graded
    // ladder for a binary/non-reasoning model until an unrelated rebuild.
    return ValueListenableBuilder<int>(
      valueListenable: ModelCapabilitiesService.revision,
      builder: (context, _, _) => KeyedSubtree(
        key: TourKeyRegistry.instance.keyFor(TourSlots.modelDropdown),
        child: ChatModeSelector(
          mode: chatMode,
          showLabel: false,
          // The same height as the round buttons beside it in the composer
          // row; a pill that stands two pixels taller reads as a mistake.
          height: _composerTargetSize,
          selectedModelId: selectedModelId,
          modelLabel:
              selectedModelName ??
              (selectedModelId.isEmpty ? null : selectedModelId),
          customModelLabel: customModelName,
          pickedModels: pickedModels,
          reasoningEffort: ChatModeService.sanitizeReasoningForModel(
            reasoningEffort,
            modelId: selectedModelId,
            providerSlug: selectedProviderSlug ?? '',
          ),
          // The picker options come straight from the server's per-model
          // `supported_efforts` (derived list only as a cold-start fallback),
          // so a level the model does not support can never be offered.
          reasoningLevels: ChatModeService.reasoningLevelsForModel(
            modelId: selectedModelId,
            // Before the provider resolves, use the mode's own default provider
            // so the derived fallback never briefly offers a wrong ladder.
            providerSlug: (selectedProviderSlug?.isNotEmpty ?? false)
                ? selectedProviderSlug!
                : ChatModeService.defaultConfig(chatMode).providerSlug,
          ),
          onReasoningEffortChanged: setReasoningEffort,
          onModeChanged: setChatMode,
          onModelSelected: applyModelSelection,
          onOpenModelScreen: openModelScreen,
        ),
      ),
    );
  }

  // NOTE: this is the pre-aef13a5 composer, restored deliberately.
  //
  // The 'one tall desktop-style box' redesign made the composer's height
  // content-driven, which put it back into the MeasureSize -> setState ->
  // full-screen rebuild loop on every keyboard frame (SafeArea sits inside
  // MeasureSize, so the keyboard's inset change re-measures it). That is why
  // it stopped rising instantly. It also deleted the AnimatedSize around the
  // left pill, which is the animation that felt broken afterwards.
  //
  // The merged model/reasoning pill (_buildModelControl) is kept — only the
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
    final bool hasAttachments = _fileHandler.hasAttachments;
    final bool showStopAction = _isCurrentChatStreaming || _isSendingMessage;
    final bool hasTypedText = composerController.text.trim().isNotEmpty;
    final bool hasText = hasTypedText || hasAttachments;
    final bool showVoiceModeAction = !hasText && kFeatureVoiceMode;
    final bool isRecording = _audioHandler.isMicActive;

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
                files: _fileHandler.attachedFiles,
                onRemove: removeComposerAttachment,
              ),
            ),
          if (messageActionsHandler.isEditing)
            _buildComposerNotice(
              theme: theme,
              icon: Icons.edit,
              label: 'Editing message',
              actionLabel: 'Cancel',
              onAction: cancelEditMessage,
            ),
          if (_pendingMessageText != null)
            _buildComposerNotice(
              theme: theme,
              icon: Icons.schedule,
              label:
                  '${AppLocalizations.of(context)!.queuedLabel}: '
                  '"${_pendingMessageText!}"',
              actionLabel: AppLocalizations.of(context)!.cancel,
              onAction: _cancelPendingMessage,
            ),

          // ── Row one: what you are saying ──
          //
          // The waveform is drawn over the text field, not in place of it:
          // the field keeps its slot in the layout, so the composer is
          // exactly as tall while recording as it is at rest and the thread
          // does not jump the moment the microphone opens.
          ComposerInputRow(
            isRecording: isRecording,
            audioLevels: _audioHandler.audioLevels,
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
                    buttonSize: _composerTargetSize,
                    // Round, so the tap ink is a circle and not a square
                    // patch behind a round icon.
                    cornerRadius: _composerTargetSize / 2,
                    onTap: () => _handleAddAttachmentTap(anchorContext),
                    isActive: hasAttachments,
                    color: iconFg,
                  ),
                ),
              ),
              const SizedBox(width: _composerTargetGap),
              _buildModelControl(isCompactMode: isCompactMode, iconFg: iconFg),
              if (kFeatureWorkspaces && _selectedWorkspaceId != null) ...[
                const SizedBox(width: _composerTargetGap),
                Flexible(child: _buildWorkspaceChip(iconFg)),
              ],
              const Spacer(),
              if (isRecording) ...[
                buildTinyIconButton(
                  icon: Icons.stop_rounded,
                  iconSize: 20,
                  buttonSize: _composerTargetSize,
                  cornerRadius: _composerTargetSize / 2,
                  onTap: _handleMicTap,
                  isActive: true,
                  color: Colors.red,
                  semanticsId: 'mic_button',
                ),
                const SizedBox(width: _composerTargetGap),
              ] else if (!hasTypedText && !showStopAction) ...[
                buildTinyIconButton(
                  icon: Icons.mic,
                  iconSize: 20,
                  buttonSize: _composerTargetSize,
                  cornerRadius: _composerTargetSize / 2,
                  onTap: _handleMicTap,
                  isActive: false,
                  color: iconFg,
                  semanticsId: 'mic_button',
                ),
                const SizedBox(width: _composerTargetGap),
              ] else if (_showFullscreenButton && !showStopAction) ...[
                // Takes the microphone's slot: the microphone only shows with
                // an empty field and this only with a long one, so the two
                // never want the place at the same time. Out here instead of
                // inside the field, the typed text keeps the full width.
                buildTinyIconButton(
                  icon: Icons.open_in_full_rounded,
                  iconSize: 18,
                  buttonSize: _composerTargetSize,
                  cornerRadius: _composerTargetSize / 2,
                  onTap: _openFullscreenEditor,
                  isActive: false,
                  color: iconFg,
                  semanticsId: 'fullscreen_composer_button',
                ),
                const SizedBox(width: _composerTargetGap),
              ],
              buildTinyActionButton(
                icon: isRecording
                    ? Icons.north_rounded
                    : (showStopAction
                          ? Icons.stop_rounded
                          : (showVoiceModeAction
                                ? Icons.graphic_eq_rounded
                                : Icons.north_rounded)),
                buttonSize: _composerTargetSize,
                iconSize: 18,
                onTap: isRecording
                    ? _handleAudioSend
                    : (showStopAction
                          ? _cancelCurrentOperation
                          : (showVoiceModeAction
                                ? () => _openComingSoonFeature('Voice Mode')
                                : sendOrSubmitEdit)),
                color: isRecording
                    ? accent
                    : (showStopAction ? Colors.red : accent),
                isLoading: _audioHandler.isTranscribingAudio,
                semanticsId: 'send_button',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A one-line notice inside the composer: editing, or a queued message.
  Widget _buildComposerNotice({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    final Color color = theme.colorScheme.primary.withValues(alpha: 0.75);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4, right: 6),
      child: Row(
        children: [
          AppIcon(icon, size: 12, color: color),
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
      ),
    );
  }
}
