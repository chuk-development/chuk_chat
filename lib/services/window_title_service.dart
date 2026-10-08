import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/window_title_setter.dart';

/// Keeps the desktop window title on the chat in view:
/// `Chuk Chat - <chat name>`, or `Chuk Chat` for a new chat.
///
/// It follows `ChatStorageService.selectedChatId`, which always points at the
/// chat of the half in front (Chat or Agents), and the chat list, because a
/// new chat gets its title only after the first reply.
class WindowTitleService {
  WindowTitleService._();

  static const String appName = 'Chuk Chat';

  /// Names a chat that is not in chuk's chat list, such as an Agents thread.
  /// Null, or a null answer, falls back to the stored chat title.
  static String? Function(String chatId)? nameResolver;

  static Future<void> Function(String title) _setter = setNativeWindowTitle;
  static bool _started = false;
  static String? _shown;
  static StreamSubscription<String?>? _changesSub;

  /// The window title for a chat name. Null or blank is a new chat.
  static String compose(String? chatName) {
    final String name = chatName?.trim() ?? '';
    return name.isEmpty ? appName : '$appName - $name';
  }

  /// The name of [chatId], or null for no chat or a chat with no title yet.
  static String? chatNameFor(String? chatId) {
    if (chatId == null) return null;
    final String? resolved = nameResolver?.call(chatId)?.trim();
    if (resolved != null && resolved.isNotEmpty) return resolved;
    final String? stored = ChatStorageService.getChatById(
      chatId,
    )?.title?.trim();
    return (stored == null || stored.isEmpty) ? null : stored;
  }

  /// Starts following the chat in view. Safe to call more than once.
  static void start() {
    if (_started || kIsWeb) return;
    _attach();
  }

  /// Attaches the listeners, then marks the service started.
  static void _attach() {
    ChatStorageService.selectedChatIdNotifier.addListener(refresh);
    _changesSub = ChatStorageService.changes.listen((_) => refresh());
    _started = true;
    refresh();
  }

  /// Sets the title again from the current state. Writes only on a change.
  static void refresh() {
    if (!_started) return;
    final String title = compose(
      chatNameFor(ChatStorageService.selectedChatId),
    );
    if (title == _shown) return;
    _shown = title;
    unawaited(_write(title));
  }

  /// Calls the setter. A failure, sync or async, leaves the old title.
  static Future<void> _write(String title) async {
    try {
      await _setter(title);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [WindowTitle] setTitle failed: $error');
      }
    }
  }

  /// Stops following and forgets the state. For tests.
  @visibleForTesting
  static void debugReset({Future<void> Function(String title)? setter}) {
    if (_started) {
      ChatStorageService.selectedChatIdNotifier.removeListener(refresh);
    }
    unawaited(_changesSub?.cancel());
    _changesSub = null;
    _started = false;
    _shown = null;
    nameResolver = null;
    _setter = setter ?? setNativeWindowTitle;
  }

  /// Starts with [setter] in place of the native call. For tests: the web
  /// check in [start] does not apply.
  @visibleForTesting
  static void debugStart(Future<void> Function(String title) setter) {
    debugReset(setter: setter);
    _attach();
  }
}
