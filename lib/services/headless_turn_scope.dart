// lib/services/headless_turn_scope.dart
//
// Marks a chat turn that runs with no chat screen: a queued message the
// outbox sends in the background (docs/OFFLINE_SEND.md). The mark is a zone
// value, so it reaches every async step of that turn (the stream callbacks,
// the tool loop, each tool call) and nothing else. A turn on screen that
// runs at the same time does not see it.
//
// Tools read it for two things:
//  * the chat the turn belongs to ([chatId]), so an artifact or a Typst file
//    lands in the queued chat and not in the chat that is open on screen;
//  * whether they may show UI ([isActive]). A tool that needs the user (a
//    permission prompt, another app's compose screen) fails with a clear
//    tool error instead of waiting for a screen that is not there.
import 'dart:async';

abstract final class HeadlessTurnScope {
  static const Symbol _key = #chukHeadlessTurnChatId;

  /// The error text a tool returns when it needs the app on screen.
  static const String needsScreenError =
      'Error: this action needs the app open on screen. The message was sent '
      'in the background, so it was not done. Tell the user to do it from '
      'the open chat.';

  /// Runs [body] as a headless turn of [chatId].
  static Future<T> run<T>(String chatId, Future<T> Function() body) =>
      runZoned(body, zoneValues: <Object?, Object?>{_key: chatId});

  /// The chat of the headless turn this code runs in, or null.
  static String? get chatId {
    final Object? value = Zone.current[_key];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Whether this code runs inside a headless turn.
  static bool get isActive => chatId != null;

  /// `device` tool actions that open another app's screen (a calendar
  /// editor, an SMS or mail composer). With no screen they would either do
  /// nothing or start an activity from the background.
  static const Set<String> screenOnlyDeviceActions = <String>{
    'create_calendar_event',
    'sms_draft',
    'email_draft',
  };

  /// The tool error for `device` [action] in a headless turn, or null when
  /// the action may run.
  static String? blockedDeviceAction(String action) =>
      isActive && screenOnlyDeviceActions.contains(action.toLowerCase())
      ? needsScreenError
      : null;
}
