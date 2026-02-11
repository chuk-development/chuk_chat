// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
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
import 'package:chuk_chat/services/image_generation_service.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/services/project_message_service.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/pages/project_management_page.dart';

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
  late final VoidCallback _modelSelectionListener;

  // Stream subscriptions
  StreamSubscription<void>? _providerRefreshSubscription;

  // Network and UI state
  bool _isOffline = false;
  bool _isSendingMessage = false; // Flag to prevent rapid send spam
  bool _isLoadingChat = false; // Loading indicator for chat switching
  late final VoidCallback _networkStatusListener;
  Timer? _audioVisualizerTimer;

  // Image generation state
  bool _isImageGenMode = false;
  bool _isGeneratingImage = false;

  // Project state
  String? _selectedProjectId;

  // Computed property - checks if CURRENT chat is streaming
  bool get _isCurrentChatStreaming =>
      _activeChatId != null && _streamingHandler.isChatStreaming(_activeChatId!);

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kAttachmentBarMarginBottom = 8.0;
  static const double _kHorizontalPaddingSmall = 8.0;

  @override
  void initState() {
    super.initState();
    _initializeHandlers();
    _initializeListeners();
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
      ..onUpdate = () => setState(() {});

    _messageActionsHandler = MessageActionsHandler()
      ..onShowSnackBar = _showSnackBar
      ..onSubmitEdit = _submitEditedMessage
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
      ..onBackgroundUpdate = (chatId, index, content, reasoning) {
        _persistenceHandler.updateBackgroundChatMessage(
          chatId: chatId,
          messageIndex: index,
          content: content,
          reasoning: reasoning,
        );
      };
  }

  void _initializeListeners() {
    // Scroll listener for scroll-to-bottom button
    _scrollController.addListener(_onScrollChanged);

    // Text controller listener
    _controller.addListener(() {
      final bool currentTextIsEmpty = _controller.text.trim().isEmpty;
      final String text = _controller.text;

      // Estimate if text is getting long (3+ lines worth of content)
      // A line is roughly 22 chars, so 3 lines = ~66 chars
      // Also check for newlines
      final int newlineCount = '\n'.allMatches(text).length;
      final bool shouldShowFullscreen =
          text.length > 66 || newlineCount >= 2;

      if (currentTextIsEmpty != _lastTextWasEmpty ||
          shouldShowFullscreen != _showFullscreenButton) {
        setState(() {
          _lastTextWasEmpty = currentTextIsEmpty;
          _showFullscreenButton = shouldShowFullscreen;
        });
      }
    });

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
          unawaited(_loadProviderSlugForModel(_selectedModelId));
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
      // Load projects for project selection feature
      if (kFeatureProjects) {
        unawaited(ProjectStorageService.loadFromCache());
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChukChatUIMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ID-BASED: Only react when the actual chat ID changes
    if (widget.selectedChatId != oldWidget.selectedChatId) {
      debugPrint('');
      debugPrint('┌─────────────────────────────────────────────────────────────');
      debugPrint('│ 🔄 [CHAT-UI-MOBILE] didUpdateWidget triggered');
      debugPrint('│ 🔄 [CHAT-UI-MOBILE] OLD widget.selectedChatId: ${oldWidget.selectedChatId}');
      debugPrint('│ 🔄 [CHAT-UI-MOBILE] NEW widget.selectedChatId: ${widget.selectedChatId}');
      debugPrint('│ 🔄 [CHAT-UI-MOBILE] Current _activeChatId: $_activeChatId');
      debugPrint('│ 🔄 [CHAT-UI-MOBILE] _isSendingMessage: $_isSendingMessage');
      debugPrint('│ 🔄 [CHAT-UI-MOBILE] _streamingHandler.isStreaming: ${_streamingHandler.isStreaming}');
      debugPrint('└─────────────────────────────────────────────────────────────');

      // Skip if we're already on this chat
      if (widget.selectedChatId == _activeChatId) {
        debugPrint('⚠️ [CHAT-UI-MOBILE] SKIP - already on this chat');
        return;
      }

      // CRITICAL FIX: Don't clear an active chat just because parent sent null
      // This can happen due to stale parent rebuilds. If we have an active chat
      // with messages, keep it instead of switching to a blank "new" chat.
      if (widget.selectedChatId == null && _activeChatId != null && _messages.isNotEmpty) {
        debugPrint('⚠️ [CHAT-UI-MOBILE] IGNORING null from parent - we have active chat: $_activeChatId');
        // Sync the parent back to our active chat
        widget.onChatIdChanged(_activeChatId);
        return;
      }

      // CRITICAL: NO persist during chat switch!
      // Persisting here causes data corruption because _messages may already contain
      // the NEW chat's content by the time didUpdateWidget fires (due to async timing).
      // Instead, we rely on:
      // 1. Immediate persist after message send/receive
      // 2. Persist in newChat() before clearing
      // 3. Chats are already saved to Supabase during message operations
      debugPrint('│ 📝 [CHAT-UI-MOBILE] Chat switch - NOT persisting (already saved on message ops)');

      // BACKGROUND STREAMING: If current chat is streaming, snapshot messages
      // to StreamingManager before clearing. This ensures the stream can
      // continue in background and persist correctly when complete.
      if (_activeChatId != null && _streamingHandler.isChatStreaming(_activeChatId!)) {
        final messagesCopy = _messages
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        _streamingHandler.setBackgroundMessages(
          _activeChatId!,
          messagesCopy,
        );
        debugPrint('│ 📦 [CHAT-UI-MOBILE] Snapshotted ${messagesCopy.length} messages for background stream: $_activeChatId');
      }

      setState(() {
        _messages.clear();
        _fileHandler.clearAll();
        _controller.clear();
        _messageActionsHandler.cancelEdit();
      });

      debugPrint('│ 🔄 [CHAT-UI-MOBILE] About to call _loadChatById(${widget.selectedChatId})');
      _loadChatById(widget.selectedChatId);
      debugPrint('│ 🔄 [CHAT-UI-MOBILE] After _loadChatById, _activeChatId: $_activeChatId');

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
    if (_activeChatId != null) {
      _streamingHandler.cancelStream(_activeChatId);
    }
    _audioVisualizerTimer?.cancel();
    _providerRefreshSubscription?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(
      _networkStatusListener,
    );
    _controller.dispose();
    _scrollController.dispose();
    _composerScrollController.dispose();
    _textFieldFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    ModelSelectionDropdown.selectedModelListenable.removeListener(
      _modelSelectionListener,
    );
    _audioHandler.dispose();
    super.dispose();
  }

  // --- CHAT MANAGEMENT ---

  void _loadChatById(String? chatId) {
    debugPrint('');
    debugPrint('┌─────────────────────────────────────────────────────────────');
    debugPrint('│ 📂 [LOAD-CHAT-MOBILE] _loadChatById called');
    debugPrint('│ 📂 [LOAD-CHAT-MOBILE] chatId param: $chatId');
    debugPrint('│ 📂 [LOAD-CHAT-MOBILE] Current _activeChatId: $_activeChatId');
    debugPrint('│ 📂 [LOAD-CHAT-MOBILE] Sidebar expanded: ${widget.isSidebarExpanded}');
    debugPrint('└─────────────────────────────────────────────────────────────');

    // Capture sidebar state NOW - before any async operations
    final bool sidebarWasExpanded = widget.isSidebarExpanded;

    // Show loading indicator immediately
    setState(() {
      _isLoadingChat = true;
    });

    // Use async function to handle lazy loading
    _loadChatByIdAsync(chatId, sidebarWasExpanded);
  }

  Future<void> _loadChatByIdAsync(String? chatId, bool sidebarWasExpanded) async {
    if (!mounted) return;

    if (chatId == null) {
      // New chat - clear everything
      debugPrint('│ 📂 [LOAD-CHAT-MOBILE] chatId is NULL - clearing for new chat');
      _messages.clear();
      _fileHandler.clearAll();
      _activeChatId = null;
    } else {
      // Find chat by ID
      StoredChat? storedChat = ChatStorageService.getChatById(chatId);

      if (storedChat != null) {
        // LAZY LOADING: Check if chat is fully loaded
        if (!storedChat.isFullyLoaded) {
          debugPrint('│ 📂 [LOAD-CHAT-MOBILE] Chat $chatId not fully loaded, fetching...');
          storedChat = await ChatStorageService.loadFullChat(chatId);

          // Check for stale load after async operation
          if (!mounted) return;
        }

        if (storedChat != null && storedChat.isFullyLoaded) {
          debugPrint('│ 📂 [LOAD-CHAT-MOBILE] FOUND chat $chatId with ${storedChat.messages.length} messages');
          debugPrint('│ 📂 [LOAD-CHAT-MOBILE] Setting _activeChatId = ${storedChat.id}');
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
                // Include attachments if present
                if (message.attachments != null && message.attachments!.isNotEmpty) {
                  map['attachments'] = message.attachments!;
                  debugPrint('📄 [AttachmentDebug] Loading message with attachments field');
                }
                // Include attachedFilesJson for retry/resend support
                if (message.attachedFilesJson != null && message.attachedFilesJson!.isNotEmpty) {
                  map['attachedFilesJson'] = message.attachedFilesJson!;
                }
                return map;
              }),
            );
        } else {
          // Chat load failed - treat as new chat
          debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Chat $chatId load failed!');
          _messages.clear();
          _fileHandler.clearAll();
          _activeChatId = null;
        }
      } else {
        // Chat not found - treat as new chat
        debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Chat $chatId NOT FOUND!');
        debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Available chats: ${ChatStorageService.savedChats.map((c) => c.id).take(5).toList()}...');
        debugPrint('│ ⚠️ [LOAD-CHAT-MOBILE] Treating as new chat, setting _activeChatId = null');
        _messages.clear();
        _fileHandler.clearAll();
        _activeChatId = null;
      }
    }

    // Check for background streaming
    final bool chatIsStreaming =
        _activeChatId != null &&
        _streamingHandler.isChatStreaming(_activeChatId!);

    if (chatIsStreaming && _activeChatId != null) {
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

  void newChat() {
    debugPrint('🆕 [NewChat] Starting newChat(), current _activeChatId: $_activeChatId');

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
    debugPrint('🆕 [NewChat] After setState, _activeChatId: $_activeChatId');
    _scrollChatToBottom(force: true);
    if (!widget.isSidebarExpanded) {
      _textFieldFocusNode.requestFocus();
    }

    // Persist old chat and refresh sidebar in background (don't await)
    // CRITICAL: Use silent=true to prevent onChatIdAssigned from changing
    // the selected chat - we're now on a NEW chat!
    if (messagesToSave != null && chatIdToSave != null) {
      unawaited(_persistenceHandler.persistChat(
        messages: messagesToSave,
        chatId: chatIdToSave,
        waitForCompletion: false,
        isOffline: _isOffline,
        silent: true,
      ).then((_) {
        // Refresh sidebar after persist completes
        unawaited(ChatStorageService.loadSavedChatsForSidebar());
      }));
    } else {
      // No chat to save, just refresh sidebar
      unawaited(ChatStorageService.loadSavedChatsForSidebar());
    }
    debugPrint('🆕 [NewChat] Background operations started');
  }

  // --- AUDIO HANDLERS ---

  Future<void> _handleMicTap() async {
    if (_audioHandler.isMicActive) {
      await _audioHandler.stopRecording();
      _audioVisualizerTimer?.cancel();
      _audioVisualizerTimer = null;
      if (!mounted) return;
      setState(() {
        _audioHandler.resetAudioLevels();
      });
    } else {
      final bool started = await _audioHandler.startRecording();
      if (!mounted) return;
      if (started) {
        setState(() {
          _audioHandler.resetAudioLevels();
        });
        // Update visualizer every 50ms for smooth animation
        _audioVisualizerTimer = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) {
            if (mounted && _audioHandler.isMicActive) {
              setState(() {});
            }
          },
        );
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
    _audioVisualizerTimer?.cancel();
    _audioVisualizerTimer = null;
    if (!mounted) return;
    setState(() {
      _audioHandler.resetAudioLevels();
    });

    final session = await _streamingHandler.getSessionSafely();
    if (session == null) return;

    setState(() {}); // Trigger UI update to show loading icon
    final result = await _audioHandler.transcribeLastRecording(
      apiService: _chatApiService,
      accessToken: session.accessToken,
    );

    if (!mounted) return;

    if (result.requiresLogout) {
      await SupabaseService.signOut();
    }

    if (!result.success) {
      _showSnackBar(result.error ?? 'Transcription failed');
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

      // If auto-send is enabled, send the message immediately
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
                      label: 'Camera',
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
                      label: 'Photos',
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
                      label: 'Files',
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
                // Project selection row (when feature enabled)
                if (kFeatureProjects) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      buildAttachmentSheetOption(
                        context: sheetContext,
                        icon: _selectedProjectId != null
                            ? Icons.folder_open
                            : Icons.folder_outlined,
                        label: 'Project',
                        isEnabled: true,
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          _showProjectSelectionSheet();
                        },
                      ),
                    ],
                  ),
                  if (_selectedProjectId != null) ...[
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

  /// Show project selection bottom sheet
  void _showProjectSelectionSheet() {
    if (!mounted) return;
    final theme = Theme.of(context);
    final projects = ProjectStorageService.activeProjects;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) {
        final Color indicatorColor = theme.dividerColor.withValues(alpha: 0.3);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Projects',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // No project option
                _buildProjectOption(
                  sheetContext,
                  theme,
                  null,
                  'No Project',
                  Icons.close,
                ),
                if (projects.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.folder_open,
                          size: 48,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No projects yet',
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _createNewProject();
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Create Project'),
                        ),
                      ],
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.4,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: projects.length + 1, // +1 for create button
                      itemBuilder: (context, index) {
                        if (index == projects.length) {
                          // Create new project button at the end
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                _createNewProject();
                              },
                              icon: const Icon(Icons.add),
                              label: const Text('Create New Project'),
                            ),
                          );
                        }
                        final project = projects[index];
                        return _buildProjectOption(
                          sheetContext,
                          theme,
                          project.id,
                          project.name,
                          Icons.folder,
                          subtitle: ProjectMessageService.getProjectContextSummary(project),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _createNewProject() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Project Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.trim().isNotEmpty && mounted) {
      try {
        final project = await ProjectStorageService.createProject(
          nameController.text.trim(),
          description: descController.text.trim().isEmpty ? null : descController.text.trim(),
        );
        _showSnackBar('Project "${project.name}" created');
        // Open the project management page
        if (mounted) {
          _openProjectManagement(project.id);
        }
      } catch (e) {
        _showSnackBar('Failed to create project: $e');
      }
    }
  }

  void _openProjectManagement(String projectId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProjectManagementPage(
          projectId: projectId,
          onStartNewChat: (selectedProjectId) {
            // Start new chat with project context
            _startNewChatWithProject(selectedProjectId);
          },
        ),
      ),
    );
  }

  void _startNewChatWithProject(String? projectId) {
    // Clear current chat and set project
    setState(() {
      _activeChatId = null;
      _messages.clear();
      _selectedProjectId = projectId;
      _controller.clear();
    });
    widget.onChatIdChanged(null);
    if (projectId != null) {
      final project = ProjectStorageService.getProject(projectId);
      if (project != null) {
        _showSnackBar('New chat with project: ${project.name}');
      }
    }
  }

  Widget _buildProjectOption(
    BuildContext sheetContext,
    ThemeData theme,
    String? projectId,
    String name,
    IconData icon, {
    String? subtitle,
  }) {
    final isSelected = _selectedProjectId == projectId;
    // Check if this project already contains the current chat
    final project = projectId != null ? ProjectStorageService.getProject(projectId) : null;
    final bool chatInProject = project != null && _activeChatId != null &&
        project.chatIds.contains(_activeChatId);

    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? theme.colorScheme.primary : null,
      ),
      title: Text(
        name,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          color: isSelected ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected)
            Icon(Icons.check, color: theme.colorScheme.primary),
          if (projectId != null) ...[
            // Link/unlink chat button
            if (_activeChatId != null) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  chatInProject ? Icons.link_off : Icons.link,
                  size: 20,
                  color: chatInProject
                      ? Colors.orange
                      : theme.colorScheme.primary.withValues(alpha: 0.7),
                ),
                tooltip: chatInProject ? 'Remove chat from project' : 'Add chat to project',
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  if (chatInProject) {
                    await _removeChatFromProject(projectId);
                  } else {
                    await _addChatToProject(projectId);
                  }
                },
              ),
            ],
            // Manage project button
            IconButton(
              icon: Icon(
                Icons.settings,
                size: 20,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              tooltip: 'Manage project',
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _openProjectManagement(projectId);
              },
            ),
          ],
        ],
      ),
      onTap: () {
        Navigator.of(sheetContext).pop();
        setState(() {
          _selectedProjectId = projectId;
        });
        if (projectId != null) {
          _showSnackBar('Project selected: $name');
        } else {
          _showSnackBar('Project cleared');
        }
      },
    );
  }

  Future<void> _addChatToProject(String projectId) async {
    if (_activeChatId == null) {
      _showSnackBar('No active chat to add');
      return;
    }
    try {
      await ProjectStorageService.addChatToProject(projectId, _activeChatId!);
      _showSnackBar('Chat added to project');
      setState(() {});
    } catch (e) {
      _showSnackBar('Failed to add chat: $e');
    }
  }

  Future<void> _removeChatFromProject(String projectId) async {
    if (_activeChatId == null) return;
    try {
      await ProjectStorageService.removeChatFromProject(projectId, _activeChatId!);
      _showSnackBar('Chat removed from project');
      setState(() {});
    } catch (e) {
      _showSnackBar('Failed to remove chat: $e');
    }
  }

  Widget _buildSelectedProjectBadge(ThemeData theme) {
    final project = ProjectStorageService.getProject(_selectedProjectId!);
    if (project == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder,
            size: 16,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 6),
          Text(
            project.name,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () {
              setState(() {
                _selectedProjectId = null;
              });
            },
            child: Icon(
              Icons.close,
              size: 14,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// Build a compact project indicator for the input area
  Widget _buildProjectIndicator(ThemeData theme) {
    final project = ProjectStorageService.getProject(_selectedProjectId!);
    if (project == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  ProjectMessageService.getProjectContextSummary(project),
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                _selectedProjectId = null;
              });
              _showSnackBar('Project cleared');
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 18,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
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

  Future<void> _finalizeAiMessage(
    int index,
    String content,
    String reasoning,
    String chatId,
    double? tps,
  ) async {
    debugPrint('✅ [FinalizeMessage] chatId: $chatId, index: $index, _activeChatId: $_activeChatId');

    // CRITICAL: Clear flags now that streaming is complete
    // This allows realtime updates and didUpdateWidget to proceed
    if (_isSendingMessage) {
      _isSendingMessage = false;
      debugPrint('✅ [FinalizeMessage] Cleared _isSendingMessage flag');
    }
    // RELEASE GLOBAL LOCK when streaming completes
    if (ChatStorageService.isMessageOperationInProgress) {
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [FinalizeMessage] GLOBAL LOCK RELEASED (stream complete)');
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
    } else if (!isActiveChat) {
      // User switched to a different chat - _messages belongs to the OTHER chat!
      // DO NOT check _messages.length - it's the wrong chat's message list.
      // Persist using the background update handler which reads from storage.
      _persistenceHandler.updateBackgroundChatMessage(
        chatId: chatId,
        messageIndex: index,
        content: content,
        reasoning: reasoning,
      );
    }
  }

  /// Generate an image from the current text prompt
  Future<void> _generateImage() async {
    final String prompt = _controller.text.trim();
    if (prompt.isEmpty) {
      _showSnackBar('Please enter a prompt to generate an image.');
      return;
    }

    if (_isGeneratingImage || _isCurrentChatStreaming || _isSendingMessage) {
      _showSnackBar('Please wait for the current operation to complete.');
      return;
    }

    // Generate chat ID if needed (new chat)
    if (_activeChatId == null) {
      _activeChatId = _uuid.v4();
      debugPrint('🆔 [ImageGen] PRE-GENERATED Chat ID: $_activeChatId');
    }

    final bool firstMessageInChat = _messages.isEmpty;
    int placeholderIndex = -1;

    setState(() {
      _isGeneratingImage = true;
      // Add user message with the prompt
      _messages.add({
        'sender': 'user',
        'text': prompt,
        'reasoning': '',
      });
      _controller.clear();
      // Add AI placeholder message
      _messages.add({
        'sender': 'ai',
        'text': 'Generating image...',
        'reasoning': '',
      });
      placeholderIndex = _messages.length - 1;
    });

    if (firstMessageInChat && mounted) {
      // Trigger any first message animations if needed
    }
    _scrollChatToBottom(force: true);

    try {
      // Determine size settings
      String? sizePreset;
      int? customWidth;
      int? customHeight;

      if (widget.imageGenUseCustomSize) {
        customWidth = widget.imageGenCustomWidth;
        customHeight = widget.imageGenCustomHeight;
      } else {
        sizePreset = widget.imageGenDefaultSize;
      }

      final result = await ImageGenerationService.generateImage(
        prompt: prompt,
        sizePreset: sizePreset,
        customWidth: customWidth,
        customHeight: customHeight,
        storeEncrypted: true,
      );

      if (!mounted) return;

      if (result.success) {
        // Update AI message with generated image
        setState(() {
          final aiMessage = <String, String>{
            'sender': 'ai',
            'text': '', // No text, just image
            'reasoning': '',
          };

          // Store the encrypted path for persistence
          if (result.encryptedPath != null) {
            aiMessage['images'] = jsonEncode([result.encryptedPath!]);
          }

          // Add cost info if available
          if (result.costEur != null) {
            aiMessage['text'] = 'Image generated (${result.costEur!.toStringAsFixed(2)} EUR)';
          }

          if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
            _messages[placeholderIndex] = aiMessage;
          }
          _isGeneratingImage = false;
          _isImageGenMode = false; // Turn off image gen mode after success
        });

        _persistChat();
        _scrollChatToBottom(force: true);
        _showSnackBar('Image generated successfully!');
      } else {
        // Handle error
        setState(() {
          if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
            _messages[placeholderIndex]['text'] = 'Error: ${result.errorMessage ?? "Image generation failed"}';
          }
          _isGeneratingImage = false;
        });

        _persistChat();

        // Check if it's a payment error
        if (result.errorMessage?.contains('credits') == true ||
            result.errorMessage?.contains('Insufficient') == true) {
          _showInsufficientCreditsDialog();
        } else {
          _showSnackBar(result.errorMessage ?? 'Image generation failed');
        }
      }
    } catch (e) {
      debugPrint('Image generation error: $e');
      if (!mounted) return;

      setState(() {
        if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
          _messages[placeholderIndex]['text'] = 'Error: $e';
        }
        _isGeneratingImage = false;
      });

      _persistChat();
      _showSnackBar('Image generation failed: $e');
    }
  }

  /// Show dialog when user has insufficient credits for image generation
  void _showInsufficientCreditsDialog() {
    if (!mounted) return;
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Row(
          children: [
            Icon(
              Icons.auto_awesome,
              color: theme.colorScheme.primary,
              size: 28,
            ),
            const SizedBox(width: 12),
            const Text('Insufficient Credits'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Image generation requires credits.',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: theme.textTheme.bodyLarge?.color,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Subscribe to get credits for AI image generation and chat messages.',
              style: TextStyle(
                fontSize: 14,
                color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
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
                borderRadius: BorderRadius.circular(8),
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
    // SET GLOBAL LOCK IMMEDIATELY - before any async operations or early returns
    // This prevents didUpdateWidget from loading a different chat during send
    ChatStorageService.isMessageOperationInProgress = true;
    debugPrint('🔒 [SendMessage] GLOBAL LOCK SET');

    if (_isCurrentChatStreaming) {
      // Current chat is streaming - cancel it
      _streamingHandler.cancelStream(_activeChatId);
      _updateCancelledMessage();
      return;
    }

    if (_isOffline) {
      _showSnackBar('You are offline. Please check your connection.');
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (offline)');
      return;
    }

    if (_fileHandler.hasUploading) {
      _showSnackBar('Upload in progress');
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (uploading)');
      return;
    }

    // Check if a model is selected
    if (_selectedModelId.isEmpty) {
      _showSnackBar('Please select a model first');
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (no model selected)');
      return;
    }

    // Set flag to block realtime updates during send operation
    _isSendingMessage = true;
    debugPrint('📨 [SendMessage] Starting send, _activeChatId BEFORE: $_activeChatId');

    // CRITICAL FIX: Sync _activeChatId with widget.selectedChatId if out of sync
    // This handles cases where _activeChatId was cleared but user is still on existing chat
    if (_activeChatId == null && widget.selectedChatId != null) {
      _activeChatId = widget.selectedChatId;
      debugPrint('⚠️ [SendMessage] SYNCED _activeChatId with widget.selectedChatId: $_activeChatId');
    }

    // Check if user has sufficient credits OR free messages
    final user = SupabaseService.auth.currentUser;
    if (user != null) {
      try {
        // Check credits first (subscribed users)
        final creditsRemainingResponse = await SupabaseService.client.rpc(
          'get_credits_remaining',
          params: {'p_user_id': user.id},
        );

        final double remainingCredits = (creditsRemainingResponse is num)
            ? creditsRemainingResponse.toDouble()
            : 0.0;

        if (remainingCredits < 0.01) {
          // No credits - check free messages (non-subscribed users)
          final freeMessagesResponse = await SupabaseService.client.rpc(
            'get_free_messages_remaining',
            params: {'p_user_id': user.id},
          );

          final int freeMessagesRemaining = (freeMessagesResponse is num)
              ? freeMessagesResponse.toInt()
              : 0;

          if (freeMessagesRemaining <= 0) {
            // No credits AND no free messages - show upgrade dialog
            if (!mounted) {
              _isSendingMessage = false;
              ChatStorageService.isMessageOperationInProgress = false;
              debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (not mounted)');
              return;
            }
            final theme = Theme.of(context);
            await showDialog(
              context: context,
              builder: (dialogContext) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Row(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      color: theme.colorScheme.primary,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('Free Messages Used'),
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'You\'ve used all 10 free messages.',
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
                              'Visit Chuk Chat on desktop to subscribe and get unlimited messages.',
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
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
            _isSendingMessage = false;
            ChatStorageService.isMessageOperationInProgress = false;
            debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (no credits and no free messages)');
            return;
          }
          // User has free messages - proceed
          debugPrint('User has $freeMessagesRemaining free messages remaining');
        }
      } catch (error) {
        debugPrint('Error checking credits/free messages: $error');
        // Continue with sending - API will handle the check as well
      }
    }

    final String originalUserInput = _controller.text.trim();
    final bool hasAttachments = _fileHandler.getUploadedFiles().isNotEmpty;

    if (originalUserInput.isEmpty && !hasAttachments) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (empty input)');
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
      systemPrompt: _systemPrompt,
      getProviderSlug: _ensureProviderSlugForCurrentModel,
    );

    if (!validationResult.isValid) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (invalid message)');
      _showSnackBar(validationResult.errorMessage ?? 'Invalid message');
      return;
    }

    // Check if widget was disposed during async operation
    if (!mounted) {
      _isSendingMessage = false;
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during prepareMessage)');
      return;
    }

    // Generate chat ID if new chat and capture it immediately
    // CRITICAL: Capture the chatId in a local variable to prevent race conditions.
    // _activeChatId could be changed by callbacks during async operations below.
    final bool isNewChat = _activeChatId == null;
    _activeChatId ??= _uuid.v4();
    final String chatIdForThisMessage = _activeChatId!;
    debugPrint('📨 [SendMessage] _activeChatId AFTER: $_activeChatId (isNewChat: $isNewChat)');
    debugPrint('📨 [SendMessage] Using chatIdForThisMessage: $chatIdForThisMessage');

    // Extract prepared values from validation result
    final String displayMessageText = validationResult.displayMessageText!;
    final List<String>? imageDataUrls = validationResult.images;

    // CRITICAL: Capture attached files BEFORE clearing them
    // These need to be passed to the streaming handler for the API call
    final List<AttachedFile> attachedFilesForApi = List.from(_fileHandler.attachedFiles);
    debugPrint('📎 [SendMessage] Captured ${attachedFilesForApi.length} attached files for API call');

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

      // Store document attachments as JSON-encoded string if present
      final documentAttachments = attachedFilesForApi
          .where((f) => !f.isImage && f.markdownContent != null)
          .map((f) => {
                'fileName': f.fileName,
                'markdownContent': f.markdownContent!,
              })
          .toList();

      if (documentAttachments.isNotEmpty) {
        userMessage['attachments'] = jsonEncode(documentAttachments);
        debugPrint('📄 [AttachmentDebug] Storing ${documentAttachments.length} attachments');
      }

      // Store original AttachedFile objects for resend functionality
      if (attachedFilesForApi.isNotEmpty) {
        userMessage['attachedFilesJson'] = jsonEncode(
          attachedFilesForApi.map((f) => f.toJson()).toList(),
        );
        debugPrint('💾 [AttachmentDebug] Storing ${attachedFilesForApi.length} attached files for resend');
      }

      _messages.add(userMessage);
      debugPrint('💾 [MessageDebug] Message added to _messages list. Total messages: ${_messages.length}');

      _controller.clear();
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
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during persistChat)');
      return;
    }

    // Verify the stored chat ID matches what we expected
    if (storedChat != null && storedChat.id != chatIdForThisMessage) {
      debugPrint('⚠️ [ChatDebug] Chat ID mismatch! Expected: $chatIdForThisMessage, Got: ${storedChat.id}');
    }

    // Keep _activeChatId in sync (should already be correct, but ensure consistency)
    if (storedChat != null) {
      _activeChatId = storedChat.id;

      // ID-BASED: Notify parent when a new chat is created
      if (isNewChat) {
        debugPrint('');
        debugPrint('┌─────────────────────────────────────────────────────────────');
        debugPrint('│ 🆕 [SEND-MOBILE] NEW CHAT CREATED!');
        debugPrint('│ 🆕 [SEND-MOBILE] New chat ID: ${storedChat.id}');
        debugPrint('│ 🆕 [SEND-MOBILE] Calling widget.onChatIdChanged(${storedChat.id})');
        debugPrint('│ 🆕 [SEND-MOBILE] This should update ChatStorageService.selectedChatId');
        debugPrint('└─────────────────────────────────────────────────────────────');
        widget.onChatIdChanged(storedChat.id);

        // Auto-generate title for new chats (fire and forget)
        unawaited(TitleGenerationService.generateAndApplyTitle(
          storedChat.id,
          displayMessageText,
        ));
      }
    }

    // Resolve system prompt with project context (if any)
    final resolvedSystemPrompt = await _resolveSystemPromptForSend();

    // Send with streaming handler using the CAPTURED chatId, not _activeChatId
    // This prevents race conditions where _activeChatId could be changed by callbacks
    debugPrint('📤 [ChatDebug] Sending to streaming handler with chatId: $chatIdForThisMessage');
    debugPrint('📤 [ChatDebug] Sending ${attachedFilesForApi.length} attached files to API');
    if (_selectedProjectId != null) {
      debugPrint('📁 [ChatDebug] Project context included: $_selectedProjectId');
    }
    // NOTE: _isSendingMessage is cleared in _finalizeAiMessage() when streaming completes,
    // NOT here. This prevents race conditions where didUpdateWidget fires while streaming.
    await _streamingHandler.sendMessage(
      userInput: originalUserInput,
      attachedFiles: attachedFilesForApi,
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
    );
  }

  List<Map<String, dynamic>> _buildApiHistory() {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
    for (final Map<String, String> message in _messages) {
      final String? sender = message['sender'];
      final String? text = message['text'];
      if (text == null || text.trim().isEmpty) continue;

      if (sender == 'user') {
        history.add({'role': 'user', 'content': text});
      } else if (sender == 'ai' || sender == 'assistant') {
        history.add({'role': 'assistant', 'content': text});
      }
    }
    return history;
  }

  /// Resolve system prompt with project context (if any)
  Future<String?> _resolveSystemPromptForSend() async {
    // Start with user's base system prompt
    String? basePrompt = _systemPrompt;
    if (basePrompt == null) {
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
        debugPrint('Error resolving system prompt for send: $error');
      }
    }

    // If a project is active, prepend project context
    if (_selectedProjectId != null && kFeatureProjects) {
      try {
        final projectContext = await ProjectMessageService.buildProjectSystemMessage(_selectedProjectId!);
        // Combine project context with user's system prompt
        if (basePrompt != null && basePrompt.isNotEmpty) {
          return '$projectContext\n\n---\n\nAdditional User Instructions:\n$basePrompt';
        }
        return projectContext;
      } catch (error) {
        debugPrint('Error building project system message: $error');
        // Fall back to base prompt if project context fails
      }
    }

    return basePrompt;
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
        debugPrint('🔓 [CancelledMessage] GLOBAL LOCK RELEASED (stream cancelled)');
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

  Future<void> _submitEditedMessage(int index, String newText) async {
    if (index < 0 || index >= _messages.length) return;
    if (_streamingHandler.isStreaming || _streamingHandler.isSending) {
      _showSnackBar('Please wait');
      return;
    }

    setState(() {
      _messages[index]['text'] = newText;
    });

    if (index + 1 < _messages.length &&
        _messages[index + 1]['sender'] == 'ai') {
      setState(() {
        _messages.removeAt(index + 1);
      });
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
              .map((item) => AttachedFile.fromJson(item as Map<String, dynamic>))
              .toList();
          debugPrint('🔄 [ResendDebug] Reconstructed ${attachedFilesForResend.length} attached files for resend');
        }
      } catch (e) {
        debugPrint('🔄 [ResendDebug] Failed to parse attachedFilesJson: $e');
      }
    }

    // Generate chat ID if needed BEFORE persisting
    _activeChatId ??= _uuid.v4();
    final String chatId = _activeChatId!;

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

    // Resolve system prompt with project context (if any)
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
    );
  }

  Future<void> _resendMessageAt(int index) async {
    if (index < 0 || index >= _messages.length) return;
    final String text = (_messages[index]['text'] ?? '').trim();
    if (text.isEmpty) {
      _showSnackBar('Nothing to resend');
      return;
    }
    await _submitEditedMessage(index, text);
  }

  // --- FULLSCREEN EDITOR ---

  Future<void> _openFullscreenEditor() async {
    final String currentText = _controller.text;
    final theme = Theme.of(context);

    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        final TextEditingController dialogController =
            TextEditingController(text: currentText);
        return Dialog.fullscreen(
          child: Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            appBar: AppBar(
              title: const Text('Edit Message'),
              backgroundColor: theme.scaffoldBackgroundColor,
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(dialogController.text);
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.all(16.0),
              child: TextField(
                controller: dialogController,
                autofocus: true,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 16,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  hintText: 'Type your message here...',
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                cursorColor: theme.colorScheme.primary,
              ),
            ),
          ),
        );
      },
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

  Future<void> _loadProviderSlugForModel(String modelId) async {
    if (modelId.isEmpty) {
      if (_selectedProviderSlug != null) {
        setState(() {
          _selectedProviderSlug = null;
        });
      }
      return;
    }

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
      debugPrint('Error loading system prompt: $e');
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
        debugPrint('Loaded saved model preference: $savedModelId');
        // Update the global notifier so dropdown stays in sync
        ModelSelectionDropdown.selectedModelNotifier.value = savedModelId;
        await _loadProviderSlugForModel(savedModelId);
      } else {
        // No model saved - use fallback
        debugPrint('No saved model preference - using fallback');
        const fallbackModelId = 'deepseek/deepseek-chat-v3.1';
        setState(() {
          _selectedModelId = fallbackModelId;
        });
        ModelSelectionDropdown.selectedModelNotifier.value = fallbackModelId;
        await _loadProviderSlugForModel(fallbackModelId);
      }
    } catch (e) {
      debugPrint('Error loading saved model preference: $e');
      // Use fallback on error
      const fallbackModelId = 'deepseek/deepseek-chat-v3.1';
      setState(() {
        _selectedModelId = fallbackModelId;
      });
    }
  }

  bool get _modelSupportsImageInput =>
      ModelCapabilitiesService.supportsImageInputSync(_selectedModelId);

  void _openComingSoonFeature(String featureName) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComingSoonPage(
          title: featureName,
          message: 'Stay tuned for $featureName.',
        ),
      ),
    );
  }

  void _showSnackBar(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        duration: const Duration(seconds: 2),
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final isNearBottom = position.maxScrollExtent - position.pixels < 200;
    if (_showScrollToBottom == isNearBottom) {
      setState(() {
        _showScrollToBottom = !isNearBottom;
      });
    }
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

  String? _formatModelInfo(String? modelId, String? provider) {
    final String normalizedModel = (modelId ?? '').trim();
    final String normalizedProvider = (provider ?? '').trim();
    if (normalizedModel.isEmpty && normalizedProvider.isEmpty) {
      return null;
    }
    if (normalizedModel.isEmpty) {
      return 'Provider: $normalizedProvider';
    }
    if (normalizedProvider.isEmpty) {
      return 'Model: $normalizedModel';
    }
    return 'Model: $normalizedModel • Provider: $normalizedProvider';
  }

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
        40.0 +
        (hasAttachments ? 80.0 : 0.0) +
        32.0 +
        mediaQuery.padding.bottom;
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
              child: Column(
                children: [
                  Expanded(
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
                                  final String? reasoningText =
                                      reasoning.trim().isEmpty
                                      ? null
                                      : reasoning;
                                  final bool isBeingEdited =
                                      _messageActionsHandler
                                          .editingMessageIndex ==
                                      i;
                                  final bool isUser = sender == 'user';

                                  // Parse images from JSON
                                  List<String>? images;
                                  final String? imagesJson = raw['images'];
                                  if (imagesJson != null && imagesJson.isNotEmpty) {
                                    try {
                                      final decoded = jsonDecode(imagesJson);
                                      if (decoded is List) {
                                        images = decoded.cast<String>();
                                      }
                                    } catch (e) {
                                      debugPrint('Failed to decode images JSON: $e');
                                    }
                                  }

                                  // Parse document attachments from JSON
                                  List<DocumentAttachment>? attachments;
                                  final String? attachmentsJson = raw['attachments'];
                                  if (attachmentsJson != null && attachmentsJson.isNotEmpty) {
                                    try {
                                      final decoded = jsonDecode(attachmentsJson);
                                      if (decoded is List) {
                                        attachments = decoded
                                            .map((item) => DocumentAttachment.fromJson(
                                                item as Map<String, dynamic>))
                                            .toList();
                                        debugPrint('📄 [AttachmentDebug] Extracted ${attachments.length} attachments from message $i');
                                      }
                                    } catch (e) {
                                      debugPrint('📄 [AttachmentDebug] Failed to decode attachments JSON: $e');
                                    }
                                  }

                                  // Parse TPS value from message
                                  final tpsStr = raw['tps'];
                                  double? tps;
                                  if (tpsStr != null && tpsStr.isNotEmpty) {
                                    tps = double.tryParse(tpsStr);
                                  }

                                  return RepaintBoundary(
                                    child: MessageBubble(
                                      key: ValueKey('msg_$i'),
                                      message: displayText,
                                      reasoning: reasoningText,
                                      isUser: isUser,
                                      maxWidth: isUser
                                          ? expandedInputWidth * 0.7
                                          : expandedInputWidth,
                                      isReasoningStreaming: isStreamingMessage,
                                      modelLabel: modelLabel,
                                      tps: tps,
                                      images: images,
                                      attachments: attachments,
                                      actions: _messageActionsHandler
                                          .buildActionsForMessage(
                                            index: i,
                                            messageText: displayText,
                                            isUser: isUser,
                                            isStreaming: isStreamingMessage,
                                            onEdit: (index) {
                                              setState(() {
                                                _messageActionsHandler
                                                    .startEdit(index);
                                              });
                                            },
                                            onResendMessage: _resendMessageAt,
                                          ),
                                      isEditing: isBeingEdited,
                                      initialEditText: isBeingEdited
                                          ? displayText
                                          : null,
                                      onSubmitEdit: isBeingEdited && isUser
                                          ? (newText) =>
                                                _submitEditedMessage(i, newText)
                                          : null,
                                      onCancelEdit: isBeingEdited
                                          ? () {
                                              setState(() {
                                                _messageActionsHandler
                                                    .cancelEdit();
                                              });
                                            }
                                          : null,
                                      showReasoningTokens: widget.showReasoningTokens,
                                      showModelInfo: widget.showModelInfo,
                                      showTps: widget.showTps,
                                    ),
                                  );
                                },
                              ),
                          ),
                        ),
                      )
                    : const SizedBox.expand(),
                        // Scroll-to-bottom button (centered above input)
                        if (_showScrollToBottom && hasMessages)
                          Positioned(
                            bottom: 12,
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
                      ],
                    ),
              ),
              Padding(
                padding: EdgeInsets.only(
                  left: effectiveHorizontalPadding,
                  right: effectiveHorizontalPadding,
                  bottom: effectiveHorizontalPadding,
                ),
                child: SafeArea(
                  top: false,
                  child: Center(
                    child: SizedBox(
                      width: expandedInputWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Project indicator
                          if (kFeatureProjects && _selectedProjectId != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _buildProjectIndicator(theme),
                            ),
                          if (hasAttachments)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: _kAttachmentBarMarginBottom,
                              ),
                              child: AttachmentPreviewBar(
                                files: _fileHandler.attachedFiles,
                                onRemove: _fileHandler.removeFile,
                              ),
                            ),
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

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _audioHandler.isMicActive
              ? Colors.red.withValues(alpha: 0.3)
              : iconFg.withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          buildTinyIconButton(
            icon: Icons.add_rounded,
            onTap: _handleAddAttachmentTap,
            isActive: hasAttachments,
            color: iconFg,
          ),
          // Image Generation Button
          if (widget.imageGenEnabled) ...[
            const SizedBox(width: 2),
            buildTinyIconButton(
              icon: Icons.auto_awesome,
              onTap: _isGeneratingImage
                  ? () {} // No-op while generating
                  : () {
                      setState(() {
                        _isImageGenMode = !_isImageGenMode;
                      });
                      debugPrint('Image Gen mode toggled: $_isImageGenMode');
                    },
              isActive: _isImageGenMode || _isGeneratingImage,
              color: _isImageGenMode || _isGeneratingImage ? accent : iconFg,
            ),
          ],
          const SizedBox(width: 2),
          GestureDetector(
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: ModelSelectionDropdown(
                initialSelectedModelId: _selectedModelId,
                onModelSelected: (newModelId) {
                  setState(() {
                    _selectedModelId = newModelId;
                  });
                },
                textFieldFocusNode: _textFieldFocusNode,
                isCompactMode: true,
                compactLabel: '#',
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _audioHandler.isMicActive
                ? Container(
                    height: 30,
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
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
                    ),
                  )
                : buildKeyboardListener(
                    focusNode: _rawKeyboardListenerFocusNode,
                    controller: _controller,
                    onSend: _isImageGenMode && !_isCurrentChatStreaming
                        ? _generateImage
                        : _sendMessage,
                    child: Scrollbar(
                      controller: _composerScrollController,
                      child: TextField(
                        controller: _controller,
                        focusNode: _textFieldFocusNode,
                        autofocus: false,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        scrollController: _composerScrollController,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 14,
                          height: 1.2,
                        ),
                        minLines: 1,
                        maxLines: 5,
                        decoration: InputDecoration(
                          hintText: 'Ask me anything',
                          hintStyle: TextStyle(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.5,
                            ),
                            fontSize: 14,
                          ),
                          filled: true,
                          fillColor: bg.withValues(alpha: 0.98),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          isDense: true,
                        ),
                        cursorColor: accent,
                        cursorWidth: 1.5,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 4),
          if (_showFullscreenButton && !_audioHandler.isMicActive) ...[
            buildTinyIconButton(
              icon: Icons.fullscreen_rounded,
              onTap: _openFullscreenEditor,
              isActive: false,
              color: iconFg,
            ),
            const SizedBox(width: 2),
          ],
          // Mic button for audio recording/transcription (always shown)
          buildTinyIconButton(
            icon: _audioHandler.isMicActive
                ? Icons.stop_rounded
                : Icons.mic_rounded,
            onTap: _handleMicTap,
            isActive: _audioHandler.isMicActive,
            color: _audioHandler.isMicActive ? Colors.red : iconFg,
          ),
          const SizedBox(width: 2),
          buildTinyActionButton(
            icon: _audioHandler.isMicActive
                ? Icons.send_rounded
                : ((_isCurrentChatStreaming || _isSendingMessage)
                      ? Icons.stop_rounded
                      : _isImageGenMode
                          ? Icons.auto_awesome
                          : (_controller.text.trim().isEmpty && !hasAttachments
                                ? (kFeatureVoiceMode ? Icons.graphic_eq_rounded : Icons.arrow_upward_rounded)
                                : Icons.arrow_upward_rounded)),
            onTap: _audioHandler.isMicActive
                ? _handleAudioSend
                : ((_isCurrentChatStreaming || _isSendingMessage)
                      ? _cancelCurrentOperation
                      : _isImageGenMode && !_isGeneratingImage
                          ? _generateImage
                          : (_controller.text.trim().isEmpty && !hasAttachments && kFeatureVoiceMode
                                ? () => _openComingSoonFeature('Voice Mode')
                                : _sendMessage)),
            color: _audioHandler.isMicActive
                ? accent
                : ((_isCurrentChatStreaming || _isSendingMessage) ? Colors.red : accent),
            isLoading: _audioHandler.isTranscribingAudio || _isGeneratingImage,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
