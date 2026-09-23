/// The roster: the left pane of the Agents desktop layout (docs/DESIGN.md
/// §14.1, §14.3).
///
/// A desktop list, not a phone inbox that got wider: the app name and the two
/// pane buttons in a 48 px header that lines up with the thread's title bar, a
/// search field, the sections "Agents" and "Rooms" in dense rows, and the
/// account row at the bottom.
///
///  * An agent row is 36 px, a room row 32 px; 8 px of horizontal padding and
///    a 24 px face. Hover fills the row with `surfaceContainerHigh`; the
///    selected row takes `secondaryContainer` and a 3 px accent bar on its left
///    edge. Unread is the bold name and a small dot — no count.
///  * A right click opens the row's context menu (profile, rename, pin, hide,
///    delete). The "…" button that opens the same menu shows on hover only.
///  * [collapsed] folds the pane to a 56 px rail of faces (Ctrl+B).
///
/// Every coworker has exactly one long-lived thread, so a row is an agent and
/// picking it opens that thread. The phone's inbox is `MobileAgentList`; this
/// widget is only ever built by the desktop layout.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_controls.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_dialog.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/coworker_name_dialog.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';
import 'package:chuk_chat/widgets/room_faces.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

// The name dialog moved to its own file when it was rebuilt in the app's
// language; it is exported here so every caller keeps one import.
export 'package:chuk_chat/widgets/coworker_name_dialog.dart';

/// The brand row's sizing knob: `SbBrand` draws the frozen wordmark and uses
/// this number as its logo height. Not a type-scale role.
const double kSidebarBrandWordmarkSize = 16;

/// Which coworkers the user pinned to the top of the desktop roster. Local to
/// this device, like the pane widths: a pin is how one window is arranged, not
/// something the host needs to know.
class DesktopRosterPins extends ChangeNotifier {
  DesktopRosterPins._();

  static final DesktopRosterPins instance = DesktopRosterPins._();

  static const String _kKey = 'agents.desktop.pinned_v1';

  final Set<String> _ids = <String>{};
  bool _loaded = false;

  Set<String> get ids => Set<String>.unmodifiable(_ids);

  bool isPinned(String agentId) => _ids.contains(agentId);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_kKey);
      if (raw == null) return;
      final Object? data = jsonDecode(raw);
      if (data is! List) return;
      _ids
        ..clear()
        ..addAll(data.whereType<String>());
      notifyListeners();
    } catch (_) {
      // Unreadable pins are no pins.
    }
  }

  void toggle(String agentId) {
    if (!_ids.remove(agentId)) _ids.add(agentId);
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(_ids.toList()));
    } catch (_) {
      // A pin that is not written is lost on the next launch, nothing more.
    }
  }

  @visibleForTesting
  void reset() {
    _ids.clear();
    _loaded = false;
    notifyListeners();
  }
}

/// The agents in the order the desktop roster shows them: pinned first, then
/// the rest, each keeping the roster's own order. Ctrl+1 … Ctrl+9 count this
/// list, so the roster and the shortcut can never disagree.
List<AgentsAgent> desktopRosterOrder(
  List<AgentsAgent> agents,
  Set<String> pinned,
) => <AgentsAgent>[
  for (final AgentsAgent a in agents)
    if (pinned.contains(a.id)) a,
  for (final AgentsAgent a in agents)
    if (!pinned.contains(a.id)) a,
];

class AgentRosterView extends StatefulWidget {
  const AgentRosterView({
    super.key,
    required this.source,
    required this.onSelect,
    this.selectedAgentId,
    this.selectedThreadKey,
    this.selectedRoomId,
    this.onAddAgent,
    this.onDeleteAgent,
    this.onRenameAgent,
    this.onOpenRooms,
    this.rooms,
    this.onOpenRoom,
    this.onCreateRoom,
    this.onRenameRoom,
    this.onDeleteRoom,
    this.onManageRoomMembers,
    this.onOpenSettings,
    this.onOpenProfile,
    this.onOpenQuickSwitcher,
    this.collapsed = false,
    this.onToggleCollapsed,
    this.accountLabel,
    this.now,
    this.readMarks,
    this.profiles,
    this.pins,
  });

  final AgentRosterSource source;

  /// Called with the agent and the thread the user picked. A coworker has one
  /// permanent thread, so this always reports that single thread's key.
  final void Function(String agentId, String threadKey) onSelect;

  final String? selectedAgentId;
  final String? selectedThreadKey;

  /// The room open in the centre pane, if one is. Its row is the selected one.
  final String? selectedRoomId;

  /// Opens the new-agent dialog. Hidden when null.
  final VoidCallback? onAddAgent;

  /// Deletes a coworker, after the user confirmed. A Delete item appears for
  /// agents that are not the paired host (the host agent is the real device).
  final void Function(String agentId)? onDeleteAgent;

  /// Renames a coworker; reports the trimmed, non-empty, changed name.
  final void Function(String agentId, String name)? onRenameAgent;

  /// Opens a coworker's profile page. Hidden when null.
  final void Function(AgentsAgent agent)? onOpenProfile;

  /// Control Rooms in the right pane.
  final VoidCallback? onOpenRooms;

  /// The group rooms, listed under "Rooms". Null leaves the section out.
  final RoomSource? rooms;

  /// Opens a room. Rooms are not listed without it.
  final void Function(String roomId)? onOpenRoom;

  /// Starts a new room.
  final VoidCallback? onCreateRoom;

  final void Function(String roomId, String name)? onRenameRoom;
  final void Function(String roomId)? onDeleteRoom;
  final void Function(String roomId)? onManageRoomMembers;

  /// Settings — the gear in the account row. The row is hidden when null.
  final VoidCallback? onOpenSettings;

  /// The quick switcher (Ctrl+K), from the search field's button.
  final VoidCallback? onOpenQuickSwitcher;

  /// Folded to the rail of faces.
  final bool collapsed;

  /// Folds or unfolds the pane (Ctrl+B).
  final VoidCallback? onToggleCollapsed;

  /// The account row's name. Null lets the roster load the profile itself.
  final String? accountLabel;

  /// Clock seam so a row's time is deterministic in a test.
  final DateTime Function()? now;

  final AgentReadMarks? readMarks;
  final AgentProfileStore? profiles;
  final DesktopRosterPins? pins;

  @override
  State<AgentRosterView> createState() => _AgentRosterViewState();
}

class _AgentRosterViewState extends State<AgentRosterView> {
  ProfileRecord? _profile;
  final TextEditingController _search = TextEditingController();
  bool _hiddenOpen = false;

  bool get _hosted => SupabaseService.isInitialized;

  DesktopRosterPins get _pins => widget.pins ?? DesktopRosterPins.instance;
  AgentReadMarks get _marks => widget.readMarks ?? AgentReadMarks.instance;
  AgentProfileStore get _profiles =>
      widget.profiles ?? AgentProfileStore.instance;

  @override
  void initState() {
    super.initState();
    if (_hosted) _loadProfile();
    _search.addListener(_onSearch);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearch);
    _search.dispose();
    super.dispose();
  }

  void _onSearch() => setState(() {});

  Future<void> _loadProfile() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    try {
      final record = await const ProfileService().loadOrCreateProfile();
      if (!mounted) return;
      setState(() => _profile = record);
    } catch (_) {
      // The row shows the fallback label.
    }
  }

  String _displayNameFor(ProfileRecord? profile) {
    if (profile == null) return 'Account';
    if (profile.displayName.trim().isNotEmpty)
      return profile.displayName.trim();
    if (profile.email.trim().isNotEmpty) return profile.email.trim();
    return 'Account';
  }

  DateTime _now() => (widget.now ?? DateTime.now)();

  bool _isSelected(AgentsAgent agent) =>
      widget.selectedRoomId == null &&
      agent.id == widget.selectedAgentId &&
      (widget.selectedThreadKey == null ||
          agent.threads.any(
            (thread) => thread.key == widget.selectedThreadKey,
          ));

  void _pick(AgentsAgent agent) {
    if (agent.threads.isEmpty) return;
    widget.onSelect(agent.id, agent.threads.first.key);
  }

  // --- menus -------------------------------------------------------------------

  Future<void> _renameAgent(AgentsAgent agent) async {
    final String? name = await showCoworkerNameDialog(
      context,
      title: 'Rename agent',
      initialName: agent.name,
      submitLabel: 'Rename',
    );
    if (!mounted) return;
    if (name == null || name.isEmpty || name == agent.name) return;
    widget.onRenameAgent?.call(agent.id, name);
  }

  Future<void> _deleteAgent(AgentsAgent agent) async {
    final bool ok = await showAgentsConfirmDialog(
      context,
      title: 'Delete ${agent.name}?',
      message:
          'The agent and its conversation leave this app. Rooms it was in '
          'lose it as a member.',
    );
    if (!mounted || !ok) return;
    widget.onDeleteAgent?.call(agent.id);
  }

  Future<void> _renameRoom(AgentsRoom room) async {
    final String? name = await showCoworkerNameDialog(
      context,
      title: 'Rename room',
      initialName: room.name,
      submitLabel: 'Rename',
    );
    if (!mounted) return;
    if (name == null || name.isEmpty || name == room.name) return;
    widget.onRenameRoom?.call(room.id, name);
  }

  Future<void> _deleteRoom(AgentsRoom room) async {
    final bool ok = await showAgentsConfirmDialog(
      context,
      title: 'Delete ${room.name}?',
      message: 'The room and its conversation are removed for everyone in it.',
    );
    if (!mounted || !ok) return;
    widget.onDeleteRoom?.call(room.id);
  }

  PopupMenuItem<VoidCallback> _item(
    String label,
    IconData icon,
    VoidCallback onTap, {
    Color? tone,
    String? shortcut,
  }) => PopupMenuItem<VoidCallback>(
    value: onTap,
    padding: EdgeInsets.zero,
    child: MenuActionRow(
      icon: icon,
      label: label,
      tone: tone,
      shortcut: shortcut,
    ),
  );

  Future<void> _openAgentMenu(
    BuildContext anchor,
    AgentsAgent agent, {
    Offset? at,
  }) async {
    final ColorScheme scheme = Theme.of(anchor).colorScheme;
    final bool pinned = _pins.isPinned(agent.id);
    final VoidCallback? picked = await showAnchoredMenu<VoidCallback>(
      anchor,
      anchorPoint: at,
      color: scheme.surfaceContainerHigh,
      items: <PopupMenuEntry<VoidCallback>>[
        if (widget.onOpenProfile != null)
          _item(
            'Profile',
            Icons.person_outline,
            () => widget.onOpenProfile!(agent),
          ),
        if (widget.onRenameAgent != null)
          _item(
            'Rename',
            Icons.edit_outlined,
            () => unawaited(_renameAgent(agent)),
          ),
        _item(
          pinned ? 'Unpin' : 'Pin',
          pinned ? Icons.push_pin : Icons.push_pin_outlined,
          () => _pins.toggle(agent.id),
        ),
        _item(
          'Hide',
          Icons.visibility_off_outlined,
          () => widget.source.hideAgent(agent.id),
        ),
        if (widget.onDeleteAgent != null &&
            !agent.onHost) ...<PopupMenuEntry<VoidCallback>>[
          const PopupMenuDivider(),
          _item(
            'Delete',
            Icons.delete_outline,
            () => unawaited(_deleteAgent(agent)),
            tone: scheme.error,
          ),
        ],
      ],
    );
    if (mounted) picked?.call();
  }

  Future<void> _openRoomMenu(
    BuildContext anchor,
    AgentsRoom room, {
    Offset? at,
  }) async {
    final ColorScheme scheme = Theme.of(anchor).colorScheme;
    final VoidCallback? picked = await showAnchoredMenu<VoidCallback>(
      anchor,
      anchorPoint: at,
      color: scheme.surfaceContainerHigh,
      items: <PopupMenuEntry<VoidCallback>>[
        if (widget.onManageRoomMembers != null)
          _item(
            'Members',
            Icons.group_outlined,
            () => widget.onManageRoomMembers!(room.id),
          ),
        if (widget.onRenameRoom != null)
          _item(
            'Rename',
            Icons.edit_outlined,
            () => unawaited(_renameRoom(room)),
          ),
        if (widget.onDeleteRoom != null) ...<PopupMenuEntry<VoidCallback>>[
          const PopupMenuDivider(),
          _item(
            'Delete',
            Icons.delete_outline,
            () => unawaited(_deleteRoom(room)),
            tone: scheme.error,
          ),
        ],
      ],
    );
    if (mounted) picked?.call();
  }

  Future<void> _openNewMenu(BuildContext anchor) async {
    final ColorScheme scheme = Theme.of(anchor).colorScheme;
    final VoidCallback? picked = await showAnchoredMenu<VoidCallback>(
      anchor,
      color: scheme.surfaceContainerHigh,
      items: <PopupMenuEntry<VoidCallback>>[
        if (widget.onAddAgent != null)
          _item(
            'New agent',
            Icons.person_add_alt,
            widget.onAddAgent!,
            shortcut: deskShortcutLabel('Ctrl+N'),
          ),
        if (widget.onCreateRoom != null)
          _item(
            'New room',
            Icons.group_add_outlined,
            widget.onCreateRoom!,
            shortcut: deskShortcutLabel('Ctrl+Shift+N'),
          ),
        if (widget.onOpenRooms != null)
          _item('Control Rooms', Icons.groups_outlined, widget.onOpenRooms!),
      ],
    );
    if (mounted) picked?.call();
  }

  // --- build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable?>[
        widget.source,
        widget.rooms,
        _marks,
        _profiles,
        _pins,
      ]),
      builder: (BuildContext context, _) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.surfaceContainerLow,
          child: widget.collapsed ? _buildRail(context) : _buildPane(context),
        );
      },
    );
  }

  List<AgentsAgent> get _orderedAgents =>
      desktopRosterOrder(widget.source.visibleAgents, _pins.ids);

  List<AgentsRoom> get _rooms => widget.onOpenRoom == null
      ? const <AgentsRoom>[]
      : (widget.rooms?.rooms ?? const <AgentsRoom>[]);

  Widget _buildPane(BuildContext context) {
    final String query = _search.text.trim().toLowerCase();
    bool matches(String name) =>
        query.isEmpty || name.toLowerCase().contains(query);
    final List<AgentsAgent> agents = <AgentsAgent>[
      for (final AgentsAgent a in _orderedAgents)
        if (matches(a.name)) a,
    ];
    final List<AgentsRoom> rooms = <AgentsRoom>[
      for (final AgentsRoom r in _rooms)
        if (matches(r.name)) r,
    ];
    final List<AgentsAgent> hidden = query.isEmpty
        ? widget.source.hiddenAgents
        : const <AgentsAgent>[];
    final bool nothingAtAll =
        widget.source.visibleAgents.isEmpty &&
        widget.source.hiddenAgents.isEmpty &&
        _rooms.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(context),
        const DeskHairline(),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: _searchField(context),
        ),
        Expanded(
          child: nothingAtAll
              ? _emptyState(context)
              : ListView(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  children: <Widget>[
                    _sectionHeader(
                      context,
                      'Agents',
                      onAdd: widget.onAddAgent,
                      addTooltip: 'New agent (${deskShortcutLabel('Ctrl+N')})',
                    ),
                    for (int i = 0; i < agents.length; i++)
                      _AgentRow(
                        key: ValueKey<String>('agent-tile-${agents[i].id}'),
                        agent: agents[i],
                        selected: _isSelected(agents[i]),
                        unread: _marks.isUnread(agents[i]),
                        pinned: _pins.isPinned(agents[i].id),
                        now: _now(),
                        profiles: _profiles,
                        shortcutIndex: query.isEmpty && i < 9 ? i + 1 : null,
                        onTap: () => _pick(agents[i]),
                        onMenu: (BuildContext anchor, Offset? at) =>
                            _openAgentMenu(anchor, agents[i], at: at),
                      ),
                    if (agents.isEmpty && query.isNotEmpty)
                      _quietLine(context, 'No agent matches.'),
                    // Rooms: listed when there are some, and offered empty
                    // only when this roster can create one.
                    if (widget.onOpenRoom != null &&
                        (rooms.isNotEmpty ||
                            (query.isEmpty &&
                                widget.onCreateRoom != null))) ...<Widget>[
                      const SizedBox(height: 8),
                      _sectionHeader(
                        context,
                        'Rooms',
                        onAdd: widget.onCreateRoom,
                        addTooltip:
                            'New room (${deskShortcutLabel('Ctrl+Shift+N')})',
                      ),
                      for (final AgentsRoom room in rooms)
                        _RoomRow(
                          key: ValueKey<String>('room-tile-${room.id}'),
                          room: room,
                          selected: room.id == widget.selectedRoomId,
                          profiles: _profiles,
                          onTap: () => widget.onOpenRoom!(room.id),
                          onMenu: (BuildContext anchor, Offset? at) =>
                              _openRoomMenu(anchor, room, at: at),
                        ),
                      if (rooms.isEmpty) _quietLine(context, 'No rooms yet.'),
                    ],
                    if (hidden.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      _hiddenHeader(context, hidden.length),
                      if (_hiddenOpen)
                        for (final AgentsAgent agent in hidden)
                          _HiddenRow(
                            agent: agent,
                            profiles: _profiles,
                            onUnhide: () => widget.source.unhideAgent(agent.id),
                          ),
                    ],
                  ],
                ),
        ),
        if (widget.onOpenSettings != null) ...<Widget>[
          const DeskHairline(),
          _accountRow(context),
        ],
      ],
    );
  }

  Widget _header(BuildContext context) {
    return SizedBox(
      height: kDeskBarHeight - 1,
      child: Row(
        children: <Widget>[
          const Expanded(
            child: SbBrand(
              label: 'Chuk Chat',
              showLogo: false,
              fontSize: kSidebarBrandWordmarkSize,
              padding: EdgeInsets.fromLTRB(16, 0, 8, 0),
            ),
          ),
          if (widget.onAddAgent != null || widget.onCreateRoom != null)
            Builder(
              builder: (BuildContext anchor) => DeskIconButton(
                icon: Icons.edit_square,
                tooltip: 'New',
                onPressed: () => unawaited(_openNewMenu(anchor)),
              ),
            ),
          if (widget.onToggleCollapsed != null) ...<Widget>[
            const SizedBox(width: kDeskButtonGap),
            DeskIconButton(
              icon: Icons.view_sidebar_outlined,
              tooltip: 'Collapse sidebar (${deskShortcutLabel('Ctrl+B')})',
              onPressed: widget.onToggleCollapsed,
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return SizedBox(
      height: 32,
      child: TextField(
        controller: _search,
        style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHigh,
          hintText: 'Search',
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 13,
            color: scheme.onSurfaceVariant,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: AppIcon(
              Icons.search,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 32),
          suffixIcon: _search.text.isNotEmpty
              ? GestureDetector(
                  onTap: _search.clear,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AppIcon(
                      Icons.close,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : (widget.onOpenQuickSwitcher == null
                    ? null
                    : Tooltip(
                        message: 'Quick switcher',
                        child: GestureDetector(
                          onTap: widget.onOpenQuickSwitcher,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _KeyCap(deskShortcutLabel('Ctrl+K')),
                          ),
                        ),
                      )),
          suffixIconConstraints: const BoxConstraints(minWidth: 24),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kDeskControlRadius),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kDeskControlRadius),
            borderSide: BorderSide(color: scheme.outline, width: 1),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    String label, {
    VoidCallback? onAdd,
    String? addTooltip,
  }) => _SectionHeader(label: label, onAdd: onAdd, addTooltip: addTooltip);

  Widget _hiddenHeader(BuildContext context, int count) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: () => setState(() => _hiddenOpen = !_hiddenOpen),
      child: SizedBox(
        height: 28,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Text(
                'Hidden · $count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 4),
              AppIcon(
                _hiddenOpen ? Icons.expand_less : Icons.expand_more,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quietLine(BuildContext context, String text) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              'No agents yet.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (widget.onAddAgent != null) ...<Widget>[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: widget.onAddAgent,
                child: const Text('Add an agent'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _accountRow(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String name = widget.accountLabel ?? _displayNameFor(_profile);
    return SizedBox(
      height: kDeskBarHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _HoverTile(
                onTap: widget.onOpenSettings,
                height: 36,
                child: Row(
                  children: <Widget>[
                    Container(
                      width: kDeskRowFace,
                      height: kDeskRowFace,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        name.isEmpty
                            ? '?'
                            : name.characters.first.toUpperCase(),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_hosted) ...<Widget>[
                      const SizedBox(width: 6),
                      BalanceBadge(
                        textStyle: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                        placeholderStyle: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: kDeskButtonGap),
            DeskIconButton(
              icon: Icons.settings_rounded,
              tooltip: 'Settings',
              onPressed: widget.onOpenSettings,
            ),
          ],
        ),
      ),
    );
  }

  // --- rail --------------------------------------------------------------------

  Widget _buildRail(BuildContext context) {
    final List<AgentsAgent> agents = _orderedAgents;
    final List<AgentsRoom> rooms = _rooms;
    return Column(
      children: <Widget>[
        SizedBox(
          height: kDeskBarHeight - 1,
          child: Center(
            child: DeskIconButton(
              icon: Icons.view_sidebar_outlined,
              tooltip: 'Expand sidebar (${deskShortcutLabel('Ctrl+B')})',
              onPressed: widget.onToggleCollapsed,
            ),
          ),
        ),
        const DeskHairline(),
        const SizedBox(height: 8),
        if (widget.onOpenQuickSwitcher != null)
          DeskIconButton(
            icon: Icons.search,
            tooltip: 'Quick switcher (${deskShortcutLabel('Ctrl+K')})',
            onPressed: widget.onOpenQuickSwitcher,
          ),
        if (widget.onAddAgent != null) ...<Widget>[
          const SizedBox(height: kDeskButtonGap),
          DeskIconButton(
            icon: Icons.person_add_alt,
            tooltip: 'New agent (${deskShortcutLabel('Ctrl+N')})',
            onPressed: widget.onAddAgent,
          ),
        ],
        const SizedBox(height: 8),
        const SizedBox(width: 24, child: DeskHairline()),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: <Widget>[
              for (final AgentsAgent agent in agents)
                _RailFace(
                  key: ValueKey<String>('rail-agent-${agent.id}'),
                  tooltip: agent.name,
                  selected: _isSelected(agent),
                  unread: _marks.isUnread(agent),
                  onTap: () => _pick(agent),
                  child: AgentFace(
                    agent: agent,
                    size: 28,
                    store: _profiles,
                    showPresence: agent.activity == AgentActivity.working,
                  ),
                ),
              if (rooms.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                const Center(child: SizedBox(width: 24, child: DeskHairline())),
                const SizedBox(height: 6),
                for (final AgentsRoom room in rooms)
                  _RailFace(
                    key: ValueKey<String>('rail-room-${room.id}'),
                    tooltip: room.name,
                    selected: room.id == widget.selectedRoomId,
                    unread: false,
                    onTap: () => widget.onOpenRoom!(room.id),
                    child: RoomFaces(
                      members: room.members,
                      size: 28,
                      store: _profiles,
                      ringColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerLow,
                    ),
                  ),
              ],
            ],
          ),
        ),
        if (widget.onOpenSettings != null) ...<Widget>[
          const DeskHairline(),
          SizedBox(
            height: kDeskBarHeight,
            child: Center(
              child: DeskIconButton(
                icon: Icons.settings_rounded,
                tooltip: 'Settings',
                onPressed: widget.onOpenSettings,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A section label: small caps in the quiet colour, and a "+" that shows
/// while the pointer is on the section.
class _SectionHeader extends StatefulWidget {
  const _SectionHeader({required this.label, this.onAdd, this.addTooltip});

  final String label;
  final VoidCallback? onAdd;
  final String? addTooltip;

  @override
  State<_SectionHeader> createState() => _SectionHeaderState();
}

class _SectionHeaderState extends State<_SectionHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        height: 28,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (widget.onAdd != null)
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hovered ? 1 : 0,
                  child: DeskIconButton(
                    icon: Icons.add_rounded,
                    size: 22,
                    glyph: 16,
                    tooltip: widget.addTooltip ?? 'Add',
                    onPressed: widget.onAdd,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The hover fill and the rounded row shape every roster row shares.
class _HoverTile extends StatefulWidget {
  const _HoverTile({
    required this.child,
    required this.height,
    this.onTap,
    this.selected = false,
    this.onSecondaryTapUp,
    this.onHover,
  });

  final Widget child;
  final double height;
  final VoidCallback? onTap;
  final bool selected;
  final GestureTapUpCallback? onSecondaryTapUp;
  final ValueChanged<bool>? onHover;

  @override
  State<_HoverTile> createState() => _HoverTileState();
}

class _HoverTileState extends State<_HoverTile> {
  bool _hovered = false;

  void _setHover(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    widget.onHover?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fill = widget.selected
        ? scheme.secondaryContainer
        : (_hovered ? scheme.surfaceContainerHigh : Colors.transparent);
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onSecondaryTapUp,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: widget.height,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(kDeskControlRadius),
          ),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: kDeskRowPadH),
                  child: widget.child,
                ),
              ),
              // The selected row's accent bar on its left edge.
              if (widget.selected)
                Positioned(
                  key: const ValueKey<String>('roster-selected-bar'),
                  left: 0,
                  top: 8,
                  bottom: 8,
                  width: kDeskSelectedBar,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One coworker: 36 px, face 24, name; on the right the unread dot, the
/// state or the time — and the "…" while the pointer is on the row.
class _AgentRow extends StatefulWidget {
  const _AgentRow({
    super.key,
    required this.agent,
    required this.selected,
    required this.unread,
    required this.pinned,
    required this.now,
    required this.profiles,
    required this.onTap,
    required this.onMenu,
    this.shortcutIndex,
  });

  final AgentsAgent agent;
  final bool selected;
  final bool unread;
  final bool pinned;
  final DateTime now;
  final AgentProfileStore profiles;
  final VoidCallback onTap;
  final Future<void> Function(BuildContext anchor, Offset? at) onMenu;

  /// Ctrl+n opens this row; shown in the row's tooltip.
  final int? shortcutIndex;

  @override
  State<_AgentRow> createState() => _AgentRowState();
}

class _AgentRowState extends State<_AgentRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AgentsAgent agent = widget.agent;
    final bool working = agent.activity == AgentActivity.working;
    final Color nameColor = widget.selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;

    Widget trailing;
    if (_hovered) {
      trailing = Builder(
        builder: (BuildContext anchor) => DeskIconButton(
          icon: Icons.more_horiz,
          size: 24,
          glyph: 16,
          tooltip: 'More',
          onPressed: () => unawaited(widget.onMenu(anchor, null)),
        ),
      );
    } else if (widget.unread) {
      trailing = Container(
        key: const ValueKey<String>('roster-unread-dot'),
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
        ),
      );
    } else if (working) {
      trailing = Text(
        activityLabel(agent.activity),
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary),
      );
    } else {
      trailing = Text(
        compactAgeLabel(agent.lastActivity, now: widget.now),
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Builder(
        builder: (BuildContext rowContext) => _HoverTile(
          height: kDeskAgentRow,
          selected: widget.selected,
          onTap: widget.onTap,
          onHover: (bool value) => setState(() => _hovered = value),
          onSecondaryTapUp: (TapUpDetails d) =>
              unawaited(widget.onMenu(rowContext, d.globalPosition)),
          child: Row(
            children: <Widget>[
              AgentFace(
                agent: agent,
                size: kDeskRowFace,
                store: widget.profiles,
                showPresence: working,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  agent.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 14,
                    color: nameColor,
                    fontWeight: widget.unread || widget.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.pinned && !_hovered) ...<Widget>[
                AppIcon(
                  Icons.push_pin,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 24),
                child: Align(
                  alignment: Alignment.centerRight,
                  widthFactor: 1,
                  child: trailing,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One room: 32 px, the members' faces, the name, the "…" on hover.
class _RoomRow extends StatefulWidget {
  const _RoomRow({
    super.key,
    required this.room,
    required this.selected,
    required this.profiles,
    required this.onTap,
    required this.onMenu,
  });

  final AgentsRoom room;
  final bool selected;
  final AgentProfileStore profiles;
  final VoidCallback onTap;
  final Future<void> Function(BuildContext anchor, Offset? at) onMenu;

  @override
  State<_RoomRow> createState() => _RoomRowState();
}

class _RoomRowState extends State<_RoomRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Builder(
        builder: (BuildContext rowContext) => _HoverTile(
          height: kDeskRoomRow,
          selected: widget.selected,
          onTap: widget.onTap,
          onHover: (bool value) => setState(() => _hovered = value),
          onSecondaryTapUp: (TapUpDetails d) =>
              unawaited(widget.onMenu(rowContext, d.globalPosition)),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: kDeskRowFace,
                height: kDeskRowFace,
                child: RoomFaces(
                  members: widget.room.members,
                  size: kDeskRowFace,
                  store: widget.profiles,
                  ringColor: widget.selected
                      ? scheme.secondaryContainer
                      : scheme.surfaceContainerLow,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.room.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 14,
                    color: widget.selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              if (_hovered)
                Builder(
                  builder: (BuildContext anchor) => DeskIconButton(
                    icon: Icons.more_horiz,
                    size: 24,
                    glyph: 16,
                    tooltip: 'More',
                    onPressed: () => unawaited(widget.onMenu(anchor, null)),
                  ),
                )
              else
                Text(
                  '${widget.room.members.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hidden coworker, dimmed, with Unhide.
class _HiddenRow extends StatelessWidget {
  const _HiddenRow({
    required this.agent,
    required this.profiles,
    required this.onUnhide,
  });

  final AgentsAgent agent;
  final AgentProfileStore profiles;
  final VoidCallback onUnhide;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _HoverTile(
        height: kDeskRoomRow,
        child: Row(
          children: <Widget>[
            AgentFace(
              agent: agent,
              size: kDeskRowFace,
              store: profiles,
              dimmed: true,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                agent.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onUnhide,
              child: const Text('Unhide'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A face in the folded rail: a 40 px target, the selected fill and bar, an
/// unread dot in its corner, the name as the tooltip.
class _RailFace extends StatelessWidget {
  const _RailFace({
    super.key,
    required this.child,
    required this.tooltip,
    required this.selected,
    required this.unread,
    required this.onTap,
  });

  final Widget child;
  final String tooltip;
  final bool selected;
  final bool unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Tooltip(
        message: tooltip,
        preferBelow: false,
        waitDuration: const Duration(milliseconds: 300),
        child: _HoverTile(
          height: 40,
          selected: selected,
          onTap: onTap,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: <Widget>[
              child,
              if (unread)
                Positioned(
                  right: -2,
                  top: 4,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A key in a hint: "Ctrl+K" in a small outlined box.
class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The word for a coworker's state, as shown in the roster.
String activityLabel(AgentActivity activity) => switch (activity) {
  AgentActivity.working => 'working',
  AgentActivity.waiting => 'ready for a task',
  AgentActivity.scheduled => 'scheduled',
};

/// "just now" / "5m ago" / "2h ago" / "3d ago", or a plain statement that
/// nothing has happened. Never a fabricated time.
String lastActivityLabel(DateTime? when, {required DateTime now}) {
  if (when == null) return 'no activity yet';
  final delta = now.difference(when);
  if (delta.isNegative || delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

/// The roster row's time: "now", "5m", "2h", "3d" — or nothing when nothing
/// has happened. Never a fabricated time.
String compactAgeLabel(DateTime? when, {required DateTime now}) {
  if (when == null) return '';
  final delta = now.difference(when);
  if (delta.isNegative || delta.inSeconds < 45) return 'now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m';
  if (delta.inHours < 24) return '${delta.inHours}h';
  if (delta.inDays < 7) return '${delta.inDays}d';
  return '${(delta.inDays / 7).floor()}w';
}
