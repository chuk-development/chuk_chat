import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'voice_mode.dart';

/* ---------- COLOURS ---------- */
const Color bg     = Color(0xFF211B15);   // 33 27 21
const Color accent = Color(0xFF3F5E5D);   // 70 99 93
const Color iconFg = Color(0xFF93854C);   //147 133 76

/* ---------- THEME ---------- */
final appTheme = ThemeData.dark().copyWith(
  scaffoldBackgroundColor: bg,
  cardColor: bg,
  dividerColor: iconFg.withOpacity(.4),
  iconTheme: const IconThemeData(color: iconFg),
  colorScheme: const ColorScheme.dark(primary: accent, secondary: iconFg, surface: bg),
);

/* ---------- MODEL ITEM ---------- */
class ModelItem {
  final String name;
  final String value;
  final bool isToggle;
  final String? badge;

  ModelItem({required this.name, required this.value, this.isToggle = false, this.badge});
}

/* ---------- MAIN ---------- */
void main() => runApp(const ChukChatApp());

class ChukChatApp extends StatelessWidget {
  const ChukChatApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) => MaterialApp(title: 'chuk.chat', debugShowCheckedModeBanner: false, theme: appTheme, home: const RootWrapper());
}

/* ---------- DATA ---------- */
List<String> _savedChats = [];

Future<void> _loadChats() async {
  final prefs = await SharedPreferences.getInstance();
  _savedChats = prefs.getStringList('savedChats') ?? [];
}

Future<void> _saveChat(String json) async {
  final prefs = await SharedPreferences.getInstance();
  _savedChats.add(json);
  await prefs.setStringList('savedChats', _savedChats);
}

/* ---------- ROOT WRAPPER ---------- */
class RootWrapper extends StatefulWidget {
  const RootWrapper({Key? key}) : super(key: key);
  @override
  State<RootWrapper> createState() => _RootWrapperState();
}

class _RootWrapperState extends State<RootWrapper> {
  bool _sidebarOpen = false;
  final GlobalKey<ScaffoldState> _key = GlobalKey();

  Future<void> _loadSidebar() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _sidebarOpen = prefs.getBool('sidebarOpen') ?? false);
  }

  Future<void> _saveSidebar(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sidebarOpen', val);
    setState(() => _sidebarOpen = val);
  }

  @override
  void initState() {
    super.initState();
    _loadSidebar();
    _loadChats();
  }

  void _openSettingsPage() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  @override
  Widget build(BuildContext context) {
    final drawerWidth = MediaQuery.of(context).size.width * 0.75;
    return Scaffold(
      key: _key,
      drawerEnableOpenDragGesture: true,
      drawer: SizedBox(
        width: drawerWidth,
        child: Container(
          color: bg,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 48, 16, 20),
                color: bg,
                child: const Text('chuk.chat', style: TextStyle(fontSize: 22)),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: _savedChats.length,
                  itemBuilder: (_, i) {
                    final title = 'Chat ${i + 1}';
                    return ListTile(
                      leading: const Icon(Icons.chat_bubble_outline, size: 20),
                      title: Text(title, style: const TextStyle(color: iconFg)),
                      dense: true,
                      onTap: () {/* load / view */},
                    );
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text('Settings'),
                onTap: () {
                  Navigator.pop(context);
                  _openSettingsPage();
                },
              ),
            ],
          ),
        ),
      ),
      body: ChukChatUI(
        sidebarOpen: _sidebarOpen,
        onToggleSidebar: () => _saveSidebar(!_sidebarOpen),
      ),
    );
  }
}

/* ---------- CHAT UI ---------- */
class ChukChatUI extends StatefulWidget {
  final bool sidebarOpen;
  final VoidCallback onToggleSidebar;
  const ChukChatUI({Key? key, required this.sidebarOpen, required this.onToggleSidebar}) : super(key: key);

  @override
  State<ChukChatUI> createState() => _ChukChatUIState();
}

class _ChukChatUIState extends State<ChukChatUI> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  late AnimationController _animCtrl;
  late Animation<double> _anim;
  String _selectedModel = 'Sonar';

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(duration: const Duration(milliseconds: 200), vsync: this);
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  /* ---------- NEW CHAT ---------- */
  void _newChat() async {
    if (_messages.isNotEmpty) {
      final json = _messages.map((m) => '${m['sender']}|${m['text']}').join('§');
      await _saveChat(json);
    }
    setState(() {
      _messages.clear();
      _animCtrl.reset();
    });
    _focusNode.requestFocus();
  }

  /* ---------- SEND MESSAGE ---------- */
  void _sendMessage() {
    if (_controller.text.trim().isEmpty) return;
    final first = _messages.isEmpty;
    setState(() {
      _messages.add({'sender': 'user', 'text': _controller.text});
      _controller.clear();
    });
    if (first) _animCtrl.forward();
    _focusNode.requestFocus();
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
        _focusNode.requestFocus();
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
          /* ---- TOP CONTROLS ---- */
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_square),
                    tooltip: 'New chat',
                    onPressed: _newChat,
                  ),
                  const SizedBox(height: 4),
                  IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: widget.onToggleSidebar,
                  ),
                ],
              ),
            ),
          ),
          /* ---- EMPTY STATE ---- */
          if (_messages.isEmpty)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('chuk.chat', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w300)),
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
          /* ---- BOTTOM SEARCH BAR ---- */
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
    const btnH = 36.0, btnW = 44.0, radius = 10.0;
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
          Flexible(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: RawKeyboardListener(
                    focusNode: FocusNode(),
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
                      focusNode: _focusNode,
                      autofocus: true,
                      minLines: 1,
                      maxLines: null,
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
                      onTap: () => _focusNode.requestFocus(),
                      onSubmitted: (_) => _focusNode.requestFocus(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VoiceMode()),
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
          ),
          const SizedBox(height: 8),
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
                  MaterialPageRoute(builder: (_) => const VoiceMode()),
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
        Future.microtask(() => _focusNode.requestFocus());
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
                    const Text('Best', style: TextStyle(color: iconFg)),
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

/* ---------- MESSAGE BUBBLE ---------- */
class MessageBubble extends StatelessWidget {
  final String message;
  final bool isUser;
  const MessageBubble({Key? key, required this.message, required this.isUser}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? accent.withOpacity(.8) : bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: iconFg.withOpacity(.3)),
        ),
        child: Text(message, style: TextStyle(color: iconFg)),
      ),
    );
  }
}

/* ---------- SETTINGS PAGE ---------- */
class SettingsPage extends StatelessWidget {
  const SettingsPage({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: bg,
        appBar: AppBar(title: const Text('Settings'), backgroundColor: bg, elevation: 0),
        body: const Center(child: Text('Settings page – add options here', style: TextStyle(color: iconFg))),
      );
}