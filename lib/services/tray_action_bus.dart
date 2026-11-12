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

  /// Bumped each time the tray "Settings" item is clicked.
  final ValueNotifier<int> settingsRequested = ValueNotifier<int>(0);

  /// The chat a tray "recent chat" item asked to open. Read it in a
  /// [chatOpenRequested] listener.
  String? requestedChatId;

  /// Bumped each time a tray "recent chat" item is clicked; the chat is
  /// [requestedChatId]. A counter, so the same chat twice still notifies.
  final ValueNotifier<int> chatOpenRequested = ValueNotifier<int>(0);

  void requestNewChat() => newChatRequested.value++;

  void requestSettings() => settingsRequested.value++;

  void requestOpenChat(String chatId) {
    requestedChatId = chatId;
    chatOpenRequested.value++;
  }
}
