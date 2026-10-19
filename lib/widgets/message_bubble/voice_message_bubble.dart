// lib/widgets/message_bubble/voice_message_bubble.dart
//
// The user bubble of a dictated message. It looks like a voice message: a mic
// badge, a waveform and the length of the recording, with the transcript
// folded away. One tap opens the full text, the next tap folds it again.
//
// There is no audio behind it. The app never stores or uploads the recording
// (privacy); the bubble is only a form for dictated text, which is usually
// long. The waveform is decoration: static bars derived from the text.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/waveform.dart';

/// Key of the tappable header row (tests and the tour find it by this).
const ValueKey<String> kVoiceBubbleHeaderKey = ValueKey<String>(
  'voice-bubble-header',
);

/// Key of the transcript while it is open.
const ValueKey<String> kVoiceBubbleTranscriptKey = ValueKey<String>(
  'voice-bubble-transcript',
);

const double _kBarWidth = 3;
const double _kBarStep = 6; // bar plus gap
const double _kWaveformWidth = 132;
const double _kWaveformHeight = 24;
const double _kBadgeSize = 32;

/// The bubble of a dictated user message.
///
/// The caller hands in the bubble's own [decoration] and [margin], so a voice
/// message has the same fill, border and corners as a typed one. [transcript]
/// is the full text as the typed bubble would draw it; it is built only while
/// the bubble is open.
class VoiceMessageBubble extends StatefulWidget {
  const VoiceMessageBubble({
    super.key,
    required this.text,
    required this.transcript,
    required this.foregroundColor,
    required this.decoration,
    this.duration,
    this.margin,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.initiallyExpanded = false,
    this.onExpandedChanged,
  });

  /// The transcript as plain text. Seeds the waveform and the semantics.
  final String text;

  /// The transcript as the bubble draws it when open.
  final Widget transcript;

  /// Text and glyph colour on the bubble fill.
  final Color foregroundColor;
  final BoxDecoration decoration;

  /// Length of the recording, when it is known.
  final Duration? duration;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry padding;
  final bool initiallyExpanded;

  /// Called after each tap with the new state.
  final ValueChanged<bool>? onExpandedChanged;

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  late bool _expanded = widget.initiallyExpanded;
  late List<double> _bars = voiceBubbleBars(widget.text);

  @override
  void didUpdateWidget(covariant VoiceMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _bars = voiceBubbleBars(widget.text);
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpandedChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations? l10n = AppLocalizations.of(context);
    final Color fg = widget.foregroundColor;
    final Duration? duration = widget.duration;
    final String label = l10n?.voiceMessage ?? 'Voice message';
    final String action = _expanded
        ? (l10n?.voiceMessageHideTranscript ?? 'Hide transcript')
        : (l10n?.voiceMessageShowTranscript ?? 'Show transcript');
    final TextStyle durationStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

    final Widget header = Semantics(
      button: true,
      expanded: _expanded,
      label: duration == null
          ? '$label. $action'
          : '$label, ${formatVoiceDuration(duration)}. $action',
      excludeSemantics: true,
      onTap: _toggle,
      child: GestureDetector(
        key: kVoiceBubbleHeaderKey,
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              width: _kBadgeSize,
              height: _kBadgeSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fg.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(_kBadgeSize * 0.34),
              ),
              child: HugeIcon(HugeIcons.mic01, size: 18, color: fg),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _kWaveformWidth),
                child: _StaticWaveform(bars: _bars, color: fg),
              ),
            ),
            if (duration != null) ...<Widget>[
              const SizedBox(width: 10),
              Text(formatVoiceDuration(duration), style: durationStyle),
            ],
            const SizedBox(width: 6),
            SizedBox(
              width: 20,
              height: 20,
              child: Center(
                child: HugeIcon(
                  _expanded ? HugeIcons.arrowUp01 : HugeIcons.arrowDown01,
                  size: 18,
                  color: fg.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Container(
      margin: widget.margin,
      padding: widget.padding,
      decoration: widget.decoration,
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: kExpressiveShort,
        curve: kExpressiveDecelerate,
        alignment: Alignment.topRight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            header,
            if (_expanded) ...<Widget>[
              const SizedBox(height: 8),
              GestureDetector(
                key: kVoiceBubbleTranscriptKey,
                behavior: HitTestBehavior.translucent,
                onTap: _toggle,
                child: widget.transcript,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The static waveform: as many bars as fit, from the seeded heights.
class _StaticWaveform extends StatelessWidget {
  const _StaticWaveform({required this.bars, required this.color});

  final List<double> bars;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kWaveformHeight,
      width: _kWaveformWidth,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : _kWaveformWidth;
          final int count = math.max(
            4,
            math.min(
              bars.length,
              ((width + _kBarStep - _kBarWidth) ~/ _kBarStep),
            ),
          );
          return CustomPaint(
            size: Size(width, _kWaveformHeight),
            painter: WaveformPainter(
              bars: bars.sublist(0, count),
              progress: 1,
              playedColor: color.withValues(alpha: 0.85),
              restColor: color,
              barWidth: _kBarWidth,
            ),
          );
        },
      ),
    );
  }
}

/// `m:ss`, or `h:mm:ss` from one hour on.
String formatVoiceDuration(Duration duration) {
  final int total = duration.inSeconds < 1 ? 1 : duration.inSeconds;
  final int hours = total ~/ 3600;
  final int minutes = (total % 3600) ~/ 60;
  final String seconds = (total % 60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

/// Number of bars the waveform is seeded with (more than ever fit).
const int kVoiceBubbleBarCount = 22;

/// Bar heights (0.25..1) for [text]: the same text always gives the same
/// shape, and two messages rarely share one. FNV-1a seeds a small xorshift;
/// a light smoothing keeps neighbours close, so the row reads as speech.
List<double> voiceBubbleBars(String text, {int count = kVoiceBubbleBarCount}) {
  int hash = 0x811c9dc5;
  for (final int unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  int state = hash == 0 ? 0x9e3779b9 : hash;
  double next() {
    state ^= (state << 13) & 0xffffffff;
    state ^= state >> 17;
    state ^= (state << 5) & 0xffffffff;
    state &= 0xffffffff;
    return state / 0xffffffff;
  }

  final List<double> raw = <double>[for (int i = 0; i < count; i++) next()];
  return <double>[
    for (int i = 0; i < count; i++)
      (0.25 +
              0.75 *
                  ((raw[i] * 2 +
                          raw[math.max(0, i - 1)] +
                          raw[math.min(count - 1, i + 1)]) /
                      4))
          .clamp(0.25, 1.0),
  ];
}
