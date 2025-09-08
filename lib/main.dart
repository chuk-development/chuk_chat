import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/* ---------- COLOR PALETTE ---------- */
const Color c1 = Color.fromARGB(255, 37, 30, 24);      // almost black
const Color c2 = Color.fromARGB(255, 147, 133, 129);   // warm grey
const Color c3 = Color.fromARGB(255, 70, 99, 98);       // teal-ish
const Color c4 = Color.fromARGB(255, 76, 89, 107);      // slate
const Color c5 = Color.fromARGB(255, 197, 213, 228);    // light blue-grey

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'chuk.chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: c1,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const PerplexityProUI(),
    );
  }
}

/* ---------- ROOT PAGE ---------- */
class PerplexityProUI extends StatefulWidget {
  const PerplexityProUI({Key? key}) : super(key: key);
  @override
  State<PerplexityProUI> createState() => _PerplexityProUIState();
}

class _PerplexityProUIState extends State<PerplexityProUI>
    with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final FocusNode _sidebarFocus = FocusNode();

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  String _selectedModel = "Sonar";

  late AnimationController _animationController;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      // first message animation starts when needed
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _sidebarFocus.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    if (_controller.text.trim().isEmpty) return;

    final String userMsg = _controller.text;
    final isFirst = _messages.isEmpty;

    setState(() {
      _messages.add({'sender': 'user', 'text': userMsg});
      _controller.clear();
    });

    if (isFirst) _animationController.forward();

    _focusNode.requestFocus();

    Future.delayed(const Duration(milliseconds: 300), () {
      setState(() {
        _messages.add({'sender': 'ai', 'text': "You said: $userMsg\n(Model: $_selectedModel)"});
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

  /* ---------- SIDEBAR ---------- */

  void _openSettings() {
    _scaffoldKey.currentState?.openEndDrawer();
    Future.microtask(() => _sidebarFocus.requestFocus());
  }

  Widget _settingsDrawer() {
    final recent = <String>[
      'How to cook pasta',
      'Flutter vs React Native',
      'Explain async-await',
      'Best coffee beans',
      'Top 10 sci-fi movies',
    ];

    return Container(
      width: MediaQuery.of(context).size.width * 0.75,
      color: c3.withOpacity(0.1),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: c3,
              width: double.infinity,
              child: const Text(
                'Settings',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                'Recent Chats',
                style: TextStyle(color: c5.withOpacity(0.8)),
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: recent.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => ListTile(
                  leading: const Icon(Icons.chat_bubble_outline, size: 20, color: c4),
                  title: Text(recent[i], style: const TextStyle(color: c2)),
                  dense: true,
                  onTap: () => Navigator.pop(context), // close on selection
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: c2.withOpacity(0.5)),
                  foregroundColor: c2,
                ),
                icon: const Icon(Icons.info_outline),
                label: const Text('About'),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /* ---------- MAIN UI ---------- */

  @override
  Widget build(BuildContext context) {
    const double baseContentWidth = 600;
    const double expandedWidthIncrease = 160;
    const double bottomBarTotalHeight = 16 + 135 + 16;

    final double dynamicWidth = _messages.isEmpty
        ? baseContentWidth
        : baseContentWidth + expandedWidthIncrease * _animation.value;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c1,
      endDrawerEnableOpenDragGesture: true,
      endDrawer: Drawer(
        backgroundColor: Colors.transparent,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: _settingsDrawer(),
      ),
      body: Stack(
        children: [
          // BACKDROP
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [c1, c4.withOpacity(0.2)],
              ),
            ),
          ),

          // CONTENT
          if (_messages.isEmpty)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'chuk.chat',
                    style: TextStyle(
                      color: c5,
                      fontSize: 32,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(width: dynamicWidth, child: _buildSearchBar()),
                ],
              ),
            ),

          if (_messages.isNotEmpty)
            Positioned.fill(
              top: bottomBarTotalHeight,
              bottom: bottomBarTotalHeight,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  constraints: BoxConstraints(maxWidth: dynamicWidth),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      return MessageBubble(
                        message: m['text']!,
                        isUser: m['sender'] == 'user',
                      );
                    },
                  ),
                ),
              ),
            ),

          // BOTTOM TEXT AREA
          if (_messages.isNotEmpty)
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.all(16),
                width: dynamicWidth,
                child: _buildSearchBar(),
              ),
            ),

          // TOP-RIGHT SETTINGS BUTTON
          Positioned(
            top: 16,
            right: 16,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.settings, color: c5),
                onPressed: _openSettings,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /* ---------- TEXT BAR ---------- */

  Widget _buildSearchBar() {
    const double buttonBorderRadius = 10;
    final Border buttonBorder = Border.all(color: c2.withOpacity(0.4), width: 0.8);
    const double buttonHeight = 36;
    const double iconButtonWidth = 44;

    const double verticalEdgePadding = 14;
    const double textFieldVerticalContentPadding = 8;

    return Container(
      height: 135,
      decoration: BoxDecoration(
        color: c3.withOpacity(0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c2.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: verticalEdgePadding,
      ),
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
                            final t = v.text.replaceRange(
                              v.selection.start,
                              v.selection.end,
                              '\n',
                            );
                            _controller.value = v.copyWith(
                              text: t,
                              selection: TextSelection.collapsed(
                                offset: v.selection.start + 1,
                              ),
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
                      style: const TextStyle(color: c5),
                      decoration: const InputDecoration(
                        hintText: 'Ask anything or @mention a Space',
                        hintStyle: TextStyle(color: c2),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          vertical: textFieldVerticalContentPadding,
                          horizontal: 0,
                        ),
                      ),
                      onTap: () => _focusNode.requestFocus(),
                      onSubmitted: (_) => _focusNode.requestFocus(),
                      cursorColor: c5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _sendMessage,
                  child: Container(
                    width: iconButtonWidth,
                    height: buttonHeight,
                    decoration: BoxDecoration(
                      color: c4,
                      borderRadius: BorderRadius.circular(buttonBorderRadius),
                    ),
                    child: const Icon(
                      Icons.arrow_upward,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildIconButton(
                icon: Icons.add,
                onPressed: () => print('Add'),
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.psychology,
                onPressed: () => print('Brain'),
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.image,
                onPressed: () => print('Image'),
              ),
              const Spacer(),
              _buildModelSelectionDropdown(),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.mic,
                onPressed: () => print('Mic'),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => print('Voice'),
                child: Container(
                  width: iconButtonWidth,
                  height: buttonHeight,
                  decoration: BoxDecoration(
                    color: c4,
                    borderRadius: BorderRadius.circular(buttonBorderRadius),
                  ),
                  child: const Icon(Icons.graphic_eq, color: Colors.white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /* ---------- BUTTON BUILDERS ---------- */

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    double borderRadius = 10,
    double height = 36,
    double width = 44,
  }) =>
      Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: c4.withOpacity(0.4),
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(color: c2.withOpacity(0.3), width: 0.8),
        ),
        child: IconButton(
          icon: Icon(icon, color: c5, size: 20),
          onPressed: onPressed,
        ),
      );

  Widget _buildModelSelectionDropdown() {
    List<Map<String, dynamic>> models = [
      {'name': 'Best', 'isToggle': true, 'value': 'best'},
      {'name': 'gpt-oss-120b', 'value': 'gpt-oss-120b'},
      {'name': 'Qwen3 235B A22B Thinking 2507', 'value': 'qwen3-235b-a22b-thinking-2507'},
      {'name': 'Qwen: Qwen3 Coder 480B A35B', 'value': 'qwen3-coder'},
      {'name': 'Qwen: Qwen3 235B A22B Instruct 2507', 'value': 'qwen3-235b-a22b-2507', 'badge': 'max'},
      {'name': 'Qwen: Qwen3 32B', 'value': 'qwen3-32b'},
      {'name': 'GPT-5', 'value': 'gpt_5', 'badge': 'new'},
      {'name': 'GPT-5 Thinking', 'value': 'gpt_5_thinking', 'badge': 'new'},
      {'name': 'o3', 'value': 'o3'},
      {'name': 'o3-pro', 'value': 'o3_pro', 'badge': 'max'},
      {'name': 'Grok 4', 'value': 'grok_4'},
    ];

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      color: c3.withOpacity(0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c2.withOpacity(0.3)),
      ),
      icon: Container(
        width: 44,
        height: 36,
        decoration: BoxDecoration(
          color: c4.withOpacity(0.4),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c2.withOpacity(0.3), width: 0.8),
        ),
        child: const Icon(Icons.grid_3x3, color: c5, size: 20),
      ),
      onSelected: (v) {
        setState(() {
          _selectedModel = models.firstWhere((m) => m['value'] == v)['name'];
        });
        Future.microtask(() => _focusNode.requestFocus());
      },
      itemBuilder: (context) => models.map((model) {
        final isSelected = _selectedModel == model['name'];
        return PopupMenuItem<String>(
          value: model['value'],
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (model['isToggle'] == true)
                Row(
                  children: [
                    Switch(
                      value: isSelected,
                      onChanged: (_) {},
                      activeColor: c5,
                    ),
                    const SizedBox(width: 6),
                    const Text('Best', style: TextStyle(color: c2)),
                  ],
                )
              else
                Text(model['name']!, style: TextStyle(color: isSelected ? c5 : c2)),
              const Spacer(),
              if (model['isToggle'] != true && isSelected)
                Icon(Icons.check, color: c5, size: 18),
              if (model['badge'] != null)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: model['badge'] == 'new' ? Colors.teal : Colors.orange,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(model['badge']!, style: const TextStyle(color: Colors.white, fontSize: 10)),
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
          color: isUser ? c4.withOpacity(0.8) : c3.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message,
          style: const TextStyle(color: c5),
        ),
      ),
    );
  }
}