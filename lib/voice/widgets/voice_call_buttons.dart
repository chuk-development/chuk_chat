import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/motion.dart';

/// The fill of one call button. The shape does not depend on it.
enum VoiceButtonTone {
  /// Resting: nothing is switched on.
  plain,

  /// Switched on: the camera, the loudspeaker.
  selected,

  /// The microphone is off.
  muted,

  /// A headset carries the sound.
  headset,
}

/// One button of a [VoiceButtonGroup].
class VoiceButtonItem {
  const VoiceButtonItem({
    required this.icon,
    required this.tooltip,
    required this.semanticsId,
    this.onPressed,
    this.tone = VoiceButtonTone.plain,
    this.opened = false,
  });

  /// Built with the ink colour of the tone.
  final Widget Function(Color ink) icon;
  final String tooltip;
  final String semanticsId;

  /// Gets the button's own context, so a menu can hang off it. Null disables.
  final void Function(BuildContext context)? onPressed;
  final VoiceButtonTone tone;

  /// This button and the joints beside it round further.
  final bool opened;
}

/// The call controls: separate buttons joined into one row. The outer ends
/// are fully round, the joints tight; a switched-on button rounds its own
/// joints and the ones that meet it.
class VoiceButtonGroup extends StatelessWidget {
  const VoiceButtonGroup({super.key, required this.items, this.height = 56});

  final List<VoiceButtonItem> items;
  final double height;

  static const double gap = 3;
  static const double innerRadius = 6;
  static const double openedRadius = 16;

  /// Fill and ink of [tone] in [scheme].
  static (Color, Color) colorsFor(ColorScheme scheme, VoiceButtonTone tone) {
    return switch (tone) {
      VoiceButtonTone.plain => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
      ),
      VoiceButtonTone.selected => (
        scheme.inverseSurface,
        scheme.onInverseSurface,
      ),
      VoiceButtonTone.muted => (scheme.error, scheme.onError),
      VoiceButtonTone.headset => (scheme.primary, scheme.onPrimary),
    };
  }

  bool _openedAt(int index) =>
      index >= 0 && index < items.length && items[index].opened;

  BorderRadius _radius(int index) {
    final double outer = height / 2;
    final bool left = _openedAt(index) || _openedAt(index - 1);
    final bool right = _openedAt(index) || _openedAt(index + 1);
    final double l = index == 0 ? outer : (left ? openedRadius : innerRadius);
    final double r = index == items.length - 1
        ? outer
        : (right ? openedRadius : innerRadius);
    return BorderRadius.horizontal(
      left: Radius.circular(l),
      right: Radius.circular(r),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int n = items.length;
        final double natural = n * (height + 8) + (n - 1) * gap;
        final double width =
            constraints.hasBoundedWidth && constraints.maxWidth < natural
            ? (constraints.maxWidth - (n - 1) * gap) / n
            : height + 8;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < n; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: gap),
              _VoiceButton(
                item: items[i],
                width: width,
                height: height,
                radius: _radius(i),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.item,
    required this.width,
    required this.height,
    required this.radius,
  });

  final VoiceButtonItem item;
  final double width;
  final double height;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (Color fill, Color ink) = VoiceButtonGroup.colorsFor(
      scheme,
      item.tone,
    );
    final bool enabled = item.onPressed != null;
    return Semantics(
      identifier: item.semanticsId,
      button: true,
      enabled: enabled,
      toggled: item.tone != VoiceButtonTone.plain,
      label: item.tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: item.tooltip,
        child: MorphTap(
          onTap: enabled ? () => item.onPressed!(context) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: kExpressiveDecelerate,
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: enabled ? fill : fill.withValues(alpha: 0.5),
              borderRadius: radius,
            ),
            alignment: Alignment.center,
            child: item.icon(enabled ? ink : ink.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }
}
