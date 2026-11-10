// lib/services/composer/composer_trigger.dart
//
// The one `/` and `@` menu of the composer (deepseek-harness idea 68,
// harness packages/client/ui-input-trigger and ui-commands).
//
// `/` lists skills, modes (plan, Agents only) and commands (compact, model,
// export, new chat). `@` lists the chat's files, agents, workspaces and other
// chats. The menu opens when the caret stands right after a `/` or `@` that
// starts a word, filters with a fuzzy subsequence match (prefix matches
// first), and is driven from the keyboard: Up/Down move, Enter picks, Tab
// opens a group (or picks a leaf), Esc goes up a level and then closes. Taps
// work the same on a phone.
//
// A picked skill, file, agent, workspace or chat becomes an atomic chip in
// the field (ChipTextEditingController). A command or a mode runs at once and
// its trigger text goes away.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show IconData;

import 'package:chuk_chat/widgets/composer/chip_text_controller.dart';

/// The groups of the menu, in display order.
enum TriggerGroup { skills, modes, commands, files, agents, workspaces, chats }

/// One row of the menu.
@immutable
class TriggerItem {
  const TriggerItem({
    required this.id,
    required this.label,
    required this.group,
    required this.icon,
    this.detail,
    this.chipLiteral,
    this.chipKind = ComposerChipKind.file,
    this.onPicked,
    this.children,
  });

  final String id;
  final String label;
  final TriggerGroup group;
  final IconData icon;
  final String? detail;

  /// The text the chip carries into the message. Null: no chip (a command
  /// or a mode runs instead).
  final String? chipLiteral;
  final ComposerChipKind chipKind;

  /// Runs when the item is picked (after its chip went in, if any): attach
  /// a chat reference, run a command, switch a mode.
  final VoidCallback? onPicked;

  /// A group row: Tab or Enter opens it.
  final List<TriggerItem>? children;

  bool get isGroup => children != null;
}

/// Where the composer's trigger text is: [start] is the `/` or `@`,
/// [end] the caret.
@immutable
class TriggerMatch {
  const TriggerMatch({
    required this.trigger,
    required this.start,
    required this.end,
    required this.query,
  });

  final String trigger;
  final int start;
  final int end;
  final String query;

  @override
  bool operator ==(Object other) =>
      other is TriggerMatch &&
      other.trigger == trigger &&
      other.start == start &&
      other.end == end &&
      other.query == query;

  @override
  int get hashCode => Object.hash(trigger, start, end, query);
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D;

/// The trigger the caret stands in, or null. [inChip] tells which offsets
/// belong to a chip: a chip's own `@`/`/` never opens the menu.
TriggerMatch? detectTrigger(
  TextEditingValue value, {
  bool Function(int offset)? inChip,
}) {
  final TextSelection sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final String text = value.text;
  final int caret = sel.baseOffset;
  if (caret <= 0 || caret > text.length) return null;
  int i = caret - 1;
  while (i >= 0 && !_isSpace(text.codeUnitAt(i))) {
    i--;
  }
  final int start = i + 1;
  if (start >= caret) return null;
  final String first = text[start];
  if (first != '/' && first != '@') return null;
  if (inChip != null && inChip(start)) return null;
  final String query = text.substring(start + 1, caret);
  // A second trigger character in the word ("//", "a@b") is not a trigger.
  if (query.contains('/') || query.contains('@')) return null;
  return TriggerMatch(trigger: first, start: start, end: caret, query: query);
}

/// How well [label] matches [query]: 0 prefix, 1 a word starts with it,
/// 2 contains it, 3 subsequence; null when the letters are not in order.
int? fuzzyTier(String query, String label) {
  final String q = query.toLowerCase().trim();
  if (q.isEmpty) return 0;
  final String l = label.toLowerCase();
  if (l.startsWith(q)) return 0;
  final int at = l.indexOf(q);
  if (at > 0) {
    final String before = l[at - 1];
    if (before == ' ' || before == '-' || before == '_' || before == '/') {
      return 1;
    }
    return 2;
  }
  int j = 0;
  for (int i = 0; i < l.length && j < q.length; i++) {
    if (l[i] == q[j]) j++;
  }
  return j == q.length ? 3 : null;
}

/// [items] that match [query], best first (tier, then shorter label, then
/// the given order). Group rows are matched by their own label.
List<TriggerItem> filterTriggerItems(List<TriggerItem> items, String query) {
  if (query.trim().isEmpty) return List<TriggerItem>.of(items);
  final List<(int, int, TriggerItem)> scored = <(int, int, TriggerItem)>[];
  for (int i = 0; i < items.length; i++) {
    final int? tier = fuzzyTier(query, items[i].label);
    if (tier != null) scored.add((tier, i, items[i]));
  }
  scored.sort(((int, int, TriggerItem) a, (int, int, TriggerItem) b) {
    final int byTier = a.$1.compareTo(b.$1);
    if (byTier != 0) return byTier;
    final int byLength = a.$3.label.length.compareTo(b.$3.label.length);
    if (byLength != 0) return byLength;
    return a.$2.compareTo(b.$2);
  });
  return <TriggerItem>[for (final s in scored) s.$3];
}

/// What feeds the menu. Each list is read when the menu opens.
class ComposerTriggerSource {
  const ComposerTriggerSource({this.slash = _none, this.at = _none});

  final FutureOr<List<TriggerItem>> Function() slash;
  final FutureOr<List<TriggerItem>> Function() at;

  static List<TriggerItem> _none() => const <TriggerItem>[];
}

/// The menu's state over one [ChipTextEditingController].
class ComposerTriggerController extends ChangeNotifier {
  ComposerTriggerController({required this.text, required this.source}) {
    text.addListener(_onText);
  }

  final ChipTextEditingController text;

  /// Builds the lists; read each time the menu opens.
  final ComposerTriggerSource Function() source;

  TriggerMatch? _match;
  List<TriggerItem> _root = const <TriggerItem>[];
  String? _rootTrigger;
  final List<TriggerItem> _path = <TriggerItem>[];
  List<TriggerItem> _visible = const <TriggerItem>[];
  int _highlight = 0;

  /// The trigger start the user closed with Esc. The menu stays shut until
  /// the caret leaves that word.
  int? _dismissedStart;
  int _loadToken = 0;

  TriggerMatch? get match => _match;
  bool get isOpen {
    final TriggerMatch? m = _match;
    return m != null && (_visible.isNotEmpty || m.query.isEmpty);
  }

  List<TriggerItem> get visible => _visible;
  int get highlight => _highlight;

  /// The open group, or null at the top level.
  TriggerItem? get group => _path.isEmpty ? null : _path.last;

  @override
  void dispose() {
    text.removeListener(_onText);
    super.dispose();
  }

  void _onText() {
    final TriggerMatch? next = detectTrigger(text.value, inChip: text.isInChip);
    if (next == null) {
      _dismissedStart = null;
      _close();
      return;
    }
    if (_dismissedStart == next.start) {
      _close();
      return;
    }
    if (_dismissedStart != null && _dismissedStart != next.start) {
      _dismissedStart = null;
    }
    final TriggerMatch? prev = _match;
    final bool sameWord =
        prev != null &&
        prev.start == next.start &&
        prev.trigger == next.trigger;
    if (sameWord && prev == next) return;
    _match = next;
    if (!sameWord || _rootTrigger != next.trigger) {
      _path.clear();
      _load(next.trigger);
    }
    _refilter();
  }

  void _load(String trigger) {
    _rootTrigger = trigger;
    _root = const <TriggerItem>[];
    final ComposerTriggerSource src = source();
    final FutureOr<List<TriggerItem>> items = trigger == '/'
        ? src.slash()
        : src.at();
    if (items is List<TriggerItem>) {
      _root = items;
      return;
    }
    final int token = ++_loadToken;
    unawaited(
      items.then((List<TriggerItem> loaded) {
        if (token != _loadToken || _rootTrigger != trigger) return;
        _root = loaded;
        _refilter();
      }),
    );
  }

  /// The top level: with no query, one row per group (Tab opens it); with a
  /// query, every leaf that matches, best first.
  List<TriggerItem> _topLevel(String query) {
    final Map<TriggerGroup, List<TriggerItem>> byGroup =
        <TriggerGroup, List<TriggerItem>>{};
    for (final TriggerItem item in _root) {
      (byGroup[item.group] ??= <TriggerItem>[]).add(item);
    }
    if (query.isEmpty) {
      return <TriggerItem>[
        for (final TriggerGroup g in TriggerGroup.values)
          if (byGroup[g] case final List<TriggerItem> items)
            // A group of one is shown as its item.
            if (items.length == 1)
              items.single
            else
              TriggerItem(
                id: 'group:${g.name}',
                label: g.name,
                group: g,
                icon: items.first.icon,
                children: items,
              ),
      ];
    }
    return filterTriggerItems(_root, query);
  }

  void _refilter() {
    final TriggerMatch? m = _match;
    if (m == null) return;
    final TriggerItem? open = group;
    _visible = open == null
        ? _topLevel(m.query)
        : filterTriggerItems(open.children ?? const <TriggerItem>[], m.query);
    if (_highlight >= _visible.length) _highlight = 0;
    notifyListeners();
  }

  void _close() {
    if (_match == null && _visible.isEmpty) return;
    _match = null;
    _visible = const <TriggerItem>[];
    _path.clear();
    _highlight = 0;
    _rootTrigger = null;
    notifyListeners();
  }

  void move(int delta) {
    if (_visible.isEmpty) return;
    _highlight = (_highlight + delta) % _visible.length;
    if (_highlight < 0) _highlight += _visible.length;
    notifyListeners();
  }

  void setHighlight(int index) {
    if (index < 0 || index >= _visible.length) return;
    _highlight = index;
    notifyListeners();
  }

  /// Esc: up one level, then close.
  void back() {
    if (_path.isNotEmpty) {
      _path.removeLast();
      _clearQuery();
      _highlight = 0;
      _refilter();
      return;
    }
    _dismissedStart = _match?.start;
    _close();
  }

  /// Opens [item]'s group: the query typed so far goes away.
  void drill(TriggerItem item) {
    if (!item.isGroup) return;
    _path.add(item);
    _highlight = 0;
    _clearQuery();
    _refilter();
  }

  void _clearQuery() {
    final TriggerMatch? m = _match;
    if (m == null || m.query.isEmpty) return;
    text.replaceRangePlain(m.start + 1, m.end, '');
  }

  /// Picks [item]: a group opens, a chip goes in, a command runs.
  void pick(TriggerItem item) {
    final TriggerMatch? m = _match;
    if (m == null) return;
    if (item.isGroup) {
      drill(item);
      return;
    }
    final String? literal = item.chipLiteral;
    _dismissedStart = null;
    if (literal != null) {
      text.insertChip(
        start: m.start,
        end: m.end,
        literal: literal,
        label: literal,
        kind: item.chipKind,
      );
    } else {
      text.replaceRangePlain(m.start, m.end, '');
    }
    _close();
    item.onPicked?.call();
  }

  /// Keyboard handling while the menu is open. True when the key was used.
  bool handleKey(KeyEvent event) {
    if (!isOpen) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      move(1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      move(-1);
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      back();
      return true;
    }
    if (_visible.isEmpty) return false;
    final TriggerItem current = _visible[_highlight];
    if (key == LogicalKeyboardKey.tab) {
      if (current.isGroup) {
        drill(current);
      } else {
        pick(current);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) return false;
      pick(current);
      return true;
    }
    return false;
  }
}
