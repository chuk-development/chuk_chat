part of 'messenger_shell.dart';

/// The Agents desktop layout (docs/DESIGN.md §14): three docked panes, no
/// floating chrome.
///
///  * **Left** — the roster, resizable between [kDeskRosterMin] and
///    [kDeskRosterMax], folded to a rail of faces with Ctrl+B. A window too
///    narrow for roster and thread folds it on its own, without changing what
///    the user chose.
///  * **Centre** — the thread (or an open room), under its 48 px title bar.
///    The one thread view stays mounted behind a room: it owns the socket.
///  * **Right** — the details pane (the agent panel) or Control Rooms,
///    resizable between [kDeskDetailsMin] and [kDeskDetailsMax]. It pushes the
///    thread; it never covers it.
///
/// Panes are divided by 1 px hairlines. The keyboard reaches everything
/// (§14.7): the shell's focus node sits above the whole body, so a shortcut
/// works from the composer as well as from anywhere else, and the composer
/// still gets first say over the keys it uses itself (Esc while editing,
/// Enter, the arrows).
///
/// Nothing here runs below the desktop breakpoint: the phone layout is built
/// by `_buildPhoneBody` and never reads this state.
mixin _AgentsDesktopLayout on State<MessengerShell>, AgentsShellHost {
  // --- hooks the state implements --------------------------------------------

  void _openSettings();

  // --- state -------------------------------------------------------------------

  double _deskRosterWidth = kDeskRosterDefault;
  bool _deskRosterCollapsed = false;
  double _deskDetailsWidth = kDeskDetailsDefault;

  /// 'details' | 'rooms' | null — what the right pane shows.
  String? _deskRightPane;

  /// The room open in the centre pane, over the (still mounted) thread.
  String? _deskRoomId;

  final FocusNode _deskFocus = FocusNode(debugLabel: 'agents-desktop-shell');

  static const String _kDeskPanesKey = 'agents.desktop.panes_v1';
  Timer? _deskSaveTimer;

  void _deskInit() {
    unawaited(_deskLoad());
    unawaited(DesktopRosterPins.instance.load());
  }

  void _deskDispose() {
    if (_deskSaveTimer?.isActive ?? false) {
      _deskSaveTimer!.cancel();
      unawaited(_deskSave());
    }
    _deskFocus.dispose();
  }

  /// Pane widths and which panes were open, as the user left them.
  Future<void> _deskLoad() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_kDeskPanesKey);
      if (raw == null || !mounted) return;
      final Object? data = jsonDecode(raw);
      if (data is! Map) return;
      setState(() {
        final Object? roster = data['roster'];
        final Object? details = data['details'];
        if (roster is num) {
          _deskRosterWidth = roster.toDouble().clamp(
            kDeskRosterMin,
            kDeskRosterMax,
          );
        }
        if (details is num) {
          _deskDetailsWidth = details.toDouble().clamp(
            kDeskDetailsMin,
            kDeskDetailsMax,
          );
        }
        _deskRosterCollapsed = data['collapsed'] == true;
        if (data['detailsOpen'] == true && _deskRightPane == null) {
          _deskRightPane = 'details';
        }
      });
    } catch (_) {
      // A layout that cannot be read is the default layout.
    }
  }

  Future<void> _deskSave() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kDeskPanesKey,
        jsonEncode(<String, Object>{
          'roster': _deskRosterWidth,
          'details': _deskDetailsWidth,
          'collapsed': _deskRosterCollapsed,
          'detailsOpen': _deskRightPane == 'details',
        }),
      );
    } catch (_) {
      // Losing the layout costs the next launch its widths, nothing more.
    }
  }

  /// Written once the reader stops dragging, not on every pixel.
  void _deskScheduleSave() {
    _deskSaveTimer?.cancel();
    _deskSaveTimer = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_deskSave()),
    );
  }

  // --- actions -----------------------------------------------------------------

  void _deskToggleRoster() {
    setState(() => _deskRosterCollapsed = !_deskRosterCollapsed);
    _deskScheduleSave();
  }

  /// Opens [pane] on the right, or closes it when it is already there.
  void _deskToggleRightPane(String pane) {
    setState(() => _deskRightPane = _deskRightPane == pane ? null : pane);
    _deskScheduleSave();
  }

  void _deskShowRightPane(String pane) {
    if (_deskRightPane == pane) return;
    setState(() => _deskRightPane = pane);
    _deskScheduleSave();
  }

  void _deskCloseRightPane() {
    if (_deskRightPane == null) return;
    setState(() => _deskRightPane = null);
    _deskScheduleSave();
  }

  void _deskOpenRoom(String roomId) {
    if (_rooms.byId(roomId) == null) return;
    setState(() => _deskRoomId = roomId);
  }

  void _deskCloseRoom() {
    if (_deskRoomId == null) return;
    setState(() => _deskRoomId = null);
  }

  /// The agents in the order the roster shows them: pinned first, then the
  /// rest, each in the roster's own order. Ctrl+1 … Ctrl+9 count this list.
  List<AgentsAgent> get _deskAgentOrder =>
      desktopRosterOrder(_roster.visibleAgents, DesktopRosterPins.instance.ids);

  void _deskOpenNth(int n) {
    final List<AgentsAgent> order = _deskAgentOrder;
    if (n < 0 || n >= order.length) return;
    final AgentsAgent agent = order[n];
    if (agent.threads.isEmpty) return;
    _deskCloseRoom();
    _select(agent.id, agent.threads.first.key);
  }

  Future<void> _deskOpenQuickSwitcher() async {
    final QuickSwitcherPick? pick = await showQuickSwitcher(
      context,
      agents: _deskAgentOrder,
      rooms: _rooms.rooms,
      profiles: _agentProfiles,
      readMarks: _readMarks,
    );
    if (!mounted || pick == null) return;
    switch (pick) {
      case QuickSwitcherAgent(:final AgentsAgent agent):
        if (agent.threads.isEmpty) return;
        _deskCloseRoom();
        _select(agent.id, agent.threads.first.key);
      case QuickSwitcherRoom(:final AgentsRoom room):
        _deskOpenRoom(room.id);
    }
  }

  /// The shell's keyboard (§14.7). Returns handled only for its own combos, so
  /// every other key goes on to whatever sits above.
  KeyEventResult _deskOnKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final bool primary = deskPrimaryModifierPressed();
    final bool shift = HardwareKeyboard.instance.isShiftPressed;
    final bool alt = HardwareKeyboard.instance.isAltPressed;
    if (key == LogicalKeyboardKey.escape && !primary) {
      if (_deskRightPane != null) {
        _deskCloseRightPane();
        return KeyEventResult.handled;
      }
      if (_deskRoomId != null) {
        _deskCloseRoom();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (!primary || alt || event is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyK && !shift) {
      unawaited(_deskOpenQuickSwitcher());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyN) {
      unawaited(shift ? _openRoomCreate() : _openOnboarding());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.period && !shift) {
      _deskToggleRightPane('details');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB && !shift) {
      _deskToggleRoster();
      return KeyEventResult.handled;
    }
    const List<LogicalKeyboardKey> digits = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final int digit = digits.indexOf(key);
    if (digit >= 0 && !shift) {
      _deskOpenNth(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- build -------------------------------------------------------------------

  /// The thread's title-bar actions on the desktop: the details toggle as a
  /// button, everything else in the "…" menu.
  List<AgentsThreadAction> _deskBarActions(AgentsAgent? agent) =>
      <AgentsThreadAction>[
        if (agent != null)
          AgentsThreadAction(
            icon: Icons.view_sidebar_outlined,
            tooltip: 'Details (${deskShortcutLabel('Ctrl+.')})',
            onPressed: () => _deskToggleRightPane('details'),
            selected: _deskRightPane == 'details',
          ),
      ];

  List<AgentsThreadAction> _deskMenuActions(AgentsAgent? agent) =>
      <AgentsThreadAction>[
        if (agent != null)
          AgentsThreadAction(
            icon: Icons.person_outline,
            tooltip: 'Profile',
            onPressed: () => _openAgentProfile(agent),
          ),
        if (agent != null)
          AgentsThreadAction(
            icon: Icons.edit_outlined,
            tooltip: 'Rename',
            onPressed: () => unawaited(_openAgentRename(agent)),
          ),
        AgentsThreadAction(
          icon: Icons.groups_outlined,
          tooltip: 'Control Rooms',
          onPressed: () => _deskToggleRightPane('rooms'),
        ),
        AgentsThreadAction(
          icon: Icons.copy_all_rounded,
          tooltip: 'Copy Debug Chat',
          onPressed: () => unawaited(_copyFullChat()),
        ),
      ];

  Widget _buildDesktopBody(
    BuildContext context,
    double width,
    AgentsAgent? agent,
  ) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // The right pane first: it is what the user opened last.
    final AgentsAgent? detailsAgent = agent;
    final bool wantsRight =
        _deskRightPane == 'rooms' ||
        (_deskRightPane == 'details' && detailsAgent != null);
    double rightW = wantsRight
        ? _deskDetailsWidth.clamp(kDeskDetailsMin, kDeskDetailsMax)
        : 0;

    // The roster folds to the rail when the user asked, or when roster,
    // thread and right pane cannot share the window.
    final double rosterFull = _deskRosterWidth.clamp(
      kDeskRosterMin,
      kDeskRosterMax,
    );
    final bool rail =
        _deskRosterCollapsed || width - rosterFull - rightW < kDeskThreadMin;
    final double rosterW = rail ? kDeskRailWidth : rosterFull;
    // A window that is still too narrow gives the right pane what is left
    // over a minimal thread, and drops it when not even that fits.
    final double roomForRight = width - rosterW - 2 - 320;
    if (wantsRight && rightW > roomForRight) {
      rightW = roomForRight >= 240 ? roomForRight : 0;
    }
    final bool showRight = wantsRight && rightW > 0;

    final AgentsRoom? room = _deskRoomId == null
        ? null
        : _rooms.byId(_deskRoomId!);

    final Widget roster = AgentRosterView(
      source: _roster,
      readMarks: _readMarks,
      profiles: _agentProfiles,
      selectedAgentId: room == null ? _selectedAgentId : null,
      selectedThreadKey: _selectedThreadKey,
      selectedRoomId: room?.id,
      collapsed: rail,
      onToggleCollapsed: _deskToggleRoster,
      onOpenQuickSwitcher: _deskOpenQuickSwitcher,
      onSelect: (String agentId, String threadKey) {
        _deskCloseRoom();
        _select(agentId, threadKey);
      },
      onOpenProfile: _openAgentProfile,
      onAddAgent: _openOnboarding,
      onDeleteAgent: _deleteAgent,
      onRenameAgent: _renameAgent,
      rooms: _rooms,
      onOpenRoom: _openRoom,
      onCreateRoom: _openRoomCreate,
      onOpenRooms: () => _deskToggleRightPane('rooms'),
      onRenameRoom: _renameRoom,
      onDeleteRoom: (String roomId) {
        if (_deskRoomId == roomId) _deskCloseRoom();
        _deleteRoom(roomId);
      },
      onManageRoomMembers: _manageRoomMembers,
      onOpenSettings: widget.shellConfig == null ? null : _openSettings,
    );

    final Widget centre = Stack(
      children: <Widget>[
        // The thread owns the socket: behind an open room it is off stage,
        // never unmounted.
        Positioned.fill(
          child: Offstage(
            offstage: room != null,
            child: _buildThread(
              actions: _deskBarActions(agent),
              menuActions: _deskMenuActions(agent),
              onOpenSubject: (_) => _deskToggleRightPane('details'),
            ),
          ),
        ),
        if (room != null)
          Positioned.fill(
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor,
              child: _buildDeskRoom(context, room),
            ),
          ),
      ],
    );

    Widget? right;
    if (showRight) {
      right = _deskRightPane == 'rooms'
          ? _buildDeskRoomsPane(context)
          : _buildDeskDetailsPane(context, detailsAgent!);
    }

    final Widget body = Stack(
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(width: rosterW, child: roster),
            const DeskHairline(vertical: true),
            Expanded(child: centre),
            if (right != null) ...<Widget>[
              const DeskHairline(vertical: true),
              SizedBox(
                key: const ValueKey<String>('desk-right-pane'),
                width: rightW,
                child: right,
              ),
            ],
          ],
        ),
        if (!rail)
          Positioned(
            key: const ValueKey<String>('desk-roster-resize'),
            left: rosterW - 4 + 0.5,
            top: 0,
            bottom: 0,
            child: PaneResizeHandle(
              semanticLabel: 'Resize the agent list',
              onDrag: (double dx) => setState(
                // From the current width, not the one this frame was built
                // with: several moves can land between two frames.
                () => _deskRosterWidth =
                    (_deskRosterWidth.clamp(kDeskRosterMin, kDeskRosterMax) +
                            dx)
                        .clamp(kDeskRosterMin, kDeskRosterMax),
              ),
              onDragEnd: _deskScheduleSave,
              onDoubleTap: () {
                setState(() => _deskRosterWidth = kDeskRosterDefault);
                _deskScheduleSave();
              },
            ),
          ),
        if (right != null)
          Positioned(
            key: const ValueKey<String>('desk-details-resize'),
            right: rightW - 4 + 0.5,
            top: 0,
            bottom: 0,
            child: PaneResizeHandle(
              semanticLabel: 'Resize the details pane',
              onDrag: (double dx) => setState(
                () => _deskDetailsWidth =
                    (_deskDetailsWidth.clamp(kDeskDetailsMin, kDeskDetailsMax) -
                            dx)
                        .clamp(kDeskDetailsMin, kDeskDetailsMax),
              ),
              onDragEnd: _deskScheduleSave,
              onDoubleTap: () {
                setState(() => _deskDetailsWidth = kDeskDetailsDefault);
                _deskScheduleSave();
              },
            ),
          ),
      ],
    );

    // Compact density and 14 px body text for everything the desktop draws
    // itself (§14.8). The message text keeps the user's chat font size: the
    // chat screen reads it from its own settings, not from the text theme.
    final ThemeData desk = theme.copyWith(
      visualDensity: VisualDensity.compact,
      textTheme: theme.textTheme.copyWith(
        bodyMedium: theme.textTheme.bodyMedium?.copyWith(fontSize: 14),
      ),
    );

    return MenuDensity(
      child: Theme(
        data: desk,
        child: Focus(
          focusNode: _deskFocus,
          autofocus: true,
          onKeyEvent: _deskOnKey,
          child: ColoredBox(color: scheme.surface, child: body),
        ),
      ),
    );
  }

  /// The details pane: the agent panel under the pane header.
  Widget _buildDeskDetailsPane(BuildContext context, AgentsAgent agent) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String sessionKey = agent.threads.isEmpty
        ? agent.id
        : agent.threads.first.key;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DeskPaneHeader(
            title: 'Details',
            actions: <Widget>[
              DeskIconButton(
                icon: Icons.refresh,
                tooltip: 'Refresh',
                onPressed: () => _controlSource.refresh(sessionKey),
              ),
              DeskIconButton(
                icon: Icons.close,
                tooltip: 'Close (Esc)',
                onPressed: _deskCloseRightPane,
              ),
            ],
          ),
          Expanded(
            child: AgentControlPanel(
              key: ValueKey<String>('desk-details-${agent.id}'),
              agent: agent,
              source: _controlSource,
              showHeader: true,
              showRefresh: false,
              onScheduleSubmitted: (spec) =>
                  _roster.setSchedule(agent.id, spec),
            ),
          ),
        ],
      ),
    );
  }

  /// Control Rooms in the right pane: the room list under the pane header.
  Widget _buildDeskRoomsPane(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DeskPaneHeader(
            title: 'Control Rooms',
            actions: <Widget>[
              DeskIconButton(
                icon: Icons.group_add_outlined,
                tooltip: 'New room (${deskShortcutLabel('Ctrl+Shift+N')})',
                onPressed: () => unawaited(_openRoomCreate()),
              ),
              DeskIconButton(
                icon: Icons.close,
                tooltip: 'Close',
                onPressed: _deskCloseRightPane,
              ),
            ],
          ),
          Expanded(child: _buildRoomList()),
        ],
      ),
    );
  }

  /// A room in the centre pane: the same 48 px bar the thread has, then the
  /// room itself.
  Widget _buildDeskRoom(BuildContext context, AgentsRoom room) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: kDeskBarHeight - 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: <Widget>[
                RoomFaces(
                  members: room.members,
                  size: 28,
                  store: _agentProfiles,
                  ringColor: theme.scaffoldBackgroundColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        room.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        roomMembersLabel(room),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                DeskIconButton(
                  icon: Icons.group_outlined,
                  tooltip: 'Members',
                  onPressed: () => unawaited(_manageRoomMembers(room.id)),
                ),
                const SizedBox(width: kDeskButtonGap),
                DeskIconButton(
                  icon: Icons.close,
                  tooltip: 'Close room (Esc)',
                  onPressed: _deskCloseRoom,
                ),
              ],
            ),
          ),
        ),
        const DeskHairline(),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey<String>('desk-room-${room.id}'),
            child: _buildRoomBody(room),
          ),
        ),
      ],
    );
  }
}
