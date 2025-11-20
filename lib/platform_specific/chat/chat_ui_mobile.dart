// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
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

class ChukChatUIMobile extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final int selectedChatIndex;
  final bool isSidebarExpanded;
  final bool showReasoningTokens;
  final bool showModelInfo;

  const ChukChatUIMobile({
    super.key,
    required this.onToggleSidebar,
    required this.selectedChatIndex,
    required this.isSidebarExpanded,
    required this.showReasoningTokens,
    required this.showModelInfo,
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

  // Services and handlers
  late ChatApiService _chatApiService;
  late final AudioRecordingHandler _audioHandler;
  late final FileAttachmentHandler _fileHandler;
  late final MessageActionsHandler _messageActionsHandler;
  late final ChatPersistenceHandler _persistenceHandler;
  late final StreamingMessageHandler _streamingHandler;

  // Model and provider state
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1';
  String? _selectedProviderSlug;
  String? _systemPrompt;
  late final VoidCallback _modelSelectionListener;

  // Stream subscriptions
  StreamSubscription<void>? _chatStorageSubscription;
  StreamSubscription<void>? _providerRefreshSubscription;

  // Network and UI state
  bool _isOffline = false;
  late final VoidCallback _networkStatusListener;

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

    // Chat storage listener
    _chatStorageSubscription = ChatStorageService.changes.listen((_) {
      _handleRealtimeChatUpdate();
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
    _loadChatFromIndex(widget.selectedChatIndex);
    unawaited(_loadProviderSlugForModel(_selectedModelId));
    unawaited(_loadSystemPrompt());
    unawaited(NetworkStatusService.quickCheck());
  }

  @override
  void didUpdateWidget(covariant ChukChatUIMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      if (_activeChatId != null) {
        final chatStillExists = ChatStorageService.savedChats.any(
          (chat) => chat.id == _activeChatId,
        );
        if (chatStillExists) {
          _persistChat(waitForCompletion: false);
        }
      }

      setState(() {
        _messages.clear();
        _fileHandler.clearAll();
        _controller.clear();
        _messageActionsHandler.cancelEdit();
      });

      _loadChatFromIndex(widget.selectedChatIndex);

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
    _chatStorageSubscription?.cancel();
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

  void _loadChatFromIndex(int index) {
    if (index == -1) {
      _messages.clear();
      _fileHandler.clearAll();
      _activeChatId = null;
    } else if (index >= 0 && index < ChatStorageService.savedChats.length) {
      final storedChat = ChatStorageService.savedChats[index];
      _activeChatId = storedChat.id;
      _messages
        ..clear()
        ..addAll(
          storedChat.messages.map((message) {
            final map = <String, String>{
              'sender': message.sender,
              'text': message.text,
              'reasoning': message.reasoning,
            };
            if (message.modelId != null && message.modelId!.isNotEmpty) {
              map['modelId'] = message.modelId!;
            }
            if (message.provider != null && message.provider!.isNotEmpty) {
              map['provider'] = message.provider!;
            }
            return map;
          }),
        );
    } else {
      _activeChatId = null;
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

    setState(() {});
    _scrollChatToBottom();
    if (!widget.isSidebarExpanded) {
      _textFieldFocusNode.requestFocus();
    }
  }

  void newChat() async {
    await _persistChat(waitForCompletion: true);
    setState(() {
      _messages.clear();
      _activeChatId = null;
      ChatStorageService.selectedChatIndex = -1;
      _fileHandler.clearAll();
      _controller.clear();
      _messageActionsHandler.cancelEdit();
    });
    _scrollChatToBottom();
    if (!widget.isSidebarExpanded) {
      _textFieldFocusNode.requestFocus();
    }
    await ChatStorageService.loadSavedChatsForSidebar();
  }

  void _handleRealtimeChatUpdate() {
    if (!mounted) return;
    final String? chatIdAtStart = _activeChatId;
    if (chatIdAtStart == null) return;

    final chatIndex = ChatStorageService.savedChats.indexWhere(
      (chat) => chat.id == chatIdAtStart,
    );
    if (chatIndex == -1) return;

    final updatedChat = ChatStorageService.savedChats[chatIndex];
    final currentMessageCount = _messages.length;
    final newMessageCount = updatedChat.messages.length;

    if (newMessageCount != currentMessageCount ||
        _messagesHaveChanged(updatedChat.messages)) {
      if (_activeChatId != chatIdAtStart) {
        return;
      }

      setState(() {
        _messages.clear();
        _messages.addAll(
          updatedChat.messages.map((message) {
            final map = <String, String>{
              'sender': message.sender,
              'text': message.text,
              'reasoning': message.reasoning,
            };
            if (message.modelId != null && message.modelId!.isNotEmpty) {
              map['modelId'] = message.modelId!;
            }
            if (message.provider != null && message.provider!.isNotEmpty) {
              map['provider'] = message.provider!;
            }
            return map;
          }),
        );
      });
      _scrollChatToBottom();
    }
  }

  bool _messagesHaveChanged(List<ChatMessage> newMessages) {
    if (newMessages.length != _messages.length) return true;
    for (int i = 0; i < newMessages.length; i++) {
      final newMsg = newMessages[i];
      final currentMsg = _messages[i];
      if (newMsg.sender != currentMsg['sender'] ||
          newMsg.text != currentMsg['text'] ||
          newMsg.reasoning != (currentMsg['reasoning'] ?? '')) {
        return true;
      }
    }
    return false;
  }

  // --- AUDIO HANDLERS ---

  Future<void> _handleMicTap() async {
    if (_audioHandler.isMicActive) {
      await _audioHandler.stopRecording();
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
    if (!mounted) return;
    setState(() {
      _audioHandler.resetAudioLevels();
    });

    final session = await _streamingHandler.getSessionSafely();
    if (session == null) return;

    _showSnackBar('Transcribing…');
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
      return;
    }

    if (result.text != null && result.text!.isNotEmpty) {
      setState(() {
        _controller.text = result.text!;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: result.text!.length),
        );
      });
      _textFieldFocusNode.requestFocus();
      _showSnackBar('Ready to send');
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
              ],
            ),
          ),
        );
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
  }

  void _finalizeAiMessage(
    int index,
    String content,
    String reasoning,
    String chatId,
  ) {
    if (index < 0 || index >= _messages.length) return;
    if (_activeChatId != chatId) return;

    if (mounted) {
      setState(() {
        final Map<String, String> message = Map<String, String>.from(
          _messages[index],
        );
        message['text'] = content;
        message['reasoning'] = reasoning;
        _messages[index] = message;
      });

      _scrollChatToBottom();
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      _persistChat();
    }
  }

  Future<void> _sendMessage() async {
    if (_streamingHandler.isSending && !_streamingHandler.isStreaming) {
      _showSnackBar('Please wait');
      return;
    }

    if (_streamingHandler.isStreaming) {
      _streamingHandler.cancelStream(_activeChatId);
      _updateCancelledMessage();
      return;
    }

    if (_isOffline) {
      _showSnackBar('You are offline. Please check your connection.');
      return;
    }

    if (_fileHandler.hasUploading) {
      _showSnackBar('Upload in progress');
      return;
    }

    final String originalUserInput = _controller.text.trim();
    final bool hasAttachments = _fileHandler.getUploadedFiles().isNotEmpty;

    if (originalUserInput.isEmpty && !hasAttachments) {
      return;
    }

    // Validate message using MessageCompositionService
    final List<Map<String, String>> apiHistory = _buildApiHistory();
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
      _showSnackBar(validationResult.errorMessage ?? 'Invalid message');
      return;
    }

    // Generate chat ID if new chat
    if (_activeChatId == null) {
      _activeChatId = _uuid.v4();
    }
    final String chatId = _activeChatId!;

    // Add user message
    setState(() {
      _messages.add({
        'sender': 'user',
        'text': originalUserInput,
        'reasoning': '',
        'modelId': _selectedModelId,
        'provider': _selectedProviderSlug ?? '',
      });
      _controller.clear();
      if (hasAttachments) {
        _fileHandler.clearAll();
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
    _scrollChatToBottom();
    // Don't persist "Thinking..." placeholder - wait for actual response
    // _persistChat(); // Removed - will persist after streaming completes

    // Send with streaming handler
    await _streamingHandler.sendMessage(
      userInput: originalUserInput,
      attachedFiles: _fileHandler.attachedFiles,
      selectedModelId: _selectedModelId,
      selectedProviderSlug: _selectedProviderSlug,
      messages: _messages,
      systemPrompt: _systemPrompt,
      activeChatId: chatId,
      placeholderIndex: placeholderIndex,
      getProviderSlug: _ensureProviderSlugForCurrentModel,
      isOffline: _isOffline,
    );
  }

  List<Map<String, String>> _buildApiHistory() {
    final List<Map<String, String>> history = <Map<String, String>>[];
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

  void _updateCancelledMessage() {
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

    // Don't persist yet - wait for actual response
    // _persistChat(); // Removed - will persist after streaming completes

    // Resend with new text
    final String originalUserInput = newText;
    late int placeholderIndex;

    // Preserve the original model and provider from the user message being resent
    final String? originalModelId = _messages[index]['modelId'];
    final String? originalProvider = _messages[index]['provider'];

    // Use original model/provider if available, otherwise use currently selected
    final String modelIdToUse = originalModelId ?? _selectedModelId;
    final String? providerToUse = originalProvider ?? _selectedProviderSlug;

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

    // Don't persist "Thinking..." placeholder - wait for actual response
    // _persistChat(); // Removed - will persist after streaming completes
    _scrollChatToBottom();

    if (_activeChatId == null) {
      _activeChatId = _uuid.v4();
    }
    final String chatId = _activeChatId!;

    // Send using streaming handler with preserved model/provider
    await _streamingHandler.sendMessage(
      userInput: originalUserInput,
      attachedFiles: [],
      selectedModelId: modelIdToUse,
      selectedProviderSlug: providerToUse,
      messages: _messages,
      systemPrompt: _systemPrompt,
      activeChatId: chatId,
      placeholderIndex: placeholderIndex,
      getProviderSlug: () async => providerToUse,
      isOffline: _isOffline,
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

  bool get _modelSupportsImageInput =>
      ModelCapabilitiesService.supportsImageInput(_selectedModelId);

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

  void _scrollChatToBottom() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _persistChat({bool waitForCompletion = false}) async {
    await _persistenceHandler.persistChat(
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
        (_audioHandler.isMicActive ? 52.0 : 44.0) +
        (hasAttachments ? 80.0 : 0.0) +
        32.0 +
        mediaQuery.padding.bottom;
    final EdgeInsets listPadding = EdgeInsets.fromLTRB(
      effectiveHorizontalPadding,
      10,
      effectiveHorizontalPadding,
      10 + composerReservedSpace,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            FocusScope.of(context).unfocus();
          },
          child: Column(
            children: [
              Expanded(
                child: hasMessages
                    ? Align(
                        alignment: Alignment.center,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: expandedInputWidth,
                          ),
                          child: SelectionArea(
                            child: Scrollbar(
                              controller: _scrollController,
                              thumbVisibility: true,
                              thickness: 8.0,
                              radius: const Radius.circular(4),
                              child: ListView.builder(
                                controller: _scrollController,
                                padding: listPadding,
                                itemCount: _messages.length,
                                addAutomaticKeepAlives: false,
                                addRepaintBoundaries: true,
                                cacheExtent: 500.0,
                                itemBuilder: (_, int i) {
                                  final Map<String, String> raw = _messages[i];
                                  final String sender = raw['sender'] ?? 'ai';
                                  final bool isAiMessage = sender != 'user';
                                  final bool isStreamingMessage =
                                      _streamingHandler.isStreaming &&
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
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.expand(),
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
    final double minComposerHeight = _audioHandler.isMicActive ? 52 : 44;

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        minHeight: minComposerHeight,
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          buildTinyIconButton(
            icon: Icons.add_rounded,
            onTap: _handleAddAttachmentTap,
            isActive: hasAttachments,
            color: iconFg,
          ),
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
            child: Stack(
              children: [
                if (_audioHandler.isMicActive)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          buildRecordingIndicator(),
                          const SizedBox(width: 6),
                          Expanded(
                            child: ClipRect(
                              child: buildAudioVisualizer(
                                audioLevels: _audioHandler.audioLevels,
                                accentColor: Colors.red,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                buildKeyboardListener(
                  focusNode: _rawKeyboardListenerFocusNode,
                  controller: _controller,
                  onSend: _sendMessage,
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
                        height: 1.3,
                      ),
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: _audioHandler.isMicActive ? '' : 'Ask me anything',
                        hintStyle: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.5,
                          ),
                          fontSize: 14,
                        ),
                        filled: true,
                        fillColor: _audioHandler.isMicActive
                            ? Colors.transparent
                            : bg.withValues(alpha: 0.98),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        isDense: true,
                      ),
                      cursorColor: accent,
                      cursorWidth: 1.5,
                    ),
                  ),
                ),
              ],
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
                : (_streamingHandler.isStreaming
                      ? Icons.stop_rounded
                      : (_controller.text.trim().isEmpty && !hasAttachments
                            ? Icons.graphic_eq_rounded
                            : Icons.arrow_upward_rounded)),
            onTap: _audioHandler.isMicActive
                ? _handleAudioSend
                : (_streamingHandler.isStreaming
                      ? _sendMessage
                      : (_controller.text.trim().isEmpty && !hasAttachments
                            ? () => _openComingSoonFeature('Voice Mode')
                            : _sendMessage)),
            color: _audioHandler.isMicActive
                ? accent
                : (_streamingHandler.isStreaming ? Colors.red : accent),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
