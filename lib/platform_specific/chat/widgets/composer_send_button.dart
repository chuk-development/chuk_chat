// lib/platform_specific/chat/widgets/composer_send_button.dart
//
// The composer's primary target, shared by the desktop and the phone
// composer (both chat and Agents thread). One button, four faces:
//
// - voice: the field is empty and the chat can call. Tap starts the call.
// - send:  the field holds text or an attachment (or the microphone is
//          open). Tap sends. With an empty field and no call it is the same
//          send target, disabled.
// - stop:  a response streams. Tap stops it. The caller decides when.
// - loading: a recording is transcribed. No tap.
//
// The face changes with a short cross-fade and scale. The fill is flat: no
// glow, no coloured shadow (docs/DESIGN.md).

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// What the composer's primary target shows.
enum ComposerSendFace { send, voice, stop, loading }

/// How long the face change takes.
const Duration kComposerSendSwap = Duration(milliseconds: 150);

class ComposerSendButton extends StatelessWidget {
  const ComposerSendButton({
    super.key,
    required this.controller,
    required this.onSend,
    required this.width,
    required this.height,
    required this.radius,
    this.hasOtherContent = false,
    this.onVoice,
    this.onStop,
    this.stopping = false,
    this.loading = false,
    this.sendIcon = Icons.north_rounded,
    this.iconSize = 18,
    this.stopIconSize,
    this.sendIconScaleY = 1,
    this.spinnerSize,
    this.spinnerStroke = 2,
    this.semanticsId = 'send_button',
  });

  /// The composer's text. The face follows it as the user types.
  final TextEditingController controller;

  /// Content that is not text: an attachment, an open microphone.
  final bool hasOtherContent;

  /// Sends what the composer holds.
  final VoidCallback onSend;

  /// Starts the voice call. Null: this build or this chat has no call, so
  /// the target stays a send target.
  final VoidCallback? onVoice;

  /// Stops the streaming response.
  final VoidCallback? onStop;

  /// A response streams and the target is the stop target.
  final bool stopping;

  /// A recording is transcribed. The target shows a spinner and takes no tap.
  final bool loading;

  final double width;
  final double height;
  final double radius;

  /// The send glyph, as today's composer drew it.
  final IconData sendIcon;

  /// Size of the send glyph. The voice glyph uses the same size.
  final double iconSize;

  /// Size of the stop glyph. Null: [iconSize].
  final double? stopIconSize;

  /// The desktop arrow is drawn slightly flattened.
  final double sendIconScaleY;

  /// Null: the button's short side less 16.
  final double? spinnerSize;
  final double spinnerStroke;

  final String semanticsId;

  /// The face for a composer state. Loading wins, then stop, then content.
  static ComposerSendFace faceFor({
    required bool hasContent,
    required bool voiceAvailable,
    bool stopping = false,
    bool loading = false,
  }) {
    if (loading) return ComposerSendFace.loading;
    if (stopping) return ComposerSendFace.stop;
    if (hasContent) return ComposerSendFace.send;
    return voiceAvailable ? ComposerSendFace.voice : ComposerSendFace.send;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, Widget? _) {
        final bool hasContent = hasOtherContent || value.text.trim().isNotEmpty;
        final ComposerSendFace face = faceFor(
          hasContent: hasContent,
          voiceAvailable: onVoice != null,
          stopping: stopping,
          loading: loading,
        );
        return _build(context, face, hasContent);
      },
    );
  }

  Widget _build(BuildContext context, ComposerSendFace face, bool hasContent) {
    final ThemeData theme = Theme.of(context);
    final Color fill = face == ComposerSendFace.stop
        ? Colors.red
        : theme.colorScheme.primary;
    final Color on = theme.accentButtonForeground(fill);
    final VoidCallback? onTap = switch (face) {
      ComposerSendFace.loading => null,
      ComposerSendFace.stop => onStop,
      ComposerSendFace.voice => onVoice,
      ComposerSendFace.send => hasContent ? onSend : null,
    };
    final String label = switch (face) {
      ComposerSendFace.loading => 'Transcribing',
      ComposerSendFace.stop => 'Stop',
      ComposerSendFace.voice => 'Voice call',
      ComposerSendFace.send => 'Send',
    };
    final BorderRadius shape = BorderRadius.circular(radius);
    return Semantics(
      identifier: semanticsId,
      button: true,
      enabled: onTap != null,
      label: label,
      child: Material(
        color: Colors.transparent,
        borderRadius: shape,
        child: InkWell(
          // One stable key: a key per face would remount the switcher and
          // drop the swap animation.
          key: const ValueKey<String>('composer-send-target'),
          onTap: onTap,
          borderRadius: shape,
          child: AnimatedContainer(
            duration: kComposerSendSwap,
            curve: Curves.easeOutCubic,
            width: width,
            height: height,
            decoration: BoxDecoration(color: fill, borderRadius: shape),
            child: AnimatedSwitcher(
              duration: kComposerSendSwap,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (Widget child, Animation<double> a) =>
                  FadeTransition(
                    opacity: a,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.6, end: 1).animate(a),
                      child: child,
                    ),
                  ),
              layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
                alignment: Alignment.center,
                children: <Widget>[...previous, ?current],
              ),
              child: SizedBox(
                key: ValueKey<ComposerSendFace>(face),
                width: width,
                height: height,
                child: Center(child: _glyph(face, on)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _glyph(ComposerSendFace face, Color on) {
    switch (face) {
      case ComposerSendFace.loading:
        final double s =
            spinnerSize ?? ((width < height ? width : height) - 16);
        return SizedBox(
          width: s,
          height: s,
          child: CircularProgressIndicator(
            strokeWidth: spinnerStroke,
            valueColor: AlwaysStoppedAnimation<Color>(on),
            backgroundColor: on.withValues(alpha: 0.2),
          ),
        );
      case ComposerSendFace.stop:
        return AppIcon(
          Icons.stop_rounded,
          color: on,
          size: stopIconSize ?? iconSize,
        );
      case ComposerSendFace.voice:
        return HugeIcon(
          HugeIcons.voiceSolid,
          key: const ValueKey<String>('composer-voice-glyph'),
          size: iconSize,
          color: on,
        );
      case ComposerSendFace.send:
        final Widget arrow = AppIcon(sendIcon, color: on, size: iconSize);
        if (sendIconScaleY == 1) return arrow;
        return Transform(
          transform: Matrix4.diagonal3Values(1, sendIconScaleY, 1),
          alignment: Alignment.center,
          child: arrow,
        );
    }
  }
}
