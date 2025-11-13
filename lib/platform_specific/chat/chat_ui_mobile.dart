// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW API SERVICE
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/constants/file_constants.dart';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class _MobileMessageRenderData {
  const _MobileMessageRenderData({
    required this.sender,
    required this.displayText,
    required this.reasoning,
    required this.isReasoningStreaming,
    this.modelLabel,
  });

  final String sender;
  final String displayText;
  final String reasoning;
  final bool isReasoningStreaming;
  final String? modelLabel;

  bool get isUser => sender == 'user';
}

/* ---------- CHAT UI MOBILE (Phone-specific rendering) ---------- */
class ChukChatUIMobile extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final int selectedChatIndex;
  final bool isSidebarExpanded; // Passed from RootWrapperMobile

  const ChukChatUIMobile({
    super.key,
    required this.onToggleSidebar,
    required this.selectedChatIndex,
    required this.isSidebarExpanded,
  });

  @override
  State<ChukChatUIMobile> createState() => ChukChatUIMobileState();
}

class ChukChatUIMobileState extends State<ChukChatUIMobile> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  String? _activeChatId;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _composerScrollController = ScrollController();
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();
  final Uuid _uuid = Uuid();
  final ImagePicker _imagePicker = ImagePicker();
  bool _lastTextWasEmpty = true; // Track text state for optimization

  late ChatApiService _chatApiService;
  final List<AttachedFile> _attachedFiles = [];
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1'; // Default model
  String? _selectedProviderSlug;
  String? _systemPrompt;
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
  String? _activeRecordingPath;
  bool _isSending = false;
  bool _isTranscribingAudio = false;
  bool _isStreaming = false;
  final StreamingManager _streamingManager = StreamingManager();
  int? _editingMessageIndex;
  StreamSubscription<void>? _chatStorageSubscription;
  StreamSubscription<void>? _providerRefreshSubscription;
  bool _isOffline = false;
  late final VoidCallback _networkStatusListener;

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kAttachmentBarMarginBottom = 8.0;
  static const double _kHorizontalPaddingSmall =
      8.0; // Always use small padding for phones
  @override
  void initState() {
    super.initState();
    _chatApiService = ChatApiService(
      onUploadStatusUpdate: _handleFileUploadUpdate,
    );

    // Add listener to update UI instantly when text changes (optimized)
    _controller.addListener(() {
      final bool currentTextIsEmpty = _controller.text.trim().isEmpty;
      // Only rebuild if empty state changed (for performance)
      if (currentTextIsEmpty != _lastTextWasEmpty) {
        setState(() {
          _lastTextWasEmpty = currentTextIsEmpty;
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only request focus if sidebar is closed (on initial load)
      if (!widget.isSidebarExpanded) {
        _textFieldFocusNode.requestFocus();
      }
    });
    _loadChatFromIndex(widget.selectedChatIndex);
    unawaited(_loadProviderSlugForModel(_selectedModelId));
    unawaited(_loadSystemPrompt());
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
    _providerRefreshSubscription = ModelSelectionEventBus().refreshStream.listen((_) {
      // Reload provider slug when settings are changed
      unawaited(_loadProviderSlugForModel(_selectedModelId));
    });

    // Listen for realtime chat updates from other devices
    _chatStorageSubscription = ChatStorageService.changes.listen((_) {
      _handleRealtimeChatUpdate();
    });

    // Listen for network status changes
    _networkStatusListener = () {
      final bool isOnline = NetworkStatusService.isOnline;
      if (_isOffline != !isOnline) {
        setState(() {
          _isOffline = !isOnline;
        });
        if (isOnline) {
          _showSnackBar('Back online');
        } else {
          _showSnackBar('You are offline');
        }
      }
    };
    NetworkStatusService.isOnlineListenable.addListener(_networkStatusListener);

    // Do initial network check
    unawaited(NetworkStatusService.quickCheck());
  }

  void _handleRealtimeChatUpdate() {
    if (!mounted) return;

    // CRITICAL: Capture chatId at the start to prevent race conditions
    final String? chatIdAtStart = _activeChatId;
    if (chatIdAtStart == null) return;

    // Find the updated chat in storage
    final chatIndex = ChatStorageService.savedChats.indexWhere(
      (chat) => chat.id == chatIdAtStart,
    );

    if (chatIndex == -1) return; // Chat was deleted

    final updatedChat = ChatStorageService.savedChats[chatIndex];

    // Check if messages have changed
    final currentMessageCount = _messages.length;
    final newMessageCount = updatedChat.messages.length;

    if (newMessageCount != currentMessageCount ||
        _messagesHaveChanged(updatedChat.messages)) {
      // CRITICAL: Verify we're still on the same chat before updating UI
      if (_activeChatId != chatIdAtStart) {
        debugPrint('Chat switched during realtime update, skipping (was: $chatIdAtStart, now: $_activeChatId)');
        return;
      }

      setState(() {
        // Reload messages from storage
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
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This model does not support images',
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
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
                    _buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.photo_camera_outlined,
                      label: 'Camera',
                      isEnabled: supportsImages,
                      onTap: () {
                        if (!supportsImages) return;
                        Navigator.of(sheetContext).pop();
                        unawaited(_pickImageFromSource(ImageSource.camera));
                      },
                    ),
                    const SizedBox(width: 12),
                    _buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.photo_library_outlined,
                      label: 'Photos',
                      isEnabled: supportsImages,
                      onTap: () {
                        if (!supportsImages) return;
                        Navigator.of(sheetContext).pop();
                        unawaited(_pickImagesFromGallery());
                      },
                    ),
                    const SizedBox(width: 12),
                    _buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.attach_file,
                      label: 'Files',
                      isEnabled: true,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_uploadFiles());
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
    debugPrint('Mic button toggled: $_isMicActive');
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
    final String? audioPath = _lastRecordedFilePath;
    if (audioPath == null) {
      _showSnackBar('No audio');
      return;
    }
    final File audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      _showSnackBar('Audio missing');
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      return;
    }

    final session = await _getSessionSafely();
    if (session == null) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      return;
    }
    final accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _showSnackBar('Auth failed');
      return;
    }

    if (!mounted) return;
    setState(() {
      _isTranscribingAudio = true;
    });
    _showSnackBar('Transcribing…');

    try {
      final transcription = await _chatApiService.transcribeAudioFile(
        file: audioFile,
        accessToken: accessToken,
      );
      final String text = transcription.text.trim();
      if (text.isEmpty) {
        _showSnackBar('No text found');
      } else {
        setState(() {
          _controller.text = text;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: text.length),
          );
        });
        _textFieldFocusNode.requestFocus();
        _showSnackBar('Ready to send');
      }
    } on TranscriptionException catch (error) {
      switch (error.statusCode) {
        case 401:
          _showSnackBar('Session expired');
          await SupabaseService.signOut();
          break;
        case 502:
          _showSnackBar('Service unavailable');
          break;
        default:
          final String message = error.message.isNotEmpty
              ? error.message
              : 'Transcription failed';
          _showSnackBar(message);
      }
    } on TimeoutException {
      _showSnackBar('Timed out');
    } catch (error) {
      _showSnackBar('Error: $error');
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
        _showSnackBar('Mic permission required');
        return false;
      }

      if (await _audioRecorder.isRecording()) {
        return true;
      }

      final String path = await _createRecordingPath();
      _activeRecordingPath = path;

      _resetAudioLevels();
      _amplitudeSub?.cancel();

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          bitRate: 64000,
        ),
        path: path,
      );

      // More responsive audio visualization (30ms instead of 80ms)
      _amplitudeSub = _audioRecorder
          .onAmplitudeChanged(const Duration(milliseconds: 30))
          .listen(_handleAmplitudeSample);

      return true;
    } catch (error, stackTrace) {
      debugPrint('Failed to start microphone: $error\n$stackTrace');
      _showSnackBar('Mic access failed');
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
          await _deleteRecordingFile(_activeRecordingPath);
        }
        _activeRecordingPath = null;
        return;
      }

      final String? path = await _audioRecorder.stop();
      final String? effectivePath = path ?? _activeRecordingPath;
      _activeRecordingPath = null;

      if (keepFile) {
        _lastRecordedFilePath = effectivePath;
      } else {
        _lastRecordedFilePath = null;
        await _deleteRecordingFile(effectivePath);
      }
    } catch (error, stackTrace) {
      debugPrint('Failed to stop microphone: $error\n$stackTrace');
    }
  }

  Future<bool> _ensureMicPermission() async {
    final PermissionStatus status = await Permission.microphone.request();
    if (status.isGranted) {
      return true;
    }
    if (status.isPermanentlyDenied) {
      _showSnackBar('Enable mic in settings');
      return false;
    }
    _showSnackBar('Mic permission required');
    return false;
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
      debugPrint('Failed to delete audio file: $error\n$stackTrace');
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
      _showSnackBar('Nothing to copy');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _showSnackBar(label ?? 'Copied');
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
      _showSnackBar('Message empty');
      return;
    }
    if (_isStreaming) {
      _showSnackBar('Please wait');
      return;
    }
    if (_isSending) {
      _showSnackBar('Please wait');
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

    setState(() {
      _isSending = true;
      _messages.add({'sender': 'ai', 'text': 'Thinking...', 'reasoning': ''});
      placeholderIndex = _messages.length - 1;
    });

    _persistChat();
    _scrollChatToBottom();

    // Generate a chat ID if this is a new chat (do this early)
    if (_activeChatId == null) {
      _activeChatId = _uuid.v4();
    }
    final String chatId = _activeChatId!;

    final session = await _getSessionSafely();
    if (session == null) {
      _finalizeAiMessage(
        placeholderIndex,
        'Cannot send message. Please check your connection.',
        chatId: chatId,
      );
      return;
    }

    final String accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      _finalizeAiMessage(
        placeholderIndex,
        'Authentication failed. Please sign in again.',
        chatId: chatId,
      );
      return;
    }

    // Build conversation history up to the edited message
    final List<Map<String, String>> conversationHistory = [];
    for (int i = 0; i < index; i++) {
      final msg = _messages[i];
      final sender = msg['sender'];
      final text = msg['text'] ?? '';
      if (sender == 'user') {
        conversationHistory.add({'role': 'user', 'content': text});
      } else if (sender == 'ai') {
        conversationHistory.add({'role': 'assistant', 'content': text});
      }
    }

    try {
      setState(() => _isStreaming = true);

      final Stream<ChatStreamEvent> eventStream =
          WebSocketChatService.sendStreamingChat(
            accessToken: accessToken,
            message: originalUserInput,
            modelId: _selectedModelId,
            providerSlug: _selectedProviderSlug ?? 'openai',
            history: conversationHistory,
            systemPrompt: _systemPrompt,
            maxTokens: 4096,
            temperature: 0.7,
          );

      // Use StreamingManager for background streaming support
      await _streamingManager.startStream(
        chatId: chatId,
        messageIndex: placeholderIndex,
        stream: eventStream,
        onUpdate: (content, reasoning) {
          if (!mounted) return;
          if (_activeChatId == chatId) {
            _updateAiMessage(placeholderIndex, content, reasoning, chatId: chatId);
            _scrollChatToBottom();
          }
        },
        onComplete: (finalContent, finalReasoning) {
          if (!mounted) return;

          // Only update UI if this is still the active chat
          if (_activeChatId == chatId) {
            if (finalContent.isEmpty) {
              _finalizeAiMessage(placeholderIndex, 'No response received.', chatId: chatId);
            } else {
              _finalizeAiMessage(
                placeholderIndex,
                finalContent,
                reasoning: finalReasoning.isEmpty ? null : finalReasoning,
                chatId: chatId,
              );
            }

            setState(() {
              _isStreaming = false;
              _isSending = false;
            });
          } else {
            debugPrint('Background edited message stream completed for chat $chatId');
            unawaited(_updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: placeholderIndex,
              content: finalContent.isNotEmpty
                  ? finalContent
                  : 'No response received.',
              reasoning: finalReasoning,
            ));
          }
        },
        onError: (errorMessage) {
          if (!mounted) return;

          // Only update UI if this is still the active chat
          if (_activeChatId == chatId) {
            _finalizeAiMessage(placeholderIndex, errorMessage, chatId: chatId);
            setState(() {
              _isStreaming = false;
              _isSending = false;
            });
          } else {
            debugPrint('Background edited message stream error for chat $chatId');
            unawaited(_updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: placeholderIndex,
              content: errorMessage,
              reasoning: '',
            ));
          }
        },
      );
    } catch (e) {
      debugPrint('Streaming error: $e');
      _finalizeAiMessage(placeholderIndex, 'Error: $e', chatId: chatId);
      if (mounted) {
        setState(() {
          _isStreaming = false;
          _isSending = false;
        });
      }
    } finally {
      _persistChat();
    }
  }

  Future<void> _resendMessageAt(int index) async {
    if (!_isValidMessageIndex(index)) return;
    final String text = (_messages[index]['text'] ?? '').trim();
    if (text.isEmpty) {
      _showSnackBar('Nothing to resend');
      return;
    }
    // Use the same logic as editing and submitting
    await _submitEditedMessage(index, text);
  }

  List<MessageBubbleAction> _buildMessageActionsForIndex(
    int index,
    _MobileMessageRenderData data,
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

  Future<void> _pickImageFromSource(ImageSource source) async {
    if (!_ensureImageUploadsSupported()) return;
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        imageQuality: 90,
      );
      if (pickedFile == null) return;

      final File file = File(pickedFile.path);
      final int fileSize = await pickedFile.length();
      final String fileName = pickedFile.name.isNotEmpty
          ? pickedFile.name
          : pickedFile.path.split('/').last;

      await _handleFileAttachment(
        file: file,
        fileName: fileName,
        fileSizeBytes: fileSize,
      );
    } catch (error) {
      final String sourceName = source == ImageSource.camera
          ? 'camera'
          : 'photo picker';
      _showAttachmentError('Unable to open $sourceName: $error');
    }
  }

  Future<void> _pickImagesFromGallery() async {
    if (!_ensureImageUploadsSupported()) return;
    try {
      final List<XFile> pickedImages = await _imagePicker.pickMultiImage(
        imageQuality: 90,
      );
      if (pickedImages.isEmpty) return;

      for (final XFile image in pickedImages) {
        final File file = File(image.path);
        final int fileSize = await image.length();
        final String fileName = image.name.isNotEmpty
            ? image.name
            : image.path.split('/').last;
        await _handleFileAttachment(
          file: file,
          fileName: fileName,
          fileSizeBytes: fileSize,
        );
      }
    } catch (error) {
      _showAttachmentError('Unable to access photo library: $error');
    }
  }

  @override
  void didUpdateWidget(covariant ChukChatUIMobile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      // Save current chat before switching
      if (_activeChatId != null) {
        _persistChat(waitForCompletion: false);
      }

      // Clear all state before loading new chat to prevent data leakage
      setState(() {
        _messages.clear();
        _attachedFiles.clear();
        _controller.clear();
        _editingMessageIndex = null;
        _isSending = false;
      });

      _loadChatFromIndex(widget.selectedChatIndex);

      // Update streaming state for the NEW chat
      final bool newChatIsStreaming = _activeChatId != null &&
          _streamingManager.isStreaming(_activeChatId!);

      if (_isStreaming != newChatIsStreaming) {
        setState(() {
          _isStreaming = newChatIsStreaming;
        });
      }
    }
  }

  @override
  void dispose() {
    // Cancel stream for current chat when disposing the widget
    if (_activeChatId != null) {
      unawaited(_streamingManager.cancelStream(_activeChatId!));
    }
    _chatStorageSubscription?.cancel();
    _providerRefreshSubscription?.cancel();
    NetworkStatusService.isOnlineListenable.removeListener(_networkStatusListener);
    _controller.dispose();
    _scrollController.dispose();
    _composerScrollController.dispose();
    _textFieldFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    unawaited(_stopMicRecording());
    _amplitudeSub?.cancel();
    unawaited(_audioRecorder.dispose());
    ModelSelectionDropdown.selectedModelListenable.removeListener(
      _modelSelectionListener,
    );
    super.dispose();
  }

  void _loadChatFromIndex(int index) {
    if (index == -1) {
      _messages.clear();
      _attachedFiles.clear();
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
            final String? modelId = message.modelId;
            if (modelId != null && modelId.isNotEmpty) {
              map['modelId'] = modelId;
            }
            final String? provider = message.provider;
            if (provider != null && provider.isNotEmpty) {
              map['provider'] = provider;
            }
            return map;
          }),
        );
    } else {
      _activeChatId = null;
    }

    // Update streaming state for the loaded chat
    final bool chatIsStreaming = _activeChatId != null &&
        _streamingManager.isStreaming(_activeChatId!);

    // CRITICAL: If this chat is streaming in background, update the message
    // with the current buffered content instead of stale storage data
    if (chatIsStreaming && _activeChatId != null) {
      final int? streamingMsgIndex =
          _streamingManager.getStreamingMessageIndex(_activeChatId!);
      if (streamingMsgIndex != null &&
          streamingMsgIndex >= 0 &&
          streamingMsgIndex < _messages.length) {
        final String? bufferedContent =
            _streamingManager.getBufferedContent(_activeChatId!);
        final String? bufferedReasoning =
            _streamingManager.getBufferedReasoning(_activeChatId!);

        if (bufferedContent != null) {
          // Update the message with live buffered content
          final Map<String, String> updatedMessage =
              Map<String, String>.from(_messages[streamingMsgIndex]);
          updatedMessage['text'] = bufferedContent;
          updatedMessage['reasoning'] = bufferedReasoning ?? '';
          _messages[streamingMsgIndex] = updatedMessage;

          debugPrint(
            'Loaded streaming chat $_activeChatId with buffered content '
            '(${bufferedContent.length} chars)',
          );
        }
      }
    }

    setState(() {
      _isMicActive = false;
      _isStreaming = chatIsStreaming;
      _isSending = chatIsStreaming; // If streaming, also mark as sending
    });

    _scrollChatToBottom();
    // Only request focus if sidebar is closed (don't steal focus from sidebar)
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
      _isMicActive = false;
      _attachedFiles.clear();
      _controller.clear();
      _editingMessageIndex = null;
      _isSending = false;
      _isStreaming = false; // New chat has no streaming
    });
    _scrollChatToBottom();
    // Only request focus if sidebar is closed
    if (!widget.isSidebarExpanded) {
      _textFieldFocusNode.requestFocus();
    }
    await ChatStorageService.loadSavedChatsForSidebar();
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

  Future<void> _loadSystemPrompt() async {
    try {
      final systemPrompt = await UserPreferencesService.loadSystemPrompt();
      if (!mounted) return;
      setState(() {
        _systemPrompt = systemPrompt;
      });
      if (systemPrompt != null && systemPrompt.isNotEmpty) {
        debugPrint('Loaded system prompt: ${systemPrompt.length} characters');
      }
    } catch (e) {
      debugPrint('Error loading system prompt: $e');
    }
  }

  bool get _modelSupportsImageInput =>
      ModelCapabilitiesService.supportsImageInput(_selectedModelId);

  bool _ensureImageUploadsSupported() {
    if (_modelSupportsImageInput) {
      return true;
    }
    _showAttachmentError(
      'Image uploads are not supported by the selected model. Choose a vision-capable model in Settings.',
    );
    return false;
  }

  bool _isImageExtension(String extension) {
    return FileConstants.imageExtensions.contains(extension);
  }

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
          _attachedFiles[index] = _attachedFiles[index].copyWith(
            markdownContent: markdownContent,
            isUploading: false,
          );
        } else if (!isUploading) {
          _attachedFiles.removeAt(index);
        } else {
          _attachedFiles[index] = _attachedFiles[index].copyWith(
            isUploading: isUploading,
          );
        }
      }
    });
    if (snackBarMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(snackBarMessage)));
    }
    _scrollChatToBottom();
  }

  void _cancelStream() {
    if (_activeChatId != null && _isStreaming) {
      debugPrint('Cancelling stream for chat $_activeChatId...');
      unawaited(_streamingManager.cancelStream(_activeChatId!));

      setState(() {
        _isStreaming = false;
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

  Future<void> _sendMessage() async {
    if (_isSending && !_isStreaming) {
      _showSnackBar('Please wait');
      return;
    }

    if (_isStreaming) {
      _cancelStream();
      return;
    }

    // Check network status before sending
    if (_isOffline) {
      _showSnackBar('You are offline. Please check your connection.');
      return;
    }

    if (_attachedFiles.any((f) => f.isUploading)) {
      _showSnackBar('Upload in progress');
      return;
    }

    final String originalUserInput = _controller.text.trim();

    // Use MessageCompositionService to prepare the message
    final List<Map<String, String>> apiHistory =
        _buildApiHistoryWithPendingMessage(originalUserInput);

    final result = await MessageCompositionService.prepareMessage(
      userInput: originalUserInput,
      attachedFiles: _attachedFiles,
      selectedModelId: _selectedModelId,
      apiHistory: apiHistory,
      systemPrompt: _systemPrompt,
      getProviderSlug: _ensureProviderSlugForCurrentModel,
    );

    if (!result.isValid) {
      _showSnackBar(result.errorMessage ?? 'Invalid message');
      if (result.errorMessage == 'Session expired. Please sign in again.') {
        await SupabaseService.signOut();
      }
      return;
    }

    // Extract prepared values
    final String displayMessageText = result.displayMessageText!;
    final String aiPromptContent = result.aiPromptContent!;
    final String accessToken = result.accessToken!;
    final String providerSlug = result.providerSlug!;
    final int maxResponseTokens = result.maxResponseTokens!;
    final String? effectiveSystemPrompt = result.effectiveSystemPrompt;

    final bool hasAttachments = _attachedFiles.any(
      (f) => f.markdownContent != null,
    );

    int placeholderIndex = -1;
    setState(() {
      _messages.add({
        'sender': 'user',
        'text': displayMessageText,
        'reasoning': '',
        'modelId': _selectedModelId,
        'provider': providerSlug,
      });
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
    _textFieldFocusNode.requestFocus();

    _scrollChatToBottom();

    _persistChat();

    // Generate a chat ID if this is a new chat
    if (_activeChatId == null) {
      _activeChatId = _uuid.v4();
    }
    final String chatId = _activeChatId!;

    setState(() {
      _isStreaming = true;
    });

    try {
      final stream = WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: aiPromptContent,
        modelId: _selectedModelId,
        providerSlug: providerSlug,
        history: apiHistory.isEmpty ? null : apiHistory,
        systemPrompt: effectiveSystemPrompt,
        maxTokens: maxResponseTokens,
      );

      // Use StreamingManager to handle the stream
      // This allows the stream to continue even when switching chats
      await _streamingManager.startStream(
        chatId: chatId,
        messageIndex: placeholderIndex,
        stream: stream,
        onUpdate: (content, reasoning) {
          if (!mounted) return;
          // CRITICAL: Only update UI if this is STILL the active chat
          // Background streams should NOT modify _messages list at all during streaming
          if (_activeChatId == chatId) {
            _updateAiMessage(placeholderIndex, content, reasoning, chatId: chatId);
            _scrollChatToBottom();
          } else {
            // Background stream - do NOT touch _messages, only onComplete saves to storage
            debugPrint('Background stream update for chat $chatId (not updating UI)');
          }
        },
        onComplete: (finalContent, finalReasoning) {
          debugPrint('Stream completed for chat $chatId');
          if (!mounted) return;

          // Only update UI if this is still the active chat
          if (_activeChatId == chatId) {
            if (finalContent.isEmpty) {
              _finalizeAiMessage(
                placeholderIndex,
                'The model returned an empty response.',
                chatId: chatId,
              );
            } else {
              _finalizeAiMessage(
                placeholderIndex,
                finalContent,
                reasoning: finalReasoning.isEmpty ? null : finalReasoning,
                chatId: chatId,
              );
            }

            setState(() {
              _isStreaming = false;
              _isSending = false;
            });
          } else {
            // Background chat completed - save to storage
            // The message will be visible when user switches back to this chat
            debugPrint('Background stream completed for chat $chatId');
            unawaited(_updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: placeholderIndex,
              content: finalContent.isNotEmpty
                  ? finalContent
                  : 'The model returned an empty response.',
              reasoning: finalReasoning,
            ));
          }
        },
        onError: (errorMessage) {
          debugPrint('Stream error for chat $chatId: $errorMessage');
          if (!mounted) return;

          // Only update UI if this is still the active chat
          if (_activeChatId == chatId) {
            _finalizeAiMessage(placeholderIndex, errorMessage, chatId: chatId);
            _showSnackBar(errorMessage);
            setState(() {
              _isStreaming = false;
              _isSending = false;
            });
          } else {
            debugPrint('Background stream error for chat $chatId');
            unawaited(_updateBackgroundChatMessage(
              chatId: chatId,
              messageIndex: placeholderIndex,
              content: errorMessage,
              reasoning: '',
            ));
          }
        },
      );
    } catch (error) {
      debugPrint('Failed to start stream: $error');
      _finalizeAiMessage(placeholderIndex, 'Failed to start streaming: $error', chatId: chatId);
      _showSnackBar('Failed to start streaming: $error');
      if (mounted) {
        setState(() {
          _isStreaming = false;
          _isSending = false;
        });
      }
    }
  }

  List<Map<String, String>> _buildApiHistoryWithPendingMessage(
    String pendingUserText,
  ) {
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

    if (pendingUserText.trim().isNotEmpty) {
      history.add({'role': 'user', 'content': pendingUserText});
    }

    return history;
  }

  void _updateAiMessage(int index, String content, String reasoning, {required String chatId}) {
    if (!mounted || index < 0 || index >= _messages.length) return;

    // CRITICAL: Only update if this is still the active chat
    if (_activeChatId != chatId) {
      debugPrint('Skipping UI update for background chat $chatId (active: $_activeChatId)');
      return;
    }

    setState(() {
      final Map<String, String> message = Map<String, String>.from(
        _messages[index],
      );
      message['text'] = content;
      message['reasoning'] = reasoning;
      _messages[index] = message;
    });
  }

  void _finalizeAiMessage(int index, String content, {String? reasoning, required String chatId}) {
    if (index < 0 || index >= _messages.length) {
      debugPrint('Invalid message index $index for finalization');
      return;
    }

    // CRITICAL: Only update UI if this is still the active chat
    if (_activeChatId != chatId) {
      debugPrint('Skipping finalization for background chat $chatId (active: $_activeChatId)');
      return;
    }

    if (mounted) {
      setState(() {
        final Map<String, String> message = Map<String, String>.from(
          _messages[index],
        );
        message['text'] = content;
        message['reasoning'] = reasoning ?? '';
        _messages[index] = message;
        _isSending = false;
        _isStreaming = false;
      });

      _scrollChatToBottom();
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      _persistChat();
    }
  }

  Future<void> _uploadFiles() async {
    if (_attachedFiles.where((f) => f.isUploading).length >=
        FileConstants.maxConcurrentUploads) {
      _showAttachmentError('Please wait for current uploads to complete');
      return;
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileConstants.allowedExtensions,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) {
      debugPrint('File picking canceled.');
      return;
    }

    for (final platformFile in result.files) {
      final String? path = platformFile.path;
      if (path == null) continue;

      await _handleFileAttachment(
        file: File(path),
        fileName: platformFile.name,
        fileSizeBytes: platformFile.size,
      );
    }
  }

  Future<void> _handleFileAttachment({
    required File file,
    required String fileName,
    required int fileSizeBytes,
  }) async {
    final String extension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    if (fileSizeBytes > FileConstants.maxFileSizeBytes) {
      _showAttachmentError('File "$fileName" exceeds 10MB limit');
      return;
    }

    if (extension.isEmpty || !FileConstants.allowedExtensions.contains(extension)) {
      final String detail = extension.isEmpty ? '' : ': .$extension';
      _showAttachmentError('Unsupported file type for "$fileName"$detail');
      return;
    }

    if (_isImageExtension(extension) && !_modelSupportsImageInput) {
      _showAttachmentError(
        'Image uploads are not supported by the selected model.',
      );
      return;
    }

    if (_attachedFiles.where((f) => f.isUploading).length >=
        FileConstants.maxConcurrentUploads) {
      _showAttachmentError(
        'Skipping "$fileName": too many concurrent uploads. Try again soon.',
      );
      return;
    }

    final String fileId = _uuid.v4();
    setState(() {
      _attachedFiles.add(
        AttachedFile(
          id: fileId,
          fileName: fileName,
          isUploading: true,
          localPath: file.path,
          fileSizeBytes: fileSizeBytes,
        ),
      );
    });
    _scrollChatToBottom();
    _chatApiService.performFileUpload(file, fileName, fileId);
  }

  void _showAttachmentError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildAttachmentSheetOption({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isEnabled,
  }) {
    final theme = Theme.of(context);
    final Color background = isEnabled
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);
    final Color borderColor = isEnabled
        ? theme.dividerColor.withValues(alpha: 0.2)
        : theme.dividerColor.withValues(alpha: 0.1);
    final Color foreground = isEnabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface.withValues(alpha: 0.3);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            height: 84,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: foreground),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _removeAttachedFile(String fileId) {
    setState(() {
      _attachedFiles.removeWhere((f) => f.id == fileId);
    });
    _scrollChatToBottom();
    _textFieldFocusNode.requestFocus();
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

  /// Safely get session, only logout on actual auth errors (not network errors)
  Future<dynamic> _getSessionSafely() async {
    try {
      final session = await SupabaseService.refreshSession() ??
                      SupabaseService.auth.currentSession;

      if (session == null) {
        // Check if we're offline before logging out
        final bool isOnline = await NetworkStatusService.hasInternetConnection();
        if (!isOnline) {
          _showSnackBar('Cannot connect. Please check your network.');
          return null;
        }

        // Online but no session = genuinely expired
        _showSnackBar('Session expired. Please sign in again.');
        await SupabaseService.signOut();
        return null;
      }

      return session;
    } catch (error) {
      // Check if this is a network error
      if (NetworkStatusService.isNetworkError(error)) {
        debugPrint('Network error during session refresh: $error');
        _showSnackBar('Network error. Please check your connection.');
        // Do a quick network check to update status
        unawaited(NetworkStatusService.quickCheck());
        return null;
      }

      // Not a network error, likely auth issue
      debugPrint('Auth error during session refresh: $error');
      _showSnackBar('Authentication error. Please sign in again.');
      await SupabaseService.signOut();
      return null;
    }
  }

  Future<void> _persistChat({bool waitForCompletion = false}) async {
    if (_messages.isEmpty) return;
    final messagesCopy = _messages
        .map((message) => Map<String, String>.from(message))
        .toList(growable: false);
    final operation = _persistChatInternal(messagesCopy, _activeChatId);
    if (waitForCompletion) {
      await operation;
    } else {
      unawaited(operation);
    }
  }

  /// Update a specific message in storage for a background chat
  Future<void> _updateBackgroundChatMessage({
    required String chatId,
    required int messageIndex,
    required String content,
    required String reasoning,
  }) async {
    try {
      // Find the chat in storage
      final chatIndex = ChatStorageService.savedChats.indexWhere(
        (chat) => chat.id == chatId,
      );

      if (chatIndex == -1) {
        debugPrint('Chat $chatId not found in storage');
        return;
      }

      final chat = ChatStorageService.savedChats[chatIndex];
      final messages = chat.messages.map((m) => m.toJson()).toList();

      // Update the message at the specified index
      if (messageIndex >= 0 && messageIndex < messages.length) {
        messages[messageIndex]['text'] = content;
        messages[messageIndex]['reasoning'] = reasoning;

        // Save back to storage
        await ChatStorageService.updateChat(chatId, messages);
        debugPrint('Updated background chat $chatId message at index $messageIndex');
      } else {
        debugPrint('Invalid message index $messageIndex for chat $chatId');
      }
    } catch (e) {
      debugPrint('Error updating background chat message: $e');
    }
  }

  Future<void> _persistChatInternal(
    List<Map<String, String>> messagesCopy,
    String? chatId,
  ) async {
    // CRITICAL: Capture chatId at the start to prevent race conditions
    final String? chatIdAtStart = chatId ?? _activeChatId;

    try {
      final stored = chatId == null
          ? await ChatStorageService.saveChat(messagesCopy)
          : await ChatStorageService.updateChat(chatId, messagesCopy);
      if (!mounted || stored == null) return;

      // CRITICAL: Only update state if we're STILL on the same chat
      // This prevents corruption when user switches chats during persist
      if (_activeChatId == chatIdAtStart && _activeChatId == stored.id) {
        setState(() {
          _activeChatId = stored.id;
        });
        final index = ChatStorageService.savedChats.indexWhere(
          (chat) => chat.id == stored.id,
        );
        if (index != -1) {
          ChatStorageService.selectedChatIndex = index;
        }
      } else {
        debugPrint('Chat switched during persist, skipping UI update (was: $chatIdAtStart, now: $_activeChatId)');
      }
    } catch (error) {
      final String errorStr = error.toString().toLowerCase();

      // Don't show errors for network issues or when offline
      if (NetworkStatusService.isNetworkError(error) || _isOffline) {
        debugPrint('Chat persist failed (offline/network): $error');
        // Silently fail - chats will sync when back online
        return;
      }

      // Check if it's a permission/auth error
      if (errorStr.contains('permission') ||
          errorStr.contains('access') ||
          errorStr.contains('denied') ||
          errorStr.contains('unauthorized')) {
        debugPrint('Chat persist failed (permissions): $error');

        // Only show error if mounted and not a transient issue
        if (mounted) {
          // Check if we actually have a valid session
          final session = SupabaseService.auth.currentSession;
          if (session == null) {
            _showSnackBar('Please sign in to save chats');
          } else {
            debugPrint('Permission error despite valid session - may be RLS policy issue');
            // Don't spam user with permission errors - log it
          }
        }
        return;
      }

      // For other errors, log but don't show to user (too disruptive)
      debugPrint('Chat persist failed: $error');
      if (mounted && errorStr.contains('encryption')) {
        _showSnackBar('Error saving chat. Your messages are still visible.');
      }
    }
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

  @override
  Widget build(BuildContext context) {
    const bool isCompactModeForModelDropdown = true;

    // Performance: Cache MediaQuery and Theme lookups
    final mediaQuery = MediaQuery.of(context);
    final theme = Theme.of(context);
    final double screenWidth = mediaQuery.size.width;
    final double keyboardInset = mediaQuery.viewInsets.bottom;
    final Color iconFg = theme.resolvedIconColor;

    const double effectiveHorizontalPadding = _kHorizontalPaddingSmall;
    final double maxPossibleChatContentWidth = math.max(
      0.0,
      screenWidth - (effectiveHorizontalPadding * 2),
    );
    final double constrainedChatContentWidth = math.min(
      _kMaxChatContentWidth,
      maxPossibleChatContentWidth,
    );

    final bool hasAttachments = _attachedFiles.isNotEmpty;
    final double expandedInputWidth = constrainedChatContentWidth;
    final double targetInputWidth = expandedInputWidth;
    final bool hasMessages = _messages.isNotEmpty;
    final double composerReservedSpace =
        (_isMicActive ? 56.0 : 48.0) +
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
            // Dismiss keyboard when tapping outside input area
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
                                // Performance: Build render data on-demand, not all at once
                                final Map<String, String> raw = _messages[i];
                                final String sender = raw['sender'] ?? 'ai';
                                final bool isAiMessage = sender != 'user';
                                final bool isStreamingMessage =
                                    _isStreaming &&
                                    i == _messages.length - 1 &&
                                    isAiMessage;
                                final String displayText = (raw['text'] ?? '')
                                    .trimRight();
                                final String reasoning = raw['reasoning'] ?? '';
                                final String? modelLabel = isAiMessage
                                    ? _formatModelInfo(
                                        raw['modelId'],
                                        raw['provider'],
                                      )
                                    : null;
                                final String? reasoningText =
                                    reasoning.trim().isEmpty ? null : reasoning;
                                final bool isBeingEdited =
                                    _editingMessageIndex == i;
                                final bool isUser = sender == 'user';

                                return RepaintBoundary(
                                  child: MessageBubble(
                                    key: ValueKey('msg_$i'),
                                    message: displayText,
                                    reasoning: reasoningText,
                                    isUser: isUser,
                                    maxWidth: expandedInputWidth * 0.7,
                                    isReasoningStreaming: isStreamingMessage,
                                    modelLabel: modelLabel,
                                    actions: _buildMessageActionsForIndex(
                                      i,
                                      _MobileMessageRenderData(
                                        sender: sender,
                                        displayText: displayText,
                                        reasoning: reasoning,
                                        isReasoningStreaming:
                                            isStreamingMessage,
                                        modelLabel: modelLabel,
                                      ),
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
                                        ? _cancelEditMessage
                                        : null,
                                  ),
                                );
                              },
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
                      width: targetInputWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasAttachments)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: _kAttachmentBarMarginBottom,
                              ),
                              child: AttachmentPreviewBar(
                                files: _attachedFiles,
                                onRemove: _removeAttachedFile,
                              ),
                            ),
                          _buildSearchBar(
                            isCompactMode: isCompactModeForModelDropdown,
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

  Widget _buildSearchBar({required bool isCompactMode}) {
    // Performance: Cache theme lookups
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final Color bg = theme.scaffoldBackgroundColor;
    final Color accent = colorScheme.primary;
    final Color iconFg = theme.resolvedIconColor;

    final bool hasAttachments = _attachedFiles.isNotEmpty;

    final double composerHeight = _isMicActive ? 56 : 48;

    return Container(
      width: double.infinity,
      height: composerHeight,
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _isMicActive
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
      child: _buildNormalRow(
        hasAttachments: hasAttachments,
        isCompactMode: isCompactMode,
        accent: accent,
        iconFg: iconFg,
      ),
    );
  }

  Widget _buildNormalRow({
    required bool hasAttachments,
    required bool isCompactMode,
    required Color accent,
    required Color iconFg,
  }) {
    // Performance: Cache colorScheme lookup
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        // Attachment button (images restricted to vision models, files work for all)
        _buildTinyIconBtn(
          icon: Icons.add_rounded,
          onTap: _handleAddAttachmentTap,
          isActive: hasAttachments,
          color: iconFg,
        ),
        const SizedBox(width: 2),
        // Model selector (ultra compact)
        GestureDetector(
          onTap: () {
            // Show model selector
          },
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
        // Text input (with recording visualization overlay)
        Expanded(
          child: Stack(
            children: [
              // Show recording visualization when mic is active
              if (_isMicActive)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        // Recording indicator
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Compact visualizer (fewer bars to prevent overflow)
                        Expanded(
                          child: ClipRect(
                            child: SizedBox(
                              height: 20,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: List.generate(10, (index) {
                                  final double level = index < _audioLevels.length
                                      ? _audioLevels[index]
                                      : 0.0;
                                  final double barHeight = (level * 16).clamp(2.0, 16.0);
                                  return Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 0.5),
                                      child: Container(
                                        height: barHeight,
                                        decoration: BoxDecoration(
                                          color: Colors.red.withValues(alpha: 0.8),
                                          borderRadius: BorderRadius.circular(1.5),
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Text field (always present, keyboard stays open)
              KeyboardListener(
            focusNode: _rawKeyboardListenerFocusNode,
            onKeyEvent: (event) {
              if (event is! KeyDownEvent) return;
              if (event.logicalKey != LogicalKeyboardKey.enter) return;

              final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
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
            child: TextField(
              controller: _controller,
              focusNode: _textFieldFocusNode,
              autofocus: false,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.send,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 14,
                height: 1.3,
              ),
              maxLines: 1,
              decoration: InputDecoration(
                hintText: 'Ask me anything',
                hintStyle: TextStyle(
                  color: colorScheme.onSurface.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
                filled: true,
                fillColor: _isMicActive
                    ? Colors.transparent  // Transparent when recording to show visualization
                    : Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.98),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 0,
                ),
                isDense: true,
              ),
              cursorColor: accent,
              cursorWidth: 1.5,
            ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        // Mic button (red when active)
        _buildTinyIconBtn(
          icon: _isMicActive ? Icons.stop_rounded : Icons.mic_rounded,
          onTap: _handleMicTap,
          isActive: _isMicActive,
          color: _isMicActive ? Colors.red : iconFg,
        ),
        const SizedBox(width: 2),
        // Send button (or send audio button when recording)
        _buildTinyActionBtn(
          icon: _isMicActive
              ? Icons.send_rounded  // Send audio when recording
              : (_isStreaming
                  ? Icons.stop_rounded
                  : (_controller.text.trim().isEmpty && !hasAttachments
                        ? Icons.graphic_eq_rounded
                        : Icons.arrow_upward_rounded)),
          onTap: _isMicActive
              ? _handleAudioSend  // Send recorded audio
              : (_isStreaming
                  ? _sendMessage  // Stop streaming when clicked
                  : (_controller.text.trim().isEmpty && !hasAttachments
                      ? () => _openComingSoonFeature('Voice Mode')
                      : _sendMessage)),
          color: _isMicActive ? accent : (_isStreaming ? Colors.red : accent),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildTinyIconBtn({
    required IconData icon,
    required VoidCallback? onTap, // Made optional for disabled state
    required bool isActive,
    required Color color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isActive
                ? color.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 18,
            color: isActive ? color : color.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _buildTinyActionBtn({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [color, color.withValues(alpha: 0.85)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}
