// lib/platform_specific/chat/chat_ui_desktop.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math; // For min/max
import 'dart:async';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/coming_soon_page.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';

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
  late ChatApiService _chatApiService;
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();

  late AnimationController _animCtrl;
  late Animation<double> _anim;
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1';

  bool _isBrainActive = false;
  bool _isImageActive = false;
  bool _isMicActive = false;
  bool _isSending = false;

  final List<AttachedFile> _attachedFiles = [];
  final Uuid _uuid = Uuid();

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kSearchBarContentHeight = 135.0;
  static const double _kAttachmentBarHeight = 40.0;
  static const double _kAttachmentBarMarginBottom =
      8.0; // Margin between attachment bar and search bar
  static const double _kHorizontalPaddingLarge = 16.0;
  static const double _kHorizontalPaddingSmall = 8.0;
  static const String _apiBaseUrl = 'https://api.chuk.chat';

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
  }

  @override
  void didUpdateWidget(covariant ChukChatUIDesktop oldWidget) {
    // RENAMED WIDGET TYPE
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
      _isBrainActive = false;
      _isImageActive = false;
      _isMicActive = false;
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
      _isBrainActive = false;
      _isImageActive = false;
      _isMicActive = false;
      _attachedFiles.clear();
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

    _persistChat();

    if (firstMessageInChat) _animCtrl.forward();
    _scrollChatToBottom();
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

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
    final Color iconFg = Theme.of(context).iconTheme.color!;

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
                      itemCount: _messages.length,
                      itemBuilder: (_, i) {
                        final m = _messages[i];
                        return MessageBubble(
                          message: m['text']!,
                          isUser: m['sender'] == 'user',
                          maxWidth:
                              expandedInputWidth *
                              0.7, // Message bubbles also use expanded width
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
                      (inputAreaVisualHeight / 2))
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
    final Color iconFg = Theme.of(context).iconTheme.color!;

    final bool hasAttachments = _attachedFiles.isNotEmpty;

    return Container(
      width:
          double.infinity, // Occupy full width of its parent AnimatedContainer
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
              // Add Button (File Upload)
              _buildIconBtn(
                icon: Icons.add,
                onTap: _uploadFiles,
                isActive: hasAttachments,
                debugLabel: 'Add button',
              ),
              const SizedBox(width: 8),
              // Brain Button
              _buildIconBtn(
                icon: Icons.psychology,
                onTap: () {
                  setState(() => _isBrainActive = !_isBrainActive);
                  debugPrint('Brain button toggled: $_isBrainActive');
                },
                isActive: _isBrainActive,
                debugLabel: 'Brain button',
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
