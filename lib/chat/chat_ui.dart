// lib/chat/chat_ui.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math; // Import for math.min
import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/models/chat_model.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';
import 'package:ui_elements_flutter/widgets/message_bubble.dart';
import 'package:ui_elements_flutter/pages/voice_mode_page.dart';
import 'package:ui_elements_flutter/widgets/model_selection_dropdown.dart';

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
    // Get colors from theme for general elements, but the search bar's internal TextField is overridden
    // to match the original "transparent" text input field.
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
        border: Border.all(color: iconFg.withOpacity(.3)),
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
                      hintText: 'Ask anything or @mention a Space',
                      hintStyle: TextStyle(color: iconFg.withOpacity(.8)),
                      border: InputBorder.none, // Crucially, no border
                      enabledBorder: InputBorder.none, // No border when enabled
                      focusedBorder: InputBorder.none, // No border when focused
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: false, // Explicitly set to false to remove background fill
                      fillColor: Colors.transparent, // Ensure transparent background
                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                      isDense: true, // Keep it compact
                    ),
                    cursorColor: iconFg,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Dieser Button sendet nun die Nachricht
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
              _buildIconBtn(Icons.add, () => print('Add')),
              const SizedBox(width: 8),
              _buildIconBtn(Icons.psychology, () => print('Brain')),
              const SizedBox(width: 8),
              _buildIconBtn(Icons.image, () => print('Image')),
              const Spacer(),
              // Verwende das neue ModelSelectionDropdown Widget
              ModelSelectionDropdown(
                initialSelectedModel: _selectedModel,
                onModelSelected: (newModel) {
                  setState(() {
                    _selectedModel = newModel; // Aktualisiere _selectedModel im Parent-Widget
                  });
                },
                textFieldFocusNode: _textFieldFocusNode,
                isCompactMode: isCompactMode,
              ),
              const SizedBox(width: 8), // Konsistenter 8px Abstand
              _buildIconBtn(Icons.mic, () => print('Mic')),
              const SizedBox(width: 8),
              // Dieser Button bleibt für den Voice Mode
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

  Widget _buildIconBtn(IconData icon, VoidCallback onTap) {
    // Get colors from theme here for this widget
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFg = Theme.of(context).iconTheme.color!;

    // Verwendet einen ValueNotifier, um den Hover-Zustand für die Randanimation zu verwalten
    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashFactory: InkRipple.splashFactory, // Standard Ripple-Effekt
        hoverColor: Colors.transparent, // Keine Hintergrundfüllung beim Hover
        highlightColor: Colors.transparent, // Keine Hintergrundfüllung beim Highlight
        child: ValueListenableBuilder<bool>(
          valueListenable: isHovered,
          builder: (context, hovered, child) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              width: 44,
              height: 36,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: hovered ? iconFg : iconFg.withOpacity(.3), // Dickerer/hellerer Rand beim Hover
                  width: hovered ? 1.2 : 0.8,
                ),
              ),
              child: Icon(icon, color: iconFg, size: 20),
            );
          },
        ),
      ),
    );
  }
}