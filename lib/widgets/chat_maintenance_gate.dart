// lib/widgets/chat_maintenance_gate.dart
//
// The blocking maintenance screen of the one-time chat rewrite to payload
// v3 (services/chat_payload_migration_service.dart). It sits between the
// auth gate and the shell: while the rewrite runs, the shell is not built,
// so no sidebar and no chat loads, and there is nothing to tap.

import 'dart:async';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/chat_payload_migration_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:flutter/material.dart';

class ChatMaintenanceGate extends StatefulWidget {
  const ChatMaintenanceGate({
    super.key,
    required this.child,
    this.controller,
    this.syncingHintDelay = const Duration(milliseconds: 400),
  });

  /// The shell, built once the chats are ready.
  final Widget child;

  /// Test seam; the app uses [ChatMaintenanceController.instance].
  final ChatMaintenanceController? controller;

  /// How long the check may run before the screen says what it waits for.
  final Duration syncingHintDelay;

  @override
  State<ChatMaintenanceGate> createState() => _ChatMaintenanceGateState();
}

class _ChatMaintenanceGateState extends State<ChatMaintenanceGate> {
  ChatMaintenanceController get _controller =>
      widget.controller ?? ChatMaintenanceController.instance;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChange);
    _start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// The session init starts the same run; whoever comes first starts it.
  void _start() {
    final String? userId = SupabaseService.isInitialized
        ? SupabaseService.auth.currentUser?.id
        : null;
    if (userId != null && _controller.phase == ChatMaintenancePhase.idle) {
      unawaited(_controller.ensureReady(userId));
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_controller.phase) {
      case ChatMaintenancePhase.done:
        return widget.child;
      case ChatMaintenancePhase.idle:
        // Signed out (nothing to check) or about to start.
        final bool signedIn =
            SupabaseService.isInitialized &&
            SupabaseService.auth.currentUser != null;
        return signedIn
            ? _Checking(hintDelay: widget.syncingHintDelay, showHint: false)
            : widget.child;
      case ChatMaintenancePhase.checking:
        return _Checking(
          hintDelay: widget.syncingHintDelay,
          showHint: _controller.showsSyncHint,
        );
      case ChatMaintenancePhase.running:
      case ChatMaintenancePhase.failed:
        return PopScope(
          canPop: false,
          child: ChatMaintenanceScreen(controller: _controller),
        );
    }
  }
}

/// The app surface while the check runs. On a normal start that is a few
/// milliseconds (the cloud is checked behind the app), so the surface stays
/// empty and no text flashes. Right after a sign-in the whole check runs
/// first (the key is set up and the cloud chats are listed), which takes
/// seconds on a new install; an empty screen for that long looks like a
/// broken app, so there [showHint] is set and after [hintDelay] a loader and
/// a line of text fade in.
class _Checking extends StatefulWidget {
  const _Checking({required this.hintDelay, required this.showHint});

  final Duration hintDelay;
  final bool showHint;

  @override
  State<_Checking> createState() => _CheckingState();
}

class _CheckingState extends State<_Checking> {
  Timer? _timer;
  bool _delayPassed = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.hintDelay, () {
      if (mounted) setState(() => _delayPassed = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: widget.showHint && _delayPassed ? _hint(context, theme) : null,
    );
  }

  Widget _hint(BuildContext context, ThemeData theme) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: kExpressiveShort,
      curve: kExpressiveDecelerate,
      builder: (BuildContext context, double t, Widget? child) =>
          Opacity(opacity: t, child: child),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const ExpressiveLoader(),
                const SizedBox(height: 24),
                Text(
                  l10n.maintenanceSyncing,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.maintenanceSyncingHint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatMaintenanceScreen extends StatelessWidget {
  const ChatMaintenanceScreen({super.key, required this.controller});

  final ChatMaintenanceController controller;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    final bool failed = controller.phase == ChatMaintenancePhase.failed;
    return ExpressiveScreen(
      title: failed ? l10n.maintenanceFailedTitle : l10n.maintenanceTitle,
      showBack: false,
      builder: (BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
              24,
              MediaQuery.paddingOf(context).top + 8,
              24,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: failed
                ? _failure(context, l10n)
                : _running(context, l10n),
          ),
        ),
      ),
    );
  }

  List<Widget> _running(BuildContext context, AppLocalizations l10n) {
    final ChatMaintenanceProgress p = controller.progress;
    return <Widget>[
      Text(
        l10n.maintenanceBody,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 28),
      _ProgressRow(
        key: const ValueKey<String>('maintenance-migrate'),
        label: l10n.maintenanceMigrating,
        count: l10n.maintenanceCount(p.migrated, p.total),
        value: p.total == 0 ? null : p.migrated / p.total,
      ),
      const SizedBox(height: 20),
      _ProgressRow(
        key: const ValueKey<String>('maintenance-verify'),
        label: l10n.maintenanceVerifying,
        count: l10n.maintenanceCount(p.verified, p.total),
        value: p.total == 0 ? null : p.verified / p.total,
      ),
    ];
  }

  List<Widget> _failure(BuildContext context, AppLocalizations l10n) {
    return <Widget>[
      Text(
        l10n.maintenanceFailedBody,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 28),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          ExpressiveButton(label: l10n.retry, onTap: controller.retry),
          ExpressiveButton(
            label: l10n.maintenanceContinue,
            tonal: true,
            onTap: controller.continueAnyway,
          ),
        ],
      ),
    ];
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    super.key,
    required this.label,
    required this.count,
    required this.value,
  });

  final String label;
  final String count;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
            Text(
              count,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: value,
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
        ),
      ],
    );
  }
}
