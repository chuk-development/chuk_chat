// lib/services/tray_menu_model.dart
//
// What the desktop tray menu shows, as plain data. The native menu in
// `system_tray_service_io.dart` is drawn from this list, so the content
// (items, labels, order, recent chats) is testable without a tray host.
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/stored_chat.dart';

/// What a tray menu item does when it is clicked.
enum TrayMenuAction {
  /// Show the window and start a fresh chat.
  newChat,

  /// Show the window on the chat in [TrayMenuEntry.chatId].
  openChat,

  /// Show the window on chuk_chat's chats (Agents build only).
  showChats,

  /// Show the window on the Agents half (Agents build only).
  showAgents,

  /// Show a hidden window, or hide a shown one to the tray.
  toggleWindow,

  /// Show the window with the settings open.
  settings,

  /// Exit the app, also when closing the window only hides it.
  quit,
}

/// One row of the tray menu: an item, a separator or a disabled heading.
class TrayMenuEntry {
  const TrayMenuEntry.item(
    this.label,
    this.action, {
    this.chatId,
    this.enabled = true,
    this.checked = false,
  }) : isSeparator = false;

  const TrayMenuEntry.heading(this.label)
    : action = null,
      chatId = null,
      enabled = false,
      checked = false,
      isSeparator = false;

  const TrayMenuEntry.separator()
    : label = '',
      action = null,
      chatId = null,
      enabled = false,
      checked = false,
      isSeparator = true;

  final String label;
  final TrayMenuAction? action;

  /// The chat an [TrayMenuAction.openChat] item opens.
  final String? chatId;
  final bool enabled;

  /// For the Chats/Agents pair: the half that is in front.
  final bool checked;
  final bool isSeparator;

  @override
  String toString() {
    if (isSeparator) return '---';
    final String target = switch (action) {
      final TrayMenuAction a => ' -> ${a.name}',
      null => '',
    };
    final String chat = chatId == null ? '' : '($chatId)';
    return '$label$target$chat${checked ? ' [x]' : ''}';
  }
}

/// How many recent chats the menu lists.
const int kTrayRecentChatCount = 5;

/// The longest chat title, in characters, before it is cut with an ellipsis.
const int kTrayChatTitleMaxChars = 40;

/// [text] on one line, cut to [max] characters with a trailing ellipsis.
String truncateTrayLabel(String text, {int max = kTrayChatTitleMaxChars}) {
  final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final List<int> runes = oneLine.runes.toList();
  if (runes.length <= max) return oneLine;
  return '${String.fromCharCodes(runes.take(max - 1)).trimRight()}…';
}

/// The title the sidebar would show for [chat], or null for an untitled one.
String? trayChatTitle(StoredChat chat) {
  final String? custom = chat.customName?.trim();
  if (custom != null && custom.isNotEmpty) return custom;
  final String preview = chat.previewText.trim();
  return preview.isEmpty ? null : preview;
}

/// Builds the tray menu.
///
/// [chats] must already be sorted with the most recent first (as
/// `ChatStorageService.savedChats` is); the first [kTrayRecentChatCount]
/// chats with a title are listed. [agentsBuild] adds the Chats/Agents pair,
/// with [agentsInFront] naming the half that is shown.
List<TrayMenuEntry> buildTrayMenu({
  required AppLocalizations l,
  required List<StoredChat> chats,
  required bool windowVisible,
  bool agentsBuild = false,
  bool agentsInFront = false,
}) {
  final List<TrayMenuEntry> recent = <TrayMenuEntry>[];
  for (final StoredChat chat in chats) {
    if (recent.length >= kTrayRecentChatCount) break;
    final String? title = trayChatTitle(chat);
    if (title == null) continue;
    recent.add(
      TrayMenuEntry.item(
        truncateTrayLabel(title),
        TrayMenuAction.openChat,
        chatId: chat.id,
      ),
    );
  }

  return <TrayMenuEntry>[
    TrayMenuEntry.item(l.newChat, TrayMenuAction.newChat),
    if (agentsBuild) ...<TrayMenuEntry>[
      TrayMenuEntry.item(
        l.trayModeChats,
        TrayMenuAction.showChats,
        checked: !agentsInFront,
      ),
      TrayMenuEntry.item(
        l.trayModeAgents,
        TrayMenuAction.showAgents,
        checked: agentsInFront,
      ),
    ],
    const TrayMenuEntry.separator(),
    TrayMenuEntry.heading(l.trayRecentChats),
    if (recent.isEmpty) TrayMenuEntry.heading(l.trayNoRecentChats),
    ...recent,
    const TrayMenuEntry.separator(),
    TrayMenuEntry.item(
      windowVisible ? l.trayHideWindow : l.trayShowWindow,
      TrayMenuAction.toggleWindow,
    ),
    TrayMenuEntry.item(l.settings, TrayMenuAction.settings),
    const TrayMenuEntry.separator(),
    TrayMenuEntry.item(l.trayQuit, TrayMenuAction.quit),
  ];
}
