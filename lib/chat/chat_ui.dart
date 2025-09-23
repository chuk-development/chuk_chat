// lib/chat/chat_ui.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/voice_mode_page.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io'; // Import for SocketException
import 'dart:async'; // Import for TimeoutException
import 'package:uuid/uuid.dart';

/* ---------- CHAT UI ---------- */
class ChukChatUI extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final int selectedChatIndex;
  final bool isSidebarExpanded;
  final bool isCompactMode;

  const ChukChatUI({
    Key? key,
    required this.onToggleSidebar,
    required this.selectedChatIndex,
    required this.isSidebarExpanded,
    required this.isCompactMode,
  }) : super(key: key);

  @override
  State<ChukChatUI> createState() => ChukChatUIState();
}

class ChukChatUIState extends State<ChukChatUI> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();

  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();

  late AnimationController _animCtrl;
  late Animation<double> _anim;
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1';

  bool _isBrainActive = false;
  bool _isImageActive = false;
  bool _isMicActive = false;

  final List<AttachedFile> _attachedFiles = [];
  final Uuid _uuid = Uuid();

  static const String _apiBaseUrl = 'https://api.chuk.chat'; // Adjust if your server is elsewhere

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kSearchBarContentHeight = 135.0;
  static const double _kAttachmentBarHeight = 40.0;
  static const double _kAttachmentBarMarginBottom = 8.0; // Margin between attachment bar and search bar
  static const double _kHorizontalPaddingLarge = 16.0;
  static const double _kHorizontalPaddingSmall = 8.0;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(duration: const Duration(milliseconds: 200), vsync: this);
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    });
    _loadChatFromIndex(widget.selectedChatIndex);
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
    } else if (index >= 0 && index < ChatStorageService.savedChats.length) {
      final chatJson = ChatStorageService.savedChats[index];
      _messages.clear();
      final messageParts = chatJson.split('§');
      for (var part in messageParts) {
        if (part.isNotEmpty) {
          final components = part.split('|');
          if (components.length == 2) {
            _messages.add({'sender': components[0], 'text': components[1]});
          }
        }
      }
      if (_messages.isNotEmpty) {
         _animCtrl.forward();
      } else {
        _animCtrl.reset();
      }
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
    if (_messages.isNotEmpty) {
      final json = _messages.map((m) => '${m['sender']}|${m['text']}').join('§');
      await ChatStorageService.saveChat(json);
    }
    setState(() {
      _messages.clear();
      _animCtrl.reset();
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

  void _sendMessage() {
    final bool hasText = _controller.text.trim().isNotEmpty;
    final bool hasAttachments = _attachedFiles.any((f) => f.markdownContent != null);

    if (!hasText && !hasAttachments) return;

    final firstMessageInChat = _messages.isEmpty;

    String userMessageText = _controller.text;
    if (hasAttachments) {
      final attachedFileNames = _attachedFiles.map((f) => '"${f.fileName}"').join(', ');
      if (userMessageText.isNotEmpty) {
        userMessageText = 'Uploaded documents: $attachedFileNames\n\n$userMessageText';
      } else {
        userMessageText = 'Uploaded documents: $attachedFileNames';
      }
    }

    setState(() {
      _messages.add({'sender': 'user', 'text': userMessageText});
      _controller.clear();
    });

    // Only trigger the animation/move-down effect when the FIRST message is sent
    // This also implicitly starts the chat content animation (_anim.forward())
    if (firstMessageInChat) _animCtrl.forward();
    _scrollChatToBottom();
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());

    String aiPrompt = userMessageText;
    if (hasAttachments) {
      final markdownSections = _attachedFiles
          .where((f) => f.markdownContent != null)
          .map((f) => "Document: \"${f.fileName}\"\n```\n${f.markdownContent}\n```")
          .join('\n\n');
      aiPrompt = "$markdownSections\n\nUser query: $aiPrompt";
      _attachedFiles.clear(); // Clear all attachments after sending
    }

    Future.delayed(const Duration(milliseconds: 300), () {
      setState(() {
        _messages.add({'sender': 'ai', 'text': 'You said: "${_messages.last['text']}"\n(Model ID: $_selectedModelId)'});
      });
      _scrollChatToBottom();
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    });
  }

  Future<void> _uploadFiles() async {
    const int maxFileSize = 10 * 1024 * 1024; // 10MB
    const int maxConcurrentUploads = 5;

    final allowedExtensions = [
      'wav', 'mp3', 'm4a', 'mp4', 'html', 'htm', 'csv', 'docx', 'pptx', 'xlsx',
      'pdf', 'jpg', 'jpeg', 'png', 'bmp', 'tiff', 'epub', 'ipynb', 'msg', 'txt',
      'text', 'md', 'markdown', 'json', 'jsonl', 'rss', 'atom', 'xml', 'xls', 'zip'
    ];

    if (_attachedFiles.where((f) => f.isUploading).length >= maxConcurrentUploads) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please wait for current uploads to complete')),
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
              SnackBar(content: Text('File "${platformFile.name}" exceeds 10MB limit')),
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
              SnackBar(content: Text('Unsupported file type for "$fileName": .$fileExtension')),
            );
          }
          continue;
        }

        // Check concurrent upload limit again before adding to UI and starting upload
        // This handles cases where user quickly picks many files, or files picked while others finish
        if (_attachedFiles.where((f) => f.isUploading).length >= maxConcurrentUploads) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Skipping "${fileName}": too many concurrent uploads. Try again soon.')),
            );
          }
          continue;
        }

        setState(() {
          _attachedFiles.add(AttachedFile(
            id: fileId,
            fileName: fileName,
            isUploading: true,
          ));
        });
        _scrollChatToBottom(); // Scroll to ensure attachment bar is visible

        _performFileUpload(file, fileName, fileId);
      }
    } else {
      print('File picking canceled.');
    }
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
  }

  Future<void> _performFileUpload(File file, String fileName, String fileId) async {
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
          request.files.add(await http.MultipartFile.fromPath('file', file.path));

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
            print('File "$fileName" conversion successful. Markdown content received.');
            uploadSuccess = true; // Mark as success to exit the while loop
          } else {
            // Non-200 status code from server: treat as a non-retriable failure
            final errorBody = json.decode(response.body);
            setState(() {
              _attachedFiles.removeWhere((f) => f.id == fileId);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to upload "$fileName" (Status: ${response.statusCode}): ${errorBody['detail'] ?? response.reasonPhrase}')),
                );
              }
            });
            print('File upload failed for "$fileName" (Status: ${response.statusCode}): ${response.body}');
            break; // Exit the retry loop immediately for server-side errors
          }
        } catch (e) {
          // This block catches network errors, timeouts, etc.
          print('Upload attempt failed for "$fileName" (Attempt ${retryCount + 1}/$maxRetries): $e');
          retryCount++;

          if (retryCount >= maxRetries) {
            // Final failure after all retries exhausted
            setState(() {
              _attachedFiles.removeWhere((f) => f.id == fileId);
              if (mounted) {
                String errorMessage = 'Error uploading "$fileName" after $maxRetries attempts.';
                if (e is TimeoutException) {
                  errorMessage = 'Upload of "$fileName" timed out after $maxRetries attempts.';
                } else if (e is SocketException) {
                  errorMessage = 'Network error uploading "$fileName" after $maxRetries attempts.';
                } else {
                  errorMessage = 'Error uploading "$fileName" after $maxRetries attempts: $e';
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(errorMessage)),
                );
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
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color textColor = iconFg;

    final double effectiveHorizontalPadding = widget.isCompactMode ? _kHorizontalPaddingSmall : _kHorizontalPaddingLarge;
    final double maxPossibleChatContentWidth = math.max(0.0, screenWidth - (effectiveHorizontalPadding * 2));
    final double constrainedChatContentWidth = math.min(_kMaxChatContentWidth, maxPossibleChatContentWidth);

    // Define the smaller width for the centered state
    final double centeredInputWidth = constrainedChatContentWidth * (widget.isCompactMode ? 0.95 : 0.8);
    // Define the full width for the bottom-aligned state
    final double expandedInputWidth = constrainedChatContentWidth;

    // Calculate the total height of the input area (search bar + attachment bar + padding)
    double inputAreaVisualHeight = _kSearchBarContentHeight;
    if (_attachedFiles.isNotEmpty) {
      inputAreaVisualHeight += _kAttachmentBarHeight + _kAttachmentBarMarginBottom;
    }
    double inputAreaTotalHeight = inputAreaVisualHeight + (2 * effectiveHorizontalPadding); // accounting for total vertical padding around the searchbar container

    // Determine if the chat is currently empty (no messages, no attached files)
    final bool isChatEmpty = _messages.isEmpty; // This refers to the chat history, not just text input
    final bool showInputAreaCentered = isChatEmpty; // Input area is centered only if NO messages yet

    // Determine the target width for the input area
    final double targetInputWidth = showInputAreaCentered ? centeredInputWidth : expandedInputWidth;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Chat-Nachrichtenliste (only shown if there are messages)
          if (!isChatEmpty)
            Positioned(
              top: 0,
              bottom: inputAreaTotalHeight, // Chat list is positioned above the entire input area
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _anim,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    constraints: BoxConstraints(maxWidth: expandedInputWidth), // Chat list itself uses expanded width
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.symmetric(horizontal: effectiveHorizontalPadding, vertical: 10),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) {
                        final m = _messages[i];
                        return MessageBubble(
                          message: m['text']!,
                          isUser: m['sender'] == 'user',
                          maxWidth: expandedInputWidth * 0.7, // Message bubbles also use expanded width
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
                ? (MediaQuery.of(context).size.height / 2 - (inputAreaVisualHeight / 2)) // Adjusted to center based on actual visual height
                : effectiveHorizontalPadding, // Always keep padding from bottom edge
            child: Center( // Centers horizontally
              child: AnimatedContainer( // NEW: AnimatedContainer for width transition
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                width: targetInputWidth, // Dynamically changes width
                child: Column(
                  mainAxisSize: MainAxisSize.min, // Crucial for column inside AnimatedPositioned/Center
                  children: [
                    // Multiple Attachment Indicator Bar (if files are present)
                    if (_attachedFiles.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: _kAttachmentBarMarginBottom), // Margin below chips
                        child: _buildAttachmentBar(targetInputWidth, effectiveHorizontalPadding, textColor, accent), // Pass targetInputWidth
                      ),
                    // Search Bar
                    _buildSearchBar(isCompactMode: widget.isCompactMode),
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
  Widget _buildAttachmentBar(double contentWidth, double horizontalPadding, Color textColor, Color accentColor) {
    return Container(
      width: contentWidth, // Use the passed contentWidth
      height: _kAttachmentBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      decoration: BoxDecoration(
        color: Colors.grey.shade800.withOpacity(0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade700),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: _attachedFiles.map((file) =>
              _buildAttachmentChip(file, textColor, accentColor)).toList(),
        ),
      ),
    );
  }

  Widget _buildAttachmentChip(AttachedFile file, Color textColor, Color accentColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Chip(
        padding: EdgeInsets.zero,
        backgroundColor: file.isUploading ? Colors.blueGrey.shade700 : Colors.grey.shade700,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (file.isUploading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                ),
              )
            else
              Icon(Icons.insert_drive_file, color: textColor.withOpacity(0.8), size: 16),
            const SizedBox(width: 6),
            Text(
              file.fileName,
              style: TextStyle(color: textColor, fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
        ),
        onDeleted: file.isUploading ? null : () => _removeAttachedFile(file.id),
        deleteIcon: Icon(Icons.close, color: textColor.withOpacity(0.8), size: 16),
        deleteButtonTooltipMessage: 'Remove "${file.fileName}"',
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
      width: double.infinity, // Occupy full width of its parent AnimatedContainer
      height: _kSearchBarContentHeight,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: iconFg.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: RawKeyboardListener(
                  focusNode: _rawKeyboardListenerFocusNode,
                  onKey: (event) {
                    if (event.runtimeType.toString() == 'RawKeyDownEvent') {
                      if (event.isKeyPressed(LogicalKeyboardKey.enter)) {
                        if (event.isShiftPressed) {
                          final v = _controller.value;
                          final t = v.text.replaceRange(v.selection.start, v.selection.end, '\n');
                          _controller.value = v.copyWith(
                            text: t,
                            selection: TextSelection.collapsed(offset: v.selection.start + 1),
                          );
                          return;
                        } else {
                          _sendMessage();
                        }
                      }
                    }
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
                      hintStyle: TextStyle(color: iconFg.withOpacity(0.8)),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false,
                      fillColor: Colors.transparent,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
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
                  print('Brain button toggled: $_isBrainActive');
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
                  print('Image button toggled: $_isImageActive');
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
                  print('Selected model ID: $_selectedModelId');
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
                  print('Mic button toggled: $_isMicActive');
                },
                isActive: _isMicActive,
                debugLabel: 'Mic button',
              ),
              const SizedBox(width: 8),
              // Voice Mode Button (navigates to VoiceModePage)
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VoiceModePage()),
                ),
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
                    ? iconFg.withOpacity(0.6)
                    : iconFg.withOpacity(0.3);

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