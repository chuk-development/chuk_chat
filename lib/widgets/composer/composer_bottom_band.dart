// lib/widgets/composer/composer_bottom_band.dart
import 'package:flutter/material.dart';

/// The band under the composer, from its top edge down to the screen edge.
///
/// The transcript runs the full height of the chat area and scrolls behind
/// the composer. Without this band, message text showed around the composer
/// and under it, and it ran through the disclaimer line. The band is opaque
/// in the screen's own background colour, with a short fade at its top, so
/// text goes soft just above the composer and is gone behind it.
///
/// The parent gives the height: the composer's distance from the bottom edge
/// plus its measured height plus [fadeHeight]. The band takes no pointer
/// events, so the composer and the list under the fade stay usable.
class ComposerBottomBand extends StatelessWidget {
  const ComposerBottomBand({super.key, required this.color});

  /// The screen background behind the transcript.
  final Color color;

  /// The soft edge above the composer's top.
  static const double fadeHeight = 16;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double height = box.maxHeight;
          final double stop = height <= 0
              ? 0
              : (fadeHeight / height).clamp(0.0, 1.0);
          return DecoratedBox(
            key: const ValueKey<String>('composer-bottom-band'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[color.withValues(alpha: 0), color, color],
                stops: <double>[0, stop, 1],
              ),
            ),
          );
        },
      ),
    );
  }
}
