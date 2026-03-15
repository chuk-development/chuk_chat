// lib/platform_specific/chat/chat_ui_desktop.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:math' as math; // For min/max
import 'dart:async';
import 'dart:convert';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/widgets/message_bubble.dart'
    show MessageBubble, MessageBubbleAction, DocumentAttachment;
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/tool_image_result_service.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/widgets/project_panel.dart';
import 'package:chuk_chat/widgets/project_selection_dropdown.dart';
import 'package:chuk_chat/services/project_message_service.dart';
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
  final String? projectId;
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
  // Tool-calling settings
  final bool toolCallingEnabled;
  final bool toolDiscoveryMode;
  final bool showToolCalls;
  final bool allowMarkdownToolCalls;
  // Voice transcription settings
  final bool autoSendVoiceTranscription;

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
    this.projectId,
    this.onExitProject,
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
    this.autoSendVoiceTranscription = false,
  });

  @override
  State<ChukChatUIDesktop> createState() => ChukChatUIDesktopState(); // RENAMED STATE
}

class ChukChatUIDesktopState extends State<ChukChatUIDesktop>
    with SingleTickerProviderStateMixin {
  // RENAMED STATE
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  String? _activeChatId;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _composerScrollController = ScrollController();
  late ChatApiService _chatApiService;
  late final FocusNode _textFieldFocusNode;
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();

  late AnimationController _animCtrl;
  String _selectedModelId = ''; // Will be loaded from user preferences
  String? _selectedProviderSlug;
  String? _systemPrompt;
  String? _selectedProjectId;
  late final VoidCallback _modelSelectionListener;

  late final AudioRecordingHandler _audioHandler;
  late final MessageActionsHandler _messageActionsHandler;
  late final ChatPersistenceHandler _persistenceHandler;
  bool _isSending = false;
  int _sendOperationCounter = 0;
  int? _activeSendOperationId;
  int? _cancelledSendOperationId;

  bool _showScrollToBottom = false;
  bool _isLoadingChat = false; // Loading indicator for chat switching
  StreamSubscription<void>? _providerRefreshSubscription;
  final StreamingManager _streamingManager = StreamingManager();
  final ToolCallHandler _toolCallHandler = ToolCallHandler();

  // Computed property - checks if CURRENT chat is streaming
  bool get _isStreaming =>
      _activeChatId != null && _streamingManager.isStreaming(_activeChatId!);
  Timer? _autoSaveTimer;

  late final DesktopFileHandler _fileHandler;
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
  static const double _kHorizontalPaddingLarge = 16.0;
  static const double _kHorizontalPaddingSmall = 8.0;
  static const double _kShowScrollButtonDistance = 260.0;
  static const double _kHideScrollButtonDistance = 140.0;
  static const double _kMessageListBottomLift = 40.0;
  static const double _kStreamingBottomScrollSlack = 180.0;

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
        }
      };
    _textFieldFocusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        // Ctrl+V / Cmd+V: handle paste (images, text, long text → attachment)
        if (event.logicalKey == LogicalKeyboardKey.keyV &&
            (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed)) {
          unawaited(_clipboardHandler.handleSmartPaste(_controller));
          return KeyEventResult.handled;
        }

        if (event.logicalKey != LogicalKeyboardKey.enter) {
          return KeyEventResult.ignored;
        }

        // Shift+Enter: insert newline manually
        if (HardwareKeyboard.instance.isShiftPressed) {
          final text = _controller.text;
          final sel = _controller.selection;
          final newText = text.replaceRange(sel.start, sel.end, '\n');
          _controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: sel.start + 1),
          );
          return KeyEventResult.handled;
        }

        // Bare Enter: send message, consume to prevent newline
        unawaited(_sendMessage());
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
      ..onScrollToBottom = () => _scrollChatToBottom(force: true);
    _chatApiService = ChatApiService(
      onUploadStatusUpdate: _fileHandler.handleFileUploadUpdate,
    );
    _fileHandler.initialize(_chatApiService);
    _clipboardHandler = DesktopClipboardHandler(
      onProcessFilePaths: _fileHandler.processFilePaths,
    );
    _scrollController.addListener(_onScrollChanged);
    _selectedProjectId = widget.projectId;
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
      unawaited(_loadProviderSlugForModel(newModelId));
    };
    ModelSelectionDropdown.selectedModelListenable.addListener(
      _modelSelectionListener,
    );

    // Listen for provider changes from model selector page
    _providerRefreshSubscription = ModelSelectionEventBus().refreshStream
        .listen((_) {
          // Reload provider slug when settings are changed
          unawaited(_loadProviderSlugForModel(_selectedModelId));
        });
  }

  @override
  void didUpdateWidget(covariant ChukChatUIDesktop oldWidget) {
    // RENAMED WIDGET TYPE
    super.didUpdateWidget(oldWidget);

    // Sync project ID from parent if it changes
    if (widget.projectId != oldWidget.projectId) {
      setState(() {
        _selectedProjectId = widget.projectId;
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
    // Don't cancel streams - they continue in background
    // _streamingManager handles all streams globally
    _autoSaveTimer?.cancel();
    _audioHandler.onLevelsChanged = null;
    _providerRefreshSubscription?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _composerScrollController.dispose();
    _textFieldFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    _animCtrl.dispose();
    unawaited(_audioHandler.dispose());
    _persistenceHandler.dispose();
    ModelSelectionDropdown.selectedModelListenable.removeListener(
      _modelSelectionListener,
    );
    super.dispose();
  }

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

    // CRITICAL: Set global loading lock to prevent rapid chat switching
    // Sidebar checks this flag before allowing chat selection
    ChatStorageService.isLoadingChat = true;

    // Show loading indicator immediately
    setState(() {
      _isLoadingChat = true;
    });
    _clearMessageDecodeCaches();

    // Use async function to handle lazy loading
    _loadChatByIdAsync(chatId);
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
        // Clean up completed stream data only after successful application
        if (desktopChatHasCompleted) {
          _streamingManager.consumeCompletedStream(_activeChatId!);
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
      _showScrollToBottom = false;
    });
    _scrollChatToBottom(animate: false, force: true);
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

  void newChat() {
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
    });

    // Notify parent that we're now on a new chat (null ID)
    widget.onChatIdChanged(null);
    _scrollChatToBottom(force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

    // Persist old chat in background (don't await)
    // CRITICAL: Use silent=true to prevent persistence handler from changing
    // _activeChatId or calling widget.onChatIdChanged - we're now on a NEW chat!
    // Sidebar auto-updates via ChatStorageService.changes stream
    if (messagesToSave != null && chatIdToSave != null) {
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

  void _openComingSoonFeature(String featureName) {
    if (!mounted) return;
    ChatUiHelpers.openComingSoonFeature(context, featureName);
  }

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
        // No model saved - keep empty, user must select one
        if (kDebugMode) {
          debugPrint('No saved model preference - user must select a model');
        }
        // _selectedModelId stays empty
      }
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

    // If a project is active, prepend project context
    if (_selectedProjectId != null) {
      try {
        final projectContext =
            await ProjectMessageService.buildProjectSystemMessage(
              _selectedProjectId!,
            );
        // Combine project context with user's system prompt
        if (resolvedPrompt != null && resolvedPrompt.isNotEmpty) {
          resolvedPrompt =
              '$projectContext\n\n---\n\nAdditional User Instructions:\n$resolvedPrompt';
        } else {
          resolvedPrompt = projectContext;
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Error building project system message: $error');
        }
        // Fall back to base prompt if project context fails
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

  bool get _modelSupportsImageInput =>
      ChatUiHelpers.modelSupportsImageInput(_selectedModelId);

  // State for drag and drop
  bool _isDraggingFiles = false;

  Future<void> _handleMicTap() async {
    if (_audioHandler.isMicActive) {
      await _audioHandler.stopRecording();
      _audioHandler.onLevelsChanged = null;
      if (!mounted) return;
      setState(() {
        _audioHandler.resetAudioLevels();
      });
    } else {
      String? accessToken;
      try {
        final session =
            await SupabaseService.refreshSession() ??
            SupabaseService.auth.currentSession;
        accessToken = session?.accessToken;
      } catch (_) {}

      final bool started = await _audioHandler.startRecording(
        accessToken: accessToken,
      );
      if (!mounted) return;
      if (started) {
        setState(() {
          _audioHandler.resetAudioLevels();
        });
        // Drive visualiser directly from amplitude data (matches the
        // pre-refactor inline behaviour where setState was called inside
        // _handleAmplitudeSample / _computeAmplitudeFromPcm).
        _audioHandler.onLevelsChanged = () {
          if (mounted && _audioHandler.isMicActive) {
            setState(() {});
          }
        };
      } else {
        _showSnackBar('Mic access failed');
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
    if (!mounted) return;
    setState(() {
      _audioHandler.resetAudioLevels();
    });

    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null) {
      _showSnackBar('Session expired. Please sign in again.');
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
      _showSnackBar(result.error ?? 'Transcription failed');
      setState(() {});
      return;
    }

    if (result.text != null && result.text!.isNotEmpty) {
      setState(() {
        _controller.text = result.text!;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: result.text!.length),
        );
        // Set sending flag instantly so loading indicator shows without gap
        if (widget.autoSendVoiceTranscription) {
          _isSending = true;
        }
      });

      // If auto-send is enabled, send the message immediately
      if (widget.autoSendVoiceTranscription) {
        await _sendMessage();
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
    setState(() {
      _messageActionsHandler.startEdit(index);
    });
  }

  void _cancelEditMessage() {
    setState(() {
      _messageActionsHandler.cancelEdit();
    });
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

  List<MessageBubbleAction> _buildMessageActionsForIndex(
    int index,
    MessageRenderData data,
  ) {
    if (!_isValidMessageIndex(index)) {
      return const <MessageBubbleAction>[];
    }

    final Map<String, String> rawMessage = _messages[index];
    final String messageText = rawMessage['text'] ?? '';
    final bool hasFailedToolCalls =
        data.toolCalls != null &&
        data.toolCalls!.any((t) => t.status == ToolCallStatus.error);

    return _messageActionsHandler.buildActionsForMessage(
      index: index,
      messageText: messageText,
      isUser: data.isUser,
      isStreaming: data.isReasoningStreaming,
      onEdit: _editMessageAt,
      onResendMessage: _resendMessageAt,
      hasFailedToolCalls: hasFailedToolCalls,
    );
  }

  Widget _buildAudioVisualizer({required Color accent, required Color iconFg}) {
    // Desktop adaptation of the mobile audio visualizer with gradient + glow
    const int barCount = 40; // More bars for wider desktop layout
    final levels = _audioHandler.audioLevels;
    final int startIndex = levels.length > barCount
        ? levels.length - barCount
        : 0;

    return SizedBox(
      key: const ValueKey<String>('audio-visualizer'),
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(barCount, (index) {
          final int levelIndex = startIndex + index;
          final double rawLevel = levelIndex < levels.length
              ? levels[levelIndex]
              : 0.0;

          // Exponential scaling for more dramatic response
          final double level = rawLevel * rawLevel;

          // Bar height with good range (3-28px)
          final double barHeight = (level * 26 + 3).clamp(3.0, 28.0);

          // Vary opacity based on level for depth effect
          final double opacity = (0.6 + (level * 0.4)).clamp(0.6, 1.0);

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0.8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 50),
                curve: Curves.easeOut,
                height: barHeight,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      accent.withValues(alpha: opacity),
                      accent.withValues(alpha: opacity * 0.7),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: level > 0.3
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.3),
                            blurRadius: 2,
                            spreadRadius: 0.5,
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

  // In-memory cache for resolved Base64 images (storage path -> data URL)
  static final Map<String, String> _imageBase64Cache = {};
  static const int _maxImageCacheSize = 10;

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
    unawaited(
      DiagnosticsLogService.info(
        'chat_ui',
        'Scroll threshold toggled',
        data: {
          'show_scroll_button': nextShowScrollButton,
          'distance_to_bottom': distanceToBottom.round(),
          'pixels': position.pixels.round(),
          'max_scroll_extent': position.maxScrollExtent.round(),
          'show_threshold': _kShowScrollButtonDistance.round(),
          'hide_threshold': _kHideScrollButtonDistance.round(),
        },
      ),
    );
  }

  void _scrollChatToBottom({bool animate = true, bool force = false}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      // Only auto-scroll if user is already near bottom (within 100px) or force is true
      final position = _scrollController.position;
      final isNearBottom = position.maxScrollExtent - position.pixels < 100;

      if (force || isNearBottom) {
        if (animate) {
          _scrollController.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(position.maxScrollExtent);
        }
      }
    });
  }

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
    double inputAreaTotalHeight =
        inputAreaVisualHeight +
        (2 *
            effectiveHorizontalPadding); // accounting for total vertical padding around the searchbar container

    // Determine if the chat is currently empty (no messages, no attached files)
    final bool isChatEmpty = _messages
        .isEmpty; // This refers to the chat history, not just text input
    // On desktop, it centers when empty.
    final bool showInputAreaCentered = isChatEmpty;

    // Determine the target width for the input area
    final double targetInputWidth = showInputAreaCentered
        ? centeredInputWidth
        : expandedInputWidth;

    // Check if we're in project mode
    final bool isProjectMode = widget.projectId != null;

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
                      _modelSupportsImageInput;
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
                  final bool isMessageSendActive = _isStreaming || _isSending;
                  final double messageListBottomPadding =
                      _kMessageListBottomLift +
                      (isMessageSendActive ? _kStreamingBottomScrollSlack : 0);

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
                          bottom: inputAreaTotalHeight,
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
                                child: SelectionArea(
                                  contextMenuBuilder: _buildMessageContextMenu,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTapDown: (_) {
                                      // Ensure keyboard shortcuts such as Ctrl+C
                                      // target message selection instead of the composer.
                                      FocusScope.of(context).unfocus();
                                    },
                                    child: ListView.builder(
                                      controller: _scrollController,
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
                                        return RepaintBoundary(
                                          child: MessageBubble(
                                            key: ValueKey('msg_$i'),
                                            message: data.displayText,
                                            reasoning: reasoningText,
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
                                            images: data.images,
                                            imageCostEur: data.imageCostEur,
                                            imageGeneratedAt:
                                                data.imageGeneratedAt,
                                            attachments: data.attachments,
                                            actions:
                                                _buildMessageActionsForIndex(
                                                  i,
                                                  data,
                                                ),
                                            isEditing: isBeingEdited,
                                            initialEditText: isBeingEdited
                                                ? data.displayText
                                                : null,
                                            onSubmitEdit:
                                                isBeingEdited && data.isUser
                                                ? (
                                                    newText,
                                                  ) => _submitEditedMessage(
                                                    i,
                                                    newText,
                                                    removeFollowingAssistant:
                                                        false,
                                                    clearMessagesBelow: true,
                                                  )
                                                : null,
                                            onCancelEdit: isBeingEdited
                                                ? _cancelEditMessage
                                                : null,
                                            showReasoningTokens:
                                                widget.showReasoningTokens,
                                            showModelInfo: widget.showModelInfo,
                                            showTps: widget.showTps,
                                            onAskUserAnswer:
                                                _askUserCallbackForIndex(
                                                  i,
                                                  data,
                                                ),
                                            onRetry:
                                                !data.isUser &&
                                                    !data.isStreamingMessage
                                                ? () => _resendMessageAt(i)
                                                : null,
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
                      // Scroll-to-bottom button (centered above input)
                      if (_showScrollToBottom && !isChatEmpty)
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
                                        _scrollChatToBottom(force: true),
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
                            child: Column(
                              mainAxisSize: MainAxisSize
                                  .min, // Crucial for column inside AnimatedPositioned/Center
                              children: [
                                // Search Bar (attachment bar is now inside)
                                _buildSearchBar(
                                  isCompactMode: widget.isCompactMode,
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
                    ],
                  );
                },
              ),
            ),
          ),
          // Project panel (right side) - only shown in project mode
          if (isProjectMode && widget.projectId != null)
            ProjectPanel(
              projectId: widget.projectId!,
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
                    onRemove: (fileId) {
                      _fileHandler.removeAttachedFile(fileId);
                      Future.delayed(
                        Duration.zero,
                        () => _textFieldFocusNode.requestFocus(),
                      );
                    },
                  ),
                ),
              // Text field with right padding to avoid send button overlap
              Padding(
                padding: EdgeInsets.only(right: btnW + 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: Scrollbar(
                    controller: _composerScrollController,
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
                        hintText: hasAttachments
                            ? 'Add a message or send documents'
                            : 'Ask me anything !',
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
                          ? _buildAudioVisualizer(
                              accent: accent,
                              iconFg: iconFg,
                            )
                          : Row(
                              key: const ValueKey<String>(
                                'default-mic-controls',
                              ),
                              children: [
                                // Add Button (File Upload)
                                _buildIconBtn(
                                  icon: Icons.add_rounded,
                                  iconSize: 24,
                                  onTap: () {
                                    _fileHandler.modelSupportsImageInput =
                                        _modelSupportsImageInput;
                                    _fileHandler.uploadFiles();
                                  },
                                  isActive: false,
                                  debugLabel: 'Add button',
                                ),
                                // Project Selection Dropdown (only when feature enabled)
                                if (kFeatureProjects) ...[
                                  const SizedBox(width: 8),
                                  ProjectSelectionDropdown(
                                    selectedProjectId: _selectedProjectId,
                                    onProjectSelected: (projectId) {
                                      if (kDebugMode) {
                                        debugPrint(
                                          '📁 onProjectSelected callback: $projectId (was: $_selectedProjectId)',
                                        );
                                      }
                                      setState(() {
                                        _selectedProjectId = projectId;
                                      });
                                      if (kDebugMode) {
                                        debugPrint(
                                          '📁 After setState: $_selectedProjectId',
                                        );
                                      }
                                    },
                                    textFieldFocusNode: _textFieldFocusNode,
                                  ),
                                ],
                                // Spacer to push model dropdown to the right edge
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: ModelSelectionDropdown(
                                      key: const ValueKey<String>(
                                        'desktop-model-selection-dropdown',
                                      ),
                                      initialSelectedModelId: _selectedModelId,
                                      onModelSelected: (newModelId) {
                                        setState(() {
                                          _selectedModelId = newModelId;
                                        });
                                        if (kDebugMode) {
                                          debugPrint(
                                            'Selected model ID: $_selectedModelId',
                                          );
                                        }
                                      },
                                      textFieldFocusNode: _textFieldFocusNode,
                                      isCompactMode: isCompactMode,
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
                        _sendMessage();
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
