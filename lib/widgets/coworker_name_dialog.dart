/// Naming a coworker: the one surface the app uses to create one and to rename
/// one.
///
/// It used to be a Material [AlertDialog] with a labelled, outlined field and
/// two text buttons — the default shape of a form from another app. This is the
/// same behaviour in the app's own language (docs/DESIGN.md): the expressive
/// dialog surface at [kRadiusDialog], the page-title treatment on the heading,
/// one filled field with no ring and no glow, the submit as a filled
/// [ExpressiveButton] and Cancel as the quiet one next to it.
///
/// Behaviour is unchanged: Enter or the submit button returns the trimmed text,
/// Cancel returns null, and the caller decides what an empty or unchanged name
/// means.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_dialog.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';

/// Asks for a coworker's name. Returns the trimmed text, or null on Cancel.
///
/// The controller belongs to the dialog widget, not to the caller: disposing it
/// right after `showDialog` returns trips "used after dispose" while the route
/// is still animating out under a widget test.
Future<String?> showCoworkerNameDialog(
  BuildContext context, {
  required String title,
  required String submitLabel,
  String initialName = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => CoworkerNameDialog(
    title: title,
    submitLabel: submitLabel,
    initialName: initialName,
  ),
);

class CoworkerNameDialog extends StatefulWidget {
  const CoworkerNameDialog({
    super.key,
    required this.title,
    required this.submitLabel,
    this.initialName = '',
  });

  final String title;
  final String submitLabel;
  final String initialName;

  @override
  State<CoworkerNameDialog> createState() => _CoworkerNameDialogState();
}

class _CoworkerNameDialogState extends State<CoworkerNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    // A desktop window gets the desktop dialog (docs/DESIGN.md §14.6): the
    // same surface, sized for a mouse — a smaller title, a 44 px field and
    // 36 px buttons. The phone keeps its thumb-sized one.
    final bool desk = isAgentsDesktop(context);
    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          desk ? kDeskDialogRadius : kRadiusDialog,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: desk
              ? const EdgeInsets.fromLTRB(22, 20, 22, 18)
              : const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.title,
                style: desk
                    ? text.titleLarge?.copyWith(fontWeight: FontWeight.w700)
                    : text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                'You can change it later.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              // Filled, no resting outline and no focus ring: the accent green
              // box around an autofocused field was the loudest thing in the
              // dialog, and it said nothing the caret does not.
              TextField(
                controller: _controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                cursorColor: scheme.primary,
                style: (desk ? text.bodyLarge : text.titleMedium)?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  hintText: 'Agent name',
                  hintStyle: text.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                  contentPadding: desk
                      ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
                      : const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                  border: _fieldBorder,
                  enabledBorder: _fieldBorder,
                  focusedBorder: _fieldBorder,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  ExpressiveButton(
                    label: 'Cancel',
                    color: scheme.surfaceContainerHighest,
                    onColor: scheme.onSurfaceVariant,
                    dense: desk,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  ExpressiveButton(
                    label: widget.submitLabel,
                    dense: desk,
                    onTap: _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final OutlineInputBorder _fieldBorder = OutlineInputBorder(
  borderRadius: BorderRadius.circular(kRadiusField),
  borderSide: BorderSide.none,
);
