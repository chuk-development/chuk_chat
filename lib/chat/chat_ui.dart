// lib/chat/chat_ui.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ui_elements_flutter/constants.dart';
import 'package:ui_elements_flutter/models/chat_model.dart';
import 'package:ui_elements_flutter/services/chat_storage_service.dart';
import 'package:ui_elements_flutter/widgets/message_bubble.dart';
import 'package:ui_elements_flutter/pages/voice_mode_page.dart'; // For the voice mode button

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
  String _selectedModel = 'Sonar';

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
                  Text('chuk.chat', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w300, color: iconFg)),
                  const SizedBox(height: 20),
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
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VoiceModePage()),
                ),
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
            children: [
              _buildIconBtn(Icons.add, () => print('Add')),
              const SizedBox(width: 8),
              _buildIconBtn(Icons.psychology, () => print('Brain')),
              const SizedBox(width: 8),
              _buildIconBtn(Icons.image, () => print('Image')),
              const Spacer(),
              _buildModelDropdown(),
              const SizedBox(width: 8),
              _buildIconBtn(Icons.mic, () => print('Mic')),
              const SizedBox(width: 8),
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

  Widget _buildIconBtn(IconData icon, VoidCallback onTap) => Container(
        width: 44,
        height: 36,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: iconFg.withOpacity(.3), width: .8),
        ),
        child: IconButton(icon: Icon(icon, color: iconFg, size: 20), onPressed: onTap),
      );

  Widget _buildModelDropdown() {
    final models = <ModelItem>[
      ModelItem(name: 'Best', isToggle: true, value: 'best'),
      ModelItem(name: 'gpt-oss-120b', value: 'gpt-oss-120b'),
      ModelItem(name: 'Qwen3 235B A22B Thinking 2507', value: 'qwen3-235b-a22b-thinking-2507'),
      ModelItem(name: 'Qwen: Qwen3 Coder 480B A35B', value: 'qwen3-coder'),
      ModelItem(name: 'Qwen: Qwen3 235B A22B Instruct 2507', value: 'qwen3-235b-a22b-2507', badge: 'max'),
      ModelItem(name: 'Qwen: Qwen3 32B', value: 'qwen3-32b'),
      ModelItem(name: 'GPT-5', value: 'gpt_5', badge: 'new'),
      ModelItem(name: 'GPT-5 Thinking', value: 'gpt_5_thinking', badge: 'new'),
      ModelItem(name: 'o3', value: 'o3'),
      ModelItem(name: 'o3-pro', value: 'o3_pro', badge: 'max'),
      ModelItem(name: 'Grok 4', value: 'grok_4'),
    ];

    return PopupMenuButton<String>(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withOpacity(.3)),
      ),
      icon: Container(
        width: 44,
        height: 36,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: iconFg.withOpacity(.3), width: .8),
        ),
        child: Icon(Icons.grid_3x3, color: iconFg, size: 20),
      ),
      onSelected: (v) {
        setState(() => _selectedModel = models.firstWhere((m) => m.value == v).name);
        Future.delayed(Duration.zero, () => _textFieldFocusNode.requestFocus());
      },
      itemBuilder: (_) => models.map((m) {
        final selected = _selectedModel == m.name;
        return PopupMenuItem<String>(
          value: m.value,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (m.isToggle)
                Row(
                  children: [
                    Switch(value: selected, onChanged: (_) {}, activeColor: iconFg),
                    const SizedBox(width: 6),
                    Text('Best', style: TextStyle(color: iconFg)),
                  ],
                )
              else
                Text(m.name, style: TextStyle(color: selected ? iconFg : iconFg.withOpacity(.8))),
              const Spacer(),
              if (!m.isToggle && selected) Icon(Icons.check, color: iconFg, size: 18),
              if (m.badge != null)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: m.badge == 'new' ? Colors.teal : Colors.orange,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(m.badge!, style: const TextStyle(color: Colors.white, fontSize: 10)),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }
}