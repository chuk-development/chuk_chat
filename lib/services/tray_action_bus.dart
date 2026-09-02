// lib/services/tray_action_bus.dart
import 'package:flutter/foundation.dart';

/// Decouples the desktop system tray menu from the widget tree.
///
/// [SystemTrayService] is a plain singleton with no [BuildContext], so it
/// cannot call into the running UI directly. It fires the notifiers here and
/// the desktop root wrapper listens and performs the actual UI action. This is
/// the same pattern the app already uses for artifact open requests.
class TrayActionBus {
  TrayActionBus._();

  static final TrayActionBus instance = TrayActionBus._();

  /// Bumped each time the tray "New Chat" item is clicked. Listeners start a
  /// fresh chat; the counter value itself carries no meaning beyond changing.
  final ValueNotifier<int> newChatRequested = ValueNotifier<int>(0);

  void requestNewChat() => newChatRequested.value++;
}
