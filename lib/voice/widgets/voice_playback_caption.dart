import 'package:flutter/material.dart';

import 'package:chuk_chat/voice/voice_playback_context.dart';

/// Ordinary chat rendering of heard speech and an explicitly unspoken draft.
class VoicePlaybackCaption extends StatelessWidget {
  const VoicePlaybackCaption({
    super.key,
    required this.heard,
    required this.metadata,
    this.textStyle,
  });

  final String heard;
  final String? metadata;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final parsed = VoicePlaybackDetails.parse(metadata);
    final details = parsed?.appliesTo(heard) == true ? parsed : null;
    final style = textStyle ?? Theme.of(context).textTheme.bodyLarge!;
    final continuation = details?.interrupted == true
        ? details!.continuation(heard)
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (heard.isNotEmpty) Text(heard, style: style),
        if (details?.interrupted == true) ...[
          const SizedBox(height: 6),
          Text(
            continuation.isEmpty
                ? 'Interrupted'
                : details!.intendedText.trim().startsWith(heard.trim())
                ? 'Interrupted · Not spoken'
                : 'Interrupted · Generated draft',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: style.color?.withValues(alpha: 0.6)),
          ),
          if (continuation.isNotEmpty)
            Text(
              continuation,
              style: style.copyWith(
                color: style.color?.withValues(alpha: 0.42),
                fontWeight: FontWeight.w300,
              ),
            ),
        ],
      ],
    );
  }
}
