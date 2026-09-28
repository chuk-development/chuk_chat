/// The roster: the left pane of the Agents desktop layout.
///
/// It is chuk_chat's desktop sidebar (`sidebar_desktop.dart`) with coworkers
/// where the chats are, built from the same chrome (`sidebar_chrome.dart`):
///
///  * a floating head bar with the wordmark, and the menu button that folds
///    the pane (Ctrl+B) where chuk's hamburger sits;
///  * a navigation block joined under it — New agent, New room, Control
///    Rooms and Search, whose card turns into the filter field;
///  * one block per group under its own lid — Pinned, Agents, Rooms and
///    Hidden — with each coworker and room as a chat tile carrying its face;
///  * the floating account line at the foot.
///
/// Folded, the pane is chuk's mini rail: the menu button and the navigation
/// icons on the rows the open pane gives them, then one face per coworker and
/// room. Nothing the reader aims at moves when the pane folds.
///
/// Every coworker has exactly one long-lived thread, so a row is an agent and
/// picking it opens that thread. The phone's inbox is `MobileAgentList`; this
/// widget is only ever built by the desktop layout.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/profile_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_controls.dart';
import 'package:chuk_chat/widgets/brand_wordmark.dart';
import 'package:chuk_chat/widgets/coworker_name_dialog.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/room_faces.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart';
import 'package:chuk_chat/widgets/update_banner.dart';

// The name dialog moved to its own file when it was rebuilt in the app's
// language; it is exported here so every caller keeps one import.
export 'package:chuk_chat/widgets/coworker_name_dialog.dart';

/// The face in front of a coworker or a room in the open pane. It fits the
/// chat tile's two lines with air above and below.
const double kRosterTileFace = 32;

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

  /// Opens the new-agent dialog. The New agent card is hidden when null.
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

  /// The group rooms, listed under "Rooms". Null leaves the group out.
  final RoomSource? rooms;

  /// Opens a room. Rooms are not listed without it.
  final void Function(String roomId)? onOpenRoom;

  /// Starts a new room.
  final VoidCallback? onCreateRoom;

  final void Function(String roomId, String name)? onRenameRoom;
  final void Function(String roomId)? onDeleteRoom;
  final void Function(String roomId)? onManageRoomMembers;

  /// Settings — the gear in the account line. The line is hidden when null.
  final VoidCallback? onOpenSettings;

  /// The quick switcher (Ctrl+K). The folded rail's search icon opens it.
  final VoidCallback? onOpenQuickSwitcher;

  /// Folded to the rail.
  final bool collapsed;

  /// Folds or unfolds the pane (Ctrl+B).
  final VoidCallback? onToggleCollapsed;

  /// The account line's name. Null lets the roster load the profile itself.
  final String? accountLabel;

  /// Clock seam so a row's time is deterministic in a test.
  final DateTime Function()? now;

  final AgentReadMarks? readMarks;
  final AgentProfileStore? profiles;
  final DesktopRosterPins? pins;

  @override
  State<AgentRosterView> createState() => _AgentRosterViewState();
}

/// One row of the navigation block. The open pane draws it as a card, the
/// rail as an icon on the same row.
class _NavRow {
  const _NavRow({
    required this.icon,
    required this.label,
    required this.railTooltip,
    required this.onTap,
    this.isSearch = false,
  });

  final IconData icon;
  final String label;
  final String railTooltip;
  final VoidCallback? onTap;

  /// The open pane turns this card into the filter field; the rail opens the
  /// quick switcher from it.
  final bool isSearch;
}

class _AgentRosterViewState extends State<AgentRosterView> {
  ProfileRecord? _profile;
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'agent-roster-search');

  /// True while the Search card shows the field instead of the card.
  bool _searchActive = false;

  /// The groups the user folded. Hidden starts folded: it is where a coworker
  /// goes to be out of the way.
  final Set<String> _folded = <String>{_kGroupHidden};

  static const String _kGroupPinned = 'pinned';
  static const String _kGroupAgents = 'agents';
  static const String _kGroupRooms = 'rooms';
  static const String _kGroupHidden = 'hidden';

  /// The height of the account line, and the air under it.
  static const double _kBottomChromeHeight = 54;
  static const double _kBottomInset = 10;

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
    _searchFocus.addListener(_onSearchFocusChanged);
  }

  @override
  void dispose() {
    _searchFocus.removeListener(_onSearchFocusChanged);
    _search.removeListener(_onSearch);
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onSearch() => setState(() {});

  /// Opens the filter field and puts the caret in it.
  void _openSearch() {
    setState(() => _searchActive = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// The field folds back into the Search card once it is empty and has lost
  /// the focus, so an abandoned search does not sit there forever.
  void _onSearchFocusChanged() {
    if (_searchFocus.hasFocus || _search.text.isNotEmpty || !mounted) return;
    setState(() => _searchActive = false);
  }

  Future<void> _loadProfile() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    try {
      final record = await const ProfileService().loadOrCreateProfile();
      if (!mounted) return;
      setState(() => _profile = record);
    } catch (_) {
      // The line shows the fallback label.
    }
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

  void _toggleGroup(String id) {
    setState(() {
      if (!_folded.remove(id)) _folded.add(id);
    });
  }

  // --- dialogs -----------------------------------------------------------------

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

  /// Asks before something is deleted, in chuk's delete dialog
  /// (`sidebar_common.dart`): a title, what is lost, Cancel and a red Delete.
  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey<String>('agents-confirm-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _deleteAgent(AgentsAgent agent) async {
    final bool ok = await _confirmDelete(
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
    final bool ok = await _confirmDelete(
      title: 'Delete ${room.name}?',
      message: 'The room and its conversation are removed for everyone in it.',
    );
    if (!mounted || !ok) return;
    widget.onDeleteRoom?.call(room.id);
  }

  // --- menus -------------------------------------------------------------------

  /// One row of a row menu, drawn as chuk's sidebar draws its chat menu: the
  /// glyph, the label, and the destructive row in red.
  PopupMenuItem<VoidCallback> _menuItem(
    String label,
    IconData icon,
    VoidCallback onTap, {
    bool destructive = false,
  }) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final Color danger = Colors.redAccent.withValues(alpha: 0.8);
    return PopupMenuItem<VoidCallback>(
      value: onTap,
      child: Row(
        children: <Widget>[
          AppIcon(icon, color: destructive ? danger : iconFg, size: 20),
          const SizedBox(width: 12),
          Text(label, style: destructive ? TextStyle(color: danger) : null),
        ],
      ),
    );
  }

  /// Opens [items] at [at] (a right click), or under [anchor] (the three-dot
  /// button, or the keyboard's menu key on a row).
  Future<void> _showMenu(
    BuildContext anchor,
    List<PopupMenuEntry<VoidCallback>> items, {
    Offset? at,
  }) async {
    if (items.isEmpty) return;
    final RenderBox? overlay =
        Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final Rect target;
    if (at != null) {
      target = Rect.fromLTWH(at.dx, at.dy, 1, 1);
    } else {
      final RenderBox? box = anchor.findRenderObject() as RenderBox?;
      if (box == null) return;
      final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
      target = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy + box.size.height,
        box.size.width,
        1,
      );
    }
    final VoidCallback? picked = await showMenu<VoidCallback>(
      context: anchor,
      position: RelativeRect.fromRect(target, Offset.zero & overlay.size),
      items: items,
    );
    if (mounted) picked?.call();
  }

  /// The coworker's menu. The tile also carries the pin as a one-click toggle
  /// on hover, as chuk's chat tile does; the menu row is the same toggle for
  /// the keyboard's menu key and for touch, where there is no hover.
  List<PopupMenuEntry<VoidCallback>> _agentMenu(AgentsAgent agent) {
    final bool pinned = _pins.isPinned(agent.id);
    return <PopupMenuEntry<VoidCallback>>[
      if (widget.onOpenProfile != null)
        _menuItem(
          'Profile',
          Icons.person_outline,
          () => widget.onOpenProfile!(agent),
        ),
      if (widget.onRenameAgent != null)
        _menuItem(
          'Rename',
          Icons.edit_outlined,
          () => unawaited(_renameAgent(agent)),
        ),
      _menuItem(
        pinned ? 'Unpin' : 'Pin',
        pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        () => _pins.toggle(agent.id),
      ),
      _menuItem(
        'Hide',
        Icons.visibility_off_outlined,
        () => widget.source.hideAgent(agent.id),
      ),
      if (widget.onDeleteAgent != null && !agent.onHost)
        _menuItem(
          'Delete',
          Icons.delete_outline,
          () => unawaited(_deleteAgent(agent)),
          destructive: true,
        ),
    ];
  }

  List<PopupMenuEntry<VoidCallback>> _roomMenu(AgentsRoom room) =>
      <PopupMenuEntry<VoidCallback>>[
        if (widget.onManageRoomMembers != null)
          _menuItem(
            'Members',
            Icons.group_outlined,
            () => widget.onManageRoomMembers!(room.id),
          ),
        if (widget.onRenameRoom != null)
          _menuItem(
            'Rename',
            Icons.edit_outlined,
            () => unawaited(_renameRoom(room)),
          ),
        if (widget.onDeleteRoom != null)
          _menuItem(
            'Delete',
            Icons.delete_outline,
            () => unawaited(_deleteRoom(room)),
            destructive: true,
          ),
      ];

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
      builder: (BuildContext context, _) =>
          widget.collapsed ? _buildRail(context) : _buildPane(context),
    );
  }

  List<AgentsAgent> get _orderedAgents =>
      desktopRosterOrder(widget.source.visibleAgents, _pins.ids);

  List<AgentsRoom> get _rooms => widget.onOpenRoom == null
      ? const <AgentsRoom>[]
      : (widget.rooms?.rooms ?? const <AgentsRoom>[]);

  /// The navigation rows, in the one order both shapes use.
  List<_NavRow> _navRows(BuildContext context) {
    final AppLocalizations? l = AppLocalizations.of(context);
    return <_NavRow>[
      if (widget.onAddAgent != null)
        _NavRow(
          icon: Icons.edit_square,
          label: 'New agent',
          railTooltip: 'New agent (${deskShortcutLabel('Ctrl+N')})',
          onTap: widget.onAddAgent,
        ),
      if (widget.onCreateRoom != null)
        _NavRow(
          icon: Icons.group_add_outlined,
          label: 'New room',
          railTooltip: 'New room (${deskShortcutLabel('Ctrl+Shift+N')})',
          onTap: widget.onCreateRoom,
        ),
      if (widget.onOpenRooms != null)
        _NavRow(
          icon: Icons.groups_outlined,
          label: 'Control Rooms',
          railTooltip: 'Control Rooms',
          onTap: widget.onOpenRooms,
        ),
      _NavRow(
        icon: Icons.search_rounded,
        label: l?.search ?? 'Search',
        railTooltip: 'Quick switcher (${deskShortcutLabel('Ctrl+K')})',
        onTap: widget.onOpenQuickSwitcher ?? widget.onToggleCollapsed,
        isSearch: true,
      ),
    ];
  }

  /// chuk's menu button, in the place chuk's desktop keeps its hamburger: on
  /// the column of the icons under it, centred on the head bar.
  Widget _menuButton(BuildContext context, {required bool folded}) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    return Positioned(
      top: kTopInitialSpacing + (kMenuButtonHeight - kButtonVisualHeight) / 2,
      left: kSbNavIconCentre - kMenuButtonHeight / 2,
      child: SizedBox(
        width: kMenuButtonHeight,
        height: kButtonVisualHeight,
        child: IconButton(
          icon: AppIcon(Icons.menu_rounded, color: iconFg, size: 24),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.standard,
          constraints: const BoxConstraints.tightFor(
            width: kMenuButtonHeight,
            height: kButtonVisualHeight,
          ),
          tooltip: folded
              ? 'Expand sidebar (${deskShortcutLabel('Ctrl+B')})'
              : 'Collapse sidebar (${deskShortcutLabel('Ctrl+B')})',
          onPressed: widget.onToggleCollapsed,
        ),
      ),
    );
  }

  Widget _buildPane(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    final bool hasMenuButton = widget.onToggleCollapsed != null;

    final List<_NavRow> rows = _navRows(context);
    final List<Widget> navCards = <Widget>[
      for (final _NavRow row in rows)
        if (row.isSearch)
          _searchEntry(row)
        else
          SbNavCard(icon: row.icon, label: row.label, onTap: row.onTap!),
    ];
    final double navBlockBottom =
        kSbNavBlockTop + navCards.length * kSbNavRowStep - kSbCardGap;
    // chuk leaves the hamburger its box at the start of the head bar; without
    // one the wordmark starts where the phone sidebar starts it.
    final double brandLeft = hasMenuButton
        ? kFixedLeftPadding + kMenuButtonHeight + 4 - kSbBlockInset
        : 14;

    return Material(
      color: sbPanelBackground(context),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            // No scrollbar: the desktop default draws one over the cards, and
            // the list already says where it stands through its group lids.
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: CustomScrollView(
                slivers: <Widget>[
                  // Room for the head bar and the navigation block, both of
                  // which float over this list. The rows start under them
                  // and run behind them on the way up.
                  SliverToBoxAdapter(
                    child: SizedBox(height: navBlockBottom + 6),
                  ),
                  ..._buildGroups(context, iconFg),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: widget.onOpenSettings == null
                          ? _kBottomInset
                          : _kBottomChromeHeight + _kBottomInset,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // The navigation block is chrome, not a list item: the rows stay
          // where they are and the list disappears under them.
          Positioned(
            top: kSbNavBlockTop,
            left: 0,
            right: 0,
            child: SbBlock(joinTop: true, children: navCards),
          ),

          // The head names the app, and nothing else.
          Positioned(
            top: kTopInitialSpacing,
            left: kSbBlockInset,
            right: kSbBlockInset,
            child: SbFloatingBar(
              // The block below starts flush against this bar, so the two
              // read as one run: round on top, tight at the joint.
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(kSbCardRadius),
                topRight: Radius.circular(kSbCardRadius),
                bottomLeft: Radius.circular(kSbCardJointRadius),
                bottomRight: Radius.circular(kSbCardJointRadius),
              ),
              child: SizedBox(
                height: kMenuButtonHeight,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(brandLeft, 0, 6, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    // Scaled down rather than cut at the narrowest width.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: BrandWordmark(color: iconFg),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (hasMenuButton) _menuButton(context, folded: false),

          if (widget.onOpenSettings != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const UpdateBanner(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      kSbBlockInset,
                      6,
                      kSbBlockInset,
                      _kBottomInset,
                    ),
                    child: SbAccountLine(
                      name: widget.accountLabel ?? sidebarDisplayName(_profile),
                      onTap: widget.onOpenSettings,
                      onSettings: widget.onOpenSettings,
                      balance: _hosted
                          ? BalanceBadge(
                              textStyle: TextStyle(
                                color: theme.colorScheme.primary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                              placeholderStyle: TextStyle(
                                color: theme.m3.onSurfaceVariant,
                                fontSize: 13,
                              ),
                              padding: EdgeInsets.zero,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The Search card, or the field itself once it is open: the pane never
  /// holds two places to type a query.
  Widget _searchEntry(_NavRow row) {
    if (!_searchActive) {
      return SbNavCard(icon: row.icon, label: row.label, onTap: _openSearch);
    }
    return SbCard(
      // Its own, even corners rather than the block's: a ring that runs round
      // two tight joints and two wide corners reads as a drawing mistake.
      outlined: true,
      radius: kSbCardRadius,
      padding: EdgeInsets.zero,
      minHeight: kSbNavCardHeight,
      child: SbSearchField(
        controller: _search,
        focusNode: _searchFocus,
        transparent: true,
        hintText: 'Search agents and rooms',
        onClear: _search.clear,
      ),
    );
  }

  /// One lid and the tiles under it, chuk's group block.
  List<Widget> _group(
    String id,
    String label,
    List<Widget> tiles, {
    int? count,
  }) {
    final bool folded = _folded.contains(id);
    return <Widget>[
      SliverToBoxAdapter(
        child: SbGroupHeader(
          label: label,
          count: count ?? tiles.length,
          collapsed: folded,
          onToggle: () => _toggleGroup(id),
        ),
      ),
      if (!folded)
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) => Padding(
              padding: const EdgeInsets.fromLTRB(
                kSbBlockInset,
                kSbCardGap,
                kSbBlockInset,
                0,
              ),
              child: SbCardShape(
                radius: sbBlockRadiusFor(
                  index: index + 1,
                  length: tiles.length + 1,
                ),
                child: tiles[index],
              ),
            ),
            childCount: tiles.length,
          ),
        ),
    ];
  }

  List<Widget> _buildGroups(BuildContext context, Color iconFg) {
    final String query = _search.text.trim().toLowerCase();
    bool matches(String name) =>
        query.isEmpty || name.toLowerCase().contains(query);
    final Set<String> pinnedIds = _pins.ids;
    final List<AgentsAgent> agents = <AgentsAgent>[
      for (final AgentsAgent a in _orderedAgents)
        if (matches(a.name)) a,
    ];
    final List<AgentsAgent> pinned = <AgentsAgent>[
      for (final AgentsAgent a in agents)
        if (pinnedIds.contains(a.id)) a,
    ];
    final List<AgentsAgent> rest = <AgentsAgent>[
      for (final AgentsAgent a in agents)
        if (!pinnedIds.contains(a.id)) a,
    ];
    final List<AgentsRoom> rooms = <AgentsRoom>[
      for (final AgentsRoom r in _rooms)
        if (matches(r.name)) r,
    ];
    final List<AgentsAgent> hidden = query.isEmpty
        ? widget.source.hiddenAgents
        : const <AgentsAgent>[];

    if (agents.isEmpty && rooms.isEmpty && hidden.isEmpty) {
      final bool nothingAtAll =
          widget.source.visibleAgents.isEmpty &&
          widget.source.hiddenAgents.isEmpty &&
          _rooms.isEmpty;
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              nothingAtAll || query.isEmpty
                  ? 'No agents yet.'
                  : 'Nothing found for "${_search.text.trim()}".',
              style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
            ),
          ),
        ),
      ];
    }

    return <Widget>[
      if (pinned.isNotEmpty)
        ..._group(
          _kGroupPinned,
          AppLocalizations.of(context)?.pinned ?? 'Pinned',
          <Widget>[for (final AgentsAgent a in pinned) _agentTile(context, a)],
        ),
      if (rest.isNotEmpty)
        ..._group(
          _kGroupAgents,
          'Agents',
          <Widget>[for (final AgentsAgent a in rest) _agentTile(context, a)],
        ),
      if (rooms.isNotEmpty)
        ..._group(
          _kGroupRooms,
          'Rooms',
          <Widget>[for (final AgentsRoom r in rooms) _roomTile(context, r)],
        ),
      if (hidden.isNotEmpty)
        ..._group(
          _kGroupHidden,
          'Hidden',
          <Widget>[
            for (final AgentsAgent a in hidden) _hiddenTile(context, a),
          ],
        ),
    ];
  }

  /// The row menu from the keyboard (the Menu key, Shift+F10), for the row
  /// that holds the focus — what a right click opens with the mouse.
  Widget _withMenuKeys(Widget tile, VoidCallback openMenu) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.contextMenu): openMenu,
      const SingleActivator(LogicalKeyboardKey.f10, shift: true): openMenu,
    },
    child: tile,
  );

  /// chuk's three-dot button: always there, 28 px, its menu opening under it.
  Widget _moreButton(Color iconFg, void Function(BuildContext anchor) open) {
    return Builder(
      builder: (BuildContext anchor) => SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          icon: AppIcon(
            Icons.more_horiz_rounded,
            size: 18,
            color: iconFg.withValues(alpha: 0.75),
          ),
          padding: EdgeInsets.zero,
          splashRadius: 16,
          visualDensity: VisualDensity.compact,
          tooltip: 'More',
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          onPressed: () => open(anchor),
        ),
      ),
    );
  }

  Widget _agentTile(BuildContext context, AgentsAgent agent) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    final Color accent = theme.colorScheme.primary;
    final bool working = agent.activity == AgentActivity.working;
    final bool unread = _marks.isUnread(agent);
    final bool pinned = _pins.isPinned(agent.id);
    return Builder(
      builder: (BuildContext rowContext) => _withMenuKeys(
        SbChatTile(
          key: ValueKey<String>('agent-tile-${agent.id}'),
          title: agent.name,
          dateLine: sbChatDateLine(context, agent.lastActivity, now: _now()),
          selected: _isSelected(agent),
          unread: unread,
          // chuk's dot for a chat that is still being written.
          streaming: working,
          leading: AgentFace(
            agent: agent,
            size: kRosterTileFace,
            store: _profiles,
          ),
          onTap: () => _pick(agent),
          onSecondaryTap: (Offset at) =>
              unawaited(_showMenu(rowContext, _agentMenu(agent), at: at)),
          // The pin stays a one-click toggle on hover, as on chuk's tile.
          hoverTrailing: SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              icon: AppIcon(
                pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 16,
                color: pinned ? accent : iconFg.withValues(alpha: 0.75),
              ),
              padding: EdgeInsets.zero,
              splashRadius: 16,
              visualDensity: VisualDensity.compact,
              tooltip: pinned ? 'Unpin' : 'Pin',
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: () => _pins.toggle(agent.id),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (unread)
                Container(
                  key: const ValueKey<String>('roster-unread-dot'),
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  // A flat dot. No halo: the design has no glow anywhere.
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
              _moreButton(
                iconFg,
                (BuildContext anchor) =>
                    unawaited(_showMenu(anchor, _agentMenu(agent))),
              ),
            ],
          ),
        ),
        () => unawaited(_showMenu(rowContext, _agentMenu(agent))),
      ),
    );
  }

  Widget _roomTile(BuildContext context, AgentsRoom room) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    final bool selected = room.id == widget.selectedRoomId;
    // The faces overlap; the ring that separates them is the card's own fill.
    final Color cardFill = selected
        ? Color.alphaBlend(
            theme.colorScheme.primary.withValues(alpha: 0.20),
            theme.m3.surfaceContainer,
          )
        : theme.m3.surfaceContainer;
    return Builder(
      builder: (BuildContext rowContext) => _withMenuKeys(
        SbChatTile(
          key: ValueKey<String>('room-tile-${room.id}'),
          title: room.name,
          dateLine: roomMembersLabel(room),
          selected: selected,
          leading: SizedBox(
            width: kRosterTileFace,
            height: kRosterTileFace,
            child: RoomFaces(
              members: room.members,
              size: kRosterTileFace,
              store: _profiles,
              ringColor: cardFill,
            ),
          ),
          onTap: () => widget.onOpenRoom!(room.id),
          onSecondaryTap: (Offset at) =>
              unawaited(_showMenu(rowContext, _roomMenu(room), at: at)),
          trailing: _roomMenu(room).isEmpty
              ? null
              : _moreButton(
                  iconFg,
                  (BuildContext anchor) =>
                      unawaited(_showMenu(anchor, _roomMenu(room))),
                ),
        ),
        () => unawaited(_showMenu(rowContext, _roomMenu(room))),
      ),
    );
  }

  /// A hidden coworker, its face dimmed, with Unhide.
  Widget _hiddenTile(BuildContext context, AgentsAgent agent) {
    return SbChatTile(
      key: ValueKey<String>('hidden-tile-${agent.id}'),
      title: agent.name,
      leading: AgentFace(
        agent: agent,
        size: kRosterTileFace,
        store: _profiles,
        dimmed: true,
      ),
      trailing: TextButton(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => widget.source.unhideAgent(agent.id),
        child: const Text('Unhide'),
      ),
    );
  }

  // --- rail --------------------------------------------------------------------

  /// chuk's mini rail: the menu button, the navigation icons on the rows the
  /// open pane gives their cards, then one face per coworker and room.
  Widget _buildRail(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<_NavRow> rows = _navRows(context);
    final double navBlockBottom =
        kSbNavBlockTop + rows.length * kSbNavRowStep - kSbCardGap;
    final List<AgentsAgent> agents = _orderedAgents;
    final List<AgentsRoom> rooms = _rooms;
    final bool hasSettings = widget.onOpenSettings != null;

    Widget slot(Widget child) => SizedBox(
      height: kSbNavRowStep,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: kSbNavIconLeft),
          child: child,
        ),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: <Widget>[
          if (widget.onToggleCollapsed != null)
            _menuButton(context, folded: true),
          for (int i = 0; i < rows.length; i++)
            Positioned(
              top: sbNavRowTop(i) + kSbNavIconTop,
              left: kSbNavIconLeft,
              child: SbRailSlot(
                tooltip: rows[i].railTooltip,
                onTap: rows[i].onTap,
                child: SbNavIcon(icon: rows[i].icon),
              ),
            ),
          Positioned(
            top: navBlockBottom + 6,
            left: 0,
            right: 0,
            bottom: hasSettings ? _kBottomChromeHeight + _kBottomInset : 0,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: <Widget>[
                  for (final AgentsAgent agent in agents)
                    slot(
                      SbRailSlot(
                        key: ValueKey<String>('rail-agent-${agent.id}'),
                        tooltip: agent.name,
                        selected: _isSelected(agent),
                        badge: _marks.isUnread(agent),
                        onTap: () => _pick(agent),
                        child: AgentFace(
                          agent: agent,
                          size: kSbNavIconTile,
                          store: _profiles,
                          showPresence: agent.activity == AgentActivity.working,
                        ),
                      ),
                    ),
                  if (agents.isNotEmpty && rooms.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(kSbNavIconLeft, 4, 0, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: kSbNavIconTile,
                          child: SbHairline(),
                        ),
                      ),
                    ),
                  for (final AgentsRoom room in rooms)
                    slot(
                      SbRailSlot(
                        key: ValueKey<String>('rail-room-${room.id}'),
                        tooltip: room.name,
                        selected: room.id == widget.selectedRoomId,
                        onTap: () => widget.onOpenRoom!(room.id),
                        child: RoomFaces(
                          members: room.members,
                          size: kSbNavIconTile,
                          store: _profiles,
                          ringColor: theme.scaffoldBackgroundColor,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Where the account line's gear was, on the same column.
          if (hasSettings)
            Positioned(
              left: kSbNavIconLeft,
              bottom:
                  _kBottomInset + (_kBottomChromeHeight - kSbNavIconTile) / 2,
              child: SbRailSlot(
                tooltip: AppLocalizations.of(context)?.settings ?? 'Settings',
                onTap: widget.onOpenSettings,
                child: SbNavIcon(
                  icon: Icons.settings_rounded,
                  tone: theme.m3.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

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
