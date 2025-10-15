// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW API SERVICE

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';


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

class ChukChatUIMobileState extends State<ChukChatUIMobile>
    with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  String? _activeChatId;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();
  final Uuid _uuid = Uuid();
  final ImagePicker _imagePicker = ImagePicker();

  late ChatApiService _chatApiService;
  final List<AttachedFile> _attachedFiles = [];
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1'; // Default model
  late final VoidCallback _modelSelectionListener;

  late AnimationController _animCtrl;
  late Animation<double> _anim;

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

  static const int _kMaxFileSizeBytes = 10 * 1024 * 1024; // 10MB
  static const int _kMaxConcurrentUploads = 5;
  static const List<String> _kAllowedExtensions = [
    'wav',
    'mp3',
    'm4a',
    'mp4',
    'html',
    'htm',
    'csv',
    'docx',
    'pptx',
    'xlsx',
    'pdf',
    'jpg',
    'jpeg',
    'png',
    'bmp',
    'tiff',
    'epub',
    'ipynb',
    'msg',
    'txt',
    'text',
    'md',
    'markdown',
    'json',
    'jsonl',
    'rss',
    'atom',
    'xml',
    'xls',
    'zip',
    'heic',
    'heif',
  ];

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kSearchBarContentHeight = 135.0;
  static const double _kAttachmentBarHeight = 40.0;
  static const double _kAttachmentBarMarginBottom = 8.0;
  static const double _kHorizontalPaddingSmall =
      8.0; // Always use small padding for phones
  static const String _apiBaseUrl = 'http://127.0.0.1:8000';

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _chatApiService = ChatApiService(
      onUploadStatusUpdate: _handleFileUploadUpdate,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    });
    _loadChatFromIndex(widget.selectedChatIndex);
    _modelSelectionListener = () {
      final String newModelId =
          ModelSelectionDropdown.selectedModelNotifier.value;
      if (newModelId != _selectedModelId) {
        setState(() {
          _selectedModelId = newModelId;
        });
      }
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
    if (!_isMicActive) {
      return;
    }
    await _stopMicRecording(keepFile: true);
    if (!mounted) return;
    setState(() {
      _isMicActive = false;
      _resetAudioLevels();
    });
    debugPrint('Audio message ready (path: $_lastRecordedFilePath)');
    _showSnackBar('Audio message ready — API integration coming soon.');
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
          const SizedBox(width: 12),
          Text(
            'Recording...',
            style: TextStyle(
              color: iconFg.withValues(alpha: 0.8),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImageFromSource(ImageSource source) async {
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
      _loadChatFromIndex(widget.selectedChatIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
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
                (message) => {'sender': message.sender, 'text': message.text},
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
    });
    _scrollChatToBottom();
    _textFieldFocusNode.requestFocus();
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
    });
    _scrollChatToBottom();
    _textFieldFocusNode.requestFocus();
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

  String? _providerNameForModel(String modelId) {
    final parts = modelId.split('/');
    if (parts.length >= 3 && parts.first == 'openrouter') {
      final providerSlug = parts[1].toLowerCase();
      const knownProviders = <String, String>{
        'anthropic': 'Anthropic',
        'openai': 'OpenAI',
        'google': 'Google',
        'meta': 'Meta',
        'mistralai': 'Mistral',
        'perplexity': 'Perplexity',
        'x-ai': 'x.ai',
        'cohere': 'Cohere',
        'deepseek': 'DeepSeek',
        'moonshot': 'Moonshot',
      };
      return knownProviders[providerSlug] ?? parts[1];
    }
    return null;
  }

  String _errorMessageFromResponse(
    Map<String, dynamic>? decodedBody,
    String fallback,
  ) {
    if (decodedBody == null || decodedBody.isEmpty) return fallback;
    final dynamic detail = decodedBody['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    if (detail is List && detail.isNotEmpty) {
      final first = detail.first;
      if (first is Map<String, dynamic>) {
        final dynamic msg = first['msg'];
        if (msg is String && msg.isNotEmpty) return msg;
      } else if (first is String && first.isNotEmpty) {
        return first;
      }
    }
    final dynamic message = decodedBody['message'];
    if (message is String && message.isNotEmpty) return message;
    return fallback;
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

  void _sendMessage() async {
    if (_isSending) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please wait for the current response to finish.'),
          ),
        );
      }
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

    setState(() {
      _messages.add({'sender': 'user', 'text': displayMessageText});
      _controller.clear();
      _isSending = true;
      if (hasAttachments) {
        _attachedFiles.clear();
      }
    });
    _textFieldFocusNode.requestFocus();

    _persistChat();

    if (firstMessageInChat) _animCtrl.forward();
    _scrollChatToBottom();

    int placeholderIndex = -1;
    setState(() {
      _messages.add({'sender': 'ai', 'text': 'Thinking...'});
      placeholderIndex = _messages.length - 1;
    });
    _scrollChatToBottom();

    bool responseHandled = false;
    void finalizeAiMessage(String text) {
      responseHandled = true;
      if (!mounted) {
        return;
      }
      setState(() {
        if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
          _messages[placeholderIndex] = {'sender': 'ai', 'text': text};
        } else {
          debugPrint('AI response arrived after chat reset, dropping message.');
        }
        _isSending = false;
      });
      _scrollChatToBottom();
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      _persistChat();
    }

    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    if (session == null) {
      _isSending = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Session expired. Please sign in again.'),
          ),
        );
      }
      await SupabaseService.signOut();
      finalizeAiMessage('Please sign in to continue the conversation.');
      return;
    }
    final accessToken = session.accessToken;
    if (accessToken.isEmpty) {
      _isSending = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to authenticate your session.')),
        );
      }
      finalizeAiMessage('Authentication required. Please sign in again.');
      return;
    }

    try {
      final requestPayload = <String, dynamic>{
        'model': _selectedModelId,
        'prompt': aiPromptContent,
        'max_tokens': 512,
        'temperature': 0.7,
        'metadata': {'source': 'flutter-chat-ui'},
      };
      final String? providerName = _providerNameForModel(_selectedModelId);
      if (providerName != null) {
        requestPayload['provider'] = providerName;
      }

      final response = await http
          .post(
            Uri.parse('$_apiBaseUrl/relay_completion'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(requestPayload),
          )
          .timeout(const Duration(seconds: 60));

      Map<String, dynamic>? decodedBody;
      if (response.body.isNotEmpty) {
        try {
          final dynamic parsed = jsonDecode(response.body);
          if (parsed is Map<String, dynamic>) {
            decodedBody = parsed;
          }
        } catch (error) {
          debugPrint('Failed to parse relay response: $error');
        }
      }

      if (response.statusCode == 200) {
        final data = decodedBody ?? <String, dynamic>{};
        if (data['insufficient_credits'] == true) {
          final String message =
              data['message'] as String? ??
              'Insufficient balance. Please top up your credits.';
          finalizeAiMessage(message);
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
          }
          return;
        }

        final String? content = data['content'] as String?;
        if (content != null && content.isNotEmpty) {
          finalizeAiMessage(content);
          final dynamic remainingCredits = data['remaining_credits'];
          if (remainingCredits != null) {
            debugPrint('Remaining credits: $remainingCredits');
          }
          return;
        }

        finalizeAiMessage('The model returned an empty response.');
        return;
      }

      if (response.statusCode == 401) {
        await SupabaseService.signOut();
        finalizeAiMessage('Your session expired. Please sign in again.');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session expired. Please sign in again.'),
            ),
          );
        }
        return;
      }

      if (response.statusCode == 402) {
        final String message =
            decodedBody?['message'] as String? ??
            'Insufficient credits. Please top up your credits.';
        finalizeAiMessage(message);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        return;
      }

      if (response.statusCode == 429) {
        finalizeAiMessage(
          'You have been rate limited. Please wait a moment and try again.',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('You are sending requests too quickly.'),
            ),
          );
        }
        return;
      }

      final String fallbackMessage =
          'Request failed with status ${response.statusCode}.';
      final String detailedMessage = _errorMessageFromResponse(
        decodedBody,
        fallbackMessage,
      );
      debugPrint(
        'Relay error body (status ${response.statusCode}): '
        '${jsonEncode(decodedBody ?? {})}',
      );
      finalizeAiMessage(detailedMessage);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(detailedMessage)));
      }
    } on TimeoutException {
      finalizeAiMessage('Request timed out. Please try again.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request timed out. Please try again.')),
        );
      }
    } on SocketException {
      finalizeAiMessage('Network error. Check your internet connection.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Network error while contacting the AI.'),
          ),
        );
      }
    } catch (error) {
      finalizeAiMessage('Failed to reach the AI service: $error');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unexpected error: $error')));
      }
    } finally {
      if (!responseHandled) {
        finalizeAiMessage('Something went wrong. Please try again.');
      }
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
    const bool isCompactModeForModelDropdown =
        true; // Mobile shows a hashtag-only trigger for model menu.

    final double screenWidth = MediaQuery.of(context).size.width;
    final Color iconFg = Theme.of(context).iconTheme.color!;

    final double effectiveHorizontalPadding = _kHorizontalPaddingSmall;
    final double maxPossibleChatContentWidth = math.max(
      0.0,
      screenWidth - (effectiveHorizontalPadding * 2),
    );
    final double constrainedChatContentWidth = math.min(
      _kMaxChatContentWidth,
      maxPossibleChatContentWidth,
    );

    final double expandedInputWidth = constrainedChatContentWidth;

    double inputAreaVisualHeight = _kSearchBarContentHeight;
    if (_attachedFiles.isNotEmpty) {
      inputAreaVisualHeight +=
          _kAttachmentBarHeight + _kAttachmentBarMarginBottom;
    }
    double inputAreaTotalHeight =
        inputAreaVisualHeight + (2 * effectiveHorizontalPadding);

    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    final double targetInputWidth = expandedInputWidth;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned(
            top: 0,
            bottom: inputAreaTotalHeight + keyboardHeight,
            left: 0,
            right: 0,
            child: FadeTransition(
              opacity: _anim,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  constraints: BoxConstraints(maxWidth: expandedInputWidth),
                  child: _messages.isEmpty
                      ? Center(
                          child: Text(
                            'Start a new chat!',
                            style: TextStyle(
                              color: iconFg.withValues(alpha: 0.6),
                              fontSize: 18,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.symmetric(
                            horizontal: effectiveHorizontalPadding,
                            vertical: 10,
                          ),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) {
                            final m = _messages[i];
                            return MessageBubble(
                              message: m['text']!,
                              isUser: m['sender'] == 'user',
                              maxWidth: expandedInputWidth * 0.7,
                            );
                          },
                        ),
                ),
              ),
            ),
          ),

          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            bottom: effectiveHorizontalPadding + keyboardHeight,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                width: targetInputWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_attachedFiles.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: _kAttachmentBarMarginBottom,
                        ),
                        child: SizedBox(
                          width: targetInputWidth,
                          child: AttachmentPreviewBar(
                            files: _attachedFiles,
                            onRemove: _removeAttachedFile,
                          ),
                        ),
                      ),
                    _buildSearchBar(
                      isCompactMode: isCompactModeForModelDropdown,
                    ), // Pass the local variable
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

  Widget _buildSearchBar({required bool isCompactMode}) {
    const btnH = 36.0, btnW = 44.0;
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;

    final bool hasAttachments = _attachedFiles.isNotEmpty;

    return Container(
      width: double.infinity,
      height: _kSearchBarContentHeight,
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

                    _sendMessage();
                  },
                  child: TextField(
                    controller: _controller,
                    focusNode: _textFieldFocusNode,
                    autofocus: false,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.send,
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
              const SizedBox(width: 8),
              // Send Message Button
              GestureDetector(
                onTap: _sendMessage,
                child: Container(
                  width: btnW,
                  height: btnH,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.arrow_upward, color: Colors.black),
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
                              onTap: _handleAddAttachmentTap,
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
                            const Spacer(),
                            // Model Selection Dropdown
                            ModelSelectionDropdown(
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
                              compactLabel: '#',
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
    final Color iconFg = Theme.of(context).iconTheme.color!;

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
