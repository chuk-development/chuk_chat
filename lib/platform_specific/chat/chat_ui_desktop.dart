// lib/platform_specific/chat/chat_ui_desktop.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math; // For min/max
import 'dart:async';
import 'dart:convert';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/message_composition_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart'
    show MessageBubble, MessageBubbleAction, DocumentAttachment;
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/image_generation_service.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/widgets/project_panel.dart';

import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:desktop_drop/desktop_drop.dart';

class _MessageRenderData {
  const _MessageRenderData({
    required this.sender,
    required this.displayText,
    required this.reasoning,
    required this.isReasoningStreaming,
    this.modelLabel,
    this.images,
    this.attachments,
  });

  final String sender;
  final String displayText;
  final String reasoning;
  final bool isReasoningStreaming;
  final String? modelLabel;
  final List<String>? images;
  final List<DocumentAttachment>? attachments;

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
  final String? projectId;
  final VoidCallback? onExitProject;
  // Image generation settings
  final bool imageGenEnabled;
  final String imageGenDefaultSize;
  final int imageGenCustomWidth;
  final int imageGenCustomHeight;
  final bool imageGenUseCustomSize;

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
    this.projectId,
    this.onExitProject,
    this.imageGenEnabled = false,
    this.imageGenDefaultSize = 'landscape_4_3',
    this.imageGenCustomWidth = 1024,
    this.imageGenCustomHeight = 768,
    this.imageGenUseCustomSize = false,
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
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1';
  String? _selectedProviderSlug;
  String? _systemPrompt;
  late final VoidCallback _modelSelectionListener;

  bool _isImageActive = false;
  bool _isImageGenMode = false; // Image generation mode toggle
  bool _isGeneratingImage = false; // Loading state for image generation
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
  bool _isLoadingChat = false; // Loading indicator for chat switching
  StreamSubscription<void>? _providerRefreshSubscription;
  final StreamingManager _streamingManager = StreamingManager();

  // Computed property - checks if CURRENT chat is streaming
  bool get _isStreaming => _activeChatId != null && _streamingManager.isStreaming(_activeChatId!);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    });
    _loadChatById(widget.selectedChatId);
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
    // ID-BASED: Only react when the actual chat ID changes
    if (widget.selectedChatId != oldWidget.selectedChatId) {
      debugPrint('');
      debugPrint('┌─────────────────────────────────────────────────────────────');
      debugPrint('│ 🔄 [CHAT-UI-DESKTOP] didUpdateWidget triggered');
      debugPrint('│ 🔄 [CHAT-UI-DESKTOP] OLD widget.selectedChatId: ${oldWidget.selectedChatId}');
      debugPrint('│ 🔄 [CHAT-UI-DESKTOP] NEW widget.selectedChatId: ${widget.selectedChatId}');
      debugPrint('│ 🔄 [CHAT-UI-DESKTOP] _activeChatId: $_activeChatId');
      debugPrint('└─────────────────────────────────────────────────────────────');

      // Skip if we're already on this chat
      if (widget.selectedChatId == _activeChatId) {
        debugPrint('⚠️ [CHAT-UI-DESKTOP] SKIP - already on this chat');
        return;
      }

      // CRITICAL FIX: Don't clear an active chat just because parent sent null
      // This can happen due to stale parent rebuilds. If we have an active chat
      // with messages, keep it instead of switching to a blank "new" chat.
      if (widget.selectedChatId == null && _activeChatId != null && _messages.isNotEmpty) {
        debugPrint('⚠️ [CHAT-UI-DESKTOP] IGNORING null from parent - we have active chat: $_activeChatId');
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
      debugPrint('│ 📝 [CHAT-UI-DESKTOP] Chat switch - NOT persisting (already saved on message ops)');

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
    debugPrint('');
    debugPrint('┌─────────────────────────────────────────────────────────────');
    debugPrint('│ 📂 [LOAD-CHAT-DESKTOP] _loadChatById called');
    debugPrint('│ 📂 [LOAD-CHAT-DESKTOP] chatId param: $chatId');
    debugPrint('│ 📂 [LOAD-CHAT-DESKTOP] Current _activeChatId: $_activeChatId');
    debugPrint('└─────────────────────────────────────────────────────────────');

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

    // Use microtask to allow UI to update with loading indicator first
    Future.microtask(() {
      if (!mounted) return;

      // CRITICAL: Check for stale load - if user switched to another chat
      // while waiting in the microtask queue, abort this load
      if (_activeChatId != chatId) {
        debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Stale load detected, aborting');
        debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Expected: $chatId, Current: $_activeChatId');
        // Note: Don't clear isLoadingChat here - the newer load operation owns it
        return;
      }

      if (chatId == null) {
        // New chat - clear everything
        debugPrint('│ 📂 [LOAD-CHAT-DESKTOP] chatId is NULL - clearing for new chat');
        _messages.clear();
        _animCtrl.reset();
        _attachedFiles.clear();
        // _activeChatId already set to null synchronously above
      } else {
        // Find chat by ID
        final storedChat = ChatStorageService.savedChats.cast<StoredChat?>().firstWhere(
          (chat) => chat?.id == chatId,
          orElse: () => null,
        );

        if (storedChat != null) {
          debugPrint('│ 📂 [LOAD-CHAT-DESKTOP] FOUND chat $chatId with ${storedChat.messages.length} messages');
          // _activeChatId already set synchronously above

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
                return map;
              }),
            );
          // Instant visibility
          _animCtrl.value = 1.0;
        } else {
          // Chat not found - treat as new chat
          debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Chat $chatId NOT FOUND!');
          debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Available chats: ${ChatStorageService.savedChats.map((c) => c.id).take(5).toList()}...');
          debugPrint('│ ⚠️ [LOAD-CHAT-DESKTOP] Treating as new chat, setting _activeChatId = null');
          _messages.clear();
          _animCtrl.reset();
          _attachedFiles.clear();
          _activeChatId = null;
        }
      }

      if (!mounted) return;


      // If this chat is streaming, restore buffered content from StreamingManager
      if (_activeChatId != null && _streamingManager.isStreaming(_activeChatId!)) {
        final bufferedContent = _streamingManager.getBufferedContent(_activeChatId!);
        final bufferedReasoning = _streamingManager.getBufferedReasoning(_activeChatId!);
        final streamingIndex = _streamingManager.getStreamingMessageIndex(_activeChatId!);

        if (streamingIndex != null && streamingIndex < _messages.length) {
          _messages[streamingIndex]['text'] = bufferedContent ?? 'Thinking...';
          _messages[streamingIndex]['reasoning'] = bufferedReasoning ?? '';
        }
      }

      // CRITICAL: Clear global loading lock - chat is now fully loaded
      ChatStorageService.isLoadingChat = false;

      setState(() {
        _isLoadingChat = false;
        _isImageActive = false;
        _isMicActive = false;
        _isSending = _isStreaming; // Reset sending state based on current chat
        _resetAudioLevels();
      });
      _scrollChatToBottom(animate: false, force: true);
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    });
  }

  void newChat() {
    // Capture current chat data for background persistence
    final chatIdToSave = _activeChatId;
    final messagesToSave = _messages.isNotEmpty
        ? _messages.map((m) => Map<String, dynamic>.from(m)).toList()
        : null;

    // Clear UI immediately for instant response
    setState(() {
      _messages.clear();
      _animCtrl.reset();
      _activeChatId = null;
      _isImageActive = false;
      _isMicActive = false;
      _isSending = false; // Reset for new chat
      _attachedFiles.clear();
      _resetAudioLevels();
    });

    // Notify parent that we're now on a new chat (null ID)
    widget.onChatIdChanged(null);
    _scrollChatToBottom(force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

    // Persist old chat and refresh sidebar in background (don't await)
    // CRITICAL: Use silent=true to prevent _persistChatInternal from changing
    // _activeChatId or calling widget.onChatIdChanged - we're now on a NEW chat!
    if (messagesToSave != null && chatIdToSave != null) {
      unawaited(_persistChatInternal(messagesToSave, chatIdToSave, silent: true).then((_) {
        // Refresh sidebar after persist completes
        unawaited(ChatStorageService.loadSavedChatsForSidebar());
      }));
    } else {
      // No chat to save, just refresh sidebar
      unawaited(ChatStorageService.loadSavedChatsForSidebar());
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

    // Preserve the original model and provider from the user message being resent
    final String? originalModelId = _messages[index]['modelId'];
    final String? originalProvider = _messages[index]['provider'];

    // Use original model/provider if available, otherwise use currently selected
    final String modelIdToUse = originalModelId ?? _selectedModelId;
    final String? providerToUse = originalProvider ?? _selectedProviderSlug;

    // Reconstruct images from stored JSON for resend
    List<String>? imagesForResend;
    final String? imagesJson = _messages[index]['images'];
    if (imagesJson != null && imagesJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(imagesJson);
        if (decoded is List) {
          final storedImages = decoded.cast<String>();
          debugPrint('🔄 [ResendDebug] Found ${storedImages.length} images for resend');

          // Convert encrypted storage paths to base64 data URLs
          imagesForResend = [];
          for (final img in storedImages) {
            if (img.endsWith('.enc') && img.contains('/')) {
              // This is a storage path - download, decrypt, and convert to base64
              try {
                debugPrint('🔄 [ResendDebug] Converting storage path to base64: $img');
                final imageBytes = await ImageStorageService.downloadAndDecryptImage(img);
                final base64Image = base64Encode(imageBytes);
                final dataUrl = 'data:image/jpeg;base64,$base64Image';
                imagesForResend.add(dataUrl);
                debugPrint('🔄 [ResendDebug] Successfully converted image to base64');
              } catch (e) {
                debugPrint('🔄 [ResendDebug] Failed to convert image: $e');
              }
            } else if (img.startsWith('data:image')) {
              // Already a base64 data URL
              imagesForResend.add(img);
            }
          }
          debugPrint('🔄 [ResendDebug] Converted ${imagesForResend.length} images for AI');
        }
      } catch (e) {
        debugPrint('🔄 [ResendDebug] Failed to parse images JSON: $e');
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

    // Capture chatId for this streaming operation
    final String chatIdForStream = _activeChatId!;

    try {
      final Stream<ChatStreamEvent> eventStream =
          WebSocketChatService.sendStreamingChat(
            accessToken: accessToken,
            message: originalUserInput,
            modelId: modelIdToUse,
            providerSlug: providerToUse ?? 'openai',
            history: conversationHistory,
            systemPrompt: systemPrompt,
            maxTokens: 4096,
            temperature: 0.7,
            images: imagesForResend,
          );

      // Use StreamingManager for proper tracking
      await _streamingManager.startStream(
        chatId: chatIdForStream,
        messageIndex: placeholderIndex,
        stream: eventStream,
        onUpdate: (content, reasoning) {
          if (mounted && _isValidMessageIndex(placeholderIndex) && _activeChatId == chatIdForStream) {
            setState(() {
              _messages[placeholderIndex]['text'] = content;
              _messages[placeholderIndex]['reasoning'] = reasoning;
            });
            _scrollChatToBottom();
          }
        },
        onComplete: (finalContent, finalReasoning) {
          if (mounted) {
            setState(() {
              _isSending = false;
            });
          }
          if (finalContent.isEmpty) {
            _finalizeAiMessage(placeholderIndex, 'No response received.');
          } else {
            _finalizeAiMessage(placeholderIndex, finalContent, reasoning: finalReasoning);
          }
          // Persist with captured chatId
          _persistChatWithId(chatIdForStream);
        },
        onError: (errorMessage) {
          if (mounted) {
            setState(() {
              _isSending = false;
            });
          }
          _finalizeAiMessage(placeholderIndex, 'Error: $errorMessage');
          _persistChatWithId(chatIdForStream);
        },
      );
    } catch (e) {
      debugPrint('Streaming error: $e');
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

  void _cancelStream() {
    if (_activeChatId != null && _isStreaming) {
      debugPrint('Cancelling stream for chat $_activeChatId...');
      unawaited(_streamingManager.cancelStream(_activeChatId!));

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

  /// Generate an image from the current text prompt
  Future<void> _generateImage() async {
    final String prompt = _controller.text.trim();
    if (prompt.isEmpty) {
      _showSnackBar('Please enter a prompt to generate an image.');
      return;
    }

    if (_isGeneratingImage || _isStreaming || _isSending) {
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

    if (firstMessageInChat) _animCtrl.forward();
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
    // SET GLOBAL LOCK IMMEDIATELY - before any async operations
    // This prevents didUpdateWidget from switching chats during the entire operation
    ChatStorageService.isMessageOperationInProgress = true;
    debugPrint('🔒 [SendMessage] GLOBAL LOCK SET');

    if (_isStreaming) {
      // Current chat is streaming - cancel it
      _cancelStream();
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (cancelled)');
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
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (uploading)');
      return;
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
                    const Text('Free Messages Used'),
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
                    Text(
                      'Subscribe to get unlimited messages and access to all AI models.',
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

    // Use MessageCompositionService to prepare the message
    final List<Map<String, String>> apiHistory =
        _buildApiHistoryWithPendingMessage(originalUserInput);
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
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (invalid message)');
      return;
    }

    // Check if widget was disposed during async operation
    if (!mounted) {
      ChatStorageService.isMessageOperationInProgress = false;
      debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (widget disposed during prepareMessage)');
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
      debugPrint('');
      debugPrint('┌─────────────────────────────────────────────────────────────');
      debugPrint('│ ⚠️ [SEND-DESKTOP] SYNCED _activeChatId with widget.selectedChatId');
      debugPrint('│ ⚠️ [SEND-DESKTOP] _activeChatId was null, now: $_activeChatId');
      debugPrint('└─────────────────────────────────────────────────────────────');
    }

    // Generate chat ID ONCE at the start for truly NEW chats only
    // This prevents race conditions where multiple _persistChat calls
    // each generate their own UUID before the first one completes
    if (_activeChatId == null) {
      _activeChatId = _uuid.v4();
      debugPrint('');
      debugPrint('┌─────────────────────────────────────────────────────────────');
      debugPrint('│ 🆔 [SEND-DESKTOP] PRE-GENERATED Chat ID: $_activeChatId');
      debugPrint('│ 🆔 [SEND-DESKTOP] This ID will be used for all persist calls');
      debugPrint('└─────────────────────────────────────────────────────────────');
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
      if (_attachedFiles.isNotEmpty) {
        userMessage['attachedFilesJson'] = jsonEncode(
          _attachedFiles.map((f) => f.toJson()).toList(),
        );
        debugPrint('💾 [AttachmentDebug] Storing ${_attachedFiles.length} attached files for resend');
      }

      _messages.add(userMessage);
      debugPrint('💾 [MessageDebug] Message added to _messages list. Total messages: ${_messages.length}');

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

    // Start auto-save timer during streaming (uses captured chatId)
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _persistChatWithId(chatIdForStream),
    );

    try {
      final stream = WebSocketChatService.sendStreamingChat(
        accessToken: accessToken,
        message: aiPromptContent,
        modelId: _selectedModelId,
        providerSlug: providerSlug,
        history: apiHistory.isEmpty ? null : apiHistory,
        systemPrompt: systemPrompt,
        maxTokens: maxResponseTokens,
        images: imageDataUrls,
      );

      // Use StreamingManager for proper multi-chat streaming support
      unawaited(_streamingManager.startStream(
        chatId: chatIdForStream,
        messageIndex: placeholderIndex,
        stream: stream,
        onUpdate: (content, reasoning) {
          // Always update _messages even if viewing different chat
          if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
            _messages[placeholderIndex]['text'] = content;
            _messages[placeholderIndex]['reasoning'] = reasoning;
          }
          // Only update UI if user is still viewing this chat
          if (mounted && _activeChatId == chatIdForStream) {
            _updateAiMessage(placeholderIndex, content, reasoning);
            _scrollChatToBottom();
          }
        },
        onComplete: (finalContent, finalReasoning) {
          debugPrint('Stream completed for chat $chatIdForStream');
          _autoSaveTimer?.cancel();
          // RELEASE GLOBAL LOCK when stream completes
          ChatStorageService.isMessageOperationInProgress = false;
          debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (stream done)');

          // Update messages
          if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
            final effectiveContent = finalContent.isEmpty
                ? 'The model returned an empty response.'
                : finalContent;
            _messages[placeholderIndex]['text'] = effectiveContent;
            _messages[placeholderIndex]['reasoning'] = finalReasoning;
          }

          // Update UI if user is still viewing this chat
          if (mounted && _activeChatId == chatIdForStream) {
            setState(() {
              _isSending = false;
            });
            final effectiveContent = finalContent.isEmpty
                ? 'The model returned an empty response.'
                : finalContent;
            _finalizeAiMessage(placeholderIndex, effectiveContent, reasoning: finalReasoning);
          } else if (mounted) {
            // User switched to different chat, just update sending state
            setState(() {
              _isSending = false;
            });
          }

          // Always persist to correct chat
          _persistChatWithId(chatIdForStream);
        },
        onError: (errorMessage) {
          debugPrint('Stream error for chat $chatIdForStream: $errorMessage');
          _autoSaveTimer?.cancel();
          // RELEASE GLOBAL LOCK on error
          ChatStorageService.isMessageOperationInProgress = false;
          debugPrint('🔓 [SendMessage] GLOBAL LOCK RELEASED (stream error)');

          // Update messages with error
          if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
            _messages[placeholderIndex]['text'] = 'Error: $errorMessage';
          }

          // Update UI if user is still viewing this chat
          if (mounted && _activeChatId == chatIdForStream) {
            setState(() {
              _isSending = false;
            });
            _finalizeAiMessage(placeholderIndex, 'Error: $errorMessage');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  errorMessage,
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
          } else if (mounted) {
            setState(() {
              _isSending = false;
            });
          }

          // Always persist to correct chat
          _persistChatWithId(chatIdForStream);
        },
      ));
    } catch (error) {
      debugPrint('Failed to start stream: $error');
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 2),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
      }
      _persistChatWithId(chatIdForStream);
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
        _messages[index] = message;
        _isSending = false;
      });
    } else {
      final Map<String, String> message = Map<String, String>.from(
        _messages[index],
      );
      message['text'] = content;
      message['reasoning'] = reasoning ?? '';
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
      _scrollChatToBottom(force: true); // Scroll to ensure attachment bar is visible

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

      debugPrint(
        'Image "$fileName" uploaded and encrypted successfully: $storagePath',
      );
    } catch (error) {
      debugPrint('Failed to upload encrypted image "$fileName": $error');

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
    );

    if (result != null && result.files.isNotEmpty) {
      List<String> filePaths = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
      await _processFilePaths(filePaths);
    } else {
      debugPrint('File picking canceled.');
    }
  }

  /// Handles files dropped via drag and drop
  Future<void> _handleDroppedFiles(List<String> filePaths) async {
    await _processFilePaths(filePaths);
  }

  void _removeAttachedFile(String fileId) {
    setState(() {
      _attachedFiles.removeWhere((f) => f.id == fileId);
    });
    _scrollChatToBottom(force: true);
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
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
    final bool chatExistsInStorage = chatId != null &&
        ChatStorageService.savedChats.any((c) => c.id == chatId);
    final bool isNewChat = !chatExistsInStorage;

    try {
      final stored = isNewChat
          // Use saveChat with pre-generated ID for new chats
          ? await ChatStorageService.saveChat(messagesCopy, chatId: chatId)
          : await ChatStorageService.updateChat(chatId!, messagesCopy);
      if (!mounted || stored == null) return;

      // If silent, don't update state or notify parent - this is a background save
      // of an old chat while user is on a different chat
      if (silent) {
        debugPrint('│ 🔇 [PERSIST] Silent save completed for chat: ${stored.id}');
        return;
      }

      setState(() {
        _activeChatId = stored.id;
      });

      // ID-BASED: Notify parent when a new chat is created
      if (isNewChat) {
        debugPrint('');
        debugPrint('┌─────────────────────────────────────────────────────────────');
        debugPrint('│ 🆕 [SEND-DESKTOP] NEW CHAT CREATED!');
        debugPrint('│ 🆕 [SEND-DESKTOP] New chat ID: ${stored.id}');
        debugPrint('│ 🆕 [SEND-DESKTOP] Calling widget.onChatIdChanged(${stored.id})');
        debugPrint('│ 🆕 [SEND-DESKTOP] This should update ChatStorageService.selectedChatId');
        debugPrint('└─────────────────────────────────────────────────────────────');
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
          debugPrint('Failed to decode images JSON: $e');
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
                .map((item) => DocumentAttachment.fromJson(
                    item as Map<String, dynamic>))
                .toList();
            debugPrint('📄 [AttachmentDebug] Extracted ${attachments.length} attachments from message $index');
          }
        } catch (e) {
          debugPrint('📄 [AttachmentDebug] Failed to decode attachments JSON: $e');
        }
      }

      return _MessageRenderData(
        sender: sender,
        displayText: displayText,
        reasoning: reasoning,
        // Show loading icon if: streaming AND (has reasoning OR might get reasoning)
        isReasoningStreaming:
            isStreamingMessage && (hasReasoning || displayText.isNotEmpty),
        modelLabel: modelLabel,
        images: images,
        attachments: attachments,
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
                              Icon(Icons.cloud_upload, color: accent, size: 32),
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
                                addAutomaticKeepAlives: true, // Keep message widgets alive
                                addRepaintBoundaries: true,
                                cacheExtent: 2000.0, // Increase cache to keep more messages in memory
                                itemBuilder: (_, int i) {
                                  final _MessageRenderData data =
                                      renderMessages[i];
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
                                      maxWidth: data.isUser
                                          ? expandedInputWidth *
                                                0.7 // User messages: 70%
                                          : expandedInputWidth, // AI messages: 100%
                                      isReasoningStreaming:
                                          data.isReasoningStreaming,
                                      modelLabel: data.modelLabel,
                                      images: data.images,
                                      attachments: data.attachments,
                                      actions: _buildMessageActionsForIndex(
                                        i,
                                        data,
                                      ),
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
                                      showReasoningTokens:
                                          widget.showReasoningTokens,
                                      showModelInfo: widget.showModelInfo,
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

                    // Handle Enter: image gen mode or send message
                    if (_isImageGenMode && !_isStreaming) {
                      unawaited(_generateImage());
                    } else {
                      unawaited(_sendMessage());
                    }
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
              // Send/Cancel Message Button (or Generate Image in image gen mode)
              GestureDetector(
                onTap: _isTranscribingAudio || _isGeneratingImage
                    ? null
                    : () {
                        if (_isImageGenMode && !_isStreaming) {
                          _generateImage();
                        } else {
                          _sendMessage();
                        }
                      },
                child: Container(
                  width: btnW,
                  height: btnH,
                  decoration: BoxDecoration(
                    color: _isStreaming
                        ? Colors.red
                        : _isImageGenMode
                            ? accent.withValues(alpha: 0.9)
                            : accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: _isTranscribingAudio || _isGeneratingImage
                      ? const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.black,
                            ),
                          ),
                        )
                      : Icon(
                          _isStreaming
                              ? Icons.stop
                              : _isImageGenMode
                                  ? Icons.auto_awesome
                                  : Icons.arrow_upward,
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
                            // Image Button (attach images)
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
                            // Image Generation Button (when feature enabled)
                            if (kFeatureImageGen && widget.imageGenEnabled) ...[
                              const SizedBox(width: 8),
                              _buildIconBtn(
                                icon: Icons.auto_awesome,
                                onTap: _isGeneratingImage
                                    ? () {} // No-op while generating
                                    : () {
                                        setState(
                                          () => _isImageGenMode = !_isImageGenMode,
                                        );
                                        debugPrint(
                                          'Image Gen mode toggled: $_isImageGenMode',
                                        );
                                      },
                                isActive: _isImageGenMode || _isGeneratingImage,
                                debugLabel: 'Image Gen button',
                              ),
                            ],
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
              // Voice Mode button (only when feature enabled) or Audio Send button
              if (_isMicActive || kFeatureVoiceMode)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _isMicActive
                      ? GestureDetector(
                          key: const ValueKey<String>('audio-send-button'),
                          onTap: _isTranscribingAudio ? null : _handleAudioSend,
                          child: Container(
                            width: 44,
                            height: 36,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: _isTranscribingAudio
                                ? const Padding(
                                    padding: EdgeInsets.all(8.0),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.black,
                                      ),
                                    ),
                                  )
                                : const Icon(Icons.send, color: Colors.black),
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
