// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW API SERVICE
import 'package:chuk_chat/services/streaming_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/token_estimator.dart';

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
  StreamSubscription<ChatStreamEvent>? _streamSubscription;
  bool _isStreaming = false;
  final StreamingManager _streamingManager = StreamingManager();
  int? _editingMessageIndex;

  static const int _kMaxFileSizeBytes = 10 * 1024 * 1024; // 10MB
  static const int _kMaxConcurrentUploads = 5;
  static const List<String> _kAllowedExtensions = [
    // Audio (with transcription)
    'wav',
    'mp3',
    'm4a',
    'aac',
    'flac',
    'ogg',
    // Video
    'mp4',
    // Documents (PDF, Word, PowerPoint, Excel, OpenDocument)
    'pdf',
    'doc',
    'docx',
    'ppt',
    'pptx',
    'xls',
    'xlsx',
    'odt',
    'ods',
    'odp',
    'odg',
    'odf',
    // Text (CSV, JSON, XML, HTML, Markdown)
    'csv',
    'json',
    'jsonl',
    'xml',
    'html',
    'htm',
    'md',
    'markdown',
    'txt',
    'text',
    // Images (PNG, JPEG, GIF, BMP, TIFF, WebP with EXIF and OCR)
    'png',
    'jpg',
    'jpeg',
    'gif',
    'bmp',
    'tiff',
    'tif',
    'webp',
    'heic',
    'heif',
    // Archives (ZIP)
    'zip',
    // E-books (EPUB)
    'epub',
    // Email (MSG, EML)
    'msg',
    'eml',
    // Code and other formats
    'py',
    'js',
    'ts',
    'jsx',
    'tsx',
    'java',
    'c',
    'cpp',
    'h',
    'hpp',
    'go',
    'rs',
    'rb',
    'php',
    'swift',
    'kt',
    'cs',
    'sh',
    'bash',
    'yaml',
    'yml',
    'toml',
    'ini',
    'cfg',
    'conf',
    'sql',
    'prisma',
    'graphql',
    'proto',
    'css',
    'scss',
    'sass',
    'less',
    'vue',
    'svelte',
    'ipynb',
    'rss',
    'atom',
  ];
  static const Set<String> _kImageExtensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'gif',
    'bmp',
    'tiff',
    'tif',
    'webp',
    'heic',
    'heif',
  };

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
  }

  void _handleAddAttachmentTap() {
    if (!mounted) return;
    final theme = Theme.of(context);
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
                const SizedBox(height: 20),
                Row(
                  children: [
                    _buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.photo_camera_outlined,
                      label: 'Camera',
                      onTap: () {
                        if (!_ensureImageUploadsSupported()) return;
                        Navigator.of(sheetContext).pop();
                        unawaited(_pickImageFromSource(ImageSource.camera));
                      },
                    ),
                    const SizedBox(width: 12),
                    _buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.photo_library_outlined,
                      label: 'Photos',
                      onTap: () {
                        if (!_ensureImageUploadsSupported()) return;
                        Navigator.of(sheetContext).pop();
                        unawaited(_pickImagesFromGallery());
                      },
                    ),
                    const SizedBox(width: 12),
                    _buildAttachmentSheetOption(
                      context: sheetContext,
                      icon: Icons.attach_file,
                      label: 'Files',
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

    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null) {
      await _deleteRecordingFile(audioPath);
      _lastRecordedFilePath = null;
      _showSnackBar('Session expired');
      await SupabaseService.signOut();
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
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
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

    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null) {
      _finalizeAiMessage(
        placeholderIndex,
        'Please sign in to continue the conversation.',
      );
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

    try {
      setState(() => _isStreaming = true);

      final Stream<ChatStreamEvent> eventStream =
          StreamingChatService.sendStreamingChat(
            accessToken: accessToken,
            message: originalUserInput,
            modelId: _selectedModelId,
            providerSlug: _selectedProviderSlug ?? 'openai',
            history: conversationHistory,
            systemPrompt: _systemPrompt,
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
    _streamSubscription?.cancel();
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
    setState(() {
      _isMicActive = false;
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
    return _kImageExtensions.contains(extension);
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
      _showSnackBar('Please wait');
      return;
    }

    if (_isStreaming) {
      _cancelStream();
      return;
    }

    if (_attachedFiles.any((f) => f.isUploading)) {
      _showSnackBar('Upload in progress');
      return;
    }

    final String originalUserInput = _controller.text.trim();
    final bool hasText = originalUserInput.isNotEmpty;
    final bool hasAttachments = _attachedFiles.any(
      (f) => f.markdownContent != null,
    );

    if (!hasText && !hasAttachments) return;

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
      _showSnackBar('Session expired. Please sign in again.');
      await SupabaseService.signOut();
      return;
    }

    final String accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      _showSnackBar('Unable to authenticate your session.');
      return;
    }

    final String? providerSlug = await _ensureProviderSlugForCurrentModel();
    if (providerSlug == null || providerSlug.isEmpty) {
      final String message =
          'No provider is configured for $_selectedModelId. Select a provider in Settings and try again.';
      _showSnackBar(message);
      return;
    }

    final List<Map<String, String>> apiHistory =
        _buildApiHistoryWithPendingMessage(displayMessageText);
    final String? effectiveSystemPrompt =
        (_systemPrompt != null && _systemPrompt!.trim().isNotEmpty)
        ? _systemPrompt
        : null;

    final ModelProviderLimits? providerLimits =
        ModelSelectionDropdown.providerLimitsForModel(_selectedModelId);

    final int promptTokens = TokenEstimator.estimatePromptTokens(
      history: apiHistory,
      currentMessage: aiPromptContent,
      systemPrompt: effectiveSystemPrompt,
    );

    int maxResponseTokens = 512;

    if (providerLimits?.contextLength != null &&
        providerLimits!.contextLength! > 0) {
      final int contextLength = providerLimits.contextLength!;
      if (promptTokens >= contextLength) {
        _showSnackBar(
          'Too much context for this model '
          '(${promptTokens.toString()} vs ${contextLength.toString()} token limit). '
          'Clear history or shorten your message.',
        );
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

    setState(() {
      _isStreaming = true;
    });

    final StringBuffer contentBuffer = StringBuffer();
    final StringBuffer reasoningBuffer = StringBuffer();

    try {
      final stream = StreamingChatService.sendStreamingChat(
        accessToken: accessToken,
        message: aiPromptContent,
        modelId: _selectedModelId,
        providerSlug: providerSlug,
        history: apiHistory.isEmpty ? null : apiHistory,
        systemPrompt: effectiveSystemPrompt,
        maxTokens: maxResponseTokens,
      );

      _streamSubscription = stream.listen(
        (event) {
          if (!mounted) return;

          if (event is ContentEvent) {
            contentBuffer.write(event.text);
            _updateAiMessage(
              placeholderIndex,
              contentBuffer.toString(),
              reasoningBuffer.toString(),
            );
            _scrollChatToBottom();
          } else if (event is ReasoningEvent) {
            reasoningBuffer.write(event.text);
            _updateAiMessage(
              placeholderIndex,
              contentBuffer.toString(),
              reasoningBuffer.toString(),
            );
          } else if (event is UsageEvent) {
            debugPrint('Usage: ${event.usage}');
          } else if (event is MetaEvent) {
            debugPrint('Meta: ${event.meta}');
          } else if (event is ErrorEvent) {
            debugPrint('Stream error: ${event.message}');
            _finalizeAiMessage(placeholderIndex, 'Error: ${event.message}');
            _showSnackBar(event.message);
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
          if (!mounted) return;

          String errorMessage = 'Failed to reach the AI service';
          if (error is StreamingChatException) {
            errorMessage = error.message;
          }

          _finalizeAiMessage(placeholderIndex, errorMessage);
          _showSnackBar(errorMessage);
        },
        onDone: () {
          debugPrint('Stream closed');
          if (!mounted) return;

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
      _showSnackBar('Failed to start streaming: $error');
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
    if (_attachedFiles.where((f) => f.isUploading).length >=
        _kMaxConcurrentUploads) {
      _showAttachmentError('Please wait for current uploads to complete');
      return;
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _kAllowedExtensions,
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

    if (fileSizeBytes > _kMaxFileSizeBytes) {
      _showAttachmentError('File "$fileName" exceeds 10MB limit');
      return;
    }

    if (extension.isEmpty || !_kAllowedExtensions.contains(extension)) {
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
        _kMaxConcurrentUploads) {
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
  }) {
    final theme = Theme.of(context);
    final Color background = theme.colorScheme.surfaceContainerHighest
        .withValues(alpha: 0.6);
    final Color borderColor = theme.dividerColor.withValues(alpha: 0.2);
    final Color foreground = theme.colorScheme.onSurface;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
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

      // Only update selectedChatIndex if this is still the active chat
      // (prevents overwriting when user switches to a different chat)
      if (_activeChatId == stored.id) {
        setState(() {
          _activeChatId = stored.id;
        });
        final index = ChatStorageService.savedChats.indexWhere(
          (chat) => chat.id == stored.id,
        );
        if (index != -1) {
          ChatStorageService.selectedChatIndex = index;
        }
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to store chat: $error')));
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
        // Attachment button (disabled if model doesn't support images)
        _buildTinyIconBtn(
          icon: Icons.add_rounded,
          onTap: _modelSupportsImageInput ? _handleAddAttachmentTap : null,
          isActive: hasAttachments,
          color: _modelSupportsImageInput ? iconFg : iconFg.withValues(alpha: 0.3),
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
