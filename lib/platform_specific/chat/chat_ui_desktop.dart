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
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/widgets/message_bubble.dart'
    show MessageBubble, MessageBubbleAction, DocumentAttachment;
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/tool_image_result_service.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/widgets/project_panel.dart';
import 'package:chuk_chat/widgets/project_selection_dropdown.dart';
import 'package:chuk_chat/services/project_message_service.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/utils/tool_parser.dart';

import 'package:file_picker/file_picker.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:uuid/uuid.dart';
import 'package:record/record.dart';
import 'package:http/http.dart' as http_client;
import 'package:chuk_chat/utils/permission_handler_stub.dart'
    if (dart.library.io) 'package:permission_handler/permission_handler.dart';
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/desktop_drop_stub.dart'
    if (dart.library.io) 'package:desktop_drop/desktop_drop.dart';
import 'package:pasteboard/pasteboard.dart';

class _MessageRenderData {
  const _MessageRenderData({
    required this.sender,
    required this.displayText,
    required this.reasoning,
    required this.isReasoningStreaming,
    this.modelLabel,
    this.modelProvider,
    this.tps,
    this.images,
    this.imageCostEur,
    this.imageGeneratedAt,
    this.attachments,
    this.toolCalls,
    this.contentBlocks,
    this.isStreamingMessage = false,
  });

  final String sender;
  final String displayText;
  final String reasoning;
  final bool isReasoningStreaming;
  final String? modelLabel;
  final String? modelProvider;
  final double? tps;
  final List<String>? images;
  final double? imageCostEur;
  final DateTime? imageGeneratedAt;
  final List<DocumentAttachment>? attachments;
  final List<ToolCall>? toolCalls;
  final List<ContentBlock>? contentBlocks;
  final bool isStreamingMessage;

  bool get isUser => sender == 'user';
}

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
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();

  late AnimationController _animCtrl;
  String _selectedModelId = ''; // Will be loaded from user preferences
  String? _selectedProviderSlug;
  String? _systemPrompt;
  String? _selectedProjectId;
  late final VoidCallback _modelSelectionListener;

  bool _isMicActive = false;
  final List<double> _audioLevels = List<double>.filled(
    32,
    0.0,
    growable: true,
  );
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Amplitude>? _amplitudeSub;
  String? _lastRecordedFilePath;
  Uint8List? _lastRecordedBytes;
  String? _activeRecordingPath;
  bool _isSending = false;
  bool _showScrollToBottom = false;
  bool _isTranscribingAudio = false;
  bool _isLoadingChat = false; // Loading indicator for chat switching
  StreamSubscription<void>? _providerRefreshSubscription;
  final StreamingManager _streamingManager = StreamingManager();
  final ToolCallHandler _toolCallHandler = ToolCallHandler();

  // Computed property - checks if CURRENT chat is streaming
  bool get _isStreaming =>
      _activeChatId != null && _streamingManager.isStreaming(_activeChatId!);
  Timer? _autoSaveTimer;
  int? _editingMessageIndex;

  final List<AttachedFile> _attachedFiles = [];
  final Uuid _uuid = Uuid();

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kSearchBarContentHeight = 135.0;
  static const double _kAttachmentBarHeight = 40.0;
  static const double _kAttachmentBarMarginBottom =
      8.0; // Margin between attachment bar and search bar
  static const double _kHorizontalPaddingLarge = 16.0;
  static const double _kHorizontalPaddingSmall = 8.0;
  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _chatApiService = ChatApiService(
      onUploadStatusUpdate: _handleFileUploadUpdate,
    );
    _scrollController.addListener(_onScrollChanged);
    _selectedProjectId = widget.projectId;
    _loadChatById(widget.selectedChatId);

    // Defer network-dependent loading to after first frame for faster startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      unawaited(_loadSavedModelPreference());
      unawaited(_loadSystemPrompt());
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
        // Sync the parent back to our active chat
        widget.onChatIdChanged(_activeChatId);
        return;
      }

      // CRITICAL: NO persist during chat switch!
      // Persisting here causes data corruption because _messages may already contain
      // the NEW chat's content by the time didUpdateWidget fires (due to async timing).
      // Instead, we rely on:
      // 1. Immediate persist after message send/receive (in _persistChatInternal)
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
    _providerRefreshSubscription?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _composerScrollController.dispose();
    _textFieldFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    _animCtrl.dispose();
    unawaited(_stopMicRecording());
    _amplitudeSub?.cancel();
    unawaited(_audioRecorder.dispose());
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

    // Use async function to handle lazy loading
    _loadChatByIdAsync(chatId);
  }

  Future<void> _loadChatByIdAsync(String? chatId) async {
    if (!mounted) return;

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
      _attachedFiles.clear();
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
          storedChat = await ChatStorageService.loadFullChat(chatId);

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
                return map;
              }),
            );
          // Instant visibility
          _animCtrl.value = 1.0;
        } else {
          // Chat load failed - treat as new chat
          if (kDebugMode) {
            debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Chat $chatId load failed!');
          }
          _messages.clear();
          _animCtrl.reset();
          _attachedFiles.clear();
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
        _attachedFiles.clear();
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

    setState(() {
      _isLoadingChat = false;
      _isMicActive = false;
      _isSending = _isStreaming; // Reset sending state based on current chat
      _showScrollToBottom = false;
      _resetAudioLevels();
    });
    _scrollChatToBottom(animate: false, force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
  }

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

    // Clear UI immediately for instant response
    setState(() {
      _messages.clear();
      _animCtrl.reset();
      _activeChatId = null;
      _isMicActive = false;
      _isSending = false; // Reset for new chat
      _attachedFiles.clear();
      _resetAudioLevels();
    });

    // Notify parent that we're now on a new chat (null ID)
    widget.onChatIdChanged(null);
    _scrollChatToBottom(force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

    // Persist old chat in background (don't await)
    // CRITICAL: Use silent=true to prevent _persistChatInternal from changing
    // _activeChatId or calling widget.onChatIdChanged - we're now on a NEW chat!
    // Sidebar auto-updates via ChatStorageService.changes stream
    if (messagesToSave != null && chatIdToSave != null) {
      unawaited(
        _persistChatInternal(messagesToSave, chatIdToSave, silent: true),
      );
    }
  }

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

    // If a project is active, prepend project context
    if (_selectedProjectId != null) {
      try {
        final projectContext =
            await ProjectMessageService.buildProjectSystemMessage(
              _selectedProjectId!,
            );
        // Combine project context with user's system prompt
        if (basePrompt != null && basePrompt.isNotEmpty) {
          return '$projectContext\n\n---\n\nAdditional User Instructions:\n$basePrompt';
        }
        return projectContext;
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Error building project system message: $error');
        }
        // Fall back to base prompt if project context fails
      }
    }

    return basePrompt;
  }

  bool get _modelSupportsImageInput =>
      ModelCapabilitiesService.supportsImageInputSync(_selectedModelId);

  bool _isImageExtension(String extension) {
    return FileConstants.imageExtensions.contains(extension);
  }

  // State for drag and drop
  bool _isDraggingFiles = false;

  Future<void> _handleMicTap() async {
    if (_isMicActive) {
      await _stopMicRecording();
      if (!mounted) return;
      setState(() {
        _isMicActive = false;
        _resetAudioLevels();
      });
    } else {
      final bool started = await _startMicRecording();
      if (!mounted) return;
      if (started) {
        setState(() {
          _isMicActive = true;
          _resetAudioLevels();
        });
      }
    }
    if (kDebugMode) {
      debugPrint('Mic button toggled: $_isMicActive');
    }
  }

  Future<void> _handleAudioSend() async {
    if (!_isMicActive || _isTranscribingAudio) {
      return;
    }
    await _stopMicRecording(keepFile: true);
    if (!mounted) return;
    setState(() {
      _isMicActive = false;
      _resetAudioLevels();
    });
    if (kIsWeb) {
      final Uint8List? bytes = _lastRecordedBytes;
      if (bytes == null || bytes.isEmpty) {
        _showSnackBar('No audio recording available.');
        return;
      }

      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;
      if (session == null) {
        _lastRecordedBytes = null;
        _showSnackBar('Session expired. Please sign in again.');
        await SupabaseService.signOut();
        return;
      }
      final accessToken = session.accessToken;
      if (accessToken.isEmpty) {
        _lastRecordedBytes = null;
        _showSnackBar('Unable to authenticate your session.');
        return;
      }

      if (!mounted) return;
      setState(() {
        _isTranscribingAudio = true;
      });

      try {
        final transcription = await _chatApiService.transcribeAudioBytes(
          bytes: bytes,
          filename: 'recording.webm',
          accessToken: accessToken,
        );
        final String text = transcription.text.trim();
        if (text.isEmpty) {
          _showSnackBar('Transcription returned no text.');
        } else {
          setState(() {
            _controller.text = text;
            _controller.selection = TextSelection.fromPosition(
              TextPosition(offset: text.length),
            );
          });
          Future.delayed(
            Duration.zero,
            () => _textFieldFocusNode.requestFocus(),
          );
        }
      } on TranscriptionException catch (error) {
        switch (error.statusCode) {
          case 401:
            _showSnackBar('Session expired. Please sign in again.');
            await SupabaseService.signOut();
            break;
          case 502:
            _showSnackBar(
              'Transcription service is unavailable. Please try again shortly.',
            );
            break;
          default:
            final String message = error.message.isNotEmpty
                ? error.message
                : 'Failed to transcribe audio.';
            _showSnackBar(message);
        }
      } on TimeoutException {
        _showSnackBar('Transcription timed out. Please try again.');
      } catch (error) {
        _showSnackBar('Unexpected transcription error: $error');
      } finally {
        _lastRecordedBytes = null;
        if (mounted) {
          setState(() {
            _isTranscribingAudio = false;
          });
        }
      }
      return;
    }

    final String? audioPath = _lastRecordedFilePath;
    if (audioPath == null) {
      _showSnackBar('No audio recording available.');
      return;
    }
    final File audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      _showSnackBar('Recorded audio file is missing.');
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      return;
    }

    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _showSnackBar('Session expired. Please sign in again.');
      await SupabaseService.signOut();
      return;
    }
    final accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _showSnackBar('Unable to authenticate your session.');
      return;
    }

    if (!mounted) return;
    setState(() {
      _isTranscribingAudio = true;
    });

    try {
      final transcription = await _chatApiService.transcribeAudioFile(
        file: audioFile,
        accessToken: accessToken,
      );
      final String text = transcription.text.trim();
      if (text.isEmpty) {
        _showSnackBar('Transcription returned no text.');
      } else {
        setState(() {
          _controller.text = text;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: text.length),
          );
        });
        Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      }
    } on TranscriptionException catch (error) {
      switch (error.statusCode) {
        case 401:
          _showSnackBar('Session expired. Please sign in again.');
          await SupabaseService.signOut();
          break;
        case 502:
          _showSnackBar(
            'Transcription service is unavailable. Please try again shortly.',
          );
          break;
        default:
          final String message = error.message.isNotEmpty
              ? error.message
              : 'Failed to transcribe audio.';
          _showSnackBar(message);
      }
    } on TimeoutException {
      _showSnackBar('Transcription timed out. Please try again.');
    } catch (error) {
      _showSnackBar('Unexpected transcription error: $error');
    } finally {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      if (mounted) {
        setState(() {
          _isTranscribingAudio = false;
        });
      }
    }
  }

  Future<bool> _startMicRecording() async {
    try {
      if (!await _ensureMicPermission()) {
        return false;
      }

      if (!await _audioRecorder.hasPermission()) {
        _showSnackBar('Microphone permission is required to record audio.');
        return false;
      }

      if (await _audioRecorder.isRecording()) {
        return true;
      }

      _resetAudioLevels();
      _amplitudeSub?.cancel();

      if (kIsWeb) {
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.opus,
            sampleRate: 16000,
            bitRate: 64000,
          ),
          path: '',
        );
      } else {
        final String path = await _createRecordingPath();
        _activeRecordingPath = path;

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            sampleRate: 16000,
            bitRate: 64000,
          ),
          path: path,
        );
      }

      _amplitudeSub = _audioRecorder
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen(_handleAmplitudeSample);

      return true;
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to start microphone: $error\n$stackTrace');
      }
      _showSnackBar('Unable to access microphone. Please try again.');
      return false;
    }
  }

  Future<void> _stopMicRecording({bool keepFile = false}) async {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    try {
      if (!await _audioRecorder.isRecording()) {
        if (!keepFile) {
          _lastRecordedFilePath = null;
          _lastRecordedBytes = null;
          if (!kIsWeb) await _deleteRecordingFile(_activeRecordingPath);
        }
        _activeRecordingPath = null;
        return;
      }

      final String? path = await _audioRecorder.stop();

      if (kIsWeb) {
        if (keepFile && path != null) {
          try {
            final response = await http_client.get(Uri.parse(path));
            _lastRecordedBytes = response.bodyBytes;
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to fetch web audio blob: $e');
            }
            _lastRecordedBytes = null;
          }
        } else {
          _lastRecordedBytes = null;
        }
        _lastRecordedFilePath = null;
      } else {
        final String? effectivePath = path ?? _activeRecordingPath;
        _activeRecordingPath = null;

        if (keepFile) {
          _lastRecordedFilePath = effectivePath;
        } else {
          _lastRecordedFilePath = null;
          await _deleteRecordingFile(effectivePath);
        }
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to stop microphone: $error\n$stackTrace');
      }
    }
  }

  Future<bool> _ensureMicPermission() async {
    if (kIsWeb) return true; // Browser handles permission via record package

    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows)) {
      return true;
    }

    try {
      final PermissionStatus status = await Permission.microphone.request();
      if (status.isGranted) {
        return true;
      }
      if (status.isPermanentlyDenied) {
        _showSnackBar(
          'Microphone permission denied. Please enable it in settings.',
        );
        return false;
      }
      _showSnackBar('Microphone permission is required to record audio.');
      return false;
    } on MissingPluginException {
      if (kDebugMode) {
        debugPrint('permission_handler plugin unavailable; skipping request.');
      }
      return true;
    }
  }

  void _handleAmplitudeSample(Amplitude amplitude) {
    final double decibels = amplitude.current;
    if (!mounted) return;

    const double minDb = -60.0;
    const double maxDb = 0.0;
    final double normalized = ((decibels - minDb) / (maxDb - minDb)).clamp(
      0.0,
      1.0,
    );

    setState(() {
      if (_audioLevels.isNotEmpty) {
        _audioLevels.removeAt(0);
      }
      _audioLevels.add(normalized);
    });
  }

  void _resetAudioLevels() {
    for (int i = 0; i < _audioLevels.length; i++) {
      _audioLevels[i] = 0.0;
    }
  }

  Future<String> _createRecordingPath() async {
    final Directory tempDir = await getTemporaryDirectory();
    final Directory audioDir = Directory('${tempDir.path}/chuk_chat_audio');
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    return '${audioDir.path}/rec_$timestamp.m4a';
  }

  Future<void> _deleteRecordingFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to delete audio file: $error\n$stackTrace');
      }
    }
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

  bool _isValidMessageIndex(int index) =>
      index >= 0 && index < _messages.length;

  Future<void> _copyTextToClipboard(String text, {String? label}) async {
    if (text.trim().isEmpty) {
      _showSnackBar('Nothing to copy.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _showSnackBar(label ?? 'Copied to clipboard.');
  }

  void _editMessageAt(int index) {
    if (!_isValidMessageIndex(index)) return;
    setState(() {
      _editingMessageIndex = index;
    });
  }

  void _cancelEditMessage() {
    setState(() {
      _editingMessageIndex = null;
    });
  }

  Future<void> _submitEditedMessage(int index, String newText) async {
    if (!_isValidMessageIndex(index)) return;
    final String trimmedText = newText.trim();
    if (trimmedText.isEmpty) {
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

    // Store the edited message
    setState(() {
      _messages[index]['text'] = trimmedText;
      _editingMessageIndex = null;
    });

    // Delete the AI response that follows this user message (if it exists)
    if (index + 1 < _messages.length &&
        _messages[index + 1]['sender'] == 'ai') {
      setState(() {
        _messages.removeAt(index + 1);
      });
    }

    _persistChat();

    // Prepare to send the edited message
    final String originalUserInput = trimmedText;
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
          final storedImages = decoded.cast<String>();
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
                final dataUrl = 'data:image/jpeg;base64,$base64Image';
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

    setState(() {
      _isSending = true;
      _messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': modelIdToUse,
        'provider': providerToUse ?? '',
      });
      placeholderIndex = _messages.length - 1;
    });

    // Don't persist "Thinking..." placeholder - wait for actual response
    // _persistChat(); // Removed - will persist after streaming completes
    _scrollChatToBottom(force: true);

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
      await SupabaseService.signOut();
      return;
    }

    final String accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      _finalizeAiMessage(
        placeholderIndex,
        'Authentication failed. Please sign in again.',
      );
      return;
    }

    // Build conversation history up to the edited message (with images/reasoning support)
    final List<Map<String, dynamic>> conversationHistory = [];
    final bool shouldIncludeImages =
        widget.includeRecentImagesInHistory || widget.includeAllImagesInHistory;
    final int imgWindow = widget.includeAllImagesInHistory ? index : 6;
    final Set<int> imgEligible = {};
    if (shouldIncludeImages) {
      int uCount = 0;
      for (int j = index - 1; j >= 0; j--) {
        if (_messages[j]['sender'] == 'user') {
          uCount++;
          if (uCount <= imgWindow) imgEligible.add(j);
        }
      }
    }
    for (int i = 0; i < index; i++) {
      final msg = _messages[i];
      final sender = msg['sender'];
      final text = msg['text'] ?? '';
      if (sender == 'user') {
        final bool hasImages =
            msg['images'] != null && msg['images']!.isNotEmpty;
        if (shouldIncludeImages && hasImages && imgEligible.contains(i)) {
          final content = <Map<String, dynamic>>[];
          if (text.isNotEmpty) content.add({'type': 'text', 'text': text});
          final urls = await _resolveHistoryImages(msg['images']!);
          for (final u in urls) {
            content.add({
              'type': 'image_url',
              'image_url': {'url': u},
            });
          }
          if (content.isNotEmpty)
            conversationHistory.add({'role': 'user', 'content': content});
        } else if (text.isNotEmpty) {
          conversationHistory.add({'role': 'user', 'content': text});
        }
      } else if (sender == 'ai') {
        if (text.isEmpty) continue;
        String assistantContent = text;
        if (widget.includeReasoningInHistory) {
          final reasoning = msg['reasoning'] ?? '';
          if (reasoning.isNotEmpty) {
            assistantContent =
                '<thinking>\n$reasoning\n</thinking>\n\n$assistantContent';
          }
        }
        conversationHistory.add({
          'role': 'assistant',
          'content': assistantContent,
        });
      }
    }

    final String? systemPrompt = await _resolveSystemPromptForSend();

    final toolSession = _toolCallHandler.createSession(
      initialUserMessage: originalUserInput,
      history: conversationHistory,
      accessToken: accessToken,
      discoveryContextKey: _activeChatId,
      baseSystemPrompt: systemPrompt,
      toolCallingEnabled: widget.toolCallingEnabled,
      discoveryMode: widget.toolDiscoveryMode,
      allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
    );
    final initialSystemPrompt = await _toolCallHandler.buildInitialSystemPrompt(
      toolSession,
    );

    // Capture chatId for this streaming operation
    final String chatIdForStream = _activeChatId!;

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
    }) async {
      final eventStream = WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: message,
        modelId: modelIdToUse,
        providerSlug: providerToUse ?? 'openai',
        history: history,
        systemPrompt: passSystemPrompt,
        maxTokens: 4096,
        temperature: 0.7,
        images: passImages,
      );

      await _streamingManager.startStream(
        chatId: chatIdForStream,
        messageIndex: placeholderIndex,
        stream: eventStream,
        onUpdate: (content, reasoning) {
          if (mounted &&
              _isValidMessageIndex(placeholderIndex) &&
              _activeChatId == chatIdForStream) {
            final displayContent = stripToolCallBlocksForDisplay(content);

            setState(() {
              _messages[placeholderIndex]['text'] = displayContent;
              _messages[placeholderIndex]['reasoning'] = reasoning;
            });
            _scrollChatToBottom();
          }
        },
        onComplete: (finalContent, finalReasoning, tps) {
          unawaited(() async {
            final loopResult = await _toolCallHandler.processAssistantResponse(
              session: toolSession,
              content: finalContent,
              reasoning: finalReasoning,
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
              final newToolCalls = allToolCalls.length > previousToolCallCount
                  ? allToolCalls.sublist(previousToolCallCount)
                  : <ToolCall>[];
              previousToolCallCount = allToolCalls.length;

              if (interimText.isNotEmpty) {
                contentBlocks.add(ContentBlock.text(interimText));
              }
              // Merge into the previous tool_calls block when the AI
              // didn't say anything to the user between passes.
              if (newToolCalls.isNotEmpty) {
                if (interimText.isEmpty &&
                    contentBlocks.isNotEmpty &&
                    contentBlocks.last.type == ContentBlockType.toolCalls) {
                  final merged = [
                    ...contentBlocks.last.toolCalls!,
                    ...newToolCalls,
                  ];
                  contentBlocks[contentBlocks.length - 1] =
                      ContentBlock.toolCalls(merged);
                } else {
                  contentBlocks.add(ContentBlock.toolCalls(newToolCalls));
                }
              }

              // Accumulate text for backward-compat message field.
              if (interimText.isNotEmpty) {
                accumulatedText.write(interimText);
                accumulatedText.write('\n\n');
              }

              final contentBlocksJson = jsonEncode(
                contentBlocks.map((b) => b.toJson()).toList(),
              );

              if (_activeChatId == chatIdForStream) {
                if (placeholderIndex >= 0 &&
                    placeholderIndex < _messages.length) {
                  _messages[placeholderIndex]['text'] = '';
                  _messages[placeholderIndex]['reasoning'] = finalReasoning;
                  _messages[placeholderIndex]['contentBlocks'] =
                      contentBlocksJson;
                }
                if (mounted) {
                  setState(() {});
                }
                _persistChatWithId(chatIdForStream);
              } else {
                final backgroundMsgs = _streamingManager.getBackgroundMessages(
                  chatIdForStream,
                );
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
              );
              return;
            }

            final resolvedContent = loopResult.finalContent ?? finalContent;
            final resolvedReasoning =
                loopResult.finalReasoning ?? finalReasoning;
            final rawContent = resolvedContent.isEmpty
                ? 'No response received.'
                : resolvedContent;

            // Build final content blocks.
            if (contentBlocks.isNotEmpty) {
              final finalText = stripToolCallBlocksForDisplay(
                rawContent,
              ).trim();
              if (resolvedReasoning.isNotEmpty) {
                contentBlocks.add(ContentBlock.reasoning(resolvedReasoning));
              }
              if (finalText.isNotEmpty) {
                contentBlocks.add(ContentBlock.text(finalText));
              }
            }
            final contentBlocksJson = contentBlocks.isNotEmpty
                ? jsonEncode(contentBlocks.map((b) => b.toJson()).toList())
                : null;

            // Prepend accumulated text from previous passes so nothing is lost.
            final effectiveContent = accumulatedText.isEmpty
                ? rawContent
                : '$accumulatedText$rawContent';

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
              final backgroundMsgs = _streamingManager.getBackgroundMessages(
                chatIdForStream,
              );
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
                _persistChatWithIdAndMessages(chatIdForStream, backgroundMsgs);
              }
            }
          }());
        },
        onError: (errorMessage) {
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
                _persistChatWithIdAndMessages(chatIdForStream, backgroundMsgs);
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
              backgroundMsgs[placeholderIndex]['text'] = 'Error: $errorMessage';
              backgroundMsgs[placeholderIndex]['reasoning'] = '';
              _persistChatWithIdAndMessages(chatIdForStream, backgroundMsgs);
            }
          }
        },
      );
    }

    try {
      await startStreamPass(
        message: originalUserInput,
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
  }

  Future<void> _resendMessageAt(int index) async {
    if (!_isValidMessageIndex(index)) return;
    final String text = (_messages[index]['text'] ?? '').trim();
    if (text.isEmpty) {
      _showSnackBar('Nothing to resend.');
      return;
    }
    // Use the same logic as editing and submitting
    await _submitEditedMessage(index, text);
  }

  List<MessageBubbleAction> _buildMessageActionsForIndex(
    int index,
    _MessageRenderData data,
  ) {
    if (!_isValidMessageIndex(index)) {
      return const <MessageBubbleAction>[];
    }

    final Map<String, String> rawMessage = _messages[index];
    final String messageText = rawMessage['text'] ?? '';
    final bool isUserMessage = data.isUser;
    final bool isAssistantPending = !isUserMessage && data.isReasoningStreaming;
    final List<MessageBubbleAction> actions = [];

    if (messageText.trim().isNotEmpty) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.copy,
          tooltip: 'Copy message',
          label: 'Copy',
          onPressed: () => _copyTextToClipboard(messageText),
          isEnabled: !isAssistantPending || isUserMessage,
        ),
      );
    }

    if (isUserMessage) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.edit,
          tooltip: 'Edit message',
          label: 'Edit',
          onPressed: () => _editMessageAt(index),
        ),
      );
      actions.add(
        MessageBubbleAction(
          icon: Icons.replay,
          tooltip: 'Resend message',
          label: 'Resend',
          onPressed: () => _resendMessageAt(index),
        ),
      );
    }

    return actions;
  }

  Widget _buildAudioVisualizer({required Color accent, required Color iconFg}) {
    // Desktop adaptation of the mobile audio visualizer with gradient + glow
    const int barCount = 40; // More bars for wider desktop layout
    final int startIndex = _audioLevels.length > barCount
        ? _audioLevels.length - barCount
        : 0;

    return SizedBox(
      key: const ValueKey<String>('audio-visualizer'),
      height: 32,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(barCount, (index) {
          final int levelIndex = startIndex + index;
          final double rawLevel = levelIndex < _audioLevels.length
              ? _audioLevels[levelIndex]
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

  // NEW: Handler for file upload status updates from ChatApiService
  void _handleFileUploadUpdate(
    String fileId,
    String? markdownContent,
    bool isUploading,
    String? snackBarMessage,
  ) {
    if (!mounted) return;
    setState(() {
      int index = _attachedFiles.indexWhere((f) => f.id == fileId);
      if (index != -1) {
        if (markdownContent != null) {
          // File successfully uploaded and content received
          _attachedFiles[index] = _attachedFiles[index].copyWith(
            markdownContent: markdownContent,
            isUploading: false,
          );
        } else if (!isUploading) {
          // Upload failed or file was removed by service, remove from list
          _attachedFiles.removeAt(index);
        } else {
          // Just updating isUploading status
          _attachedFiles[index] = _attachedFiles[index].copyWith(
            isUploading: isUploading,
          );
        }
      }
    });
    if (snackBarMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            snackBarMessage,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
    _scrollChatToBottom();
  }

  Future<void> _cancelStream() async {
    if (_activeChatId != null && _isStreaming) {
      if (kDebugMode) {
        debugPrint('Cancelling stream for chat $_activeChatId...');
      }
      await _streamingManager.cancelStream(_activeChatId!);

      setState(() {
        _isSending = false;
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
      _showSnackBar('Response cancelled');
    }
  }

  /// Cancel any ongoing operation (streaming or sending)
  Future<void> _cancelCurrentOperation() async {
    if (_isStreaming) {
      // Stream is active - cancel via existing method
      await _cancelStream();
    } else if (_isSending) {
      // Only sending flag is set (stream not yet started) - reset state
      setState(() {
        _isSending = false;
      });
      if (ChatStorageService.isMessageOperationInProgress) {
        ChatStorageService.isMessageOperationInProgress = false;
      }
      _showSnackBar('Cancelled');
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
    // SET GLOBAL LOCK IMMEDIATELY - before any async operations
    // This prevents didUpdateWidget from switching chats during the entire operation
    ChatStorageService.isMessageOperationInProgress = true;
    if (kDebugMode) {
      debugPrint('🔒 [SendMessage] GLOBAL LOCK SET');
    }

    if (_isStreaming) {
      // Current chat is streaming - cancel it
      await _cancelStream();
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (cancelled)');
      }
      return;
    }

    if (_attachedFiles.any((f) => f.isUploading)) {
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
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (no model selected)');
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
      attachedFiles: _attachedFiles,
      selectedModelId: _selectedModelId,
      apiHistory: apiHistory,
      systemPrompt: resolvedSystemPrompt,
      getProviderSlug: _ensureProviderSlugForCurrentModel,
    );

    if (!result.isValid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.errorMessage ?? 'Invalid message',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
      if (result.errorMessage == 'Session expired. Please sign in again.') {
        await SupabaseService.signOut();
      }
      ChatStorageService.isMessageOperationInProgress = false;
      if (kDebugMode) {
        debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (invalid message)');
      }
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
    final List<String>? imageDataUrls = result.images;

    final bool hasAttachments = _attachedFiles.any(
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
        debugPrint('');
      }
      if (kDebugMode) {
        debugPrint(
          '┌─────────────────────────────────────────────────────────────',
        );
      }
      if (kDebugMode) {
        debugPrint('│ 🆔 [SEND-DESKTOP] PRE-GENERATED Chat ID: $_activeChatId');
      }
      if (kDebugMode) {
        debugPrint(
          '│ 🆔 [SEND-DESKTOP] This ID will be used for all persist calls',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '└─────────────────────────────────────────────────────────────',
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
      final documentAttachments = _attachedFiles
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
      if (_attachedFiles.isNotEmpty) {
        userMessage['attachedFilesJson'] = jsonEncode(
          _attachedFiles.map((f) => f.toJson()).toList(),
        );
        if (kDebugMode) {
          debugPrint(
            '💾 [AttachmentDebug] Storing ${_attachedFiles.length} attached files for resend',
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
        _attachedFiles.clear();
      }
      _messages.add({
        'sender': 'ai',
        'text': 'Thinking...',
        'reasoning': '',
        'modelId': _selectedModelId,
        'provider': providerSlug,
      });
      placeholderIndex = _messages.length - 1;
    });

    // Don't persist "Thinking..." placeholder - wait for actual response
    // _persistChat(); // Removed - will persist after streaming completes

    if (firstMessageInChat) _animCtrl.forward();
    _scrollChatToBottom(force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

    // Capture chatId for this streaming operation - ensures correct persistence even if user switches chats
    final String chatIdForStream = _activeChatId!;

    // Auto-generate title for new chats (fire and forget)
    if (firstMessageInChat) {
      unawaited(
        TitleGenerationService.generateAndApplyTitle(
          chatIdForStream,
          displayMessageText,
        ),
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

    final toolSession = _toolCallHandler.createSession(
      initialUserMessage: aiPromptContent,
      history: apiHistory,
      accessToken: accessToken,
      discoveryContextKey: chatIdForStream,
      baseSystemPrompt: systemPrompt,
      toolCallingEnabled: widget.toolCallingEnabled,
      discoveryMode: widget.toolDiscoveryMode,
      allowMarkdownToolCalls: widget.allowMarkdownToolCalls,
    );
    final initialSystemPrompt = await _toolCallHandler.buildInitialSystemPrompt(
      toolSession,
    );

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
    }) async {
      final stream = WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: message,
        modelId: _selectedModelId,
        providerSlug: providerSlug,
        history: history.isEmpty ? null : history,
        systemPrompt: passSystemPrompt,
        maxTokens: maxResponseTokens,
        images: passImages,
      );

      await _streamingManager.startStream(
        chatId: chatIdForStream,
        messageIndex: placeholderIndex,
        stream: stream,
        onUpdate: (content, reasoning) {
          if (mounted && _activeChatId == chatIdForStream) {
            final displayContent = stripToolCallBlocksForDisplay(content);
            if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
              _messages[placeholderIndex]['text'] = displayContent;
              _messages[placeholderIndex]['reasoning'] = reasoning;
            }
            _updateAiMessage(placeholderIndex, displayContent, reasoning);
            _scrollChatToBottom();
          }
        },
        onComplete: (finalContent, finalReasoning, tps) {
          unawaited(() async {
            if (kDebugMode) {
              debugPrint('Stream completed for chat $chatIdForStream');
            }

            try {
              final loopResult = await _toolCallHandler
                  .processAssistantResponse(
                    session: toolSession,
                    content: finalContent,
                    reasoning: finalReasoning,
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
                    allToolCalls.length > previousToolCallCount2
                    ? allToolCalls.sublist(previousToolCallCount2)
                    : <ToolCall>[];
                previousToolCallCount2 = allToolCalls.length;

                if (interimText.isNotEmpty) {
                  contentBlocks2.add(ContentBlock.text(interimText));
                }
                // Merge into the previous tool_calls block when the AI
                // didn't say anything to the user between passes.
                if (newToolCalls.isNotEmpty) {
                  if (interimText.isEmpty &&
                      contentBlocks2.isNotEmpty &&
                      contentBlocks2.last.type == ContentBlockType.toolCalls) {
                    final merged = [
                      ...contentBlocks2.last.toolCalls!,
                      ...newToolCalls,
                    ];
                    contentBlocks2[contentBlocks2.length - 1] =
                        ContentBlock.toolCalls(merged);
                  } else {
                    contentBlocks2.add(ContentBlock.toolCalls(newToolCalls));
                  }
                }

                // Accumulate text for backward-compat message field.
                if (interimText.isNotEmpty) {
                  accumulatedText2.write(interimText);
                  accumulatedText2.write('\n\n');
                }

                final contentBlocksJson = jsonEncode(
                  contentBlocks2.map((b) => b.toJson()).toList(),
                );

                if (_activeChatId == chatIdForStream) {
                  if (placeholderIndex >= 0 &&
                      placeholderIndex < _messages.length) {
                    _messages[placeholderIndex]['text'] = '';
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

              final resolvedContent = loopResult.finalContent ?? finalContent;
              final resolvedReasoning =
                  loopResult.finalReasoning ?? finalReasoning;
              final rawContent = resolvedContent.isEmpty
                  ? 'The model returned an empty response.'
                  : resolvedContent;

              // Build final content blocks.
              if (contentBlocks2.isNotEmpty) {
                final finalText = stripToolCallBlocksForDisplay(
                  rawContent,
                ).trim();
                if (resolvedReasoning.isNotEmpty) {
                  contentBlocks2.add(ContentBlock.reasoning(resolvedReasoning));
                }
                if (finalText.isNotEmpty) {
                  contentBlocks2.add(ContentBlock.text(finalText));
                }
              }
              final contentBlocksJson = contentBlocks2.isNotEmpty
                  ? jsonEncode(contentBlocks2.map((b) => b.toJson()).toList())
                  : null;

              // Prepend accumulated text from previous passes so nothing is lost.
              final effectiveContent = accumulatedText2.isEmpty
                  ? rawContent
                  : '$accumulatedText2$rawContent';

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
                  _messages[placeholderIndex]['reasoning'] = resolvedReasoning;
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
                final backgroundMsgs = _streamingManager.getBackgroundMessages(
                  chatIdForStream,
                );
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
                final backgroundMsgs = _streamingManager.getBackgroundMessages(
                  chatIdForStream,
                );
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
          }());
        },
        onError: (errorMessage) {
          if (kDebugMode) {
            debugPrint('Stream error for chat $chatIdForStream: $errorMessage');
          }
          _autoSaveTimer?.cancel();
          ChatStorageService.isMessageOperationInProgress = false;
          if (kDebugMode) {
            debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (stream error)');
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
                _persistChatWithIdAndMessages(chatIdForStream, backgroundMsgs);
              }
            }
            _showPaymentRequiredDialog();
            return;
          }

          final errorText = 'Error: $errorMessage';
          if (_activeChatId == chatIdForStream) {
            if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
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
      _finalizeAiMessage(placeholderIndex, 'Failed to start streaming: $error');
      if (mounted) {
        setState(() {
          _isSending = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to start streaming: $error',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
  }

  // In-memory cache for resolved Base64 images (storage path -> data URL)
  static final Map<String, String> _imageBase64Cache = {};
  static const int _maxImageCacheSize = 10;

  Future<List<Map<String, dynamic>>> _buildApiHistoryWithPendingMessage(
    String pendingUserText,
  ) async {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
    final bool shouldIncludeImages =
        widget.includeRecentImagesInHistory || widget.includeAllImagesInHistory;
    final int imageWindow = widget.includeAllImagesInHistory
        ? _messages.length
        : 6;

    // Determine which user messages are within the image window
    final Set<int> imageEligibleIndices = {};
    if (shouldIncludeImages) {
      int userMsgCount = 0;
      for (int i = _messages.length - 1; i >= 0; i--) {
        if (_messages[i]['sender'] == 'user') {
          userMsgCount++;
          if (userMsgCount <= imageWindow) {
            imageEligibleIndices.add(i);
          }
        }
      }
    }

    for (int i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      final String? sender = message['sender'];
      final String? text = message['text'];

      if (sender == 'user') {
        final bool hasImages =
            message['images'] != null && message['images']!.isNotEmpty;
        final bool shouldAddImages =
            shouldIncludeImages &&
            hasImages &&
            imageEligibleIndices.contains(i);

        if (shouldAddImages) {
          final content = <Map<String, dynamic>>[];
          if (text != null && text.trim().isNotEmpty) {
            content.add({'type': 'text', 'text': text});
          }
          final imageDataUrls = await _resolveHistoryImages(message['images']!);
          for (final dataUrl in imageDataUrls) {
            content.add({
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            });
          }
          if (content.isNotEmpty) {
            history.add({'role': 'user', 'content': content});
          }
        } else if (text != null && text.trim().isNotEmpty) {
          history.add({'role': 'user', 'content': text});
        }
      } else if (sender == 'ai' || sender == 'assistant') {
        if (text == null || text.trim().isEmpty) continue;
        String assistantContent = text;
        if (widget.includeReasoningInHistory) {
          final reasoning = message['reasoning'] ?? '';
          if (reasoning.isNotEmpty) {
            assistantContent =
                '<thinking>\n$reasoning\n</thinking>\n\n$assistantContent';
          }
        }
        history.add({'role': 'assistant', 'content': assistantContent});
      }
    }

    // Don't add pendingUserText here - the server adds the current message
    // from the 'message' parameter. Adding it here causes duplicate user
    // messages which makes AI models think the user sent the message twice.

    return history;
  }

  /// Resolve image storage paths from a JSON-encoded list to Base64 data URLs
  Future<List<String>> _resolveHistoryImages(String imagesJson) async {
    final List<String> dataUrls = [];
    try {
      final decoded = jsonDecode(imagesJson);
      if (decoded is! List) return dataUrls;

      for (final img in decoded) {
        final path = img.toString();
        if (path.isEmpty) continue;

        if (path.startsWith('data:image/')) {
          dataUrls.add(path);
          continue;
        }

        if (_imageBase64Cache.containsKey(path)) {
          dataUrls.add(_imageBase64Cache[path]!);
          continue;
        }

        try {
          final bytes = await ImageStorageService.downloadAndDecryptImage(path);
          final base64 = base64Encode(bytes);
          final dataUrl = 'data:image/jpeg;base64,$base64';

          if (_imageBase64Cache.length >= _maxImageCacheSize) {
            _imageBase64Cache.remove(_imageBase64Cache.keys.first);
          }
          _imageBase64Cache[path] = dataUrl;
          dataUrls.add(dataUrl);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('⚠️ [Desktop] Failed to resolve history image: $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [Desktop] Failed to parse images JSON: $e');
      }
    }
    return dataUrls;
  }

  void _updateAiMessage(int index, String content, String reasoning) {
    if (!mounted || index < 0 || index >= _messages.length) return;

    setState(() {
      final Map<String, String> message = Map<String, String>.from(
        _messages[index],
      );
      message['text'] = content;
      message['reasoning'] = reasoning;
      _messages[index] = message;
    });
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

      final isActiveChat = _activeChatId == chatId;
      if (mounted && isActiveChat && index >= 0 && index < _messages.length) {
        setState(() {
          final message = Map<String, String>.from(_messages[index]);
          message['images'] = jsonEncode(imageResult.imagePaths);
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
          if (imageResult.imageCostEur != null) {
            backgroundMsgs[index]['imageCostEur'] = imageResult.imageCostEur!;
          }
          if (imageResult.imageGeneratedAt != null) {
            backgroundMsgs[index]['imageGeneratedAt'] =
                imageResult.imageGeneratedAt!;
          }
          backgroundMsgs[index]['toolCalls'] = updatedToolCallsJson;
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
    if (index < 0 || index >= _messages.length) {
      _isSending = false;
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
      _scrollChatToBottom();
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      _persistChat();
    }
  }

  /// Processes a list of file paths (from drag and drop or file picker)
  Future<void> _processFilePaths(List<String> filePaths) async {
    const int maxFileSize = 10 * 1024 * 1024; // 10MB
    const int maxConcurrentUploads = 5;

    if (_attachedFiles.where((f) => f.isUploading).length >=
        maxConcurrentUploads) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Please wait for current uploads to complete',
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
      return;
    }

    for (String filePath in filePaths) {
      final File file = File(filePath);

      // Check if file exists
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'File not found: ${file.path}',
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
        continue;
      }

      // Get file size
      final int fileSize = await file.length();
      final String fileName = file.path.split(Platform.pathSeparator).last;
      final String fileExtension = fileName.split('.').last.toLowerCase();

      // Check if it's an image
      final isImage = FileConstants.imageExtensions.contains(fileExtension);

      // Check file size (skip for images - they'll be compressed automatically with no size limit)
      if (!isImage && fileSize > maxFileSize) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'File "$fileName" exceeds 10MB limit',
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
        continue; // Skip this file and go to the next
      }

      String fileId = _uuid.v4();

      if (!FileConstants.allowedExtensions.contains(fileExtension)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Unsupported file type for "$fileName": .$fileExtension',
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
        continue;
      }

      if (_isImageExtension(fileExtension) && !_modelSupportsImageInput) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Image uploads are not supported by the selected model.',
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
        continue;
      }

      // Check concurrent upload limit again before adding to UI and starting upload
      // This handles cases where user quickly picks many files, or files picked while others finish
      if (_attachedFiles.where((f) => f.isUploading).length >=
          maxConcurrentUploads) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Skipping "$fileName": too many concurrent uploads. Try again soon.',
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
        continue;
      }

      setState(() {
        _attachedFiles.add(
          AttachedFile(
            id: fileId,
            fileName: fileName,
            isUploading: true,
            localPath: file.path,
            fileSizeBytes: fileSize,
            isImage: isImage,
          ),
        );
      });
      _scrollChatToBottom(
        force: true,
      ); // Scroll to ensure attachment bar is visible

      // Handle images differently - compress, encrypt, and upload to storage
      if (isImage) {
        _uploadEncryptedImage(file, fileName, fileId);
      } else {
        _chatApiService.performFileUpload(file, fileName, fileId);
      }
    }
  }

  /// Upload image with compression and encryption
  Future<void> _uploadEncryptedImage(
    File file,
    String fileName,
    String fileId,
  ) async {
    try {
      // Read image bytes
      final Uint8List imageBytes = await file.readAsBytes();

      // Upload to encrypted storage (compression + encryption happens inside)
      final String storagePath = await ImageStorageService.uploadEncryptedImage(
        imageBytes,
      );

      // Update the attached file with the storage path
      setState(() {
        final int index = _attachedFiles.indexWhere((f) => f.id == fileId);
        if (index != -1) {
          _attachedFiles[index] = _attachedFiles[index].copyWith(
            encryptedImagePath: storagePath,
            isUploading: false,
            // Don't set markdownContent for images - they'll be sent separately
          );
        }
      });

      if (kDebugMode) {
        debugPrint(
          'Image "$fileName" uploaded and encrypted successfully: $storagePath',
        );
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to upload encrypted image "$fileName": $error');
      }

      // Show error snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to upload image "$fileName": $error',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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

      // Remove failed upload
      setState(() {
        _attachedFiles.removeWhere((f) => f.id == fileId);
      });
    }
  }

  Future<void> _uploadFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileConstants.allowedExtensions,
      allowMultiple: true,
      withData: kIsWeb, // On web, we need bytes since paths aren't available
    );

    if (result != null && result.files.isNotEmpty) {
      if (kIsWeb) {
        await _processWebFiles(result.files);
      } else {
        List<String> filePaths = result.files
            .where((f) => f.path != null)
            .map((f) => f.path!)
            .toList();
        await _processFilePaths(filePaths);
      }
    } else {
      if (kDebugMode) {
        debugPrint('File picking canceled.');
      }
    }
  }

  /// Process files on web where we only have bytes, not file paths
  Future<void> _processWebFiles(List<PlatformFile> platformFiles) async {
    const int maxFileSize = 10 * 1024 * 1024; // 10MB
    const int maxConcurrentUploads = 5;

    if (_attachedFiles.where((f) => f.isUploading).length >=
        maxConcurrentUploads) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Please wait for current uploads to complete',
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
      return;
    }

    for (final platformFile in platformFiles) {
      final Uint8List? bytes = platformFile.bytes;
      if (bytes == null) continue;

      final String fileName = platformFile.name;
      final int fileSize = platformFile.size;
      final String fileExtension = fileName.contains('.')
          ? fileName.split('.').last.toLowerCase()
          : '';

      final isImage = FileConstants.imageExtensions.contains(fileExtension);

      // Check file size (skip for images)
      if (!isImage && fileSize > maxFileSize) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'File "$fileName" exceeds 10MB limit',
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
        continue;
      }

      if (!FileConstants.allowedExtensions.contains(fileExtension)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Unsupported file type for "$fileName": .$fileExtension',
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
        continue;
      }

      if (isImage && !_modelSupportsImageInput) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Image uploads are not supported by the selected model.',
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
        continue;
      }

      if (_attachedFiles.where((f) => f.isUploading).length >=
          maxConcurrentUploads) {
        continue;
      }

      String fileId = _uuid.v4();

      setState(() {
        _attachedFiles.add(
          AttachedFile(
            id: fileId,
            fileName: fileName,
            isUploading: true,
            localPath: '',
            fileSizeBytes: fileSize,
            isImage: isImage,
          ),
        );
      });
      _scrollChatToBottom(force: true);

      if (isImage) {
        _uploadEncryptedImageFromBytes(bytes, fileName, fileId);
      } else {
        _chatApiService.performFileUploadFromBytes(bytes, fileName, fileId);
      }
    }
  }

  /// Upload image from bytes (web)
  Future<void> _uploadEncryptedImageFromBytes(
    Uint8List imageBytes,
    String fileName,
    String fileId,
  ) async {
    try {
      final String storagePath = await ImageStorageService.uploadEncryptedImage(
        imageBytes,
      );

      setState(() {
        final int index = _attachedFiles.indexWhere((f) => f.id == fileId);
        if (index != -1) {
          _attachedFiles[index] = _attachedFiles[index].copyWith(
            encryptedImagePath: storagePath,
            isUploading: false,
          );
        }
      });

      if (kDebugMode) {
        debugPrint(
          'Image "$fileName" uploaded and encrypted successfully: $storagePath',
        );
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to upload encrypted image "$fileName": $error');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to upload image "$fileName": $error',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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

      setState(() {
        _attachedFiles.removeWhere((f) => f.id == fileId);
      });
    }
  }

  /// Handles files dropped via drag and drop
  Future<void> _handleDroppedFiles(List<String> filePaths) async {
    await _processFilePaths(filePaths);
  }

  /// Handles Ctrl+V paste of clipboard images
  Future<bool> _handleClipboardPaste() async {
    try {
      final Uint8List? imageBytes = await Pasteboard.image;
      if (imageBytes == null || imageBytes.isEmpty) return false;

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempFile = File('${tempDir.path}/paste_$timestamp.png');
      await tempFile.writeAsBytes(imageBytes);

      await _processFilePaths([tempFile.path]);
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Clipboard paste error: $e');
      }
      return false;
    }
  }

  void _removeAttachedFile(String fileId) {
    setState(() {
      _attachedFiles.removeWhere((f) => f.id == fileId);
    });
    _scrollChatToBottom(force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
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
    // Use Map.from() instead of Map<String, String>.from() to preserve all field types
    // This ensures images (String) and attachments (String) fields are not lost
    final messagesCopy = _messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: false);
    final operation = _persistChatInternal(messagesCopy, _activeChatId);
    if (waitForCompletion) {
      await operation;
    } else {
      unawaited(operation);
    }
  }

  /// Persist chat with a specific chatId (for background streaming to correct chat)
  void _persistChatWithId(String chatId) {
    if (_messages.isEmpty) return;
    final messagesCopy = _messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: false);
    unawaited(_persistChatInternal(messagesCopy, chatId));
  }

  /// Persist specific messages to a specific chat (for background streaming)
  /// Used when user has switched away from a streaming chat
  void _persistChatWithIdAndMessages(
    String chatId,
    List<Map<String, dynamic>> messages,
  ) {
    if (messages.isEmpty) return;
    unawaited(_persistChatInternal(messages, chatId, silent: true));
  }

  /// Persist chat messages to storage.
  ///
  /// [silent] - If true, don't update _activeChatId or notify parent.
  /// Use silent=true when persisting an old chat in the background while
  /// user has already moved to a new chat (e.g., in newChat()).
  Future<void> _persistChatInternal(
    List<Map<String, dynamic>> messagesCopy,
    String? chatId, {
    bool silent = false,
  }) async {
    // Check if chat exists in storage (not just if chatId is null)
    // With pre-generated IDs, chatId is never null but chat may not exist yet
    final bool chatExistsInStorage =
        chatId != null &&
        ChatStorageService.savedChats.any((c) => c.id == chatId);
    final bool isNewChat = !chatExistsInStorage;

    try {
      final stored = isNewChat
          // Use saveChat with pre-generated ID for new chats
          ? await ChatStorageService.saveChat(messagesCopy, chatId: chatId)
          : await ChatStorageService.updateChat(chatId, messagesCopy);
      if (!mounted || stored == null) return;

      // If silent, don't update state or notify parent - this is a background save
      // of an old chat while user is on a different chat
      if (silent) {
        if (kDebugMode) {
          debugPrint(
            '│ 🔇 [PERSIST] Silent save completed for chat: ${stored.id}',
          );
        }
        return;
      }

      setState(() {
        _activeChatId = stored.id;
      });

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
          debugPrint('│ 🆕 [SEND-DESKTOP] NEW CHAT CREATED!');
        }
        if (kDebugMode) {
          debugPrint('│ 🆕 [SEND-DESKTOP] New chat ID: ${stored.id}');
        }
        if (kDebugMode) {
          debugPrint(
            '│ 🆕 [SEND-DESKTOP] Calling widget.onChatIdChanged(${stored.id})',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '│ 🆕 [SEND-DESKTOP] This should update ChatStorageService.selectedChatId',
          );
        }
        if (kDebugMode) {
          debugPrint(
            '└─────────────────────────────────────────────────────────────',
          );
        }
        widget.onChatIdChanged(stored.id);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to store chat: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
  }

  String? _formatModelInfo(String? modelId, String? provider) {
    final String normalizedModel = (modelId ?? '').trim();
    final String normalizedProvider = (provider ?? '').trim();
    if (normalizedModel.isEmpty && normalizedProvider.isEmpty) {
      return null;
    }
    // Return just the model name for the card header.
    // Provider is passed separately via modelProvider parameter.
    if (normalizedModel.isEmpty) {
      return normalizedProvider;
    }
    return normalizedModel;
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
    if (_attachedFiles.isNotEmpty) {
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

    final List<_MessageRenderData>
    renderMessages = List<_MessageRenderData>.generate(_messages.length, (
      int index,
    ) {
      final Map<String, String> raw = _messages[index];
      final String sender = raw['sender'] ?? 'ai';
      final String displayText = (raw['text'] ?? '').trimRight();
      final String reasoning = raw['reasoning'] ?? '';
      final bool isAiMessage = sender != 'user';
      final bool isStreamingMessage =
          _isStreaming && index == _messages.length - 1 && isAiMessage;
      // Check if reasoning has content (meaning reasoning exists)
      final bool hasReasoning = reasoning.isNotEmpty;
      final String? modelLabel = isAiMessage
          ? _formatModelInfo(raw['modelId'], raw['provider'])
          : null;
      final String? modelProvider = isAiMessage
          ? (raw['provider'] ?? '').trim()
          : null;

      // Extract images if present (stored as JSON string)
      List<String>? images;
      final String? imagesJson = raw['images'];
      if (imagesJson != null && imagesJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(imagesJson);
          if (decoded is List) {
            images = decoded.cast<String>();
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Failed to decode images JSON: $e');
          }
        }
      }

      // Extract attachments if present (stored as JSON string)
      List<DocumentAttachment>? attachments;
      final String? attachmentsJson = raw['attachments'];
      if (attachmentsJson != null && attachmentsJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(attachmentsJson);
          if (decoded is List) {
            attachments = decoded
                .map(
                  (item) =>
                      DocumentAttachment.fromJson(item as Map<String, dynamic>),
                )
                .toList();
            if (kDebugMode) {
              debugPrint(
                '📄 [AttachmentDebug] Extracted ${attachments.length} attachments from message $index',
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
      final String? toolCallsJson = raw['toolCalls'];
      if (toolCallsJson != null && toolCallsJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(toolCallsJson);
          if (decoded is List) {
            toolCalls = decoded
                .whereType<Map>()
                .map(
                  (item) => ToolCall.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList();
          }
        } catch (_) {}
      }

      // Parse content blocks for interleaved tool call / text display.
      List<ContentBlock>? parsedContentBlocks;
      final String? contentBlocksJson = raw['contentBlocks'];
      if (contentBlocksJson != null && contentBlocksJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(contentBlocksJson);
          if (decoded is List) {
            parsedContentBlocks = decoded
                .whereType<Map>()
                .map(
                  (item) =>
                      ContentBlock.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList();
          }
        } catch (_) {}
      }

      final String? imageCostStr = raw['imageCostEur'];
      final double? imageCostEur =
          imageCostStr != null && imageCostStr.isNotEmpty
          ? double.tryParse(imageCostStr)
          : null;
      final String? imageGeneratedAtStr = raw['imageGeneratedAt'];
      final DateTime? imageGeneratedAt =
          imageGeneratedAtStr != null && imageGeneratedAtStr.isNotEmpty
          ? DateTime.tryParse(imageGeneratedAtStr)
          : null;

      return _MessageRenderData(
        sender: sender,
        displayText: displayText,
        reasoning: reasoning,
        // Show loading icon if: streaming AND (has reasoning OR might get reasoning)
        isReasoningStreaming:
            isStreamingMessage && (hasReasoning || displayText.isNotEmpty),
        modelLabel: modelLabel,
        modelProvider: modelProvider,
        tps: tps,
        images: images,
        imageCostEur: imageCostEur,
        imageGeneratedAt: imageGeneratedAt,
        attachments: attachments,
        toolCalls: toolCalls,
        contentBlocks: parsedContentBlocks,
        isStreamingMessage: isStreamingMessage,
      );
    });

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
                  _handleDroppedFiles(filePaths);
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
                                  child: ListView.builder(
                                    controller: _scrollController,
                                    padding: EdgeInsets.symmetric(
                                      horizontal: effectiveHorizontalPadding,
                                      vertical: 10,
                                    ),
                                    itemCount: renderMessages.length,
                                    addAutomaticKeepAlives:
                                        true, // Keep message widgets alive
                                    addRepaintBoundaries: true,
                                    cacheExtent:
                                        2000.0, // Increase cache to keep more messages in memory
                                    itemBuilder: (_, int i) {
                                      final _MessageRenderData data =
                                          renderMessages[i];
                                      final String? reasoningText =
                                          data.reasoning.trim().isEmpty
                                          ? null
                                          : data.reasoning;
                                      final bool startsNewGroup =
                                          i == 0 ||
                                          (renderMessages[i - 1].isUser !=
                                              data.isUser);
                                      final bool endsGroup =
                                          i == renderMessages.length - 1 ||
                                          (renderMessages[i + 1].isUser !=
                                              data.isUser);
                                      final bool isBeingEdited =
                                          _editingMessageIndex == i;
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
                                          actions: _buildMessageActionsForIndex(
                                            i,
                                            data,
                                          ),
                                          isEditing: isBeingEdited,
                                          initialEditText: isBeingEdited
                                              ? data.displayText
                                              : null,
                                          onSubmitEdit:
                                              isBeingEdited && data.isUser
                                              ? (newText) =>
                                                    _submitEditedMessage(
                                                      i,
                                                      newText,
                                                    )
                                              : null,
                                          onCancelEdit: isBeingEdited
                                              ? _cancelEditMessage
                                              : null,
                                          showReasoningTokens:
                                              widget.showReasoningTokens,
                                          showModelInfo: widget.showModelInfo,
                                          showTps: widget.showTps,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Scroll-to-bottom button (centered above input)
                      if (_showScrollToBottom && !isChatEmpty)
                        Positioned(
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
                                // Multiple Attachment Indicator Bar (if files are present)
                                if (_attachedFiles.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: _kAttachmentBarMarginBottom,
                                    ), // Margin below chips
                                    child: SizedBox(
                                      width: targetInputWidth,
                                      child: AttachmentPreviewBar(
                                        files: _attachedFiles,
                                        onRemove: _removeAttachedFile,
                                      ),
                                    ),
                                  ),
                                // Search Bar
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

    final bool hasAttachments = _attachedFiles.isNotEmpty;

    return Container(
      width:
          double.infinity, // Occupy full width of its parent AnimatedContainer
      constraints: const BoxConstraints(minHeight: _kSearchBarContentHeight),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(containerRadius),
        border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: KeyboardListener(
                  focusNode: _rawKeyboardListenerFocusNode,
                  onKeyEvent: (event) {
                    if (event is! KeyDownEvent) return;

                    // Handle Ctrl+V / Cmd+V for clipboard image paste
                    if (event.logicalKey == LogicalKeyboardKey.keyV &&
                        (HardwareKeyboard.instance.isControlPressed ||
                            HardwareKeyboard.instance.isMetaPressed)) {
                      unawaited(_handleClipboardPaste());
                    }

                    if (event.logicalKey != LogicalKeyboardKey.enter) return;

                    final isShiftPressed =
                        HardwareKeyboard.instance.isShiftPressed;
                    if (isShiftPressed) {
                      final value = _controller.value;
                      final updatedText = value.text.replaceRange(
                        value.selection.start,
                        value.selection.end,
                        '\n',
                      );
                      _controller.value = value.copyWith(
                        text: updatedText,
                        selection: TextSelection.collapsed(
                          offset: value.selection.start + 1,
                        ),
                      );
                      return;
                    }

                    unawaited(_sendMessage());
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: Scrollbar(
                      controller: _composerScrollController,
                      child: TextField(
                        controller: _controller,
                        focusNode: _textFieldFocusNode,
                        autofocus: false,
                        minLines: 1,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.send,
                        scrollController: _composerScrollController,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(color: iconFg),
                        decoration: InputDecoration(
                          hintText: hasAttachments
                              ? 'Add a message or send documents'
                              : 'Ask me anything !',
                          hintStyle: TextStyle(
                            color: iconFg.withValues(alpha: 0.8),
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
                        cursorColor: iconFg,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Smart Send Button: sends audio when mic active, text otherwise
              GestureDetector(
                onTap: _isTranscribingAudio
                    ? null
                    : () {
                        if (_isStreaming || _isSending) {
                          _cancelCurrentOperation();
                        } else if (_isMicActive) {
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
                  child: _isTranscribingAudio
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
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _isMicActive
                      ? _buildAudioVisualizer(accent: accent, iconFg: iconFg)
                      : Row(
                          key: const ValueKey<String>('default-mic-controls'),
                          children: [
                            // Add Button (File Upload)
                            _buildIconBtn(
                              icon: Icons.add,
                              onTap: _uploadFiles,
                              isActive: hasAttachments,
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
                icon: _isMicActive ? Icons.stop : Icons.mic_rounded,
                iconSize: 18,
                onTap: _handleMicTap,
                isActive: _isMicActive,
                debugLabel: 'Mic button',
              ),
              // Voice Mode button (only when feature enabled, hidden during recording)
              if (!_isMicActive && kFeatureVoiceMode) ...[
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
                    child: const Icon(Icons.graphic_eq, color: Colors.black),
                  ),
                ),
              ],
            ],
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
