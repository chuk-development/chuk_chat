// lib/chat/chat_ui.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/services/streaming_chat_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io'; // Import for SocketException
import 'dart:async'; // Import for TimeoutException
import 'package:uuid/uuid.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/token_estimator.dart';

/* ---------- CHAT UI ---------- */
class ChukChatUI extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final int selectedChatIndex;
  final bool isSidebarExpanded;
  final bool isCompactMode;

  const ChukChatUI({
    super.key,
    required this.onToggleSidebar,
    required this.selectedChatIndex,
    required this.isSidebarExpanded,
    required this.isCompactMode,
  });

  @override
  State<ChukChatUI> createState() => ChukChatUIState();
}

class ChukChatUIState extends State<ChukChatUI>
    with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  String? _activeChatId;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _composerScrollController = ScrollController();

  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();

  late AnimationController _animCtrl;
  late Animation<double> _anim;
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1';
  String? _systemPrompt;
  final Map<String, String> _modelProviderCache = {};
  bool _providerPreferencesLoaded = false;
  late final VoidCallback _modelSelectionListener;

  bool _isImageActive = false;
  bool _isMicActive = false;
  bool _isSending = false;

  final List<AttachedFile> _attachedFiles = [];
  final Uuid _uuid = Uuid();

  static const String _apiBaseUrl =
      'https://api.chuk.chat'; // Adjust if your server is elsewhere

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
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refocusTextField(delay: true);
    });
    _loadChatFromIndex(widget.selectedChatIndex);
    _loadSavedModelPreference();
    _loadSystemPrompt();
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

  @override
  void didUpdateWidget(covariant ChukChatUI oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChatIndex != oldWidget.selectedChatIndex) {
      _loadChatFromIndex(widget.selectedChatIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _composerScrollController.dispose();
    _textFieldFocusNode.dispose();
    _rawKeyboardListenerFocusNode.dispose();
    _animCtrl.dispose();
    super.dispose();
    ModelSelectionDropdown.selectedModelListenable.removeListener(
      _modelSelectionListener,
    );
  }

  void _refocusTextField({bool delay = false}) {
    if (!mounted) return;

    void request() {
      if (_textFieldFocusNode.canRequestFocus &&
          !_textFieldFocusNode.hasPrimaryFocus) {
        FocusScope.of(context).requestFocus(_textFieldFocusNode);
      }
    }

    if (delay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => request());
    } else {
      request();
    }
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
          storedChat.messages.map(
            (message) => {
              'id': _uuid.v4(),
              'sender': message.sender,
              'text': message.text,
              'rawText': message.sender == 'user' ? message.text : null,
              'attachments': <Map<String, dynamic>>[],
              'modelId': message.modelId,
              'provider': message.provider,
              'status': 'sent',
              'timestamp': DateTime.now().toIso8601String(),
            },
          ),
        );
      for (final chatMessage in storedChat.messages) {
        final String? modelId = chatMessage.modelId;
        final String? provider = chatMessage.provider;
        if (modelId != null &&
            modelId.isNotEmpty &&
            provider != null &&
            provider.isNotEmpty) {
          _modelProviderCache[modelId] = provider;
        }
      }
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
    _refocusTextField(delay: true);
  }

  /// Load the user's saved model preference from Supabase
  Future<void> _loadSavedModelPreference() async {
    try {
      final savedModelId = await UserPreferencesService.loadSelectedModel();
      if (savedModelId != null && savedModelId.isNotEmpty) {
        setState(() {
          _selectedModelId = savedModelId;
        });
        debugPrint('Loaded saved model preference: $savedModelId');
      }
    } catch (e) {
      debugPrint('Error loading saved model preference: $e');
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
        debugPrint('Loaded system prompt: ${systemPrompt.length} characters');
      }
    } catch (error) {
      debugPrint('Error loading system prompt: $error');
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

  Future<String?> _resolveProviderForModel(String modelId) async {
    if (modelId.isEmpty) return null;

    final String? dropdownProvider =
        ModelSelectionDropdown.providerSlugForModel(modelId);
    if (dropdownProvider != null && dropdownProvider.isNotEmpty) {
      _modelProviderCache[modelId] = dropdownProvider;
      return dropdownProvider;
    }

    final String? cached = _modelProviderCache[modelId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    if (!_providerPreferencesLoaded) {
      try {
        final Map<String, String> prefs =
            await UserPreferencesService.loadAllProviderPreferences();
        if (prefs.isNotEmpty) {
          _modelProviderCache.addAll(prefs);
        }
      } catch (error) {
        debugPrint('Failed to load provider preferences: $error');
      } finally {
        _providerPreferencesLoaded = true;
      }
    }

    final String? hydrated = _modelProviderCache[modelId];
    if (hydrated != null && hydrated.isNotEmpty) {
      return hydrated;
    }

    return null;
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
    _refocusTextField(delay: true);
    await ChatStorageService.loadSavedChatsForSidebar();
  }

  Future<void> _sendMessage({
    Map<String, dynamic>? resendSource,
    String? overrideModelId,
  }) async {
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
    final String modelIdForSend = overrideModelId ?? _selectedModelId;
    final String? providerSlug = await _resolveProviderForModel(modelIdForSend);

    String displayMessageText = originalUserInput;

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
    }

    final List<Map<String, dynamic>> attachmentSnapshots =
        List<Map<String, dynamic>>.unmodifiable(
          _attachedFiles
              .where((f) => f.markdownContent != null)
              .map(
                (f) => {
                  'fileName': f.fileName,
                  'markdownContent': f.markdownContent,
                },
              ),
        );
    final String userMessageId = _uuid.v4();
    final String aiPromptContent = originalUserInput.isNotEmpty
        ? originalUserInput
        : displayMessageText;

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

    // Build message history including the pending user message
    final List<Map<String, String>> apiHistory =
        _buildApiHistoryWithPendingMessage(displayMessageText);

    final String? resolvedSystemPrompt = await _resolveSystemPromptForSend();
    final String? systemPrompt =
        (resolvedSystemPrompt != null && resolvedSystemPrompt.trim().isNotEmpty)
        ? resolvedSystemPrompt
        : null;

    final ModelProviderLimits? providerLimits =
        ModelSelectionDropdown.providerLimitsForModel(modelIdForSend);

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

    setState(() {
      _messages.add({
        'id': userMessageId,
        'sender': 'user',
        'text': displayMessageText,
        'rawText': originalUserInput,
        'attachments': attachmentSnapshots,
        'modelId': modelIdForSend,
        'provider': providerSlug,
        'status': 'sent',
        'timestamp': DateTime.now().toIso8601String(),
      });
      _controller.clear();
      _isSending = true;
      if (hasAttachments) {
        _attachedFiles.clear();
      }
    });

    _persistChat();

    if (firstMessageInChat) _animCtrl.forward();
    _scrollChatToBottom();
    _refocusTextField(delay: true);

    int placeholderIndex = -1;
    setState(() {
      final String aiMessageId = _uuid.v4();
      _messages.add({
        'id': aiMessageId,
        'sender': 'ai',
        'text': 'Thinking...',
        'status': 'pending',
        'relatedMessageId': userMessageId,
        'modelId': modelIdForSend,
        'provider': providerSlug,
        'timestamp': DateTime.now().toIso8601String(),
      });
      placeholderIndex = _messages.length - 1;
    });
    _scrollChatToBottom();

    void finalizeAiMessage(String text) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (placeholderIndex >= 0 && placeholderIndex < _messages.length) {
          final Map<String, dynamic> existing = Map<String, dynamic>.from(
            _messages[placeholderIndex],
          );
          existing['text'] = text;
          existing['status'] = 'sent';
          existing['modelId'] = modelIdForSend;
          existing['provider'] = providerSlug;
          existing['timestamp'] = DateTime.now().toIso8601String();
          _messages[placeholderIndex] = existing;
        } else {
          debugPrint('AI response arrived after chat reset, dropping message.');
        }
        _isSending = false;
      });
      _scrollChatToBottom();
      _refocusTextField(delay: true);
      _persistChat();
    }

    // Make actual API call using StreamingChatService
    try {
      final stream = StreamingChatService.sendStreamingChat(
        accessToken: accessToken,
        message: aiPromptContent,
        modelId: modelIdForSend,
        providerSlug: providerSlug ?? '',
        history: apiHistory.isEmpty ? null : apiHistory,
        systemPrompt: systemPrompt,
        maxTokens: maxResponseTokens,
      );

      final StringBuffer contentBuffer = StringBuffer();
      final StringBuffer reasoningBuffer = StringBuffer();

      await for (final event in stream) {
        if (!mounted) break;

        switch (event) {
          case ContentEvent(text: final text):
            contentBuffer.write(text);
            finalizeAiMessage(contentBuffer.toString());
            break;
          case ReasoningEvent(text: final text):
            reasoningBuffer.write(text);
            break;
          case DoneEvent():
            // Finalize with complete content
            finalizeAiMessage(contentBuffer.toString());
            break;
          case ErrorEvent(message: final message):
            finalizeAiMessage('Error: $message');
            break;
          case UsageEvent():
          case MetaEvent():
            // Handle usage and meta events if needed
            break;
        }
      }
    } catch (e) {
      if (mounted) {
        finalizeAiMessage('Error: Failed to get AI response - $e');
      }
    }
  }

  List<Map<String, String>> _buildApiHistoryWithPendingMessage(
    String pendingUserText,
  ) {
    final List<Map<String, String>> history = <Map<String, String>>[];
    for (final Map<String, dynamic> message in _messages) {
      final String? sender = message['sender'] as String?;
      final String? text = message['text'] as String?;
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _copyTextToClipboard(String text, {String? label}) async {
    if (text.isEmpty) {
      _showSnack('Nothing to copy.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack(label ?? 'Copied to clipboard.');
  }

  Future<void> _copyAttachment(AttachedFile file) async {
    final String? markdown = file.markdownContent;
    if (markdown != null && markdown.isNotEmpty) {
      await _copyTextToClipboard(
        markdown,
        label: '"${file.fileName}" copied to clipboard.',
      );
      return;
    }
    final String? path = file.localPath;
    if (path != null) {
      try {
        final String content = await File(path).readAsString();
        await _copyTextToClipboard(
          content,
          label: '"${file.fileName}" copied to clipboard.',
        );
        return;
      } catch (_) {
        _showSnack('Unable to copy "${file.fileName}".');
        return;
      }
    }
    _showSnack('No copyable content for "${file.fileName}".');
  }

  Map<String, dynamic>? _findMessageById(String id) {
    try {
      return _messages.firstWhere((message) => message['id'] == id);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _messageAttachments(Map<String, dynamic> message) {
    final dynamic attachments = message['attachments'];
    if (attachments is List) {
      return attachments
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  Future<void> _prepareMessageAndSend(
    Map<String, dynamic> source, {
    String? overrideModelId,
    bool autoSend = true,
  }) async {
    if (autoSend && _isSending) {
      _showSnack('Please wait for the current response to finish.');
      return;
    }

    final String rawInput =
        (source['rawText'] as String?) ?? (source['text'] as String? ?? '');
    final List<Map<String, dynamic>> attachments = _messageAttachments(source)
        .where(
          (attachment) =>
              (attachment['markdownContent'] as String?)?.isNotEmpty ?? false,
        )
        .toList();
    final String? targetModelId =
        overrideModelId ??
        (source['modelId'] as String?) ??
        (_selectedModelId.isNotEmpty ? _selectedModelId : null);

    setState(() {
      _controller
        ..text = rawInput
        ..selection = TextSelection.fromPosition(
          TextPosition(offset: rawInput.length),
        );
      _attachedFiles
        ..clear()
        ..addAll(
          attachments.map(
            (attachment) => AttachedFile(
              id: _uuid.v4(),
              fileName: attachment['fileName'] as String? ?? 'attachment',
              markdownContent: attachment['markdownContent'] as String?,
              isUploading: false,
            ),
          ),
        );
      if (targetModelId != null &&
          targetModelId.isNotEmpty &&
          _selectedModelId != targetModelId) {
        _selectedModelId = targetModelId;
      }
    });

    if (targetModelId != null && targetModelId.isNotEmpty) {
      ModelSelectionDropdown.selectedModelNotifier.value = targetModelId;
    }
    _refocusTextField(delay: true);

    if (!autoSend) {
      return;
    }

    await _sendMessage(resendSource: source, overrideModelId: targetModelId);
  }

  Future<void> _resendMessage(Map<String, dynamic> message) async {
    await _prepareMessageAndSend(message);
  }

  Future<void> _retryMessage(Map<String, dynamic> message) async {
    await _prepareMessageAndSend(message);
  }

  Future<void> _resendMessageToDifferentModel(
    Map<String, dynamic> message,
  ) async {
    final String currentModel =
        (message['modelId'] as String?) ?? _selectedModelId;
    final String? selectedModel = await _promptModelSelection(currentModel);
    if (selectedModel == null) return;
    await _prepareMessageAndSend(message, overrideModelId: selectedModel);
  }

  Future<void> _retryRelatedMessage(String relatedMessageId) async {
    final Map<String, dynamic>? source = _findMessageById(relatedMessageId);
    if (source == null) {
      _showSnack('Original message not found.');
      return;
    }
    await _prepareMessageAndSend(source);
  }

  Future<void> _resendRelatedMessageToDifferentModel(
    String relatedMessageId,
  ) async {
    final Map<String, dynamic>? source = _findMessageById(relatedMessageId);
    if (source == null) {
      _showSnack('Original message not found.');
      return;
    }
    final String currentModel =
        (source['modelId'] as String?) ?? _selectedModelId;
    final String? selectedModel = await _promptModelSelection(currentModel);
    if (selectedModel == null) return;
    await _prepareMessageAndSend(source, overrideModelId: selectedModel);
  }

  void _startEditingMessage(Map<String, dynamic> message) {
    if ((message['sender'] as String?)?.toLowerCase() != 'user') {
      return;
    }
    setState(() {
      for (final Map<String, dynamic> entry in _messages) {
        if (identical(entry, message)) {
          entry['isEditing'] = true;
        } else {
          entry.remove('isEditing');
        }
      }
    });
  }

  void _cancelEditingMessage(Map<String, dynamic> message) {
    setState(() {
      message.remove('isEditing');
    });
  }

  Future<void> _submitEditedMessage(
    Map<String, dynamic> message,
    String updatedText,
  ) async {
    final String trimmed = updatedText.trim();
    if (trimmed.isEmpty) {
      _showSnack('Message cannot be empty.');
      return;
    }
    if (_isSending) {
      _showSnack('Please wait for the current response to finish.');
      return;
    }

    setState(() {
      message['text'] = trimmed;
      message['rawText'] = trimmed;
      message.remove('isEditing');
    });
    _persistChat();

    final Map<String, dynamic> payload = Map<String, dynamic>.from(message)
      ..remove('isEditing')
      ..['text'] = trimmed
      ..['rawText'] = trimmed;

    await _prepareMessageAndSend(payload);
  }

  List<MessageBubbleAction> _buildMessageActions(Map<String, dynamic> message) {
    final String text = (message['text'] as String?) ?? '';
    final bool isUserMessage =
        (message['sender'] as String?)?.toLowerCase() == 'user';
    final String status = (message['status'] as String?) ?? 'sent';
    final bool isEditing = (message['isEditing'] as bool?) ?? false;
    final List<MessageBubbleAction> actions = [];
    final bool isPending = status == 'pending';

    if (isEditing) {
      return actions;
    }

    if (text.isNotEmpty) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.copy,
          tooltip: 'Copy message',
          onPressed: () => _copyTextToClipboard(text),
          isEnabled: !isPending || isUserMessage,
        ),
      );
    }

    if (isUserMessage) {
      actions.add(
        MessageBubbleAction(
          icon: Icons.edit,
          tooltip: 'Edit & resend',
          onPressed: () => _startEditingMessage(message),
          isEnabled: !isPending && !_isSending,
        ),
      );
      actions.add(
        MessageBubbleAction(
          icon: Icons.replay,
          tooltip: 'Resend',
          onPressed: () => _resendMessage(message),
          isEnabled: !_isSending,
        ),
      );
      actions.add(
        MessageBubbleAction(
          icon: Icons.model_training,
          tooltip: 'Send with different model',
          onPressed: () => _resendMessageToDifferentModel(message),
        ),
      );
      actions.add(
        MessageBubbleAction(
          icon: Icons.refresh,
          tooltip: 'Retry send',
          onPressed: () => _retryMessage(message),
          isEnabled: status != 'pending',
        ),
      );
    } else {
      final String? relatedId = message['relatedMessageId'] as String?;
      if (relatedId != null) {
        actions.add(
          MessageBubbleAction(
            icon: Icons.refresh,
            tooltip: 'Retry send',
            onPressed: () => _retryRelatedMessage(relatedId),
            isEnabled: !isPending,
          ),
        );
        actions.add(
          MessageBubbleAction(
            icon: Icons.model_training,
            tooltip: 'Send with different model',
            onPressed: () => _resendRelatedMessageToDifferentModel(relatedId),
            isEnabled: !isPending,
          ),
        );
      }
    }

    return actions;
  }

  List<ModelItem> _filterModelsForProviders(
    List<Map<String, dynamic>> payload,
    Map<String, String> providerPrefs,
  ) {
    final List<ModelItem> filtered = [];
    if (providerPrefs.isEmpty) {
      return filtered;
    }
    for (final modelJson in payload) {
      final ModelItem modelItem = ModelItem.fromJson(modelJson);
      if (modelItem.value.isEmpty) continue;
      final String? providerSlug = providerPrefs[modelItem.value];
      if (providerSlug == null || providerSlug.isEmpty) {
        continue;
      }
      final List<dynamic>? providers = modelJson['providers'] as List<dynamic>?;
      if (providers == null || providers.isEmpty) {
        continue;
      }
      final bool providerExists = providers.any(
        (entry) =>
            entry is Map<String, dynamic> && entry['slug'] == providerSlug,
      );
      if (providerExists) {
        filtered.add(modelItem);
      }
    }
    filtered.sort((a, b) => a.name.compareTo(b.name));
    return filtered;
  }

  Future<List<ModelItem>> _loadCachedModelsForPrompt(
    Map<String, String> providerPrefs,
  ) async {
    final String? userId =
        SupabaseService.auth.currentSession?.user.id ??
        SupabaseService.auth.currentUser?.id;
    Map<String, String> effectivePrefs = providerPrefs;
    if (effectivePrefs.isEmpty && userId != null) {
      effectivePrefs = await ModelCacheService.loadProviderPreferences(userId);
    }
    final List<Map<String, dynamic>> payload =
        await ModelCacheService.loadAvailableModels();
    if (payload.isEmpty || effectivePrefs.isEmpty) {
      return const <ModelItem>[];
    }
    return _filterModelsForProviders(payload, effectivePrefs);
  }

  Future<String?> _promptModelSelection(String currentModelId) async {
    Map<String, String> providerPrefs =
        await UserPreferencesService.loadAllProviderPreferences();
    List<ModelItem> models = const <ModelItem>[];
    final String? userId =
        SupabaseService.auth.currentSession?.user.id ??
        SupabaseService.auth.currentUser?.id;

    try {
      final response = await http.get(Uri.parse('$_apiBaseUrl/models_info'));
      if (response.statusCode == 200) {
        final dynamic decoded = json.decode(response.body);
        if (decoded is List) {
          final List<Map<String, dynamic>> payload = decoded
              .whereType<Map<String, dynamic>>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(growable: false);
          models = _filterModelsForProviders(payload, providerPrefs);
          await ModelCacheService.saveAvailableModels(payload);
          if (userId != null) {
            await ModelCacheService.saveProviderPreferences(
              userId,
              Map<String, String>.from(providerPrefs),
            );
          }
        } else {
          throw const FormatException('Unexpected models payload');
        }
      } else {
        debugPrint(
          'Model fetch failed: ${response.statusCode} - ${response.body}',
        );
      }
    } on SocketException catch (error) {
      debugPrint('Model selection fetch offline: $error');
    } on FormatException catch (error) {
      debugPrint('Model selection payload error: $error');
    } on http.ClientException catch (error) {
      debugPrint('Model selection client error: $error');
    } catch (error, stackTrace) {
      debugPrint('Model selection fetch failed: $error');
      debugPrint('$stackTrace');
    }

    if (models.isEmpty) {
      models = await _loadCachedModelsForPrompt(providerPrefs);
      if (models.isNotEmpty && mounted) {
        _showSnack('Using your saved models while offline.');
      }
    }

    if (models.isEmpty) {
      _showSnack('No models available.');
      return null;
    }

    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('Send with model'),
          children: [
            ...models.map(
              (model) => SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(model.value),
                child: Row(
                  children: [
                    Expanded(child: Text(model.name)),
                    if (model.value == currentModelId)
                      const Icon(Icons.check, size: 16),
                  ],
                ),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _uploadFiles() async {
    const int maxFileSize = 10 * 1024 * 1024; // 10MB
    const int maxConcurrentUploads = 5;

    final allowedExtensions = [
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
    ];

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
      allowedExtensions: allowedExtensions,
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

        if (!allowedExtensions.contains(fileExtension)) {
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

        _performFileUpload(file, fileName, fileId);
      }
    } else {
      debugPrint('File picking canceled.');
    }
    _refocusTextField(delay: true);
  }

  Future<void> _performFileUpload(
    File file,
    String fileName,
    String fileId,
  ) async {
    const int maxRetries = 3;
    const Duration timeoutDuration = Duration(seconds: 30);
    int retryCount = 0;
    bool uploadSuccess = false; // Flag to track if upload was successful

    // We'll keep the `finally` outside the loop to ensure _scrollChatToBottom() is called only once
    // after the process is truly finished (either success or final failure).
    try {
      while (retryCount < maxRetries && !uploadSuccess) {
        try {
          var request = http.MultipartRequest(
            'POST',
            Uri.parse('$_apiBaseUrl/upload_file'),
          );
          request.files.add(
            await http.MultipartFile.fromPath('file', file.path),
          );

          // Apply timeout to the request send operation
          var streamedResponse = await request.send().timeout(timeoutDuration);
          var response = await http.Response.fromStream(streamedResponse);

          if (response.statusCode == 200) {
            final jsonResponse = json.decode(response.body);
            setState(() {
              int index = _attachedFiles.indexWhere((f) => f.id == fileId);
              if (index != -1) {
                _attachedFiles[index] = _attachedFiles[index].copyWith(
                  markdownContent: jsonResponse['markdown_content'],
                  isUploading: false,
                );
              }
            });
            debugPrint(
              'File "$fileName" conversion successful. Markdown content received.',
            );
            uploadSuccess = true; // Mark as success to exit the while loop
          } else {
            // Non-200 status code from server: treat as a non-retriable failure
            final errorBody = json.decode(response.body);
            setState(() {
              _attachedFiles.removeWhere((f) => f.id == fileId);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Failed to upload "$fileName" (Status: ${response.statusCode}): ${errorBody['detail'] ?? response.reasonPhrase}',
                    ),
                  ),
                );
              }
            });
            debugPrint(
              'File upload failed for "$fileName" (Status: ${response.statusCode}): ${response.body}',
            );
            break; // Exit the retry loop immediately for server-side errors
          }
        } catch (e) {
          // This block catches network errors, timeouts, etc.
          debugPrint(
            'Upload attempt failed for "$fileName" (Attempt ${retryCount + 1}/$maxRetries): $e',
          );
          retryCount++;

          if (retryCount >= maxRetries) {
            // Final failure after all retries exhausted
            setState(() {
              _attachedFiles.removeWhere((f) => f.id == fileId);
              if (mounted) {
                String errorMessage =
                    'Error uploading "$fileName" after $maxRetries attempts.';
                if (e is TimeoutException) {
                  errorMessage =
                      'Upload of "$fileName" timed out after $maxRetries attempts.';
                } else if (e is SocketException) {
                  errorMessage =
                      'Network error uploading "$fileName" after $maxRetries attempts.';
                } else {
                  errorMessage =
                      'Error uploading "$fileName" after $maxRetries attempts: $e';
                }
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(errorMessage)));
              }
            });
            // The loop condition will naturally terminate it here.
          } else {
            // Delay before next retry with exponential backoff
            await Future.delayed(Duration(seconds: retryCount * 2));
            // Loop continues for next retry attempt
          }
        }
      }
    } finally {
      _scrollChatToBottom(); // Ensure scrolling happens once after all attempts
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
        .map((message) {
          final Map<String, String> entry = {
            'sender': (message['sender'] as String?) ?? 'user',
            'text': (message['text'] as String?) ?? '',
          };
          final String? modelId = message['modelId'] as String?;
          if (modelId != null && modelId.isNotEmpty) {
            entry['modelId'] = modelId;
          }
          final String? provider = message['provider'] as String?;
          if (provider != null && provider.isNotEmpty) {
            entry['provider'] = provider;
          }
          final String? reasoning = message['reasoning'] as String?;
          if (reasoning != null && reasoning.isNotEmpty) {
            entry['reasoning'] = reasoning;
          }
          return entry;
        })
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
    final bool showInputAreaCentered =
        isChatEmpty; // Input area is centered only if NO messages yet

    // Determine the target width for the input area
    final double targetInputWidth = showInputAreaCentered
        ? centeredInputWidth
        : expandedInputWidth;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Chat-Nachrichtenliste (only shown if there are messages)
          if (!isChatEmpty)
            Positioned(
              top: 0,
              bottom:
                  inputAreaTotalHeight, // Chat list is positioned above the entire input area
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _anim,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    constraints: BoxConstraints(
                      maxWidth: expandedInputWidth,
                    ), // Chat list itself uses expanded width
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.symmetric(
                        horizontal: effectiveHorizontalPadding,
                        vertical: 10,
                      ),
                      cacheExtent: 240,
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final Map<String, dynamic> message = _messages[i];
                        final String messageText =
                            (message['text'] as String?) ?? '';
                        final bool isUserMessage =
                            (message['sender'] as String?) == 'user';
                        final String? modelInfo = _formatModelInfo(
                          message['modelId'] as String?,
                          message['provider'] as String?,
                        );
                        final String bubbleId =
                            (message['id'] as String?) ?? 'message-$i';
                        return RepaintBoundary(
                          child: MessageBubble(
                            key: ValueKey<String>(bubbleId),
                            message: messageText,
                            isUser: isUserMessage,
                            maxWidth:
                                expandedInputWidth *
                                0.7, // Message bubbles also use expanded width
                            actions: _buildMessageActions(message),
                            isEditing:
                                isUserMessage &&
                                ((message['isEditing'] as bool?) ?? false),
                            initialEditText:
                                (message['rawText'] as String?) ?? messageText,
                            onSubmitEdit: isUserMessage
                                ? (updated) => unawaited(
                                    _submitEditedMessage(message, updated),
                                  )
                                : null,
                            onCancelEdit: isUserMessage
                                ? () => _cancelEditingMessage(message)
                                : null,
                            modelLabel: modelInfo,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

          // Combined Input Area (Search bar + Attachment bar)
          // Uses AnimatedPositioned to smoothly move from center to bottom
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            left: 0,
            right: 0,
            // Position at the bottom if not empty, otherwise calculate center position
            bottom: showInputAreaCentered
                ? (MediaQuery.of(context).size.height / 2 -
                      (inputAreaVisualHeight /
                          2)) // Adjusted to center based on actual visual height
                : effectiveHorizontalPadding, // Always keep padding from bottom edge
            child: Center(
              // Centers horizontally
              child: AnimatedContainer(
                // NEW: AnimatedContainer for width transition
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
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
                            onCopy: _copyAttachment,
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

                    _sendMessage();
                    _refocusTextField();
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
              // Send Message Button
              GestureDetector(
                onTap: () {
                  _sendMessage();
                  _refocusTextField();
                },
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
                  setState(() => _isImageActive = !_isImageActive);
                  debugPrint('Image button toggled: $_isImageActive');
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
                  debugPrint('Selected model ID: $_selectedModelId');
                },
                textFieldFocusNode: _textFieldFocusNode,
                isCompactMode: isCompactMode,
              ),
              const SizedBox(width: 8),
              // Mic Button (for a quick toggle in the main chat UI)
              _buildIconBtn(
                icon: Icons.mic,
                onTap: () {
                  setState(() => _isMicActive = !_isMicActive);
                  debugPrint('Mic button toggled: $_isMicActive');
                },
                isActive: _isMicActive,
                debugLabel: 'Mic button',
              ),
              const SizedBox(width: 8),
              // Voice Mode Button (placeholder)
              GestureDetector(
                onTap: () => _openComingSoonFeature('Voice Mode'),
                child: Container(
                  width: 44,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.graphic_eq, color: Colors.black),
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
