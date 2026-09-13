/// The app-level [WidgetsBindingObserver] Agents was missing.
///
/// [AppLifecycleService] is imported from chuk_chat and is what the imported
/// chat UI registers its resume and pause callbacks on
/// (`platform_specific/chat/chat_ui_mobile.dart`,
/// `platform_specific/chat/handlers/streaming_message_handler.dart`). Upstream
/// drives it from its own `main.dart`. Agents never did: nothing in `app/lib`
/// called `handleLifecycleState`, so every one of those callbacks was dead
/// code — a stream cut when the phone went to sleep was never resumed, and the
/// queued-prompt flush never got its "the app is back" signal.
///
/// This widget is that missing wire. It is a widget rather than a mixin on the
/// app state so the wiring itself can be tested without booting the whole app.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/app_lifecycle_service.dart';

class AppLifecycleObserver extends StatefulWidget {
  const AppLifecycleObserver({super.key, required this.child, this.onState});

  final Widget child;

  /// Where a lifecycle change goes. Defaults to [AppLifecycleService]; a test
  /// passes its own so it does not have to stand up sync, network and
  /// streaming singletons to observe one callback.
  final void Function(AppLifecycleState state)? onState;

  @override
  State<AppLifecycleObserver> createState() => _AppLifecycleObserverState();
}

class _AppLifecycleObserverState extends State<AppLifecycleObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final void Function(AppLifecycleState) sink =
        widget.onState ?? AppLifecycleService.instance.handleLifecycleState;
    sink(state);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
