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

class _PerplexityProUIState extends State<PerplexityProUI> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  String _selectedModel = "Sonar"; // Track selected AI model

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    if (_controller.text.trim().isNotEmpty) {
      final String userMessage = _controller.text;
      setState(() {
        _messages.add({'sender': 'user', 'text': userMessage});
        _controller.clear();
      });

      // Simulate AI response
      Future.delayed(const Duration(milliseconds: 500), () {
        setState(() {
          _messages.add(
              {'sender': 'ai', 'text': "You said: $userMessage (Model: $_selectedModel)"});
        });
        Future.delayed(const Duration(milliseconds: 100), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color darkBackground = Color(0xFF1E1E1E);
    const double baseContentWidth = 600;
    const double expandedWidthIncrease = 160;

    final double dynamicContentWidth =
        _messages.isEmpty ? baseContentWidth : baseContentWidth + expandedWidthIncrease;

    const double bottomBarTotalHeight = 16.0 + 135.0 + 16.0;

    return Scaffold(
      backgroundColor: darkBackground,
      body: Stack(
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
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  constraints: BoxConstraints(maxWidth: dynamicContentWidth),
                  child: ListView.builder(
                    controller: _scrollController,
                    reverse: false,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                padding: const EdgeInsets.all(16.0), // This padding contributes to `bottomBarTotalHeight`
                width: dynamicContentWidth,
                child: _buildSearchBar(),
              ),
            ),
        ],
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
      height: 135, // Fixed height for the search bar container
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
                            // Wenn Shift + Enter gedrückt wird, füge einen Zeilenumbruch ein
                            // und verhindere, dass der RawKeyboardListener das Event für Senden verarbeitet.
                            // Wichtig: Der TextField sollte selbst auch nicht versuchen, eine neue Zeile einzufügen,
                            // deshalb haben wir textInputAction auf .send gesetzt.
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
                            // Verhindere, dass das Send-Event ausgelöst wird
                            return;
                          } else {
                            // Nur Enter ohne Shift -> Nachricht senden
                            _sendMessage();
                            // Wichtig: Hier kehren wir nicht zurück, da wir wollen, dass das Event
                            // vom TextField NICHT als neuer Zeilenumbruch behandelt wird.
                            // Durch textInputAction: TextInputAction.send im TextField
                            // sollte das TextField die Enter-Taste nicht als Zeilenumbruch interpretieren.
                          }
                        }
                      }
                    },
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: null, // Allow multiple lines if text exceeds
                      keyboardType: TextInputType.multiline,
                      // WICHTIGE ÄNDERUNG: Setze textInputAction auf .send, damit die Enter-Taste
                      // nicht automatisch einen Zeilenumbruch erzeugt.
                      textInputAction: TextInputAction.send,
                      decoration: InputDecoration(
                        hintText: 'Ask anything or @mention a Space',
                        hintStyle: const TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          vertical: textFieldVerticalContentPadding,
                          horizontal: 0,
                        ),
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Send Button
                GestureDetector(
                  onTap: _sendMessage,
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
                onPressed: () => print("Add button tapped!"),
                borderRadius: buttonBorderRadius,
                border: buttonBorder,
                height: buttonHeight,
                width: iconButtonWidth,
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.psychology, // brain icon
                onPressed: () => print("Thinking (brain) button tapped!"),
                borderRadius: buttonBorderRadius,
                border: buttonBorder,
                height: buttonHeight,
                width: iconButtonWidth,
              ),
              const SizedBox(width: 8),
              _buildIconButton(
                icon: Icons.image,
                onPressed: () => print("Image generation button tapped!"),
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
                onPressed: () => print("Mic button tapped!"),
                borderRadius: buttonBorderRadius,
                border: buttonBorder,
                height: buttonHeight,
                width: iconButtonWidth,
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  print("Voice mode button clicked, functionality not available in standalone mode.");
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