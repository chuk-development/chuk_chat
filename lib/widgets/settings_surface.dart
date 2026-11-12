// lib/widgets/settings_surface.dart
//
// The one settings pattern (docs/DESIGN.md §2, "One settings pattern").
//
// A settings surface is a page in chuk's frame: FloatingPageScaffold,
// FloatingAppBar, SettingsListView and the Expressive rows. Where that page
// shows depends on the window, never on the half of the app:
//
//  * Phone: a full page, pushed on the app's navigator.
//  * Desktop: the settings modal, the centred panel the Chat settings use
//    (`showDesktopSettingsModal`). The page runs in its own navigator inside
//    the panel, so the pages it opens stay in the panel too. The page's own
//    header gets the panel's close chip at its right end.
//
// Open every settings page through [openSettingsSurface]. Small confirm
// dialogs and pickers stay dialogs; this is for settings menus only.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Widest settings modal: the Chat settings, a rail and a page.
const double kSettingsModalMaxWidth = 1080;

/// Width of a settings modal that holds one page and no rail.
const double kSettingsPageModalMaxWidth = 720;

/// Tallest settings modal.
const double kSettingsModalMaxHeight = 760;

/// Tells the pages inside a settings modal where they are.
///
/// [FloatingAppBar] reads it: inside a modal its header ends in the close
/// chip, and the first page of a compact modal gets a back chip that runs
/// [onRootBack].
class SettingsSurfaceScope extends InheritedWidget {
  const SettingsSurfaceScope({
    super.key,
    required this.onClose,
    this.onRootBack,
    required super.child,
  });

  /// Closes the whole modal.
  final VoidCallback onClose;

  /// Back from the first page of the modal's navigator. Null: the first
  /// page shows no back chip.
  final VoidCallback? onRootBack;

  static SettingsSurfaceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsSurfaceScope>();

  @override
  bool updateShouldNotify(SettingsSurfaceScope oldWidget) =>
      onClose != oldWidget.onClose || onRootBack != oldWidget.onRootBack;
}

/// The panel of a settings modal: the page colour, the dialog radius, a
/// hairline, centred in the window with a margin. Small windows get a small
/// margin and a smaller radius.
class SettingsModalFrame extends StatelessWidget {
  const SettingsModalFrame({
    super.key,
    required this.builder,
    this.maxWidth = kSettingsModalMaxWidth,
    this.maxHeight = kSettingsModalMaxHeight,
  });

  /// Builds the content for the panel's [Size].
  final Widget Function(BuildContext context, Size panel) builder;

  final double maxWidth;
  final double maxHeight;

  /// True when the panel is too narrow for a rail next to a page.
  static bool isCompact(Size panel) => panel.width < 720;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Size size = MediaQuery.sizeOf(context);
    final double margin = size.width < 560 || size.height < 560 ? 8 : 24;
    final Size panel = Size(
      math.max(0, math.min(maxWidth, size.width - margin * 2)),
      math.max(0, math.min(maxHeight, size.height - margin * 2)),
    );
    final double radius = isCompact(panel) ? 20 : kRadiusDialog;
    // One Material draws the rounded border AND clips its children to the
    // same shape, so the corners stay clean.
    return Center(
      child: Padding(
        padding: EdgeInsets.all(margin),
        child: Material(
          color: theme.scaffoldBackgroundColor,
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: theme.m3.outlineVariant),
          ),
          child: SizedBox(
            width: panel.width,
            height: panel.height,
            // The page inside sits in the panel, not under a status bar.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              removeBottom: true,
              child: builder(context, panel),
            ),
          ),
        ),
      ),
    );
  }
}

/// A navigator for the pages of a settings modal. While it is mounted,
/// [openSettingsSurface] pushes onto it.
class SettingsSurfaceNavigator extends StatefulWidget {
  const SettingsSurfaceNavigator({
    super.key,
    required this.builder,
    required this.onClose,
    this.onRootBack,
  });

  /// The first page.
  final WidgetBuilder builder;

  /// Closes the modal.
  final VoidCallback onClose;

  /// See [SettingsSurfaceScope.onRootBack].
  final VoidCallback? onRootBack;

  @override
  State<SettingsSurfaceNavigator> createState() =>
      _SettingsSurfaceNavigatorState();
}

class _SettingsSurfaceNavigatorState extends State<SettingsSurfaceNavigator> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  /// The settings navigators that are open now, the newest last.
  static final List<_SettingsSurfaceNavigatorState> _open =
      <_SettingsSurfaceNavigatorState>[];

  @override
  void initState() {
    super.initState();
    _open.add(this);
  }

  @override
  void dispose() {
    _open.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSurfaceScope(
      onClose: widget.onClose,
      onRootBack: widget.onRootBack,
      child: Navigator(
        key: _navigator,
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: widget.builder),
      ),
    );
  }
}

/// Opens a settings modal with [builder] as its first page. Desktop only;
/// call [openSettingsSurface], which picks the form.
Future<void> showSettingsModal(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxWidth = kSettingsPageModalMaxWidth,
  String routeName = 'settings:page',
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 180),
    routeSettings: RouteSettings(name: routeName),
    pageBuilder: (BuildContext dialogContext, _, _) => SettingsModalFrame(
      maxWidth: maxWidth,
      builder: (BuildContext context, Size panel) => SettingsSurfaceNavigator(
        builder: builder,
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    ),
    transitionBuilder: settingsModalTransition,
  );
}

/// The open of every settings modal: a short fade and a slight grow.
Widget settingsModalTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final CurvedAnimation curved = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
  );
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
      child: child,
    ),
  );
}

/// Opens a settings page the one way (docs/DESIGN.md §2):
///
///  * from inside a settings modal: pushed in that modal;
///  * on a phone: pushed as a full page;
///  * on a desktop window: in a new settings modal.
Future<void> openSettingsSurface(BuildContext context, WidgetBuilder builder) {
  final NavigatorState? inside = SettingsSurfaceScope.maybeOf(context) != null
      ? Navigator.of(context)
      : _SettingsSurfaceNavigatorState
            ._open
            .lastOrNull
            ?._navigator
            .currentState;
  if (inside != null) {
    return inside.push<void>(MaterialPageRoute<void>(builder: builder));
  }
  if (MobileLayout.isPhoneWidth(MediaQuery.sizeOf(context).width)) {
    return Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(builder: builder));
  }
  return showSettingsModal(context, builder: builder);
}

/// Closes every settings modal that is open, the newest first. For a row
/// in one settings modal that opens another (an agent's "Account & app
/// settings"), so two panels never stack.
void closeSettingsModals() {
  for (final _SettingsSurfaceNavigatorState state
      in _SettingsSurfaceNavigatorState._open.reversed.toList()) {
    if (state.mounted) state.widget.onClose();
  }
}
