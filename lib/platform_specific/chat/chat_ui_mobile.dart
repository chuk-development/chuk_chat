// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/services/app_lifecycle_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
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
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/mobile_workspace_handler.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/fullscreen_composer.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/services/artifact_context_service.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';

class ChukChatUIMobile extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final String? selectedChatId;
  final Function(String?) onChatIdChanged;
  final bool isSidebarExpanded;
  final bool showReasoningTokens;
  final bool showModelInfo;
  final bool showTps;
  final bool autoSendVoiceTranscription;
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
  // Tool-calling settings
  final bool toolCallingEnabled;
  final bool toolDiscoveryMode;
  final bool showToolCalls;
  final bool allowMarkdownToolCalls;

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
    this.imageGenEnabled = false,
    this.imageGenDefaultSize = 'landscape_4_3',
    this.imageGenCustomWidth = 1024,
    this.imageGenCustomHeight = 768,
    this.imageGenUseCustomSize = false,
    this.includeRecentImagesInHistory = true,
    this.includeAllImagesInHistory = false,
    this.includeReasoningInHistory = false,
    this.toolCallingEnabled = true,
    this.toolDiscoveryMode = true,
    this.showToolCalls = true,
    this.allowMarkdownToolCalls = true,
  });

  @override
  State<ChukChatUIMobile> createState() => ChukChatUIMobileState();
}

class ChukChatUIMobileState extends State<ChukChatUIMobile> {
  // Controllers and basic state
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  String? _activeChatId;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _composerScrollController = ScrollController();
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();
  final Uuid _uuid = const Uuid();
  bool _lastTextWasEmpty = true;
  bool _showFullscreenButton = false;
  bool _showScrollToBottom = false;
  bool _isInputFocused = false;

  // Services and handlers
  late ChatApiService _chatApiService;
  late final AudioRecordingHandler _audioHandler;
  late final FileAttachmentHandler _fileHandler;
  late final MessageActionsHandler _messageActionsHandler;
  late final ChatPersistenceHandler _persistenceHandler;
  late final StreamingMessageHandler _streamingHandler;

  // Model and provider state
  String _selectedModelId = ''; // Will be loaded from user preferences
  String? _selectedProviderSlug;
  String? _systemPrompt;
  bool _reasoningEnabled = true;
  late final VoidCallback _modelSelectionListener;

  // Stream subscriptions
  StreamSubscription<void>? _providerRefreshSubscription;

  // Network and UI state
  bool _isOffline = false;
  bool _isSendingMessage = false; // Flag to prevent rapid send spam

  /// Queued message text — when the user sends while AI is still streaming,
  /// the text is parked here and dispatched after the current response ends.
  String? _pendingMessageText;
  String? _pendingMessageReplyContext;
  String? _pendingMessageReplyPreviewText;
  String? _pendingReplyContext;
  String? _pendingReplyPreviewText;
  String _pendingReplyPreviewLabel = 'Reply to AI';
  bool _isLoadingChat = false; // Loading indicator for chat switching
  bool _isAppInBackground = false;
  late final VoidCallback _networkStatusListener;
  Timer? _audioVisualizerTimer;

  // Workspace state
  String? _selectedWorkspaceId;

  // Computed property - checks if CURRENT chat is streaming
  bool get _isCurrentChatStreaming =>
      _activeChatId != null &&
      _streamingHandler.isChatStreaming(_activeChatId!);

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kHorizontalPaddingSmall = 8.0;
  static const double _kShowScrollButtonDistance = 260.0;
  static const double _kHideScrollButtonDistance = 140.0;

  @override
  void initState() {
    super.initState();
    _initializeHandlers();
    _initializeListeners();
    AppLifecycleService.instance.addOnResumeCallback(_handleAppResumed);
    AppLifecycleService.instance.addOnPauseCallback(_handleAppPaused);
    _loadInitialData();
  }

  void _initializeHandlers() {
    _chatApiService = ChatApiService(
      onUploadStatusUpdate: _handleFileUploadUpdate,
    );

    _audioHandler = AudioRecordingHandler();

    _fileHandler = FileAttachmentHandler()
      ..initialize(_chatApiService)
      ..onError = _showSnackBar
      ..onUpdate = () {
        if (_audioHandler.isMicActive) {
          // Defer rebuild while mic visualizer is active to avoid flicker.
        } else {
          setState(() {});
        }
      };

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
        }
      };

    _streamingHandler = StreamingMessageHandler()
      ..onShowSnackBar = _showSnackBar
      ..onUpdateUI = () {
        if (mounted) setState(() {});
      }
      ..onMessageUpdate = _updateAiMessage
      ..onMessageFinalize = _finalizeAiMessage
      ..onToolCallsUpdate = _updateToolCallsForMessage
      ..onToolImagesProcessed = _handleToolImagesProcessed
      ..onContentBlocksUpdate = _updateContentBlocksForMessage
      ..onRequestPayloadUpdate = _updateRequestPayloadForMessage
      ..onBackgroundUpdate = (chatId, index, content, reasoning) {
        if (_activeChatId != chatId || _isAppInBackground) {
          unawaited(
            _persistenceHandler.updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: index,
              content: content,
              reasoning: reasoning,
              immediate: _isAppInBackground,
            ).catchError((error) {
              if (kDebugMode) {
                debugPrint('updateBackgroundChatMessage (onBackgroundUpdate) failed: $error');
              }
            }),
          );
        }
      }
      ..onPaymentRequired = _showPaymentRequiredDialog;
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
            Icon(
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
                  Icon(
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
    _scrollController.addListener(_onScrollChanged);

    // Text field focus listener — collapse mic & model buttons while typing
    _textFieldFocusNode.addListener(_onTextFieldFocusChanged);

    // Text controller listener
    _controller.addListener(_onControllerChanged);

    // Request focus if sidebar closed
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.isSidebarExpanded) {
        _textFieldFocusNode.requestFocus();
      }
    });

    // Model selection listener
    _modelSelectionListener = () {
      final String newModelId =
          ModelSelectionDropdown.selectedModelNotifier.value;
      if (newModelId != _selectedModelId) {
        setState(() {
          _selectedModelId = newModelId;
        });
      }
      unawaited(_loadProviderSlugForModel(newModelId));
    };
    ModelSelectionDropdown.selectedModelListenable.addListener(
      _modelSelectionListener,
    );

    // Provider refresh listener
    _providerRefreshSubscription = ModelSelectionEventBus().refreshStream
        .listen((_) {
          // Skip dropdown cache (may be stale) and read from prefs directly
          unawaited(_loadProviderSlugForModel(_selectedModelId, forceFromPrefs: true));
        });

    // Network status listener
    _networkStatusListener = () {
      final bool isOnline = NetworkStatusService.isOnline;
      if (_isOffline != !isOnline) {
        setState(() {
          _isOffline = !isOnline;
        });
        _showSnackBar(isOnline ? 'Back online' : 'You are offline');
      }
    };
    NetworkStatusService.isOnlineListenable.addListener(_networkStatusListener);
  }

  void _onTextFieldFocusChanged() {
    final bool focused = _textFieldFocusNode.hasFocus;
    if (focused != _isInputFocused) {
      setState(() {
        _isInputFocused = focused;
      });
    }
  }

  void _onControllerChanged() {
    final bool currentTextIsEmpty = _controller.text.trim().isEmpty;
    final String text = _controller.text;

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
      unawaited(_loadSavedModelPreference());
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
        _fileHandler.clearAll();
        _controller.clear();
        _messageActionsHandler.cancelEdit();
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
    }
    _persistenceHandler.dispose();
    _audioVisualizerTimer?.cancel();
    _providerRefreshSubscription?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      _networkStatusListener,
    );
    _scrollController.removeListener(_onScrollChanged);
    _textFieldFocusNode.removeListener(_onTextFieldFocusChanged);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _scrollController.dispose();
    _composerScrollController.dispose();
    _textFieldFocusNode.dispose();
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

    // Show loading indicator immediately
    setState(() {
      _isLoadingChat = true;
      _pendingReplyContext = null;
      _pendingReplyPreviewText = null;
      _pendingReplyPreviewLabel = 'Reply to AI';
    });

    // Use async function to handle lazy loading
    _loadChatByIdAsync(chatId, sidebarWasExpanded);
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
      _messages.clear();
      _fileHandler.clearAll();
      _messageActionsHandler.cancelEdit();
      _activeChatId = null;
    } else {
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
          _messages
            ..clear()
            ..addAll(
              storedChat.messages.map((message) {
                final map = <String, String>{
                  'sender': message.sender,
                  'text': message.text,
                  'reasoning': message.reasoning ?? '',
                };
                if (message.modelId != null && message.modelId!.isNotEmpty) {
                  map['modelId'] = message.modelId!;
                }
                if (message.provider != null && message.provider!.isNotEmpty) {
                  map['provider'] = message.provider!;
                }
                // Include images if present
                if (message.images != null && message.images!.isNotEmpty) {
                  map['images'] = message.images!;
                }
                if (message.imageMetas != null &&
                    message.imageMetas!.isNotEmpty) {
                  map['imageMetas'] = message.imageMetas!;
                }
                if (message.imageCostEur != null &&
                    message.imageCostEur!.isNotEmpty) {
                  map['imageCostEur'] = message.imageCostEur!;
                }
                if (message.imageGeneratedAt != null &&
                    message.imageGeneratedAt!.isNotEmpty) {
                  map['imageGeneratedAt'] = message.imageGeneratedAt!;
                }
                // Include attachments if present
                if (message.attachments != null &&
                    message.attachments!.isNotEmpty) {
                  map['attachments'] = message.attachments!;
                  if (kDebugMode) {
                    debugPrint(
                      '📄 [AttachmentDebug] Loading message with attachments field',
                    );
                  }
                }
                // Include attachedFilesJson for retry/resend support
                if (message.attachedFilesJson != null &&
                    message.attachedFilesJson!.isNotEmpty) {
                  map['attachedFilesJson'] = message.attachedFilesJson!;
                }
                if (message.toolCalls != null &&
                    message.toolCalls!.isNotEmpty) {
                  map['toolCalls'] = message.toolCalls!;
                }
                if (message.contentBlocks != null &&
                    message.contentBlocks!.isNotEmpty) {
                  map['contentBlocks'] = message.contentBlocks!;
                }
                if (message.replyContext != null &&
                    message.replyContext!.isNotEmpty) {
                  map['replyContext'] = message.replyContext!;
                }
                return map;
              }),
            );

          final bool shouldRecoverStaleToolCalls =
              !_streamingHandler.isChatStreaming(_activeChatId!) &&
              !_streamingHandler.hasCompletedStream(_activeChatId!);
          if (shouldRecoverStaleToolCalls) {
            var recoveredStaleCalls = false;
            for (final message in _messages) {
              if (ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message)) {
                recoveredStaleCalls = true;
              }
            }

            if (recoveredStaleCalls) {
              unawaited(
                _persistenceHandler.persistChat(
                  messages: _messages
                      .map((m) => Map<String, String>.from(m))
                      .toList(),
                  chatId: _activeChatId,
                  waitForCompletion: false,
                  isOffline: _isOffline,
                  silent: true,
                ).catchError((error) {
                  if (kDebugMode) {
                    debugPrint('persistChat (recover stale) failed: $error');
                  }
                  return null;
                }),
              );
            }
          }
        } else {
          // Chat load failed - treat as new chat
          if (kDebugMode) {
            debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Chat $chatId load failed!');
          }
          _messages.clear();
          _fileHandler.clearAll();
          _messageActionsHandler.cancelEdit();
          _activeChatId = null;
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
        _messages.clear();
        _fileHandler.clearAll();
        _messageActionsHandler.cancelEdit();
        _activeChatId = null;
      }
    }

    // Check for background streaming (still active) or completed stream
    final bool chatIsStreaming =
        _activeChatId != null &&
        _streamingHandler.isChatStreaming(_activeChatId!);
    final bool chatHasCompletedStream =
        _activeChatId != null &&
        _streamingHandler.hasCompletedStream(_activeChatId!);

    if (_activeChatId != null && (chatIsStreaming || chatHasCompletedStream)) {
      final int? streamingMsgIndex = _streamingHandler.getStreamingMessageIndex(
        _activeChatId!,
      );
      if (streamingMsgIndex != null &&
          streamingMsgIndex >= 0 &&
          streamingMsgIndex < _messages.length) {
        final String? bufferedContent = _streamingHandler.getBufferedContent(
          _activeChatId!,
        );
        final String? bufferedReasoning = _streamingHandler
            .getBufferedReasoning(_activeChatId!);

        if (bufferedContent != null) {
          final Map<String, String> updatedMessage = Map<String, String>.from(
            _messages[streamingMsgIndex],
          );
          updatedMessage['text'] = bufferedContent;
          updatedMessage['reasoning'] = bufferedReasoning ?? '';
          _messages[streamingMsgIndex] = updatedMessage;
          // Clean up completed stream data only after successful application
          if (chatHasCompletedStream) {
            _streamingHandler.consumeCompletedStream(_activeChatId!);
          }
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoadingChat = false;
      _showScrollToBottom = false;
    });
    _scrollChatToBottom(force: true);
    // Use captured sidebar state to prevent focus when sidebar was open
    if (!sidebarWasExpanded && !widget.isSidebarExpanded) {
      _textFieldFocusNode.requestFocus();
    }
  }

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

  /// Whether reasoning is enabled for the current model. Debug only.
  bool get debugReasoningEnabled => _reasoningEnabled;

  /// Current active chat id. Debug only.
  String? get debugActiveChatId => _activeChatId;

  void newChat() {
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

    // Clear UI immediately for instant response
    setState(() {
      _messages.clear();
      _activeChatId = null;
      _fileHandler.clearAll();
      _controller.clear();
      _messageActionsHandler.cancelEdit();
    });

    // Notify parent that we're now on a new chat (null ID)
    widget.onChatIdChanged(null);
    if (kDebugMode) {
      debugPrint('🆕 [NewChat] After setState, _activeChatId: $_activeChatId');
    }
    _scrollChatToBottom(force: true);
    if (!widget.isSidebarExpanded) {
      _textFieldFocusNode.requestFocus();
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
        _persistenceHandler.persistChat(
          messages: messagesToSave,
          chatId: chatIdToSave,
          waitForCompletion: false,
          isOffline: _isOffline,
          silent: true,
        ).catchError((error) {
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
        // Drive visualizer updates from recorder/PCM callbacks directly.
        // This avoids unnecessary full-screen rebuilds while attachments upload.
        _audioHandler.onLevelsChanged = () {
          if (mounted && _audioHandler.isMicActive) {
            setState(() {});
          }
        };
      } else {
        _showSnackBar('Mic access failed');
      }
    }
  }

  Future<void> _handleAudioSend() async {
    if (!_audioHandler.isMicActive || _audioHandler.isTranscribingAudio) {
      return;
    }

    await _audioHandler.stopRecording(keepFile: true);
    _audioHandler.onLevelsChanged = null;
    _audioVisualizerTimer?.cancel();
    _audioVisualizerTimer = null;
    if (!mounted) return;
    setState(() {
      _audioHandler.resetAudioLevels();
    });

    final session = await _streamingHandler.getSessionSafely();
    if (session == null) return;

    // Mark transcribing immediately so the send button shows loading spinner
    // before the async transcription call sets it internally.
    _audioHandler.setTranscribing(true);
    if (mounted) setState(() {});

    final result = await _audioHandler.transcribeLastRecording(
      apiService: _chatApiService,
      accessToken: session.accessToken,
    );

    if (!mounted) return;

    if (result.requiresLogout) {
      await SupabaseService.signOut();
    }

    if (!result.success) {
      _showSnackBar(
        result.error ?? AppLocalizations.of(context)!.transcriptionFailed,
      );
      setState(() {}); // Trigger UI update to hide loading icon
      return;
    }

    if (result.text != null && result.text!.isNotEmpty) {
      setState(() {
        _controller.text = result.text!;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: result.text!.length),
        );
      });

      // If auto-send is enabled, send the message immediately.
      // Do NOT set _isSendingMessage here — _sendMessage() guards on that flag
      // at its top and would bail before doing any work. _sendMessage() sets
      // the flag itself once it passes the guard.
      if (widget.autoSendVoiceTranscription) {
        await _sendMessage();
      } else {
        // Otherwise, focus the text field so user can review before sending
        _textFieldFocusNode.requestFocus();
      }
    }
  }

  // --- FILE HANDLERS ---

  void _handleAddAttachmentTap() {
    if (!mounted) return;
    final theme = Theme.of(context);
    final bool supportsImages = _modelSupportsImageInput;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final Color indicatorColor = theme.dividerColor.withValues(alpha: 0.3);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 16),
                if (!supportsImages) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.7,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This model does not support images',
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.8,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.photo_camera_outlined,
                      label: AppLocalizations.of(sheetContext)!.camera,
                      isEnabled: supportsImages,
                      onTap: () {
                        if (!supportsImages) return;
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          _fileHandler.pickImageFromSource(
                            ImageSource.camera,
                            supportsImages: supportsImages,
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                    buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.photo_library_outlined,
                      label: AppLocalizations.of(sheetContext)!.photos,
                      isEnabled: supportsImages,
                      onTap: () {
                        if (!supportsImages) return;
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          _fileHandler.pickImagesFromGallery(
                            supportsImages: supportsImages,
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                    buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.attach_file,
                      label: AppLocalizations.of(sheetContext)!.files,
                      isEnabled: true,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          _fileHandler.uploadFiles(
                            supportsImages: supportsImages,
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.tag_rounded,
                      label: 'Model',
                      isEnabled: true,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        // Show model selection as a separate bottom sheet
                        Future<void>.delayed(
                          const Duration(milliseconds: 200),
                          () {
                            if (!mounted) return;
                            ModelSelectionDropdown.showModelSelectionSheet(
                              context,
                              currentModelId: _selectedModelId,
                              onModelSelected: (newModelId) {
                                setState(() {
                                  _selectedModelId = newModelId;
                                });
                              },
                            );
                          },
                        );
                      },
                    ),
                    // Spacers to keep the single option left-aligned at 1/3 width
                    const SizedBox(width: 12),
                    const Spacer(),
                    const SizedBox(width: 12),
                    const Spacer(),
                  ],
                ),
                // Workspace selection row (when feature enabled)
                if (kFeatureWorkspaces) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      buildAttachmentSheetOption(
                        context: sheetContext,
                        icon: _selectedWorkspaceId != null
                            ? Icons.folder_open
                            : Icons.folder_outlined,
                        label: 'Workspace',
                        isEnabled: true,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          _showProjectSelectionSheet();
                        },
                      ),
                    ],
                  ),
                  if (_selectedWorkspaceId != null) ...[
                    const SizedBox(height: 8),
                    _buildSelectedProjectBadge(theme),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Show workspace selection bottom sheet
  void _showProjectSelectionSheet() {
    MobileWorkspaceHandler.showProjectSelectionSheet(
      context: context,
      selectedWorkspaceId: _selectedWorkspaceId,
      activeChatId: _activeChatId,
      onWorkspaceSelected: (workspaceId) {
        if (!mounted) return;
        setState(() {
          _selectedWorkspaceId = workspaceId;
        });
      },
      onShowSnackBar: _showSnackBar,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
      onOpenWorkspaceManagement: _openProjectManagement,
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
      _messageActionsHandler.cancelEdit();
      _selectedWorkspaceId = workspaceId;
      _controller.clear();
    });
    widget.onChatIdChanged(null);
    if (workspaceId != null) {
      final workspace = WorkspaceStorageService.getWorkspace(workspaceId);
      if (workspace != null) {
        _showSnackBar('New chat with workspace: ${workspace.name}');
      }
    }
  }

  Widget _buildSelectedProjectBadge(ThemeData theme) {
    return MobileWorkspaceHandler.buildSelectedProjectBadge(
      theme: theme,
      selectedWorkspaceId: _selectedWorkspaceId!,
      onClearProject: () {
        setState(() {
          _selectedWorkspaceId = null;
        });
      },
    );
  }

  /// Build the slim floating pill shown at the top of the chat while a
  /// workspace is selected.
  Widget _buildTopProjectPill(ThemeData theme) {
    return MobileWorkspaceHandler.buildTopProjectPill(
      theme: theme,
      selectedWorkspaceId: _selectedWorkspaceId!,
      onClearProject: () {
        setState(() {
          _selectedWorkspaceId = null;
        });
      },
    );
  }

  void _handleFileUploadUpdate(
    String fileId,
    String? markdownContent,
    bool isUploading,
    String? snackBarMessage,
  ) {
    if (!mounted) return;
    _fileHandler.handleUploadStatusUpdate(fileId, markdownContent, isUploading);
    if (snackBarMessage != null) {
      _showSnackBar(snackBarMessage);
    }
    _scrollChatToBottom();
  }

  // --- MESSAGE HANDLERS ---

  void _updateAiMessage(
    int index,
    String content,
    String reasoning,
    String chatId,
  ) {
    if (!mounted || index < 0 || index >= _messages.length) return;
    if (_activeChatId != chatId) return;

    setState(() {
      final Map<String, String> message = Map<String, String>.from(
        _messages[index],
      );
      message['text'] = content;
      message['reasoning'] = reasoning;
      _messages[index] = message;
    });

    _scrollChatToBottom();
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
      _persistChat();
      return;
    }

    if (!isActiveChat) {
      final bool hasInFlightCalls = toolCalls.any(
        (call) =>
            call.status == ToolCallStatus.running ||
            call.status == ToolCallStatus.pending,
      );
      unawaited(
        _persistenceHandler.updateBackgroundChatMessage(
          chatId: chatId,
          messageIndex: index,
          toolCallsJson: toolCallsJson,
          immediate: !hasInFlightCalls,
        ).catchError((error) {
          if (kDebugMode) {
            debugPrint('updateBackgroundChatMessage (toolCalls) failed: $error');
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
      _persistChat();
    } else if (!isActiveChat) {
      unawaited(
        _persistenceHandler.updateBackgroundChatMessage(
          chatId: chatId,
          messageIndex: index,
          toolCallsJson: toolCallsJson,
          images: jsonEncode(imagePaths),
          imageMetas: imageMetasJson,
          imageCostEur: imageCostEur,
          imageGeneratedAt: imageGeneratedAt,
          immediate: true,
        ).catchError((error) {
          if (kDebugMode) {
            debugPrint('updateBackgroundChatMessage (toolImages) failed: $error');
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
        _persistenceHandler.updateBackgroundChatMessage(
          chatId: chatId,
          messageIndex: index,
          contentBlocksJson: contentBlocksJson,
        ).catchError((error) {
          if (kDebugMode) {
            debugPrint('updateBackgroundChatMessage (contentBlocks) failed: $error');
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
      final message = Map<String, String>.from(_messages[index]);
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
      _messages[index] = message;
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
        _messages[index] = message;
      });

      _scrollChatToBottom();
      _persistChat();
      if (_isAppInBackground) {
        unawaited(
          _persistenceHandler.updateBackgroundChatMessage(
            chatId: chatId,
            messageIndex: index,
            content: content,
            reasoning: reasoning,
            tps: tps?.toString(),
            immediate: true,
          ).catchError((error) {
            if (kDebugMode) {
              debugPrint('updateBackgroundChatMessage (background-final) failed: $error');
            }
          }),
        );
      }

      // Drain the message queue — if the user typed while AI was responding.
      _drainPendingMessage();
    } else if (!isActiveChat) {
      // User switched to a different chat - _messages belongs to the OTHER chat!
      // DO NOT check _messages.length - it's the wrong chat's message list.
      // Persist using the background update handler which reads from storage.
      unawaited(
        _persistenceHandler.updateBackgroundChatMessage(
          chatId: chatId,
          messageIndex: index,
          content: content,
          reasoning: reasoning,
          immediate: true,
        ).catchError((error) {
          if (kDebugMode) {
            debugPrint('updateBackgroundChatMessage (chat-switched) failed: $error');
          }
        }),
      );
    }
  }

  /// If a message was queued while the AI was streaming, inject it into the
  /// text field and trigger a new send cycle.
  void _drainPendingMessage() {
    final pending = _pendingMessageText;
    if (pending == null) return;
    final pendingReplyContext = _pendingMessageReplyContext;
    final pendingReplyPreview = _pendingMessageReplyPreviewText;
    _pendingMessageText = null;
    _pendingMessageReplyContext = null;
    _pendingMessageReplyPreviewText = null;

    if (kDebugMode) {
      debugPrint(
        '📋 [DrainQueue] Sending queued message (${pending.length} chars)',
      );
    }

    setState(() {
      _pendingReplyContext = pendingReplyContext;
      _pendingReplyPreviewText = pendingReplyPreview;
      _pendingReplyPreviewLabel = pendingReplyPreview != null
          ? ChatUiHelpers.extractReplyPreviewLabel(pendingReplyContext)
          : 'Reply to AI';
      _controller.text = pending;
      _controller.selection = TextSelection.collapsed(offset: pending.length);
    });
    unawaited(_sendMessage());
  }

  void _clearPendingReplyContext() {
    if (!mounted) return;
    setState(() {
      _pendingReplyContext = null;
      _pendingReplyPreviewText = null;
      _pendingReplyPreviewLabel = 'Reply to AI';
    });
  }

  void _setPendingReplyContext({
    required int messageIndex,
    required int blockIndex,
    required String blockType,
    required String blockText,
  }) {
    final String trimmed = blockText.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final String replyContext = ChatUiHelpers.buildReplyContextJson(
      sourceMessageIndex: messageIndex,
      sourceBlockIndex: blockIndex,
      blockType: blockType,
      blockText: trimmed,
    );
    final String? preview = ChatUiHelpers.extractReplyPreviewText(replyContext);
    if (!mounted || preview == null || preview.isEmpty) return;

    setState(() {
      _pendingReplyContext = replyContext;
      _pendingReplyPreviewText = preview;
      _pendingReplyPreviewLabel = ChatUiHelpers.extractReplyPreviewLabel(
        replyContext,
      );
    });
    _textFieldFocusNode.requestFocus();
    _showSnackBar('Reply target selected');
  }

  Future<void> _sendMessage() async {
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
      final text = _controller.text.trim();
      if (text.isNotEmpty) {
        _pendingMessageText = text;
        _pendingMessageReplyContext = _pendingReplyContext;
        _pendingMessageReplyPreviewText = _pendingReplyPreviewText;
        _controller.clear();
        if (mounted) {
          setState(() {
            _pendingReplyContext = null;
            _pendingReplyPreviewText = null;
            _pendingReplyPreviewLabel = 'Reply to AI';
          });
        } else {
          _pendingReplyContext = null;
          _pendingReplyPreviewText = null;
          _pendingReplyPreviewLabel = 'Reply to AI';
        }
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

    if (_isOffline) {
      _showSnackBar('You are offline. Please check your connection.');
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (offline)');
      }
      return;
    }

    if (_fileHandler.hasUploading) {
      _showSnackBar('Upload in progress');
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (uploading)');
      }
      return;
    }

    // Check if a model is selected
    if (_selectedModelId.isEmpty) {
      _showSnackBar('Please select a model first');
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
      if (kDebugMode) {
        debugPrint(
          '⚠️ [SendMessage] SYNCED _activeChatId with widget.selectedChatId: $_activeChatId',
        );
      }
    }

    // Credit/free message checks are handled server-side (API returns 402)

    final String originalUserInput = _controller.text.trim();
    final String? replyContextForMessage = _pendingReplyContext;
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
          selectedModelId: _selectedModelId,
          apiHistory: apiHistory,
          replyContextJson: replyContextForMessage,
          systemPrompt: _systemPrompt,
          getProviderSlug: _ensureProviderSlugForCurrentModel,
        );

    if (!validationResult.isValid) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (invalid message)');
      }
      _showSnackBar(validationResult.errorMessage ?? 'Invalid message');
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
        'modelId': _selectedModelId,
        'provider': _selectedProviderSlug ?? '',
      };

      // Store images as JSON-encoded string if present
      if (imageDataUrls != null && imageDataUrls.isNotEmpty) {
        userMessage['images'] = jsonEncode(imageDataUrls);
      }
      if (replyContextForMessage != null && replyContextForMessage.isNotEmpty) {
        userMessage['replyContext'] = replyContextForMessage;
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
      if (kDebugMode) {
        debugPrint(
          '💾 [MessageDebug] Message added to _messages list. Total messages: ${_messages.length}',
        );
      }

      _controller.clear();
      _pendingReplyContext = null;
      _pendingReplyPreviewText = null;
      _pendingReplyPreviewLabel = 'Reply to AI';
      // Always clear attachments after sending (not just uploaded ones)
      // Clear directly without relying on callback since we're already in setState
      if (_fileHandler.attachedFiles.isNotEmpty) {
        _fileHandler.attachedFiles.clear();
      }
      _messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': _selectedModelId,
        'provider': _selectedProviderSlug ?? '',
      });
    });

    final int placeholderIndex = _messages.length - 1;
    _textFieldFocusNode.requestFocus();
    _scrollChatToBottom(force: true);

    // Immediately create chat in Supabase for reliable chat ID assignment
    // Use the captured chatIdForThisMessage to ensure consistency
    final storedChat = await _persistenceHandler.persistChat(
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
      replyContextJson: replyContextForMessage,
      selectedModelId: _selectedModelId,
      selectedProviderSlug: _selectedProviderSlug,
      messages: _messages,
      systemPrompt: resolvedSystemPrompt,
      activeChatId: chatIdForThisMessage,
      placeholderIndex: placeholderIndex,
      getProviderSlug: _ensureProviderSlugForCurrentModel,
      isOffline: _isOffline,
      includeRecentImagesInHistory: widget.includeRecentImagesInHistory,
      includeAllImagesInHistory: widget.includeAllImagesInHistory,
      includeReasoningInHistory: widget.includeReasoningInHistory,
      toolCallingEnabled: widget.toolCallingEnabled,
      toolDiscoveryMode: widget.toolDiscoveryMode,
      allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
      reasoningEffort: _reasoningEnabled ? null : 'none',
    );
  }

  List<Map<String, dynamic>> _buildApiHistory() {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
    for (final Map<String, String> message in _messages) {
      final String? sender = message['sender'];
      final String? text = message['text'];
      if (text == null || text.trim().isEmpty || text == 'Thinking...') {
        continue;
      }

      if (sender == 'user') {
        history.add({'role': 'user', 'content': text});
      } else if (sender == 'ai' || sender == 'assistant') {
        history.add({'role': 'assistant', 'content': text});
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
          } else {
            lastMessage['text'] = '$currentText\n\n[Response cancelled]';
          }
          _messages[_messages.length - 1] = lastMessage;
        }
      });
      _persistChat();
    }
  }

  /// Cancel any ongoing operation (streaming or sending)
  Future<void> _cancelCurrentOperation() async {
    // Explicit cancel discards any queued follow-up message too.
    _pendingMessageText = null;
    _pendingMessageReplyContext = null;
    _pendingMessageReplyPreviewText = null;

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
        _showSnackBar('Cancelled');
      }
    }
  }

  Future<void> _submitEditedMessage(
    int index,
    String newText, {
    bool removeFollowingAssistant = true,
    bool clearMessagesBelow = false,
  }) async {
    if (index < 0 || index >= _messages.length) return;
    if (_streamingHandler.isStreaming || _streamingHandler.isSending) {
      _showSnackBar('Please wait');
      return;
    }

    setState(() {
      _messages[index]['text'] = newText;
    });

    // Before removing AI messages, collect artifact ids they emitted so the
    // backing artifact rows get deleted alongside the messages that created
    // them — otherwise resend leaves orphan artifact cards in the chat.
    final artifactIdsToDelete = <String>{};
    void collectArtifactsFrom(int start, int end) {
      for (int i = start; i < end && i < _messages.length; i++) {
        if (_messages[i]['sender'] != 'ai') continue;
        artifactIdsToDelete.addAll(
          ChatUiHelpers.extractArtifactIdsFromRawMessage(_messages[i]),
        );
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

    if (artifactIdsToDelete.isNotEmpty) {
      // MUST await. deleteArtifactsByIds prunes the in-memory cache
      // only after the Supabase round-trip; firing it unawaited lets
      // the next loadArtifactsForChat return the ghost artifact which
      // ends up in the system prompt as a "still active" item.
      await ArtifactStorageService.deleteArtifactsByIds(
        artifactIdsToDelete,
      );
    }

    // Resend with new text
    final String originalUserInput = newText;
    late int placeholderIndex;

    // Always use the currently selected model and provider for resend
    // This allows users to switch models and resend with the new selection
    final String modelIdToUse = _selectedModelId;
    final String? providerToUse = _selectedProviderSlug;

    // Update the user message with the new model/provider
    _messages[index]['modelId'] = modelIdToUse;
    _messages[index]['provider'] = providerToUse ?? '';

    // Reconstruct attached files from stored JSON for resend
    List<AttachedFile> attachedFilesForResend = [];
    final String? attachedFilesJson = _messages[index]['attachedFilesJson'];
    if (attachedFilesJson != null && attachedFilesJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(attachedFilesJson);
        if (decoded is List) {
          attachedFilesForResend = decoded
              .map(
                (item) => AttachedFile.fromJson(item as Map<String, dynamic>),
              )
              .toList();
          if (kDebugMode) {
            debugPrint(
              '🔄 [ResendDebug] Reconstructed ${attachedFilesForResend.length} attached files for resend',
            );
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('🔄 [ResendDebug] Failed to parse attachedFilesJson: $e');
        }
      }
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

    setState(() {
      _messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': modelIdToUse,
        'provider': providerToUse ?? '',
      });
      placeholderIndex = _messages.length - 1;
    });

    // Persist immediately after editing - chat ID is now guaranteed to exist
    _persistChat();
    _scrollChatToBottom(force: true);

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
      toolCallingEnabled: widget.toolCallingEnabled,
      toolDiscoveryMode: widget.toolDiscoveryMode,
      allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
      reasoningEffort: _reasoningEnabled ? null : 'none',
    );
  }

  /// Returns a callback for the ask_user interactive buttons if [index] is
  /// the last AI message, is not streaming, and contains a completed
  /// ask_user tool call. Otherwise returns null.
  ValueChanged<String>? _askUserCallbackForMessage({
    required int index,
    required bool isUser,
    required bool isStreaming,
    required List<ToolCall>? toolCalls,
    required List<ContentBlock>? contentBlocks,
  }) {
    if (isUser || isStreaming || _isCurrentChatStreaming || _isSendingMessage) {
      return null;
    }
    if (index != _messages.length - 1) {
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
      _controller.text = answer;
      _sendMessage();
    };
  }

  void _editMessageAt(int index) {
    if (index < 0 || index >= _messages.length) return;
    final String text = (_messages[index]['text'] ?? '').trim();
    if (text.isEmpty) return;
    setState(() {
      _messageActionsHandler.startEdit(index);
      _pendingReplyContext = null;
      _pendingReplyPreviewText = null;
      _pendingReplyPreviewLabel = 'Reply to AI';
      _controller.text = text;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
    });
    _textFieldFocusNode.requestFocus();
  }

  void _cancelEditMessage() {
    setState(() {
      _messageActionsHandler.cancelEdit();
      _controller.clear();
    });
  }

  /// Sends the message, or submits an edited message if in edit mode.
  Future<void> _sendOrSubmitEdit() async {
    if (_messageActionsHandler.isEditing) {
      final editIndex = _messageActionsHandler.editingMessageIndex!;
      final newText = _controller.text.trim();
      _cancelEditMessage();
      if (newText.isNotEmpty) {
        await _submitEditedMessage(
          editIndex,
          newText,
          removeFollowingAssistant: false,
          clearMessagesBelow: true,
        );
      }
    } else {
      await _sendMessage();
    }
  }

  Future<void> _resendMessageAt(int index) async {
    if (index < 0 || index >= _messages.length) return;

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

    if (sourceIndex < 0 || sourceIndex >= _messages.length) {
      _showSnackBar(AppLocalizations.of(context)!.nothingToResend);
      return;
    }

    final String text = (_messages[sourceIndex]['text'] ?? '').trim();
    if (text.isEmpty) {
      _showSnackBar(AppLocalizations.of(context)!.nothingToResend);
      return;
    }
    await _submitEditedMessage(
      sourceIndex,
      text,
      removeFollowingAssistant: false,
      clearMessagesBelow: true,
    );
  }

  // --- FULLSCREEN EDITOR ---

  Future<void> _openFullscreenEditor() async {
    final result = await showFullscreenComposer(
      context,
      initialText: _controller.text,
    );
    if (result != null) {
      setState(() {
        _controller.text = result;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: result.length),
        );
      });
    }
  }

  // --- UTILITY METHODS ---

  Future<void> _loadProviderSlugForModel(String modelId, {bool forceFromPrefs = false}) async {
    if (modelId.isEmpty) {
      if (_selectedProviderSlug != null) {
        setState(() {
          _selectedProviderSlug = null;
        });
      }
      return;
    }

    if (!forceFromPrefs) {
      final String? dropdownSlug = ModelSelectionDropdown.providerSlugForModel(
        modelId,
      );
      if (dropdownSlug != null && dropdownSlug.isNotEmpty) {
        if (_selectedProviderSlug != dropdownSlug) {
          setState(() {
            _selectedProviderSlug = dropdownSlug;
          });
        }
        return;
      }
    }

    final String? loadedSlug =
        await UserPreferencesService.loadSelectedProvider(modelId);
    if (!mounted) return;
    if (_selectedProviderSlug != loadedSlug) {
      setState(() {
        _selectedProviderSlug = loadedSlug;
      });
    }
  }

  Future<String?> _ensureProviderSlugForCurrentModel() async {
    if (_selectedModelId.isEmpty) return null;
    if (_selectedProviderSlug != null && _selectedProviderSlug!.isNotEmpty) {
      return _selectedProviderSlug;
    }
    await _loadProviderSlugForModel(_selectedModelId);
    return _selectedProviderSlug;
  }

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

  /// Load the user's saved model preference
  Future<void> _loadSavedModelPreference() async {
    try {
      final savedModelId = await UserPreferencesService.loadSelectedModel();
      if (!mounted) return;

      if (savedModelId != null && savedModelId.isNotEmpty) {
        setState(() {
          _selectedModelId = savedModelId;
        });
        if (kDebugMode) {
          debugPrint('Loaded saved model preference: $savedModelId');
        }
        // Update the global notifier so dropdown stays in sync
        ModelSelectionDropdown.selectedModelNotifier.value = savedModelId;
        await _loadProviderSlugForModel(savedModelId);
      } else {
        // No cached model — force-fetch from Supabase (trigger sets default)
        if (kDebugMode) {
          debugPrint(
            'No cached model preference, fetching default from Supabase',
          );
        }
        final defaultModelId =
            await UserPreferencesService.forceLoadSelectedModel();
        if (!mounted) return;
        if (defaultModelId != null && defaultModelId.isNotEmpty) {
          setState(() {
            _selectedModelId = defaultModelId;
          });
          ModelSelectionDropdown.selectedModelNotifier.value = defaultModelId;
          await _loadProviderSlugForModel(defaultModelId);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading saved model preference: $e');
      }
    }
  }

  bool get _modelSupportsImageInput =>
      ChatUiHelpers.modelSupportsImageInput(_selectedModelId);

  void _openComingSoonFeature(String featureName) {
    if (!mounted) return;
    ChatUiHelpers.openComingSoonFeature(context, featureName);
  }

  void _showSnackBar(String message) {
    ChatUiHelpers.showSnackBar(context, message);
  }

  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final distanceToBottom = position.maxScrollExtent - position.pixels;

    bool nextShowScrollButton = _showScrollToBottom;
    if (!_showScrollToBottom && distanceToBottom > _kShowScrollButtonDistance) {
      nextShowScrollButton = true;
    } else if (_showScrollToBottom &&
        distanceToBottom < _kHideScrollButtonDistance) {
      nextShowScrollButton = false;
    }

    if (nextShowScrollButton == _showScrollToBottom) return;
    setState(() {
      _showScrollToBottom = nextShowScrollButton;
    });
  }

  void _scrollChatToBottom({bool force = false}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      // Only auto-scroll if user is already near bottom (within 100px) or force is true
      final position = _scrollController.position;
      final isNearBottom = position.maxScrollExtent - position.pixels < 100;

      if (force || isNearBottom) {
        _scrollController.animateTo(
          position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<StoredChat?> _persistChat({bool waitForCompletion = false}) async {
    return await _persistenceHandler.persistChat(
      messages: _messages,
      chatId: _activeChatId,
      waitForCompletion: waitForCompletion,
      isOffline: _isOffline,
    );
  }

  String? _formatModelInfo(String? modelId, String? provider) =>
      ChatUiHelpers.formatModelInfo(modelId, provider);

  // --- BUILD METHOD ---

  @override
  Widget build(BuildContext context) {
    const bool isCompactModeForModelDropdown = true;
    final mediaQuery = MediaQuery.of(context);
    final theme = Theme.of(context);
    final double keyboardInset = mediaQuery.viewInsets.bottom;
    final Color iconFg = theme.resolvedIconColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Use actual available width from constraints, not screen width
        final double availableWidth = constraints.maxWidth;

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
          mediaQuery: mediaQuery,
          theme: theme,
          iconFg: iconFg,
          keyboardInset: keyboardInset,
          expandedInputWidth: constrainedChatContentWidth,
          effectiveHorizontalPadding: effectiveHorizontalPadding,
          isCompactModeForModelDropdown: isCompactModeForModelDropdown,
        );
      },
    );
  }

  Widget _buildChatContent({
    required BuildContext context,
    required MediaQueryData mediaQuery,
    required ThemeData theme,
    required Color iconFg,
    required double keyboardInset,
    required double expandedInputWidth,
    required double effectiveHorizontalPadding,
    required bool isCompactModeForModelDropdown,
  }) {
    final bool hasAttachments = _fileHandler.hasAttachments;
    final bool hasMessages = _messages.isNotEmpty;
    final double composerReservedSpace =
        40.0 + (hasAttachments ? 80.0 : 0.0) + 32.0 + mediaQuery.padding.bottom;
    final EdgeInsets listPadding = EdgeInsets.fromLTRB(
      effectiveHorizontalPadding,
      10,
      effectiveHorizontalPadding,
      10 + composerReservedSpace,
    );

    final Color accent = theme.colorScheme.primary;
    final Color bg = theme.scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: keyboardInset),
            child: GestureDetector(
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
                            child: SelectionArea(
                              child: ListView.builder(
                                controller: _scrollController,
                                padding: listPadding,
                                itemCount: _messages.length,
                                addAutomaticKeepAlives: false,
                                addRepaintBoundaries: true,
                                cacheExtent: 1000.0,
                                itemBuilder: (_, int i) {
                                  final Map<String, String> raw = _messages[i];
                                  final String sender = raw['sender'] ?? 'ai';
                                  final bool isAiMessage = sender != 'user';
                                  final bool isStreamingMessage =
                                      _isCurrentChatStreaming &&
                                      i == _messages.length - 1 &&
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
                                      _messageActionsHandler
                                          .editingMessageIndex ==
                                      i;
                                  final bool isUser = sender == 'user';
                                  final bool startsNewGroup =
                                      i == 0 ||
                                      ((_messages[i - 1]['sender'] ?? 'ai') !=
                                          sender);
                                  final bool endsGroup =
                                      i == _messages.length - 1 ||
                                      ((_messages[i + 1]['sender'] ?? 'ai') !=
                                          sender);

                                  // Parse images from JSON
                                  List<String>? images;
                                  final String? imagesJson = raw['images'];
                                  if (imagesJson != null &&
                                      imagesJson.isNotEmpty) {
                                    try {
                                      final decoded = jsonDecode(imagesJson);
                                      if (decoded is List) {
                                        images = decoded.cast<String>();
                                      }
                                    } catch (e) {
                                      if (kDebugMode) {
                                        debugPrint(
                                          'Failed to decode images JSON: $e',
                                        );
                                      }
                                    }
                                  }

                                  // Parse document attachments from JSON
                                  List<DocumentAttachment>? attachments;
                                  final String? attachmentsJson =
                                      raw['attachments'];
                                  if (attachmentsJson != null &&
                                      attachmentsJson.isNotEmpty) {
                                    try {
                                      final decoded = jsonDecode(
                                        attachmentsJson,
                                      );
                                      if (decoded is List) {
                                        attachments = decoded
                                            .map(
                                              (item) =>
                                                  DocumentAttachment.fromJson(
                                                    item
                                                        as Map<String, dynamic>,
                                                  ),
                                            )
                                            .toList();
                                        if (kDebugMode) {
                                          debugPrint(
                                            '📄 [AttachmentDebug] Extracted ${attachments.length} attachments from message $i',
                                          );
                                        }
                                      }
                                    } catch (e) {
                                      if (kDebugMode) {
                                        debugPrint(
                                          '📄 [AttachmentDebug] Failed to decode attachments JSON: $e',
                                        );
                                      }
                                    }
                                  }

                                  // Parse TPS value from message
                                  final tpsStr = raw['tps'];
                                  double? tps;
                                  if (tpsStr != null && tpsStr.isNotEmpty) {
                                    tps = double.tryParse(tpsStr);
                                  }

                                  List<ToolCall>? toolCalls;
                                  final String? toolCallsJson =
                                      raw['toolCalls'];
                                  if (toolCallsJson != null &&
                                      toolCallsJson.isNotEmpty) {
                                    try {
                                      final decoded = jsonDecode(toolCallsJson);
                                      if (decoded is List) {
                                        toolCalls = decoded
                                            .whereType<Map>()
                                            .map(
                                              (item) => ToolCall.fromJson(
                                                Map<String, dynamic>.from(item),
                                              ),
                                            )
                                            .toList();
                                      }
                                    } catch (_) {}
                                  }

                                  // Parse content blocks for interleaved
                                  // tool call / text display.
                                  List<ContentBlock>? parsedContentBlocks;
                                  final String? contentBlocksJson =
                                      raw['contentBlocks'];
                                  if (contentBlocksJson != null &&
                                      contentBlocksJson.isNotEmpty) {
                                    try {
                                      final decoded = jsonDecode(
                                        contentBlocksJson,
                                      );
                                      if (decoded is List) {
                                        parsedContentBlocks = decoded
                                            .whereType<Map>()
                                            .map(
                                              (item) => ContentBlock.fromJson(
                                                Map<String, dynamic>.from(item),
                                              ),
                                            )
                                            .toList();
                                      }
                                    } catch (_) {}
                                  }

                                  final String? replyContextJson =
                                      raw['replyContext'];
                                  final String? replyPreviewText =
                                      ChatUiHelpers.extractReplyPreviewText(
                                        replyContextJson,
                                      );
                                  final String? replyPreviewLabel =
                                      replyPreviewText != null
                                      ? ChatUiHelpers.extractReplyPreviewLabel(
                                          replyContextJson,
                                        )
                                      : null;

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

                                  return RepaintBoundary(
                                    child: MessageBubble(
                                      key: ValueKey('msg_$i'),
                                      message: displayText,
                                      reasoning: reasoningText,
                                      isUser: isUser,
                                      startsNewGroup: startsNewGroup,
                                      endsGroup: endsGroup,
                                      maxWidth: isUser
                                          ? expandedInputWidth * 0.8
                                          : expandedInputWidth,
                                      isReasoningStreaming: isStreamingMessage,
                                      modelLabel: modelLabel,
                                      modelProvider: modelProvider,
                                      tps: tps,
                                      toolCalls: toolCalls,
                                      showToolCalls: widget.showToolCalls,
                                      contentBlocks: parsedContentBlocks,
                                      replyPreviewText: replyPreviewText,
                                      replyPreviewLabel: replyPreviewLabel,
                                      isStreamingMessage: isStreamingMessage,
                                      images: images,
                                      imageMetas: imageMetas,
                                      attachments: attachments,
                                      imageCostEur: imageCostEur,
                                      imageGeneratedAt: imageGeneratedAt,
                                      actions: _messageActionsHandler
                                          .buildActionsForMessage(
                                            index: i,
                                            messageText: displayText,
                                            isUser: isUser,
                                            isStreaming: isStreamingMessage,
                                            hasFailedToolCalls:
                                                toolCalls != null &&
                                                toolCalls.any(
                                                  (t) =>
                                                      t.status ==
                                                      ToolCallStatus.error,
                                                ),
                                            onEdit: _editMessageAt,
                                            onResendMessage: _resendMessageAt,
                                          ),
                                      userMessageActions: isUser
                                          ? _messageActionsHandler
                                                .buildUserMessageActions(
                                                  index: i,
                                                  messageText: displayText,
                                                  onEdit: _editMessageAt,
                                                  onResendMessage:
                                                      _resendMessageAt,
                                                )
                                          : const [],
                                      isEditing: isBeingEdited,
                                      showReasoningTokens:
                                          widget.showReasoningTokens,
                                      showModelInfo: widget.showModelInfo,
                                      showTps: widget.showTps,
                                      onAskUserAnswer:
                                          _askUserCallbackForMessage(
                                            index: i,
                                            isUser: isUser,
                                            isStreaming: isStreamingMessage,
                                            toolCalls: toolCalls,
                                            contentBlocks: parsedContentBlocks,
                                          ),
                                      onReplyToAiBlock:
                                          !isUser && !isStreamingMessage
                                          ? (
                                              blockText,
                                              blockType,
                                              blockIndex,
                                            ) => _setPendingReplyContext(
                                              messageIndex: i,
                                              blockIndex: blockIndex,
                                              blockType: blockType,
                                              blockText: blockText,
                                            )
                                          : null,
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
                            child: Opacity(
                              opacity: 0.08,
                              child: Image.asset(
                                'web/icons/Icon-512.png',
                                width: 180,
                                height: 180,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                  // Scroll-to-bottom button (centered above input)
                  if (_showScrollToBottom && hasMessages)
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
                            onTap: () => _scrollChatToBottom(force: true),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(
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
                    child: SafeArea(
                      top: false,
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
                              const SizedBox(height: 8),
                              Text(
                                'AI/LLMs can make mistakes — double-check important info.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: iconFg.withValues(alpha: 0.7),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Floating workspace pill at the top of the chat
          if (kFeatureWorkspaces && _selectedWorkspaceId != null)
            Positioned(
              top: mediaQuery.padding.top + 8,
              left: effectiveHorizontalPadding,
              right: effectiveHorizontalPadding,
              child: IgnorePointer(
                ignoring: false,
                child: _buildTopProjectPill(theme),
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

  Widget _buildSearchBar({
    required bool isCompactMode,
    required ThemeData theme,
    required Color iconFg,
  }) {
    final Color bg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final bool hasAttachments = _fileHandler.hasAttachments;
    final bool showStopAction = _isCurrentChatStreaming || _isSendingMessage;
    final bool hasTypedText = _controller.text.trim().isNotEmpty;
    final bool hasText = hasTypedText || hasAttachments;
    final bool showVoiceModeAction = !hasText && kFeatureVoiceMode;

    final Color borderColor = _audioHandler.isMicActive
        ? Colors.red.withValues(alpha: 0.4)
        : iconFg.withValues(alpha: 0.25);

    // Uniform pill height for all three groups.
    const double pillHeight = 46;

    // Shared pill decoration for all three groups.
    BoxDecoration pillDecoration({bool isActive = false}) => BoxDecoration(
      color: bg.withValues(alpha: 0.98),
      borderRadius: BorderRadius.circular(pillHeight / 2),
      border: Border.all(
        color: isActive ? Colors.red.withValues(alpha: 0.4) : borderColor,
        width: 2,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.06),
          blurRadius: 10,
          offset: const Offset(0, 2),
        ),
      ],
    );

    // Whether to show the mic inside the text field pill.
    // Shown when: typed text is empty, not recording, not streaming.
    // Attachments must not hide the mic (user can dictate with images attached).
    final bool showInlineMic =
        !hasTypedText && !_audioHandler.isMicActive && !showStopAction;
    final bool rightPillHasMultipleActions = _audioHandler.isMicActive;

    // Three-part layout: [+]  [TextField + mic]  [Send]
    // With optional attachment previews and editing indicator above.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_pendingReplyPreviewText != null &&
            _pendingReplyPreviewText!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: accent.withValues(alpha: 0.32),
                  width: 1.2,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.reply_rounded,
                    size: 16,
                    color: accent.withValues(alpha: 0.95),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _pendingReplyPreviewLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: accent.withValues(alpha: 0.9),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _pendingReplyPreviewText!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: iconFg.withValues(alpha: 0.78),
                            fontSize: 12,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: iconFg.withValues(alpha: 0.8),
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed: _clearPendingReplyContext,
                  ),
                ],
              ),
            ),
          ),
        if (hasAttachments)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AttachmentPreviewBar(
              files: _fileHandler.attachedFiles,
              onRemove: _fileHandler.removeFile,
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // ── Left pill: +, Model selector ──
            // When collapsed (only +), minWidth == pillHeight keeps it circular.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              alignment: Alignment.centerLeft,
              child: Container(
                height: pillHeight,
                constraints: const BoxConstraints(minWidth: pillHeight),
                decoration: pillDecoration(),
                padding: EdgeInsets.symmetric(
                  horizontal: _controller.text.isNotEmpty ? 7 : 4,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    buildTinyIconButton(
                      icon: Icons.add_rounded,
                      iconSize: 22,
                      onTap: _handleAddAttachmentTap,
                      isActive: hasAttachments,
                      color: iconFg,
                    ),
                    Offstage(
                      offstage: _controller.text.isNotEmpty,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 1),
                          if (ModelSelectionDropdown.modelSupportsReasoning(
                            _selectedModelId,
                          ))
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _reasoningEnabled = !_reasoningEnabled;
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Icon(
                                  Icons.psychology,
                                  size: 20,
                                  color: _reasoningEnabled
                                      ? Theme.of(context).colorScheme.primary
                                      : iconFg.withValues(alpha: 0.3),
                                ),
                              ),
                            ),
                          ModelSelectionDropdown(
                            key: const ValueKey<String>(
                              'mobile-model-selection-dropdown',
                            ),
                            initialSelectedModelId: _selectedModelId,
                            onModelSelected: (newModelId) {
                              setState(() {
                                _selectedModelId = newModelId;
                              });
                            },
                            textFieldFocusNode: _textFieldFocusNode,
                            isCompactMode: isCompactMode,
                            transparentStyle: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),

            // ── Middle: TextField + inline mic (grows upward for multi-line) ──
            Expanded(
              child: Container(
                height: _audioHandler.isMicActive ? pillHeight : null,
                constraints: _audioHandler.isMicActive
                    ? null
                    : const BoxConstraints(minHeight: pillHeight),
                decoration: pillDecoration(isActive: _audioHandler.isMicActive),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: _audioHandler.isMicActive
                    ? SizedBox(
                        height: pillHeight - 6, // minus border + padding
                        child: Row(
                          children: [
                            buildRecordingIndicator(),
                            const SizedBox(width: 6),
                            Expanded(
                              child: buildAudioVisualizer(
                                audioLevels: _audioHandler.audioLevels,
                                accentColor: Colors.red,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // ── Editing indicator (inside the pill) ──
                          if (_messageActionsHandler.isEditing)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.edit,
                                    size: 12,
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Editing message',
                                    style: TextStyle(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.7),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: _cancelEditMessage,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        'Cancel',
                                        style: TextStyle(
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.6),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          // ── TextField ──
                          buildKeyboardListener(
                            focusNode: _rawKeyboardListenerFocusNode,
                            controller: _controller,
                            onSend: _sendOrSubmitEdit,
                            child: Scrollbar(
                              controller: _composerScrollController,
                              child: Semantics(
                                identifier: 'message_input',
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _textFieldFocusNode,
                                  autofocus: false,
                                  keyboardType: TextInputType.multiline,
                                  textInputAction: TextInputAction.newline,
                                  scrollController: _composerScrollController,
                                  style: TextStyle(
                                    color: theme.colorScheme.onSurface,
                                    fontSize: 15,
                                    height: 1.3,
                                  ),
                                  minLines: 1,
                                  maxLines: 6,
                                  decoration: InputDecoration(
                                    hintText: _messageActionsHandler.isEditing
                                        ? AppLocalizations.of(
                                            context,
                                          )!.editYourMessage
                                        : AppLocalizations.of(
                                            context,
                                          )!.askMeAnything,
                                    hintStyle: TextStyle(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.5),
                                      fontSize: 15,
                                    ),
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 0,
                                      vertical: 10,
                                    ),
                                    isDense: true,
                                    // Mic or fullscreen button as suffix icon.
                                    // Mic shown when text is empty; fullscreen
                                    // shown when text is long; otherwise nothing.
                                    suffixIcon: showInlineMic
                                        ? GestureDetector(
                                            onTap: _handleMicTap,
                                            child: Semantics(
                                              identifier: 'mic_button',
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 4,
                                                ),
                                                child: Icon(
                                                  Icons.mic,
                                                  size: 20,
                                                  color: iconFg.withValues(
                                                    alpha: 0.6,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          )
                                        : _showFullscreenButton
                                        ? GestureDetector(
                                            onTap: _openFullscreenEditor,
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                left: 4,
                                              ),
                                              child: Icon(
                                                Icons.open_in_full_rounded,
                                                size: 14,
                                                color: iconFg.withValues(
                                                  alpha: 0.4,
                                                ),
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
                        ],
                      ),
              ),
            ),
            const SizedBox(width: 6),

            // ── Right pill: Send / Stop / Voice Mode ──
            Container(
              height: pillHeight,
              width: rightPillHasMultipleActions ? null : pillHeight,
              decoration: pillDecoration(isActive: _audioHandler.isMicActive),
              padding: rightPillHasMultipleActions
                  ? const EdgeInsets.symmetric(horizontal: 5)
                  : EdgeInsets.zero,
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // When mic is recording: stop + send buttons
                  if (_audioHandler.isMicActive) ...[
                    buildTinyIconButton(
                      icon: Icons.stop_rounded,
                      iconSize: 20,
                      onTap: _handleMicTap,
                      isActive: true,
                      color: Colors.red,
                      semanticsId: 'mic_button',
                    ),
                    const SizedBox(width: 3),
                  ],
                  buildTinyActionButton(
                    icon: _audioHandler.isMicActive
                        ? Icons.north_rounded
                        : (showStopAction
                              ? Icons.stop_rounded
                              : (showVoiceModeAction
                                    ? Icons.graphic_eq_rounded
                                    : Icons.north_rounded)),
                    buttonSize: 36,
                    iconSize: 16,
                    onTap: _audioHandler.isMicActive
                        ? _handleAudioSend
                        : (showStopAction
                              ? _cancelCurrentOperation
                              : (showVoiceModeAction
                                    ? () => _openComingSoonFeature('Voice Mode')
                                    : _sendOrSubmitEdit)),
                    color: _audioHandler.isMicActive
                        ? accent
                        : (showStopAction ? Colors.red : accent),
                    isLoading: _audioHandler.isTranscribingAudio,
                    semanticsId: 'send_button',
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
