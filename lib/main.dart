import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'chuk.chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const PerplexityProUI(),
    );
  }
}

class PerplexityProUI extends StatefulWidget {
  const PerplexityProUI({Key? key}) : super(key: key);

  @override
  State<PerplexityProUI> createState() => _PerplexityProUIState();
}

class _PerplexityProUIState extends State<PerplexityProUI> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  String _selectedModel = "Sonar";
  
  // Animation controller for smoother transitions
  late AnimationController _animationController;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    
    // Set up animation controller for UI transitions
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );
    
    // Request focus when the app starts
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    if (_controller.text.trim().isNotEmpty) {
      final String userMessage = _controller.text;
      
      // If this is the first message, start the animation
      bool isFirstMessage = _messages.isEmpty;
      
      // Add the message first
      setState(() {
        _messages.add({'sender': 'user', 'text': userMessage});
        _controller.clear();
      });
      
      // Run animation if this is the first message
      if (isFirstMessage) {
        // Explicitly request focus before animation starts
        _focusNode.requestFocus();
        _animationController.forward();
      }

      // Ensure focus is maintained
      _focusNode.requestFocus();

      // Simulate AI response
      Future.delayed(const Duration(milliseconds: 300), () {
        setState(() {
          _messages.add(
              {'sender': 'ai', 'text': "You said: $userMessage (Model: $_selectedModel)"});
        });
        
        // Scroll to bottom after a short delay
        Future.delayed(const Duration(milliseconds: 50), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
          // Request focus again after scrolling
          _focusNode.requestFocus();
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color darkBackground = Color(0xFF1E1E1E);
    const double baseContentWidth = 600;
    const double expandedWidthIncrease = 160;

    // Use animation value for smoother transition
    final double dynamicContentWidth = _messages.isEmpty 
        ? baseContentWidth 
        : baseContentWidth + (expandedWidthIncrease * _animation.value);

    const double bottomBarTotalHeight = 16.0 + 135.0 + 16.0;

    return Scaffold(
      backgroundColor: darkBackground,
      body: GestureDetector(
        // Add this to maintain focus when tapping outside the text field
        onTap: () {
          FocusScope.of(context).unfocus();
          _focusNode.requestFocus();
        },
        child: Stack(
          children: [
            if (_messages.isEmpty)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'chuk.chat',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: dynamicContentWidth,
                      child: _buildSearchBar(),
                    ),
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
                    constraints: BoxConstraints(maxWidth: dynamicContentWidth),
                    child: ListView.builder(
                      controller: _scrollController,
                      reverse: false,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final messageData = _messages[index];
                        final bool isUserMessage = messageData['sender'] == 'user';
                        return MessageBubble(
                          message: messageData['text']!,
                          isUser: isUserMessage,
                        );
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
                  padding: const EdgeInsets.all(16.0),
                  width: dynamicContentWidth,
                  child: _buildSearchBar(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    const double buttonBorderRadius = 10.0;
    final Border buttonBorder = Border.all(color: Colors.grey[700]!, width: 0.8);
    const double buttonHeight = 36.0;
    const double iconButtonWidth = 44.0;

    const double verticalEdgePadding = 14.0;
    const double textFieldVerticalContentPadding = 8.0;

    return Container(
      height: 135,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[800]!),
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
                            final TextEditingValue value = _controller.value;
                            final TextSelection selection = value.selection;
                            final String newText = value.text.replaceRange(
                              selection.start,
                              selection.end,
                              '\n',
                            );
                            _controller.value = value.copyWith(
                              text: newText,
                              selection: TextSelection.collapsed(offset: selection.start + 1),
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
                      minLines: 1,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.send,
                      autofocus: true, // Set autofocus to true
                      decoration: const InputDecoration(
                        hintText: 'Ask anything or @mention a Space',
                        hintStyle: TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          vertical: textFieldVerticalContentPadding,
                          horizontal: 0,
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: (_) {
                        // Ensure focus is maintained after submission
                        _focusNode.requestFocus();
                      },
                      onTap: () {
                        // Ensure selection is preserved when tapping
                        _focusNode.requestFocus();
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    _sendMessage();
                    // Request focus immediately after tap
                    _focusNode.requestFocus();
                  },
                  child: Container(
                    width: iconButtonWidth,
                    height: buttonHeight,
                    decoration: BoxDecoration(
                      color: const Color.fromARGB(255, 194, 18, 18),
                      borderRadius: BorderRadius.circular(buttonBorderRadius),
                    ),
                    child: const Icon(
                      Icons.arrow_upward,
                      color: Colors.black,
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
                onPressed: () {
                  print("Add button tapped!");
                  _focusNode.requestFocus(); // Maintain focus
                },
                borderRadius: buttonBorderRadius,
                border: buttonBorder,
                height: buttonHeight,
                width: iconButtonWidth,
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.psychology,
                onPressed: () {
                  print("Thinking button tapped!");
                  _focusNode.requestFocus(); // Maintain focus
                },
                borderRadius: buttonBorderRadius,
                border: buttonBorder,
                height: buttonHeight,
                width: iconButtonWidth,
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.image,
                onPressed: () {
                  print("Image generation button tapped!");
                  _focusNode.requestFocus(); // Maintain focus
                },
                borderRadius: buttonBorderRadius,
                border: buttonBorder,
                height: buttonHeight,
                width: iconButtonWidth,
              ),
              const Spacer(),
              _buildModelSelectionDropdown(
                buttonBorderRadius: buttonBorderRadius,
                buttonBorder: buttonBorder,
                buttonHeight: buttonHeight,
                buttonWidth: iconButtonWidth,
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.mic,
                onPressed: () {
                  print("Mic button tapped!");
                  _focusNode.requestFocus(); // Maintain focus
                },
                borderRadius: buttonBorderRadius,
                border: buttonBorder,
                height: buttonHeight,
                width: iconButtonWidth,
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  print("Voice mode button clicked");
                  _focusNode.requestFocus(); // Maintain focus
                },
                child: Container(
                  width: iconButtonWidth,
                  height: buttonHeight,
                  decoration: BoxDecoration(
                    color: const Color.fromARGB(255, 194, 18, 18),
                    borderRadius: BorderRadius.circular(buttonBorderRadius),
                  ),
                  child: const Icon(
                    Icons.graphic_eq,
                    color: Colors.black,
                    size: 24,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    required double borderRadius,
    required Border border,
    required double height,
    required double width,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(borderRadius),
        border: border,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 20),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildCustomButton({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
    bool isDropdown = false,
    required double borderRadius,
    required Border border,
    required double height,
    double horizontalPadding = 12.0,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(borderRadius),
          border: border,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            if (isDropdown) ...[
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 20),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModelSelectionDropdown({
    required double buttonBorderRadius,
    required Border buttonBorder,
    required double buttonHeight,
    required double buttonWidth,
  }) {
    final List<Map<String, dynamic>> models = [
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
      color: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey[800]!),
      ),
      icon: Container(
        width: buttonWidth,
        height: buttonHeight,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(buttonBorderRadius),
          border: buttonBorder,
        ),
        child: const Icon(Icons.grid_3x3, color: Colors.white, size: 20),
      ),
      onSelected: (String newValue) {
        setState(() {
          _selectedModel = models.firstWhere((model) => model['value'] == newValue)['name'];
          if (newValue == 'best') {
            // Handle toggle logic for "Best" if needed
          }
        });
        // Ensure focus is maintained after selection
        Future.microtask(() => _focusNode.requestFocus());
      },
      itemBuilder: (BuildContext context) {
        return models.map((model) {
          bool isSelected = _selectedModel == model['name'];
          return PopupMenuItem<String>(
            value: model['value'],
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (model['isToggle'] == true)
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context, model['value']);
                    },
                    child: Row(
                      children: [
                        Switch(
                          value: isSelected,
                          onChanged: (bool value) {},
                          activeColor: Colors.cyan[300],
                        ),
                        const Text(
                          'Best',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Text(
                    model['name']!,
                    style: TextStyle(
                      color: isSelected ? Colors.cyan[300] : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                const Spacer(),
                if (model['isToggle'] != true && isSelected)
                  Icon(Icons.check, color: Colors.cyan[300], size: 18),
                if (model['badge'] != null)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color:
                          model['badge'] == 'new' ? Colors.teal[700] : Colors.orange[700],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      model['badge']!,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
              ],
            ),
          );
        }).toList();
      },
    );
  }
}

class MessageBubble extends StatelessWidget {
  final String message;
  final bool isUser;

  const MessageBubble({
    Key? key,
    required this.message,
    required this.isUser,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? Colors.blue[700] : Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: const TextStyle(color: Colors.white),
            ),
            if (isUser) ...[
              const SizedBox(width: 8),
              const Icon(Icons.graphic_eq, color: Colors.white, size: 18),
            ],
          ],
        ),
      ),
    );
  }
}