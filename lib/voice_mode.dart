import 'package:flutter/material.dart';
import 'dart:math' as math;

///  Voice-Mode  –  UI ONLY  –  LifeKit ready
class VoiceMode extends StatefulWidget {
  const VoiceMode({Key? key}) : super(key: key);

  @override
  State<VoiceMode> createState() => _VoiceModeState();
}

class _VoiceModeState extends State<VoiceMode> with TickerProviderStateMixin {
  /* ---------- colours ---------- */
  final Color bg     = const Color(0xFF211B15);   // 33 27 21
  final Color accent = const Color(0xFF466362);   // 70 99 93
  final Color iconFg = const Color(0xFF93854C);   //147 133 76

  /* ---------- UI state ---------- */
  bool _listening = false;                 // mic hot
  bool _thinking  = false;                 // bot typing
  String _transcript = '';                 // user words
  String _reply = '';                      // bot words
  String _imageUrl = '';                   // bot image (dummy)

  /* ---------- animators ---------- */
  late AnimationController _waveCtrl;
  late AnimationController _barCtrl;

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
    _barCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))..repeat();
    _startHotMic();   // auto-start
  }

  /* ---------- auto hot mic ---------- */
  void _startHotMic() {
    setState(() => _listening = true);
    _fakeListen();    // UI dummy
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
            // LEFT: Voice Mode (visualiser + mic)
            Expanded(
              flex: 1,
              child: Container(
                color: bg,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _visualiser(),
                    const SizedBox(height: 24),
                    _bottomMic(),
                    const SizedBox(height: 24),
                  ],
                ),
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
                              child: Image.network(
                                _imageUrl,
                                width: double.infinity,
                                height: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            )
                          : Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: accent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'No image generated',
                                style: TextStyle(color: Colors.white.withOpacity(0.5)),
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
                              const Text('Voice Mode',
                                  style: TextStyle(fontSize: 18, color: Colors.white)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.white),
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
                                if (_reply.isNotEmpty) _botBubble(_reply, ''),
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

  /* ---------- USER BUBBLE (LEFT) ---------- */
  Widget _userBubble(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
          border: Border.all(color: iconFg.withOpacity(.3)),
        ),
        child: Text(text, style: TextStyle(color: iconFg)),
      ),
    );
  }

  /* ---------- BOT TYPING INDICATOR ---------- */
  Widget _botTyping() {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: accent.withOpacity(.8),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(0), const SizedBox(width: 4), _dot(1), const SizedBox(width: 4), _dot(2),
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
        color: Colors.white.withOpacity(.6),
        borderRadius: BorderRadius.circular(3),
      ),
    ),
  );

  /* ---------- BOT BUBBLE (RIGHT) ---------- */
  Widget _botBubble(String text, String _) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: accent.withOpacity(.8),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
          ),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  /* ---------- COMPLEX VISUALISER ---------- */
  Widget _visualiser() {
    return SizedBox(
      height: 100,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(7, (i) => _complexBar(i)),
      ),
    );
  }

  Widget _complexBar(int i) {
    return AnimatedBuilder(
      animation: _barCtrl,
      builder: (_, __) {
        final t = ((i / 7) + _barCtrl.value).clamp(0.0, 1.0);
        return Container(
          width: 10,
          height: 20 + 60 * t,
          margin: const EdgeInsets.symmetric(horizontal: 2), // reduced margin to fit
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [accent.withOpacity(.3), accent.withOpacity(.9)],
            ),
            borderRadius: BorderRadius.circular(5),
          ),
        );
      },
    );
  }

  /* ---------- BOTTOM MIC + WAVE ---------- */
  Widget _bottomMic() {
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
        const SizedBox(height: 12),
        IconButton(
          icon: const Icon(Icons.mic_none, size: 64),
          color: accent,
          onPressed: () {},
        ),
        Text('Listening…', style: TextStyle(color: iconFg.withOpacity(.8))),
      ],
    );
  }
}

/* ---------- custom wave painter ---------- */
class _WavePainter extends CustomPainter {
  final double value;
  final Color color;
  _WavePainter(this.value, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(.4)
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
