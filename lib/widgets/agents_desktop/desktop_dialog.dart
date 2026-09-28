/// Centred dialogs for the Agents desktop layout.
library;

import 'package:flutter/material.dart';

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

/// The dialog frame itself: chuk_chat's dialog — the surface, corner and
/// elevation come from the app's dialog theme, as they do for every
/// `AlertDialog` — centred, capped at [kDeskDialogMaxWidth] and at 85 % of the
/// window height.
class AgentsDesktopDialog extends StatelessWidget {
  const AgentsDesktopDialog({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        key: const ValueKey<String>('agents-desktop-dialog-box'),
        constraints: BoxConstraints(
          maxWidth: kDeskDialogMaxWidth,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}
