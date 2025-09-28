// lib/platform_specific/chat/chat_ui_mobile.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/voice_mode_page.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';
import 'package:chuk_chat/platform_specific/chat/chat_api_service.dart'; // NEW API SERVICE

import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:async';
import 'package:uuid/uuid.dart';

/* ---------- CHAT UI MOBILE (Phone-specific rendering) ---------- */
class ChukChatUIMobile extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final int selectedChatIndex;
  final bool isSidebarExpanded; // Passed from RootWrapperMobile

  const ChukChatUIMobile({
    Key? key,
    required this.onToggleSidebar,
    required this.selectedChatIndex,
    required this.isSidebarExpanded,
  }) : super(key: key);

  @override
  State<ChukChatUIMobile> createState() => ChukChatUIMobileState();
}


class ChukChatUIMobileState extends State<ChukChatUIMobile> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();
  final Uuid _uuid = Uuid();

  late ChatApiService _chatApiService;
  final List<AttachedFile> _attachedFiles = [];
  String _selectedModelId = 'deepseek/deepseek-chat-v3.1'; // Default model

  late AnimationController _animCtrl;
  late Animation<double> _anim;

  bool _isBrainActive = false;
  bool _isImageActive = false;
  bool _isMicActive = false;

  static const double _kMaxChatContentWidth = 760.0;
  static const double _kSearchBarContentHeight = 135.0;
  static const double _kAttachmentBarHeight = 40.0;
  static const double _kAttachmentBarMarginBottom = 8.0;
  static const double _kHorizontalPaddingSmall = 8.0; // Always use small padding for phones

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(duration: const Duration(milliseconds: 200), vsync: this);
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _chatApiService = ChatApiService(onUploadStatusUpdate: _handleFileUploadUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    });
    _loadChatFromIndex(widget.selectedChatIndex);
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
    _textFieldFocusNode.requestFocus();
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
    _textFieldFocusNode.requestFocus();
    await ChatStorageService.loadSavedChatsForSidebar();
  }

  void _handleFileUploadUpdate(
      String fileId, String? markdownContent, bool isUploading, String? snackBarMessage) {
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
          _attachedFiles[index] = _attachedFiles[index].copyWith(isUploading: isUploading);
        }
      }
    });
    if (snackBarMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(snackBarMessage)));
    }
    _scrollChatToBottom();
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
    _textFieldFocusNode.requestFocus();

    if (firstMessageInChat) _animCtrl.forward();
    _scrollChatToBottom();

    String aiPrompt = userMessageText;
    if (hasAttachments) {
      final markdownSections = _attachedFiles
          .where((f) => f.markdownContent != null)
          .map((f) => "Document: \"${f.fileName}\"\n```\n${f.markdownContent}\n```")
          .join('\n\n');
      aiPrompt = "$markdownSections\n\nUser query: $aiPrompt";
      _attachedFiles.clear();
    }

    Future.delayed(const Duration(milliseconds: 300), () {
      setState(() {
        _messages.add({'sender': 'ai', 'text': 'You said: "${_messages.last['text']}"\n(Model ID: $_selectedModelId)'});
      });
      _scrollChatToBottom();
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
        if (platformFile.size > maxFileSize) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('File "${platformFile.name}" exceeds 10MB limit')),
            );
          }
          continue;
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
        _scrollChatToBottom();
        _chatApiService.performFileUpload(file, fileName, fileId);
      }
    } else {
      print('File picking canceled.');
    }
  }

  void _removeAttachedFile(String fileId) {
    setState(() {
      _attachedFiles.removeWhere((f) => f.id == fileId);
    });
    _scrollChatToBottom();
    _textFieldFocusNode.requestFocus();
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
    const bool isCompactModeForModelDropdown = true; // Mobile shows a hashtag-only trigger for model menu.

    final double screenWidth = MediaQuery.of(context).size.width;
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color textColor = iconFg;

    final double effectiveHorizontalPadding = _kHorizontalPaddingSmall;
    final double maxPossibleChatContentWidth = math.max(0.0, screenWidth - (effectiveHorizontalPadding * 2));
    final double constrainedChatContentWidth = math.min(_kMaxChatContentWidth, maxPossibleChatContentWidth);

    final double expandedInputWidth = constrainedChatContentWidth;

    double inputAreaVisualHeight = _kSearchBarContentHeight;
    if (_attachedFiles.isNotEmpty) {
      inputAreaVisualHeight += _kAttachmentBarHeight + _kAttachmentBarMarginBottom;
    }
    double inputAreaTotalHeight = inputAreaVisualHeight + (2 * effectiveHorizontalPadding);

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
                            style: TextStyle(color: iconFg.withOpacity(0.6), fontSize: 18),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.symmetric(horizontal: effectiveHorizontalPadding, vertical: 10),
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
                        padding: const EdgeInsets.only(bottom: _kAttachmentBarMarginBottom),
                        child: _buildAttachmentBar(targetInputWidth, effectiveHorizontalPadding, textColor, accent),
                      ),
                    _buildSearchBar(isCompactMode: isCompactModeForModelDropdown), // Pass the local variable
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentBar(
      double contentWidth, double horizontalPadding, Color textColor, Color accentColor) {
    return Container(
      width: contentWidth,
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
          children:
              _attachedFiles.map((file) => _buildAttachmentChip(file, textColor, accentColor)).toList(),
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
      width: double.infinity,
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
                isCompactMode: isCompactMode, // Corrected: Use the parameter passed to _buildSearchBar
                compactLabel: '#',
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
