// lib/widgets/masked_secret_text.dart
//
// A user's own text with every pasted credential masked: the first eight
// characters in monospace, then dots, and a small eye target per value that
// shows it in full. Only the screen changes; the message, its copy action
// and what was sent keep the original text (lib/utils/secret_mask.dart).

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/utils/secret_mask.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

class MaskedSecretText extends StatefulWidget {
  const MaskedSecretText({
    super.key,
    required this.text,
    required this.style,
    this.matches,
  });

  final String text;
  final TextStyle style;

  /// Pre-computed [findSecrets] result, so a caller that already looked
  /// does not scan twice. Null: scanned here.
  final List<SecretMatch>? matches;

  @override
  State<MaskedSecretText> createState() => _MaskedSecretTextState();
}

class _MaskedSecretTextState extends State<MaskedSecretText> {
  /// Start offsets of the values the reader chose to see.
  final Set<int> _revealed = <int>{};

  @override
  void didUpdateWidget(MaskedSecretText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _revealed.clear();
  }

  @override
  Widget build(BuildContext context) {
    final List<SecretMatch> matches =
        widget.matches ?? findSecrets(widget.text);
    if (matches.isEmpty) return Text(widget.text, style: widget.style);

    final AppLocalizations? l10n = AppLocalizations.of(context);
    final TextStyle base = widget.style;
    final double fontSize = base.fontSize ?? 14;
    final Color color = base.color ?? Theme.of(context).colorScheme.onSurface;
    final TextStyle mono = base.copyWith(
      fontFamily: 'monospace',
      fontSize: fontSize * 0.92,
    );
    // One text line high, so the eye sits centred on the value's line.
    final double iconBox = fontSize * (base.height ?? 1.3);

    final List<InlineSpan> spans = <InlineSpan>[];
    int pos = 0;
    for (final SecretMatch m in matches) {
      if (m.start > pos) {
        spans.add(TextSpan(text: widget.text.substring(pos, m.start)));
      }
      final bool shown = _revealed.contains(m.start);
      spans.add(
        TextSpan(
          text: shown ? m.value : maskSecret(m.value),
          style: mono,
          semanticsLabel: shown
              ? null
              : (l10n?.secretMaskedLabel ?? 'Hidden key'),
        ),
      );
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Semantics(
            button: true,
            label: shown
                ? (l10n?.secretHide ?? 'Hide key')
                : (l10n?.secretShow ?? 'Show key'),
            child: GestureDetector(
              key: ValueKey<String>('secret-toggle-${m.start}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() {
                if (!_revealed.remove(m.start)) _revealed.add(m.start);
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: iconBox,
                  height: iconBox,
                  child: Center(
                    child: AppIcon(
                      shown ? Icons.visibility_off : Icons.visibility,
                      size: fontSize,
                      color: color.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      pos = m.end;
    }
    if (pos < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(pos)));
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
