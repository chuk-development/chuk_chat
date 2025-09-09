// lib/chat/chat_ui.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/models/chat_model.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';
import 'package:ui_elements_flutter/widgets/message_bubble.dart';
import 'package:ui_elements_flutter/pages/voice_mode_page.dart'; // For the voice mode button
// Importiere das neue ModelSelectionDropdown widget
import 'package:ui_elements_flutter/widgets/model_selection_dropdown.dart';

/* ---------- CHAT UI ---------- */
class ChukChatUI extends StatefulWidget {
  final VoidCallback onToggleSidebar;
  final int selectedChatIndex;
  final bool isSidebarExpanded;

  const ChukChatUI({
    Key? key,
    required this.onToggleSidebar,
    required this.selectedChatIndex,
    required this.isSidebarExpanded,
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
    const baseW = 600.0, extraW = 160.0, bottomH = 16.0 + 135.0 + 16.0;
    final dynamicW = _messages.isEmpty ? baseW : baseW + extraW * _anim.value;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (_messages.isEmpty)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Removed the 'chuk.chat' text here
                  SizedBox(width: dynamicW, child: _buildSearchBar()),
                ],
              ),
            )
          else
            Positioned.fill(
              top: bottomH,
              bottom: bottomH,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  constraints: BoxConstraints(maxWidth: dynamicW),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      return MessageBubble(message: m['text']!, isUser: m['sender'] == 'user');
                    },
                  ),
                ),
              ),
            ),
          if (_messages.isNotEmpty)
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.all(16),
                width: dynamicW,
                child: _buildSearchBar(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    const btnH = 36.0, btnW = 44.0;
    return Container(
      height: 135,
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
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
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