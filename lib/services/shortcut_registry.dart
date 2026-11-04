// lib/services/shortcut_registry.dart
//
// One list of the app's keyboard shortcuts: id → keys, label, description.
// Key handlers ask the registry whether an event is "their" shortcut, and
// tooltips and the shortcut dialog (Ctrl+/) print the same label, so a key
// that changes changes everywhere at once.
//
// Keys are written once, the PC way ("Ctrl+Shift+N"). On macOS the primary
// modifier is Cmd: the activator uses `meta` and the label goes through
// `deskShortcutLabel` ("⌘⇧N"-style), the same formatter the Agents desktop
// uses. Rebinding is not supported yet.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_controls.dart'
    show deskShortcutLabel;

/// Where a shortcut works. The dialog groups by it.
enum ShortcutScope { chat, agents }

/// One shortcut.
@immutable
class ShortcutEntry {
  const ShortcutEntry({
    required this.id,
    required this.keys,
    required this.descriptionKey,
    required this.scope,
    this.bindable = true,
  });

  /// Stable id, e.g. `chat.send`.
  final String id;

  /// The keys, PC style: `Ctrl+/`, `Shift+Enter`, `Ctrl+1…9`.
  final String keys;

  /// l10n key of the one-line description.
  final String descriptionKey;

  final ShortcutScope scope;

  /// False for an entry that stands for a range (`Ctrl+1…9`): it has a label
  /// but no single activator.
  final bool bindable;
}

/// The registry. Static: there is one set of shortcuts per app.
abstract final class AppShortcuts {
  static const String send = 'chat.send';
  static const String newline = 'chat.newline';
  static const String cancelEdit = 'chat.cancelEdit';
  static const String editLast = 'chat.editLast';
  static const String paste = 'chat.paste';
  static const String showShortcuts = 'app.showShortcuts';
  static const String quickSwitcher = 'agents.quickSwitcher';
  static const String newAgent = 'agents.newAgent';
  static const String newRoom = 'agents.newRoom';
  static const String openNthAgent = 'agents.openNth';
  static const String toggleDetails = 'agents.toggleDetails';
  static const String toggleRoster = 'agents.toggleRoster';
  static const String closeOverlay = 'agents.close';

  /// Every shortcut, in the order the dialog lists them.
  static const List<ShortcutEntry> entries = <ShortcutEntry>[
    ShortcutEntry(
      id: send,
      keys: 'Enter',
      descriptionKey: 'shortcutSend',
      scope: ShortcutScope.chat,
    ),
    ShortcutEntry(
      id: newline,
      keys: 'Shift+Enter',
      descriptionKey: 'shortcutNewline',
      scope: ShortcutScope.chat,
    ),
    ShortcutEntry(
      id: cancelEdit,
      keys: 'Esc',
      descriptionKey: 'shortcutCancelEdit',
      scope: ShortcutScope.chat,
    ),
    ShortcutEntry(
      id: editLast,
      keys: 'Up',
      descriptionKey: 'shortcutEditLast',
      scope: ShortcutScope.chat,
    ),
    ShortcutEntry(
      id: paste,
      keys: 'Ctrl+V',
      descriptionKey: 'shortcutPaste',
      scope: ShortcutScope.chat,
    ),
    ShortcutEntry(
      id: showShortcuts,
      keys: 'Ctrl+/',
      descriptionKey: 'shortcutShowShortcuts',
      scope: ShortcutScope.chat,
    ),
    // The Agents desktop (agents_desktop_layout.dart) handles these itself;
    // they are listed here so the dialog and tooltips can show them.
    ShortcutEntry(
      id: quickSwitcher,
      keys: 'Ctrl+K',
      descriptionKey: 'shortcutQuickSwitcher',
      scope: ShortcutScope.agents,
    ),
    ShortcutEntry(
      id: newAgent,
      keys: 'Ctrl+N',
      descriptionKey: 'shortcutNewAgent',
      scope: ShortcutScope.agents,
    ),
    ShortcutEntry(
      id: newRoom,
      keys: 'Ctrl+Shift+N',
      descriptionKey: 'shortcutNewRoom',
      scope: ShortcutScope.agents,
    ),
    ShortcutEntry(
      id: openNthAgent,
      keys: 'Ctrl+1…9',
      descriptionKey: 'shortcutOpenNthAgent',
      scope: ShortcutScope.agents,
      bindable: false,
    ),
    ShortcutEntry(
      id: toggleDetails,
      keys: 'Ctrl+.',
      descriptionKey: 'shortcutToggleDetails',
      scope: ShortcutScope.agents,
    ),
    ShortcutEntry(
      id: toggleRoster,
      keys: 'Ctrl+B',
      descriptionKey: 'shortcutToggleRoster',
      scope: ShortcutScope.agents,
    ),
    ShortcutEntry(
      id: closeOverlay,
      keys: 'Esc',
      descriptionKey: 'shortcutCloseOverlay',
      scope: ShortcutScope.agents,
    ),
  ];

  static final Map<String, ShortcutEntry> _byId = <String, ShortcutEntry>{
    for (final ShortcutEntry e in entries) e.id: e,
  };

  /// The entry for [id]. Throws on an unknown id: a typo is a bug.
  static ShortcutEntry entry(String id) {
    final ShortcutEntry? e = _byId[id];
    if (e == null) throw ArgumentError.value(id, 'id', 'unknown shortcut');
    return e;
  }

  /// The keys as this platform prints them: `Ctrl+/` on Linux and Windows,
  /// `⌘/` on macOS.
  static String label(String id) => deskShortcutLabel(entry(id).keys);

  /// The keys split into caps for the dialog: `['Ctrl', 'Shift', 'N']`, or
  /// `['⌘', 'N']` on macOS.
  static List<String> keyCaps(String id) {
    final String keys = entry(id).keys;
    final List<String> parts = keys.split('+');
    if (defaultTargetPlatform != TargetPlatform.macOS) return parts;
    return <String>[for (final String p in parts) p == 'Ctrl' ? '⌘' : p];
  }

  /// `text (keys)`, for a tooltip.
  static String tooltip(String text, String id) => '$text (${label(id)})';

  /// The description in [l10n]'s language, English without one.
  static String describe(String id, [AppLocalizations? l10n]) {
    final String key = entry(id).descriptionKey;
    return l10n?.shortcutDescription(key) ?? stringsEn[key] ?? id;
  }

  /// The activator for [id] on this platform. Null for a range entry.
  static SingleActivator? activator(String id) {
    final ShortcutEntry e = entry(id);
    if (!e.bindable) return null;
    final bool mac = defaultTargetPlatform == TargetPlatform.macOS;
    bool primary = false;
    bool shift = false;
    bool alt = false;
    LogicalKeyboardKey? trigger;
    for (final String part in e.keys.split('+')) {
      switch (part) {
        case 'Ctrl':
          primary = true;
        case 'Shift':
          shift = true;
        case 'Alt':
          alt = true;
        default:
          trigger = _keyFor(part);
      }
    }
    if (trigger == null) return null;
    return SingleActivator(
      trigger,
      control: primary && !mac,
      meta: primary && mac,
      shift: shift,
      alt: alt,
    );
  }

  /// Whether [event] triggers [id] given the keys held right now.
  static bool matches(String id, KeyEvent event) {
    final SingleActivator? a = activator(id);
    if (a == null) return false;
    return a.accepts(event, HardwareKeyboard.instance);
  }

  static LogicalKeyboardKey? _keyFor(String name) {
    switch (name) {
      case 'Enter':
        return LogicalKeyboardKey.enter;
      case 'Esc':
        return LogicalKeyboardKey.escape;
      case 'Up':
        return LogicalKeyboardKey.arrowUp;
      case '/':
        return LogicalKeyboardKey.slash;
      case '.':
        return LogicalKeyboardKey.period;
    }
    if (name.length == 1) {
      final int c = name.toUpperCase().codeUnitAt(0);
      if (c >= 0x41 && c <= 0x5A) {
        // The ids of letter keys are their lower-case code units.
        return LogicalKeyboardKey.findKeyByKeyId(c + 0x20);
      }
      if (c >= 0x30 && c <= 0x39) return LogicalKeyboardKey.findKeyByKeyId(c);
    }
    return null;
  }
}
