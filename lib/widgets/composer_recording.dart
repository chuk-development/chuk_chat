// lib/widgets/composer_recording.dart
//
// What the composer looks like while the microphone is open.
//
// Shared by both platforms on purpose: dictating on the phone and dictating
// on the desktop are the same act, and they used to look like two different
// features — the phone drew a live waveform over the text field, the desktop
// a red dot and a small visualiser down in its toolbar.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/waveform.dart';

/// Row one of the mobile composer: the text field, and — while the microphone
/// is open — the live waveform drawn in its place.
///
/// The field is kept in the layout while it is hidden ([Visibility] with
/// `maintainSize`), so the composer keeps exactly the height it had at rest.
/// Recording must not make the box taller: a taller box pushes the thread up
/// the moment the microphone opens. Do not replace this with a branch that
/// swaps in a row of its own height.
class ComposerInputRow extends StatelessWidget {
  const ComposerInputRow({
    super.key,
    required this.isRecording,
    required this.audioLevels,
    required this.accentColor,
    required this.timeColor,
    required this.child,
  });

  final bool isRecording;

  /// The recorder's rolling level buffer (0..1, oldest first).
  final List<double> audioLevels;

  /// The colour of the bars.
  final Color accentColor;

  /// The colour of the elapsed time.
  final Color timeColor;

  /// The text field of the composer.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Visibility(
          visible: !isRecording,
          maintainSize: true,
          maintainState: true,
          maintainAnimation: true,
          child: child,
        ),
        if (isRecording)
          Positioned.fill(
            child: RecordingWaveformBar(
              audioLevels: audioLevels,
              color: accentColor,
              timeColor: timeColor,
            ),
          ),
      ],
    );
  }
}

/// The open microphone: the live waveform, and the elapsed time beside it.
///
/// Nothing else — no pulsing dot. The bars are the same rounded, round-capped
/// bars a voice message is drawn with (see [LiveWaveform]), so dictating and
/// listening look like one feature.
class RecordingWaveformBar extends StatefulWidget {
  const RecordingWaveformBar({
    super.key,
    required this.audioLevels,
    required this.color,
    required this.timeColor,
  });

  final List<double> audioLevels;
  final Color color;
  final Color timeColor;

  @override
  State<RecordingWaveformBar> createState() => _RecordingWaveformBarState();
}

class _RecordingWaveformBarState extends State<RecordingWaveformBar> {
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (Timer _) {
      if (!mounted) return;
      setState(() => _elapsed = _clock.elapsed);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _clock.stop();
    super.dispose();
  }

  static String _format(Duration value) {
    final int minutes = value.inMinutes;
    final int seconds = value.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double room = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : 26;
              return LiveWaveform(
                levels: widget.audioLevels,
                color: widget.color,
                height: math.min(26, math.max(12, room)),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _format(_elapsed),
          style: TextStyle(
            color: widget.timeColor,
            fontSize: 13,
            height: 1.0,
            fontWeight: FontWeight.w600,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
