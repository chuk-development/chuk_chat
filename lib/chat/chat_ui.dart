// lib/chat/chat_ui.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math; // Import for math.min
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/pages/voice_mode_page.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart';

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
  State<ChukChatUI> createState() => ChukChatUIState(); // Made state public for GlobalKey
}

class ChukChatUIState extends State<ChukChatUI> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();

  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _rawKeyboardListenerFocusNode = FocusNode();

  late AnimationController _animCtrl;
  late Animation<double> _anim;
  String _selectedModel = 'Qwen3 235B'; // _selectedModel bleibt hier, da _sendMessage es verwendet

  // NEW: State for the toggle buttons
  bool _isAddActive = false; // Corresponds to Icons.add
  bool _isBrainActive = false; // Corresponds to Icons.psychology
  bool _isImageActive = false; // Corresponds to Icons.image
  bool _isMicActive = false; // Corresponds to Icons.mic


  // Responsive constants
  static const double _kMaxChatContentWidth = 760.0; // Maximale Breite für Chat-Blasen und Suchleiste
  static const double _kSearchBarContentHeight = 135.0; // Die intrinsische Höhe des Inhalts der Suchleiste

  // Responsive horizontale Polsterung
  static const double _kHorizontalPaddingLarge = 16.0; // Standard-Horizontal-Padding für große Bildschirme
  static const double _kHorizontalPaddingSmall = 8.0; // Horizontal-Padding im Kompaktmodus (kleinere Bildschirme)


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
    setState(() {});
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    Future.delayed(const Duration(milliseconds: 50), () {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  // This method is now public for parent widget to call
  void newChat() async {
    if (_messages.isNotEmpty) {
      final json = _messages.map((m) => '${m['sender']}|${m['text']}').join('§');
      await ChatStorageService.saveChat(json);
    }
    setState(() {
      _messages.clear();
      _animCtrl.reset();
      ChatStorageService.selectedChatIndex = -1;
      // Reset button states on new chat
      _isAddActive = false;
      _isBrainActive = false;
      _isImageActive = false;
      _isMicActive = false;
    });
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    await ChatStorageService.loadSavedChatsForSidebar();
  }

  void _sendMessage() {
    if (_controller.text.trim().isEmpty) return;
    final first = _messages.isEmpty;
    setState(() {
      _messages.add({'sender': 'user', 'text': _controller.text});
      _controller.clear();
    });
    if (first) _animCtrl.forward();
    Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
    Future.delayed(const Duration(milliseconds: 300), () {
      setState(() {
        _messages.add({'sender': 'ai', 'text': 'You said: ${_messages.last['text']}\n(Model: $_selectedModel)'});
      });
      Future.delayed(const Duration(milliseconds: 50), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
        Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    // Get colors from theme
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;

    final double effectiveHorizontalPadding = widget.isCompactMode ? _kHorizontalPaddingSmall : _kHorizontalPaddingLarge;
    final double maxPossibleChatContentWidth = math.max(0.0, screenWidth - (effectiveHorizontalPadding * 2));
    final double constrainedChatContentWidth = math.min(_kMaxChatContentWidth, maxPossibleChatContentWidth);
    final double currentChatContentWidth = _messages.isEmpty
        ? constrainedChatContentWidth * (widget.isCompactMode ? 0.95 : 0.8)
        : constrainedChatContentWidth;
    final double searchBarWidgetTotalHeight = _kSearchBarContentHeight + (2 * 14.0);
    final double bottomOffsetForChatList = searchBarWidgetTotalHeight + effectiveHorizontalPadding;


    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (_messages.isEmpty)
            Center(
              child: SizedBox(
                width: currentChatContentWidth,
                child: _buildSearchBar(isCompactMode: widget.isCompactMode),
              ),
            )
          else
            // Chat-Nachrichtenliste
            Positioned(
              top: 0,
              bottom: bottomOffsetForChatList,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  constraints: BoxConstraints(maxWidth: currentChatContentWidth),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.symmetric(horizontal: effectiveHorizontalPadding, vertical: 10),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      return MessageBubble(
                        message: m['text']!,
                        isUser: m['sender'] == 'user',
                        maxWidth: currentChatContentWidth * 0.7,
                      );
                    },
                  ),
                ),
              ),
            ),
          // Suchleiste (immer am unteren Rand, wenn Nachrichten existieren)
          if (_messages.isNotEmpty)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(effectiveHorizontalPadding),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  width: currentChatContentWidth,
                  child: _buildSearchBar(isCompactMode: widget.isCompactMode),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar({required bool isCompactMode}) {
    const btnH = 36.0, btnW = 44.0;
    // Get colors from theme here for this widget
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;

    return Container(
      height: _kSearchBarContentHeight,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: iconFg.withValues(alpha: .3)),
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
                      hintText: 'Ask me anything !',
                      hintStyle: TextStyle(color: iconFg.withValues(alpha: .8)),
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
              // Add Button
              _buildIconBtn(
                icon: Icons.add,
                onTap: () {
                  setState(() => _isAddActive = !_isAddActive);
                  print('Add button toggled: $_isAddActive');
                },
                isActive: _isAddActive,
                debugLabel: 'Add button', // Added debug label
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
                debugLabel: 'Brain button', // Added debug label
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
                debugLabel: 'Image button', // Added debug label
              ),
              const Spacer(),
              // Model Selection Dropdown
              ModelSelectionDropdown(
                initialSelectedModel: _selectedModel,
                onModelSelected: (newModel) {
                  setState(() {
                    _selectedModel = newModel;
                  });
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
                debugLabel: 'Mic button', // Added debug label
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
    String? debugLabel, // New: Optional debug label
  }) {
    // Get current theme colors
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFg = Theme.of(context).iconTheme.color!;

    // Use a ValueNotifier for hover state to preserve existing hover animation
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
            // Determine colors based on isActive state
            final Color effectiveBgColor = isActive ? iconFg : bg; // Active: button is iconFg color
            final Color effectiveIconColor = isActive ? bg : iconFg; // Active: icon is bg color

            // Determine border color based on hover or active state
            final Color effectiveBorderColor = hovered
                ? iconFg // Bright border on hover
                : isActive
                    ? iconFg.withValues(alpha: 0.6) // Slightly muted active border
                    : iconFg.withValues(alpha: .3); // Default border

            final double effectiveBorderWidth = hovered
                ? 1.2
                : isActive
                    ? 1.0 // Slightly thicker active border
                    : 0.8;

            // Debug print for this specific button
            if (debugLabel != null) {
              print('[$debugLabel] isActive: $isActive, effectiveBgColor: $effectiveBgColor, effectiveIconColor: $effectiveIconColor');
            }

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