import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/widgets/vnc_webview_screen.dart';

/// What the view is still waiting for, as named steps rather than a spinner.
///
/// A spinner says "something is happening". These two lines say which thing,
/// and what comes after it. The step that is done is ticked, the step that is
/// running is bright, the step that has not begun is dimmed — so the reader
/// can see how far along the wait is without reading a word twice.
class VncLoadingSteps extends StatelessWidget {
  const VncLoadingSteps({
    super.key,
    required this.machineReady,
    required this.screenReady,
  });

  /// The executor answered `started`: there is a box with a screen on it.
  final bool machineReady;

  /// The first picture is painted. When true this widget is not shown at all.
  final bool screenReady;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.scrim.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 22, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _VncStep(
                label: 'Getting a machine',
                done: machineReady,
                active: !machineReady,
              ),
              const SizedBox(height: 10),
              _VncStep(
                label: 'Opening its screen',
                done: screenReady,
                active: machineReady && !screenReady,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VncStep extends StatelessWidget {
  const _VncStep({
    required this.label,
    required this.done,
    required this.active,
  });

  final String label;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color on = cs.onInverseSurface;
    final Color color = done || active ? on : on.withValues(alpha: 0.45);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 16,
          height: 16,
          child: done
              ? Icon(Icons.check, size: 16, color: color)
              : active
                  ? CircularProgressIndicator(strokeWidth: 2, color: color)
                  : Center(
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                      ),
                    ),
        ),
        const SizedBox(width: 12),
        // Flexible, so a big text scale wraps the step onto a second line
        // instead of pushing it off the right edge.
        Flexible(
          child: Text(label, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }
}

/// The note over a frozen picture while the socket re-handshakes.
///
/// The picture behind it is real but old, so the note says how old. Without
/// an age "Reconnecting" is a riddle: the reader cannot tell a hiccup from a
/// box that went away.
class VncReconnectingNote extends StatefulWidget {
  const VncReconnectingNote({super.key, required this.since});

  final DateTime since;

  @override
  State<VncReconnectingNote> createState() => _VncReconnectingNoteState();
}

class _VncReconnectingNoteState extends State<VncReconnectingNote> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int seconds = DateTime.now().difference(widget.since).inSeconds;
    final String age = seconds < 60
        ? '${seconds}s ago'
        : '${(seconds / 60).floor()} min ago';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.scrim.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 18, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.onInverseSurface,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Reconnecting — picture from $age',
                style: TextStyle(color: cs.onInverseSurface, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The row of controls under the agent's screen.
///
/// One button family and one size, the same chip the close button uses,
/// because they all float over a live picture and have to stay readable on any
/// of it. No overflow menu: five targets fit at 360 dp, and a menu would put
/// the pointer mode two taps away from a user who is fighting the pointer.
class VncControlBar extends StatelessWidget {
  const VncControlBar({
    super.key,
    required this.controller,
    required this.onToggleKeyboard,
    required this.keyboardOpen,
  });

  final VncWebViewController controller;
  final VoidCallback onToggleKeyboard;
  final bool keyboardOpen;

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text != null && text.isNotEmpty) controller.paste(text);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool live = controller.phase == VncPhase.connected;
    final Color chip = cs.scrim.withValues(alpha: 0.55);
    final double size = MobileLayout.controlHeight;
    // The app's icon set has no keyboard, zoom, paste or pointer glyph, so
    // these stay Material — the same exception the full-screen toggle takes.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: <Widget>[
        ExpressiveIconButton(
          key: const Key('vnc_keyboard'),
          icon: keyboardOpen ? Icons.keyboard_hide : Icons.keyboard_alt_outlined,
          size: size,
          color: chip,
          onColor: cs.onInverseSurface,
          tooltip: keyboardOpen ? 'Hide the keys' : 'Type',
          semanticsId: 'vnc_keyboard',
          onTap: live ? onToggleKeyboard : null,
        ),
        ExpressiveIconButton(
          key: const Key('vnc_zoom_to_fit'),
          icon: Icons.fit_screen_outlined,
          size: size,
          // Lit while there is something to undo, quiet otherwise. The page
          // reports the crossing, so this never flickers per pan frame.
          color: controller.zoomed ? cs.primary : chip,
          onColor: controller.zoomed ? cs.onPrimary : cs.onInverseSurface,
          tooltip: 'Zoom to fit',
          semanticsId: 'vnc_zoom_to_fit',
          onTap: controller.zoomed ? controller.zoomToFit : null,
        ),
        ExpressiveIconButton(
          key: const Key('vnc_paste'),
          icon: Icons.content_paste_go,
          size: size,
          color: chip,
          onColor: cs.onInverseSurface,
          tooltip: 'Paste into the screen',
          semanticsId: 'vnc_paste',
          onTap: live ? _paste : null,
        ),
        ExpressiveIconButton(
          key: const Key('vnc_trackpad'),
          icon: controller.trackpad
              ? Icons.mouse_outlined
              : Icons.touch_app_outlined,
          size: size,
          color: controller.trackpad ? cs.primary : chip,
          onColor: controller.trackpad ? cs.onPrimary : cs.onInverseSurface,
          tooltip: controller.trackpad
              ? 'Back to tapping where you tap'
              : 'Trackpad mode: drive a pointer',
          semanticsId: 'vnc_trackpad',
          onTap: live ? () => controller.setTrackpad(!controller.trackpad) : null,
        ),
        // Only in trackpad mode: there is no pointer of ours to recentre
        // otherwise. The agent moves the real one with xdotool, so the two
        // drift apart while the mode is off.
        if (controller.trackpad)
          ExpressiveIconButton(
            key: const Key('vnc_recenter'),
            icon: Icons.filter_center_focus,
            size: size,
            color: chip,
            onColor: cs.onInverseSurface,
            tooltip: 'Recenter the pointer',
            semanticsId: 'vnc_recenter',
            onTap: live ? controller.recenterPointer : null,
          ),
      ],
    );
  }
}

/// The invisible field that takes the soft keyboard.
///
/// Android gives a soft keyboard no raw key stream worth trusting, so the
/// field takes the text and every character becomes an X11 keysym here. The
/// field never really empties: it holds one zero-width character, so a
/// backspace on an "empty" field still reaches [onChanged] and can be sent on.
class VncKeyboardField extends StatelessWidget {
  const VncKeyboardField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.text,
  });

  static const String sentinel = '​';

  final VncWebViewController controller;
  final FocusNode focusNode;
  final TextEditingController text;

  static void reset(TextEditingController text) {
    text.value = const TextEditingValue(
      text: sentinel,
      selection: TextSelection.collapsed(offset: sentinel.length),
    );
  }

  void _onChanged(String value) {
    if (value.length <= sentinel.length) {
      if (value.length < sentinel.length) {
        controller.sendKeysym(VncWebViewController.keysymBackspace);
      }
      reset(text);
      return;
    }
    final String typed = value.substring(sentinel.length);
    // A newline is Return, not a character. Everything else goes through as
    // text in one call, so a paste-sized burst is one message, not one per
    // letter.
    final List<String> lines = typed.split(RegExp('\r\n|\r|\n'));
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) controller.sendKeysym(VncWebViewController.keysymReturn);
      if (lines[i].isNotEmpty) controller.typeText(lines[i]);
    }
    reset(text);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      bottom: 0,
      width: 1,
      height: 1,
      child: Opacity(
        opacity: 0,
        child: EditableText(
          key: const Key('vnc_key_field'),
          controller: text,
          focusNode: focusNode,
          style: const TextStyle(fontSize: 1),
          cursorColor: const Color(0x00000000),
          backgroundCursorColor: const Color(0x00000000),
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.multiline,
          maxLines: null,
          onChanged: _onChanged,
        ),
      ),
    );
  }
}
