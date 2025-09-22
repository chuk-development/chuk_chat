// lib/pages/voice_mode_page.dart
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:ui' as ui; // Import for MaskFilter

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/voice_mode_models.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import for color extensions

///  Voice-Mode  –  UI ONLY  –  LifeKit ready
class VoiceModePage extends StatefulWidget {
  const VoiceModePage({Key? key}) : super(key: key);

  @override
  State<VoiceModePage> createState() => _VoiceModePageState();
}

class _VoiceModePageState extends State<VoiceModePage> with TickerProviderStateMixin {
  /* ---------- colours (local overrides to match image) ---------- */
  // Use theme colors but allow local overrides for specific visual effects if needed
  late Color cardBg;
  late Color userMicColor;
  late Color aiVoiceColor;
  late Color accent;
  late Color iconFg;
  late Color bg;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Initialize theme-dependent colors here
    accent = Theme.of(context).colorScheme.primary;
    iconFg = Theme.of(context).iconTheme.color!;
    bg = Theme.of(context).scaffoldBackgroundColor;

    cardBg = bg.lighten(0.05); // A slightly lighter dark for cards based on current bg
    userMicColor = iconFg; // Goldish, from iconFg
    aiVoiceColor = accent; // Bluish-green, from accent
  }


  /* ---------- UI state ---------- */
  bool _listening = false; // mic hot
  bool _thinking = false; // bot typing
  String _transcript = ''; // user words
  String _reply = ''; // bot words
  String _imageUrl = ''; // bot image (dummy)

  // New: Mute, voice, and speed state
  bool _muted = false;
  late VoiceOption _selectedVoice;
  late PersonalityOption _selectedPersonality;
  double _playbackSpeed = 1.2; // Default from image

  // Pop-up dropdown states
  bool _showPersonalityOptions = false;
  bool _showVoiceOptions = false; // New state for voice pop-up

  final List<VoiceOption> _allVoices = [
    VoiceOption(id: VoiceId.ara, name: 'Ara', description: 'Upbeat Female'),
    VoiceOption(id: VoiceId.eve, name: 'Eve', description: 'Soothing Female'),
    VoiceOption(id: VoiceId.leo, name: 'Leo', description: 'British Male'),
    VoiceOption(id: VoiceId.rex, name: 'Rex', description: 'Calm Male'),
    VoiceOption(id: VoiceId.sal, name: 'Sal', description: 'Smooth Male'),
    VoiceOption(id: VoiceId.gork, name: 'Gork', description: 'Lazy Male'),
  ];

  final List<PersonalityOption> _allPersonalities = [
    PersonalityOption(id: PersonalityId.custom, name: 'Custom', icon: Icons.tune),
    PersonalityOption(
        id: PersonalityId.assistant, name: 'Assistant', icon: Icons.assistant_outlined),
    PersonalityOption(id: PersonalityId.therapist, name: '"Therapist"', icon: Icons.healing),
    PersonalityOption(id: PersonalityId.storyteller, name: 'Storyteller', icon: Icons.menu_book),
    PersonalityOption(
        id: PersonalityId.kidsStoryTime, name: 'Kids Story Time', icon: Icons.scale),
    PersonalityOption(
        id: PersonalityId.kidsTriviaGame, name: 'Kids Trivia Game', icon: Icons.emoji_events),
    PersonalityOption(id: PersonalityId.meditation, name: 'Meditation', icon: Icons.self_improvement),
    PersonalityOption(id: PersonalityId.grokDoc, name: 'Grok "Doc"', icon: Icons.medical_services_outlined, canReset: true),
    PersonalityOption(id: PersonalityId.unhinged, name: 'Unhinged', icon: Icons.recycling, isAdultContent: true, canReset: true),
    PersonalityOption(id: PersonalityId.sexy, name: 'Sexy', icon: Icons.local_fire_department, isAdultContent: true),
    PersonalityOption(id: PersonalityId.motivation, name: 'Motivation', icon: Icons.fitness_center, isAdultContent: true),
    PersonalityOption(id: PersonalityId.conspiracy, name: 'Conspiracy', icon: Icons.travel_explore, canReset: true),
    PersonalityOption(id: PersonalityId.romantic, name: 'Romantic', icon: Icons.redeem, isAdultContent: true),
    PersonalityOption(id: PersonalityId.argumentative, name: 'Argumentative', icon: Icons.electric_bolt, isAdultContent: true, canReset: true),
  ];

  /* ---------- animators ---------- */
  late AnimationController _waveCtrl;
  late AnimationController _barCtrl;

  // GlobalKeys for accurate positioning of pop-ups
  final GlobalKey _voiceButtonKey = GlobalKey();
  final GlobalKey _personalityButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
    // Adjusted duration for _barCtrl for a more fluid sci-fi animation
    _barCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();
    _selectedVoice = _allVoices.firstWhere((v) => v.id == VoiceId.ara); // Default to Ara
    _selectedPersonality = _allPersonalities.firstWhere((p) => p.id == PersonalityId.assistant); // Default to Assistant
    _startHotMic(); // auto-start
  }

  /* ---------- auto hot mic ---------- */
  void _startHotMic() {
    setState(() => _listening = true);
    _fakeListen(); // UI dummy
  }

  /* ---------- fake listen 3s → fake reply ---------- */
  void _fakeListen() async {
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    setState(() {
      _listening = false;
      _transcript = 'Hey, show me a picture of a cat';
    });
    _fakeThink();
  }

  void _fakeThink() async {
    setState(() => _thinking = true);
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() {
      _thinking = false;
      _reply = 'Here is a cat for you!';
      _imageUrl = 'https://images.pexels.com/photos/33815055/pexels-photo-33815055.jpeg';
    });
  }

  /* ---------- close ---------- */
  void _close() => Navigator.pop(context);

  @override
  void dispose() {
    _waveCtrl.dispose();
    _barCtrl.dispose();
    super.dispose();
  }

  /* ----------------------------------------------------------
   *  NEW LAYOUT
   * ---------------------------------------------------------- */
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Row(
          children: [
            // LEFT: Voice Mode (visualiser + settings + mic - centered and compact)
            Expanded(
              flex: 1,
              child: Stack(
                // Use stack for pop-up overlays
                children: [
                  Container(
                    color: bg,
                    child: Center(
                      // Center the entire content of the left pane
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min, // Make column content compact
                        children: [
                          // Visualizer (top, smaller)
                          SizedBox(
                            height: 100, // Reduced height for visualizer
                            width: double.infinity,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: _visualiser(),
                            ),
                          ),
                          const SizedBox(height: 24), // Spacing between visualizer and settings
                          // Settings (middle)
                          _bottomSettingsPanel(),
                          const SizedBox(height: 24), // Spacing between settings and mic
                          _bottomMicMainStyle(), // Mic button at the very bottom
                        ],
                      ),
                    ),
                  ),
                  if (_showVoiceOptions) _voiceOptionsOverlay(),
                  if (_showPersonalityOptions) _personalityOptionsOverlay(),
                ],
              ),
            ),
            // RIGHT: Split vertically (top: image, bottom: chat/text)
            Expanded(
              flex: 1,
              child: Column(
                children: [
                  // TOP: Generated image (50%)
                  Expanded(
                    flex: 1,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      child: _imageUrl.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Image.network(
                                  _imageUrl,
                                ),
                              ),
                            )
                          : Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'No image generated',
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                              ),
                            ),
                    ),
                  ),
                  // BOTTOM: Text/chat (50%)
                  Expanded(
                    flex: 1,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Spacer(),
                              IconButton(
                                icon: Icon(Icons.close, color: iconFg),
                                onPressed: _close,
                              ),
                            ],
                          ),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              children: [
                                if (_transcript.isNotEmpty) _userBubble(_transcript),
                                if (_thinking) _botTyping(),
                                if (_reply.isNotEmpty) _botBubble(_reply),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // New Widget to group bottom settings
  Widget _bottomSettingsPanel() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // Voice Selection Button
              _voiceSelectionButton(),
              const SizedBox(width: 8),
              // Personality Selection Button
              _personalitySelectionButton(),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Speed Selector
        _speedSlider(),
      ],
    );
  }

  // Voice Selection Button (now a compact button)
  Widget _voiceSelectionButton() {
    return Expanded(
      child: GestureDetector(
        key: _voiceButtonKey, // Assign GlobalKey
        onTap: () {
          setState(() {
            _showVoiceOptions = !_showVoiceOptions;
            _showPersonalityOptions = false; // Close other pop-ups
          });
        },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _selectedVoice.name,
                style: TextStyle(
                  color: iconFg,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4.0),
                child: Text(
                  '• ${_selectedVoice.description.split(' ')[0]}', // e.g., "Upbeat"
                  style: TextStyle(
                    color: iconFg.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ),
              Icon(
                _showVoiceOptions ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, // Icon points down if open, up if closed (to indicate opening upwards)
                color: iconFg,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Voice Options Overlay (the pop-up "menu") - opens upwards
  Widget _voiceOptionsOverlay() {
    final RenderBox? renderBox = _voiceButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return const SizedBox.shrink();

    final Offset buttonOffset = renderBox.localToGlobal(Offset.zero);
    final Size buttonSize = renderBox.size;
    final double screenHeight = MediaQuery.of(context).size.height;

    // Calculate position for the overlay to open upwards
    // Bottom edge of overlay should be 8px above the button's top edge
    final double bottomPosition = screenHeight - buttonOffset.dy + 8;

    return Positioned(
      bottom: bottomPosition,
      left: buttonOffset.dx,
      width: buttonSize.width, // Match width of the button
      child: Material(
        color: Colors.transparent, // Allows tap outside to close
        child: GestureDetector(
          onTap: () {
            setState(() {
              _showVoiceOptions = false;
            });
          },
          child: Container(
            color: Colors.transparent, // This also needs to be transparent to propagate tap
            alignment: Alignment.bottomCenter, // Align content to bottom for upwards growth
            child: Container(
              constraints: BoxConstraints(maxHeight: screenHeight * 0.3), // Max height to not go off screen
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    spreadRadius: 2,
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _allVoices.map((voice) {
                    final bool isSelected = voice.id == _selectedVoice.id;
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedVoice = voice;
                          _showVoiceOptions = false;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected ? accent.withValues(alpha: 0.2) : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Text(
                              voice.name,
                              style: TextStyle(
                                color: isSelected ? iconFg : iconFg.withValues(alpha: 0.8),
                                fontSize: 16,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 8.0),
                              child: Text(
                                voice.description,
                                style: TextStyle(
                                  color: isSelected ? iconFg.withValues(alpha: 0.7) : iconFg.withValues(alpha: 0.5),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (isSelected) Icon(Icons.check, color: iconFg, size: 20),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Personality Selection Button (now a compact button)
  Widget _personalitySelectionButton() {
    return Expanded(
      child: GestureDetector(
        key: _personalityButtonKey, // Assign GlobalKey
        onTap: () {
          setState(() {
            _showPersonalityOptions = !_showPersonalityOptions;
            _showVoiceOptions = false; // Close other pop-ups
          });
        },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_selectedPersonality.icon, color: iconFg, size: 20),
              const SizedBox(width: 8),
              Text(
                _selectedPersonality.name.split(' ')[0], // Just first word for compactness
                style: TextStyle(
                  color: iconFg,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_selectedPersonality.isAdultContent)
                Padding(
                  padding: const EdgeInsets.only(left: 4.0),
                  child: Text('18+',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              Icon(
                _showPersonalityOptions ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, // Icon points down if open, up if closed
                color: iconFg,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Personality Options Overlay (the "dropdown" itself) - opens upwards
  Widget _personalityOptionsOverlay() {
    final RenderBox? renderBox = _personalityButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return const SizedBox.shrink();

    final Offset buttonOffset = renderBox.localToGlobal(Offset.zero);
    final Size buttonSize = renderBox.size;
    final double screenHeight = MediaQuery.of(context).size.height;

    // Calculate position for the overlay to open upwards
    // Bottom edge of overlay should be 8px above the button's top edge
    final double bottomPosition = screenHeight - buttonOffset.dy + 8;

    return Positioned(
      bottom: bottomPosition,
      left: buttonOffset.dx,
      width: buttonSize.width, // Match width of the button
      child: Material(
        color: Colors.transparent, // Allows tap outside to close
        child: GestureDetector(
          onTap: () {
            setState(() {
              _showPersonalityOptions = false;
            });
          },
          child: Container(
            color: Colors.transparent, // Also needs to be transparent
            alignment: Alignment.bottomCenter, // Align content to bottom for upwards growth
            child: Container(
              constraints: BoxConstraints(maxHeight: screenHeight * 0.4), // Max height to not go off screen
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    spreadRadius: 2,
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _allPersonalities.map((personality) {
                    final bool isSelected = personality.id == _selectedPersonality.id;
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedPersonality = personality;
                          _showPersonalityOptions = false;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected ? accent.withValues(alpha: 0.2) : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(personality.icon, color: iconFg, size: 20),
                            const SizedBox(width: 12),
                            Text(
                              personality.name,
                              style: TextStyle(
                                color: isSelected ? iconFg : iconFg.withValues(alpha: 0.8),
                                fontSize: 16,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            if (personality.isAdultContent)
                              Padding(
                                padding: const EdgeInsets.only(left: 8.0),
                                child: Text('18+',
                                    style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                            const Spacer(),
                            if (isSelected)
                              Icon(Icons.check, color: iconFg, size: 20)
                            else if (personality.canReset)
                              Icon(Icons.refresh, color: iconFg.withValues(alpha: 0.6), size: 20),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Speed Slider Widget (more compact)
  Widget _speedSlider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Container(
        height: 48, // To match the height of other interactive elements
        padding: const EdgeInsets.symmetric(horizontal: 8), // Reduced horizontal padding
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.0,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0), // Smaller thumb
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16.0), // Smaller overlay
                  activeTrackColor: accent,
                  inactiveTrackColor: accent.withValues(alpha: 0.3),
                  thumbColor: iconFg,
                  overlayColor: iconFg.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: _playbackSpeed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 3, // 0.5, 1.0, 1.5, 2.0
                  onChanged: (double value) {
                    setState(() {
                      _playbackSpeed = value;
                    });
                  },
                ),
              ),
            ),
            Container(
              width: 45, // Adjusted width for smaller text
              alignment: Alignment.center,
              child: Text(
                '${_playbackSpeed.toStringAsFixed(1)}x',
                style: TextStyle(color: iconFg, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Use main.dart MessageBubble style for user and bot
  Widget _userBubble(String text) {
    return MessageBubble(
      message: text,
      isUser: false, // User's message appearing on the left in the example chat
      // Removed accentColor, bgColor, iconFgColor as they are now pulled from Theme
    );
  }

  /* ---------- BOT TYPING INDICATOR ---------- */
  Widget _botTyping() {
    return Align(
      alignment: Alignment.centerLeft, // Bot typing on the left
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: .8),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12), // Adjusted for left alignment
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(0),
            const SizedBox(width: 4),
            _dot(1),
            const SizedBox(width: 4),
            _dot(2),
          ],
        ),
      ),
    );
  }

  Widget _dot(int i) => SizedBox(
        width: 6,
        height: 6,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );

  Widget _botBubble(String text) {
    return MessageBubble(
      message: text,
      isUser: true, // Bot's message appearing on the right in the example chat
      // Removed accentColor, bgColor, iconFgColor as they are now pulled from Theme
    );
  }

  /* ---------- COMPLEX VISUALISER / SCI-FI PAINTER ---------- */
  Widget _visualiser() {
    return AnimatedBuilder(
      animation: _barCtrl,
      builder: (_, __) {
        // Determine the active color based on state
        Color activeColor =
            accent.withValues(alpha: 0.3); // Default idle color, subtle accent
        bool isActive = false;
        if (_listening) {
          activeColor = userMicColor;
          isActive = true;
        } else if (_thinking) {
          activeColor = aiVoiceColor;
          isActive = true;
        }

        return CustomPaint(
          painter: _SciFiVisualizerPainter(
              _barCtrl.value, activeColor, isActive), // Pass active state
          size: const Size(double.infinity, double.infinity),
        );
      },
    );
  }

  // Main.dart style bottom mic
  Widget _bottomMicMainStyle() {
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: AnimatedBuilder(
            animation: _waveCtrl,
            builder: (_, __) => CustomPaint(
              painter: _WavePainter(_waveCtrl.value, accent),
              size: const Size(double.infinity, 40),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: 44,
          height: 36,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: IconButton(
            icon: Icon(_muted ? Icons.mic_off : Icons.mic, color: Colors.black, size: 22),
            onPressed: () => setState(() => _muted = !_muted),
            tooltip: _muted ? 'Unmute' : 'Mute',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _muted ? 'Muted' : 'Listening…',
          style: TextStyle(
            color: _muted ? Colors.redAccent : iconFg.withValues(alpha: .8),
            fontWeight: _muted ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

/* ---------- custom wave painter (for mic button) ---------- */
class _WavePainter extends CustomPainter {
  final double value;
  final Color color;
  _WavePainter(this.value, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: .4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path();
    final mid = size.height / 2;
    for (double x = 0; x <= size.width; x += 4) {
      final y = mid + 15 * math.sin((x / size.width) * 6 * math.pi + value * 4 * math.pi);
      x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.value != value;
}

/* ---------- SCI-FI VISUALIZER PAINTER ---------- */
class _SciFiVisualizerPainter extends CustomPainter {
  final double animationValue;
  final Color baseColor;
  final bool isActive;

  _SciFiVisualizerPainter(this.animationValue, this.baseColor, this.isActive);

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    final double maxRadius = 0.4 * math.min(size.width, size.height);

    // Base paint for lines
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = isActive // Apply blur only when active
          ? ui.MaskFilter.blur(ui.BlurStyle.outer, 2.0)
          : null;

    // Draw central pulsing elements
    if (isActive) {
      // Outer ring pulse
      double pulseRadius =
          (5 + 20 * (0.5 + 0.5 * math.sin(animationValue * 2 * math.pi))).clamp(5.0, 25.0);
      linePaint.color = baseColor.withValues(alpha: 0.8);
      canvas.drawCircle(Offset(centerX, centerY), pulseRadius, linePaint);

      // Inner ring pulse
      pulseRadius = (5 + 15 * (0.5 + 0.5 * math.sin(animationValue * 2 * math.pi + math.pi / 2)))
          .clamp(5.0, 20.0);
      linePaint.color = baseColor.withValues(alpha: 0.6);
      canvas.drawCircle(Offset(centerX, centerY), pulseRadius, linePaint);
    }

    // Draw radiating/waveform lines
    const int lineCount = 40;
    for (int i = 0; i < lineCount; i++) {
      final double angle = (i / lineCount) * 2 * math.pi;
      final double offsetFactor = math.sin(animationValue * 2 * math.pi + angle);

      // Adjust opacity and length based on offsetFactor and activity
      double opacity = isActive
          ? (0.5 + 0.5 * offsetFactor.abs()) * 0.7
          : 0.1 + 0.05 * offsetFactor.abs(); // Subtle when idle
      double lengthFactor = isActive
          ? (0.3 + 0.7 * offsetFactor.abs()).clamp(0.3, 1.0)
          : 0.2; // Fixed short length when idle

      linePaint.color = baseColor.withValues(alpha: opacity);

      // Calculate start and end points for lines
      final double startRadius = 0.1 * maxRadius; // Start further out from center
      final double endRadius = startRadius + (maxRadius - startRadius) * lengthFactor;

      final double x1 = centerX + startRadius * math.cos(angle);
      final double y1 = centerY + startRadius * math.sin(angle);
      final double x2 = centerX + endRadius * math.cos(angle);
      final double y2 = centerY + endRadius * math.sin(angle);

      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), linePaint);
    }
  }

  @override
  bool shouldRepaint(_SciFiVisualizerPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.isActive != isActive;
  }
}