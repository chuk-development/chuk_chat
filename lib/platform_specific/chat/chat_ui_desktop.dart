// lib/platform_specific/chat/chat_ui_desktop.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math; // For min/max
import 'dart:async';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/constants/file_constants.dart';

import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/token_estimator.dart';

class _MessageRenderData {
  const _MessageRenderData({
    required this.sender,
    required this.displayText,
    required this.reasoning,
    required this.isReasoningStreaming,
  });

  final String sender;
  final String displayText;
  final String reasoning;
  final bool isReasoningStreaming;

  bool get isUser => sender == 'user';
}

class ChukChatUIDesktop extends StatefulWidget {
  // RENAMED CLASS
  final VoidCallback onToggleSidebar;
  final int selectedChatIndex;
  final bool isSidebarExpanded;
  final bool isCompactMode;

  const ChukChatUIDesktop({
    // RENAMED CONSTRUCTOR
    super.key,
    required this.onToggleSidebar,
    required this.selectedChatIndex,
    required this.isSidebarExpanded,
    required this.isCompactMode,
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
  late Animation<double> _anim;
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1';
  String? _selectedProviderSlug;
  String? _systemPrompt;
  late final VoidCallback _modelSelectionListener;

  bool _isImageActive = false;
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
  StreamSubscription<ChatStreamEvent>? _streamSubscription;
  bool _isStreaming = false;
  final StreamingManager _streamingManager = StreamingManager();
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
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
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
  }

  @override
  void didUpdateWidget(covariant ChukChatUIDesktop oldWidget) {
    // RENAMED WIDGET TYPE
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      // Save current chat before switching
      if (_activeChatId != null) {
        _persistChat(waitForCompletion: false);
      }
      _loadChatFromIndex(widget.selectedChatIndex);
      // Update UI based on new chat's streaming status
      setState(() {
        _isStreaming =
            _activeChatId != null &&
            _streamingManager.isStreaming(_activeChatId!);
      });
    }
  }

  @override
  void dispose() {
    // Don't cancel streams - they continue in background
    // _streamingManager handles all streams globally
    _autoSaveTimer?.cancel();
    _streamSubscription?.cancel();
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

  void _loadChatFromIndex(int index) {
    if (index == -1) {
      _messages.clear();
      _animCtrl.reset();
      _attachedFiles.clear();
      _activeChatId = null;
    } else if (index >= 0 && index < ChatStorageService.savedChats.length) {
      final storedChat = ChatStorageService.savedChats[index];
      _activeChatId = storedChat.id;
      _messages
        ..clear()
        ..addAll(
          storedChat.messages
              .map(
                (message) => {
                  'sender': message.sender,
                  'text': message.text,
                  'reasoning': message.reasoning,
                },
              )
              .toList(),
        );
      if (_messages.isNotEmpty) {
        _animCtrl.forward();
      } else {
        _animCtrl.reset();
      }
    } else {
      _activeChatId = null;
    }
    setState(() {
      _isImageActive = false;
      _isMicActive = false;
      _resetAudioLevels();
    });
    _scrollChatToBottom();
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
  }

  void newChat() async {
    await _persistChat(waitForCompletion: true);
    setState(() {
      _messages.clear();
      _animCtrl.reset();
      _activeChatId = null;
      ChatStorageService.selectedChatIndex = -1;
      _isImageActive = false;
      _isMicActive = false;
      _attachedFiles.clear();
      _resetAudioLevels();
    });
    _scrollChatToBottom();
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
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

  Future<String?> _resolveSystemPromptForSend() async {
    if (_systemPrompt != null) return _systemPrompt;
    try {
      final prompt = await UserPreferencesService.loadSystemPrompt();
      if (mounted) {
        setState(() {
          _systemPrompt = prompt;
        });
      } else {
        _systemPrompt = prompt;
      }
      return prompt;
    } catch (error) {
      debugPrint('Error resolving system prompt for send: $error');
      return _systemPrompt;
    }
  }

  bool get _modelSupportsImageInput =>
      ModelCapabilitiesService.supportsImageInput(_selectedModelId);

  bool _isImageExtension(String extension) {
    return FileConstants.imageExtensions.contains(extension);
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
    _showSnackBar('Transcribing audio…');

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
        _showSnackBar('Transcription ready. Tap send to share it.');
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

      _amplitudeSub = _audioRecorder
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen(_handleAmplitudeSample);

      return true;
    } catch (error, stackTrace) {
      debugPrint('Failed to start microphone: $error\n$stackTrace');
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
    if (!(kIsWeb ||
        Platform.isAndroid ||
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
      debugPrint('permission_handler plugin unavailable; skipping request.');
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
      debugPrint('Failed to delete audio file: $error\n$stackTrace');
    }
  }

  void _showSnackBar(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
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

    setState(() {
      _isSending = true;
      _messages.add({'sender': 'ai', 'text': 'Thinking...', 'reasoning': ''});
      placeholderIndex = _messages.length - 1;
    });

    _persistChat();
    _scrollChatToBottom();

    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session expired. Please sign in again.'),
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

    final String? systemPrompt = await _resolveSystemPromptForSend();

    try {
      setState(() => _isStreaming = true);

      final Stream<ChatStreamEvent> eventStream =
          WebSocketChatService.sendStreamingChat(
            accessToken: accessToken,
            message: originalUserInput,
            modelId: _selectedModelId,
            providerSlug: _selectedProviderSlug ?? 'openai',
            history: conversationHistory,
            systemPrompt: systemPrompt,
            maxTokens: 4096,
            temperature: 0.7,
          );

      final StringBuffer contentBuffer = StringBuffer();
      final StringBuffer reasoningBuffer = StringBuffer();

      await for (final event in eventStream) {
        switch (event) {
          case ContentEvent(:final text):
            contentBuffer.write(text);
            if (mounted && _isValidMessageIndex(placeholderIndex)) {
              setState(() {
                _messages[placeholderIndex]['text'] = contentBuffer.toString();
              });
              _scrollChatToBottom();
            }
            break;
          case ReasoningEvent(:final text):
            reasoningBuffer.write(text);
            if (mounted && _isValidMessageIndex(placeholderIndex)) {
              setState(() {
                _messages[placeholderIndex]['reasoning'] = reasoningBuffer
                    .toString();
              });
            }
            break;
          case DoneEvent():
            break;
          case ErrorEvent(:final message):
            _finalizeAiMessage(placeholderIndex, 'Error: $message');
            break;
          case UsageEvent():
          case MetaEvent():
            break;
        }
      }

      final String finalContent = contentBuffer.toString().trim();
      if (finalContent.isEmpty) {
        _finalizeAiMessage(placeholderIndex, 'No response received.');
      }
    } catch (e) {
      debugPrint('Streaming error: $e');
      _finalizeAiMessage(placeholderIndex, 'Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isStreaming = false;
          _isSending = false;
        });
      }
      _persistChat();
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
    return SizedBox(
      key: const ValueKey<String>('audio-visualizer'),
      height: 44,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final int barCount = _audioLevels.length;
                if (barCount == 0) {
                  return const SizedBox.shrink();
                }
                final double maxHeight = constraints.maxHeight;

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(barCount, (int index) {
                    final double level = _audioLevels[index];
                    final double clampedLevel = level.clamp(0.0, 1.0);
                    final double barHeight = math.max(
                      4.0,
                      clampedLevel * maxHeight,
                    );
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.2),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 90),
                            height: barHeight,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ),
        ],
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(snackBarMessage)));
    }
    _scrollChatToBottom();
  }

  void _cancelStream() {
    if (_streamSubscription != null && _isStreaming) {
      debugPrint('Cancelling stream...');
      _streamSubscription?.cancel();
      _streamSubscription = null;

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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please wait for the current response to finish.'),
          ),
        );
      }
      return;
    }

    if (_isStreaming) {
      _cancelStream();
      return;
    }

    if (_attachedFiles.any((f) => f.isUploading)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please wait for file uploads to finish.'),
          ),
        );
      }
      return;
    }

    final String originalUserInput = _controller.text.trim();
    final bool hasText = originalUserInput.isNotEmpty;
    final bool hasAttachments = _attachedFiles.any(
      (f) => f.markdownContent != null,
    );

    if (!hasText && !hasAttachments) return;

    final bool firstMessageInChat = _messages.isEmpty;

    String displayMessageText = originalUserInput;
    String aiPromptContent = originalUserInput;

    if (hasAttachments) {
      final attachedFileNames = _attachedFiles
          .where((f) => f.markdownContent != null)
          .map((f) => '"${f.fileName}"')
          .join(', ');
      final String attachmentsLine = 'Uploaded documents: $attachedFileNames';
      if (displayMessageText.isNotEmpty) {
        displayMessageText = '$attachmentsLine\n\n$displayMessageText';
      } else {
        displayMessageText = attachmentsLine;
      }

      final markdownSections = _attachedFiles
          .where((f) => f.markdownContent != null)
          .map(
            (f) => 'Document: "${f.fileName}"\n```\n${f.markdownContent}\n```',
          )
          .join('\n\n');
      final String queryText = originalUserInput.isNotEmpty
          ? originalUserInput
          : 'Please review the uploaded documents.';
      aiPromptContent = '$markdownSections\n\nUser query: $queryText';
    }

    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session expired. Please sign in again.'),
          ),
        );
      }
      await SupabaseService.signOut();
      return;
    }

    final accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to authenticate your session.')),
        );
      }
      return;
    }

    final String? providerSlug = await _ensureProviderSlugForCurrentModel();
    if (providerSlug == null || providerSlug.isEmpty) {
      final String message =
          'No provider is configured for $_selectedModelId. Select a provider in Settings and try again.';
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }

    final List<Map<String, String>> apiHistory =
        _buildApiHistoryWithPendingMessage(displayMessageText);

    final String? resolvedSystemPrompt = await _resolveSystemPromptForSend();
    final String? systemPrompt =
        (resolvedSystemPrompt != null && resolvedSystemPrompt.trim().isNotEmpty)
        ? resolvedSystemPrompt
        : null;

    final ModelProviderLimits? providerLimits =
        ModelSelectionDropdown.providerLimitsForModel(_selectedModelId);

    final int promptTokens = TokenEstimator.estimatePromptTokens(
      history: apiHistory,
      currentMessage: aiPromptContent,
      systemPrompt: systemPrompt,
    );

    int maxResponseTokens = 512;

    if (providerLimits?.contextLength != null &&
        providerLimits!.contextLength! > 0) {
      final int contextLength = providerLimits.contextLength!;
      if (promptTokens >= contextLength) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Too much context for this model '
                '(${promptTokens.toString()} vs ${contextLength.toString()} token limit). '
                'Clear history or shorten your message.',
              ),
            ),
          );
        }
        return;
      }

      final int availableForCompletion = contextLength - promptTokens;
      final int completionCap =
          providerLimits.maxCompletionTokens != null &&
              providerLimits.maxCompletionTokens! > 0
          ? providerLimits.maxCompletionTokens!
          : math.max(256, contextLength ~/ 4);
      maxResponseTokens = math.max(
        1,
        math.min(completionCap, availableForCompletion),
      );

      debugPrint(
        'Prompt tokens (est): $promptTokens / $contextLength, '
        'max completion tokens: $maxResponseTokens',
      );
    } else {
      debugPrint('Prompt tokens (est): $promptTokens (no context limit data)');
    }

    int placeholderIndex = -1;
    setState(() {
      _messages.add({
        'sender': 'user',
        'text': displayMessageText,
        'reasoning': '',
      });
      _controller.clear();
      _isSending = true;
      if (hasAttachments) {
        _attachedFiles.clear();
      }
      _messages.add({'sender': 'ai', 'text': 'Thinking...', 'reasoning': ''});
      placeholderIndex = _messages.length - 1;
    });

    _persistChat();

    if (firstMessageInChat) _animCtrl.forward();
    _scrollChatToBottom();
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

    setState(() {
      _isStreaming = true;
    });

    final StringBuffer contentBuffer = StringBuffer();
    final StringBuffer reasoningBuffer = StringBuffer();

    try {
      final stream = WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: aiPromptContent,
        modelId: _selectedModelId,
        providerSlug: providerSlug,
        history: apiHistory.isEmpty ? null : apiHistory,
        systemPrompt: systemPrompt,
        maxTokens: maxResponseTokens,
      );

      // Start auto-save timer during streaming
      _autoSaveTimer?.cancel();
      _autoSaveTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _persistChat(waitForCompletion: false),
      );

      _streamSubscription = stream.listen(
        (event) {
          // Continue processing even if not mounted - stream runs in background
          final bool canUpdateUI = mounted;

          if (event is ContentEvent) {
            contentBuffer.write(event.text);
            // Always update messages, even if not mounted
            if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
              _messages[placeholderIndex]['text'] = contentBuffer.toString();
              _messages[placeholderIndex]['reasoning'] = reasoningBuffer
                  .toString();
            }
            if (canUpdateUI) {
              _updateAiMessage(
                placeholderIndex,
                contentBuffer.toString(),
                reasoningBuffer.toString(),
              );
              _scrollChatToBottom();
            }
          } else if (event is ReasoningEvent) {
            reasoningBuffer.write(event.text);
            // Always update messages, even if not mounted
            if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
              _messages[placeholderIndex]['text'] = contentBuffer.toString();
              _messages[placeholderIndex]['reasoning'] = reasoningBuffer
                  .toString();
            }
            if (canUpdateUI) {
              _updateAiMessage(
                placeholderIndex,
                contentBuffer.toString(),
                reasoningBuffer.toString(),
              );
            }
          } else if (event is UsageEvent) {
            debugPrint('Usage: ${event.usage}');
          } else if (event is MetaEvent) {
            debugPrint('Meta: ${event.meta}');
          } else if (event is ErrorEvent) {
            debugPrint('Stream error: ${event.message}');
            _finalizeAiMessage(placeholderIndex, 'Error: ${event.message}');
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(event.message)));
            }
          } else if (event is DoneEvent) {
            debugPrint('Stream completed successfully');
            final String finalContent = contentBuffer.toString().trim();
            final String finalReasoning = reasoningBuffer.toString().trim();
            if (finalContent.isEmpty) {
              _finalizeAiMessage(
                placeholderIndex,
                'The model returned an empty response.',
              );
            } else {
              _finalizeAiMessage(
                placeholderIndex,
                finalContent,
                reasoning: finalReasoning,
              );
            }
          }
        },
        onError: (error) {
          debugPrint('Stream error: $error');
          _autoSaveTimer?.cancel();
          if (!mounted) {
            // Save even if not mounted
            _persistChat(waitForCompletion: false);
            return;
          }

          String errorMessage = 'Failed to reach the AI service';
          if (error is WebSocketChatException) {
            errorMessage = error.message;
          }

          _finalizeAiMessage(placeholderIndex, errorMessage);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(errorMessage)));
        },
        onDone: () {
          debugPrint('Stream closed');
          _autoSaveTimer?.cancel();

          if (!mounted) {
            // Finalize and save even if not mounted
            if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
              _messages[placeholderIndex]['text'] = contentBuffer.toString();
              _messages[placeholderIndex]['reasoning'] = reasoningBuffer
                  .toString();
            }
            _persistChat(waitForCompletion: false);
            _isStreaming = false;
            _isSending = false;
            _streamSubscription = null;
            return;
          }

          if (!_isStreaming) {
            _streamSubscription = null;
            return;
          }

          setState(() {
            _isStreaming = false;
            _isSending = false;
          });

          final String finalContent = contentBuffer.toString().trim();
          final String currentText =
              (placeholderIndex >= 0 && placeholderIndex < _messages.length)
              ? (_messages[placeholderIndex]['text'] ?? '')
              : '';

          if (currentText.contains('[Cancelled]') ||
              currentText.contains('[Response cancelled]')) {
            _streamSubscription = null;
            return;
          }

          if (finalContent.isNotEmpty) {
            _finalizeAiMessage(
              placeholderIndex,
              finalContent,
              reasoning: reasoningBuffer.toString().trim(),
            );
          } else if (_messages.isNotEmpty &&
              placeholderIndex < _messages.length &&
              (_messages[placeholderIndex]['text'] ?? '').trim().isEmpty) {
            _finalizeAiMessage(
              placeholderIndex,
              'No response received from the model.',
            );
          }

          _streamSubscription = null;
        },
        cancelOnError: true,
      );
    } catch (error) {
      debugPrint('Failed to start stream: $error');
      _finalizeAiMessage(placeholderIndex, 'Failed to start streaming: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start streaming: $error')),
        );
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

  void _finalizeAiMessage(int index, String content, {String? reasoning}) {
    _autoSaveTimer?.cancel();
    if (index < 0 || index >= _messages.length) {
      _streamSubscription?.cancel();
      _streamSubscription = null;
      _isSending = false;
      _isStreaming = false;
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
    } else {
      final Map<String, String> message = Map<String, String>.from(
        _messages[index],
      );
      message['text'] = content;
      message['reasoning'] = reasoning ?? '';
      _messages[index] = message;
      _isSending = false;
      _isStreaming = false;
    }

    _streamSubscription?.cancel();
    _streamSubscription = null;

    if (mounted) {
      _scrollChatToBottom();
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      _persistChat();
    }
  }

  Future<void> _uploadFiles() async {
    const int maxFileSize = 10 * 1024 * 1024; // 10MB
    const int maxConcurrentUploads = 5;

    if (_attachedFiles.where((f) => f.isUploading).length >=
        maxConcurrentUploads) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please wait for current uploads to complete'),
          ),
        );
      }
      return;
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileConstants.allowedExtensions,
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      List<PlatformFile> selectedPlatformFiles = result.files;

      for (PlatformFile platformFile in selectedPlatformFiles) {
        if (platformFile.path == null) continue;

        // Check file size
        if (platformFile.size > maxFileSize) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('File "${platformFile.name}" exceeds 10MB limit'),
              ),
            );
          }
          continue; // Skip this file and go to the next
        }

        File file = File(platformFile.path!);
        String fileName = platformFile.name;
        String fileExtension = fileName.split('.').last.toLowerCase();
        String fileId = _uuid.v4();

        if (!FileConstants.allowedExtensions.contains(fileExtension)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Unsupported file type for "$fileName": .$fileExtension',
                ),
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
                ),
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
                ),
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
              fileSizeBytes: platformFile.size,
            ),
          );
        });
        _scrollChatToBottom(); // Scroll to ensure attachment bar is visible

        _chatApiService.performFileUpload(
          file,
          fileName,
          fileId,
        ); // Use the service
      }
    } else {
      debugPrint('File picking canceled.');
    }
  }

  void _removeAttachedFile(String fileId) {
    setState(() {
      _attachedFiles.removeWhere((f) => f.id == fileId);
    });
    _scrollChatToBottom();
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
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

  Future<void> _persistChatInternal(
    List<Map<String, String>> messagesCopy,
    String? chatId,
  ) async {
    try {
      final stored = chatId == null
          ? await ChatStorageService.saveChat(messagesCopy)
          : await ChatStorageService.updateChat(chatId, messagesCopy);
      if (!mounted || stored == null) return;
      setState(() {
        _activeChatId = stored.id;
      });
      final index = ChatStorageService.savedChats.indexWhere(
        (chat) => chat.id == stored.id,
      );
      if (index != -1) {
        ChatStorageService.selectedChatIndex = index;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to store chat: $error')));
    }
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
      return _MessageRenderData(
        sender: sender,
        displayText: displayText,
        reasoning: reasoning,
        // Show loading icon if: streaming AND (has reasoning OR might get reasoning)
        isReasoningStreaming:
            isStreamingMessage && (hasReasoning || displayText.isNotEmpty),
      );
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (!isChatEmpty)
            Positioned(
              top: 0,
              bottom: inputAreaTotalHeight,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _anim,
                child: Padding(
                  padding: EdgeInsets.zero,
                  child: Align(
                    alignment: Alignment.center,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: expandedInputWidth),
                      child: Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        thickness: 8.0,
                        radius: const Radius.circular(4),
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.symmetric(
                            horizontal: effectiveHorizontalPadding,
                            vertical: 10,
                          ),
                          itemCount: renderMessages.length,
                          addAutomaticKeepAlives: false,
                          addRepaintBoundaries: true,
                          cacheExtent: 500.0,
                          itemBuilder: (_, int i) {
                            final _MessageRenderData data = renderMessages[i];
                            final String? reasoningText =
                                data.reasoning.trim().isEmpty
                                ? null
                                : data.reasoning;
                            final bool isBeingEdited =
                                _editingMessageIndex == i;
                            return RepaintBoundary(
                              child: MessageBubble(
                                key: ValueKey('msg_$i'),
                                message: data.displayText,
                                reasoning: reasoningText,
                                isUser: data.isUser,
                                maxWidth: expandedInputWidth * 0.7,
                                isReasoningStreaming: data.isReasoningStreaming,
                                actions: _buildMessageActionsForIndex(i, data),
                                isEditing: isBeingEdited,
                                initialEditText: isBeingEdited
                                    ? data.displayText
                                    : null,
                                onSubmitEdit: isBeingEdited && data.isUser
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
                  ),
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
                width: targetInputWidth, // Dynamically changes width
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
                    _buildSearchBar(isCompactMode: widget.isCompactMode),
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
      ),
    );
  }

  // NEW: Extracted Attachment Bar Widget
  Widget _buildSearchBar({required bool isCompactMode}) {
    const btnH = 36.0, btnW = 44.0;
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: iconFg.withValues(alpha: 0.3)),
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
              // Send/Cancel Message Button
              GestureDetector(
                onTap: () => _sendMessage(),
                child: Container(
                  width: btnW,
                  height: btnH,
                  decoration: BoxDecoration(
                    color: _isStreaming ? Colors.red : accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _isStreaming ? Icons.stop : Icons.arrow_upward,
                    color: Colors.black,
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
                            const SizedBox(width: 8),
                            // Image Button
                            _buildIconBtn(
                              icon: Icons.image,
                              onTap: () {
                                setState(
                                  () => _isImageActive = !_isImageActive,
                                );
                                debugPrint(
                                  'Image button toggled: $_isImageActive',
                                );
                              },
                              isActive: _isImageActive,
                              debugLabel: 'Image button',
                            ),
                            // Spacer to push the dropdown to the right edge while
                            // still letting it grow with longer model names.
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: ModelSelectionDropdown(
                                  initialSelectedModelId: _selectedModelId,
                                  onModelSelected: (newModelId) {
                                    setState(() {
                                      _selectedModelId = newModelId;
                                    });
                                    debugPrint(
                                      'Selected model ID: $_selectedModelId',
                                    );
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
                icon: _isMicActive ? Icons.stop : Icons.mic,
                onTap: _handleMicTap,
                isActive: _isMicActive,
                debugLabel: 'Mic button',
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _isMicActive
                    ? GestureDetector(
                        key: const ValueKey<String>('audio-send-button'),
                        onTap: _handleAudioSend,
                        child: Container(
                          width: 44,
                          height: 36,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.send, color: Colors.black),
                        ),
                      )
                    : GestureDetector(
                        key: const ValueKey<String>('voice-mode-button'),
                        onTap: () => _openComingSoonFeature('Voice Mode'),
                        child: Container(
                          width: 44,
                          height: 36,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.graphic_eq,
                            color: Colors.black,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIconBtn({
    required IconData icon,
    required VoidCallback onTap,
    required bool isActive,
    String? debugLabel,
  }) {
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFg = Theme.of(context).resolvedIconColor;

    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
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
                ? 1.2
                : isActive
                ? 1.0
                : 0.8;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              width: 44,
              height: 36,
              decoration: BoxDecoration(
                color: effectiveBgColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: effectiveBorderColor,
                  width: effectiveBorderWidth,
                ),
              ),
              child: Icon(icon, color: effectiveIconColor, size: 20),
            );
          },
        ),
      ),
    );
  }
}
