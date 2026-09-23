/// Centred dialogs for the Agents desktop layout (docs/DESIGN.md §14.6).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';

/// Whether [context] is laid out as the desktop (not the phone).
bool isAgentsDesktop(BuildContext context) =>
    !MobileLayout.isPhoneWidth(MediaQuery.sizeOf(context).width);

/// A form that is a bottom sheet on the phone and a centred dialog, at most
/// [kDeskDialogMaxWidth] wide, on a desktop window.
///
/// The phone path is exactly the sheet it always was; only a desktop window
/// takes the dialog.
Future<T?> showAgentsSheetOrDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  if (!isAgentsDesktop(context)) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (BuildContext dialogContext) =>
        AgentsDesktopDialog(child: builder(dialogContext)),
  );
}

/// The dialog frame itself: the app's dialog surface and radius, centred,
/// capped at [kDeskDialogMaxWidth] and at 85 % of the window height.
class AgentsDesktopDialog extends StatelessWidget {
  const AgentsDesktopDialog({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusDialog),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: kDeskDialogMaxWidth,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

/// Asks before something is deleted. Returns true when the user confirms.
Future<bool> showAgentsConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ThemeData theme = Theme.of(dialogContext);
      final ColorScheme scheme = theme.colorScheme;
      return AgentsDesktopDialog(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('agents-confirm-button'),
                    autofocus: true,
                    style: destructive
                        ? FilledButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                          )
                        : null,
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: Text(confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return ok ?? false;
}
