part of 'messenger_shell.dart';

/// The Agents desktop layout: chuk_chat's desktop with coworkers in it.
///
///  * **Left** — the roster, which is chuk's sidebar ([AgentRosterView]).
///    Resizable between [kDeskRosterMin] and [kDeskRosterMax], folded to
///    chuk's mini rail with Ctrl+B. A window too narrow for roster and thread
///    folds it on its own, without changing what the user chose.
///  * **Centre** — the thread (or an open room) on the page colour, its
///    actions floating at the top right as chuk floats "Copy full chat". The
///    one thread view stays mounted behind a room: it owns the socket.
///  * **Right** — the details pane (the agent panel) or Control Rooms, in
///    chuk's artifact panel slot: its header, its left border and its
///    divider. Resizable between [kDeskDetailsMin] and [kDeskDetailsMax]. It
///    pushes the thread; it never covers it.
///  * **Top centre** — the Chat | Agents switch, where chuk's desktop floats
///    it in the Chat half: on the line of the thread's buttons, clear of the
///    roster and of those buttons. A centre pane too narrow for both gives
///    the switch a line of its own above the thread.
///
/// The keyboard reaches everything: the shell's focus node sits above the
/// whole body, so a shortcut works from the composer as well as from anywhere
/// else, and the composer still gets first say over the keys it uses itself
/// (Esc while editing, Enter, the arrows).
///
/// Nothing here runs below the desktop breakpoint: the phone layout is built
/// by `_buildPhoneBody` and never reads this state.
mixin _AgentsDesktopLayout on State<MessengerShell>, AgentsShellHost {
  // --- hooks the state implements --------------------------------------------

  void _openSettings();

  /// The Chat | Agents switch, or null when there is no Chat half.
  Widget? _agentsModeSwitch();

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

  /// The shell's keyboard. Returns handled only for its own combos, so
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

  /// The thread's floating buttons on the desktop: Control Rooms, the
  /// details pane and, where chuk keeps it, Copy full chat. The coworker's
  /// profile and rename wait behind "…".
  List<AgentsThreadAction> _deskBarActions(AgentsAgent? agent) =>
      <AgentsThreadAction>[
        AgentsThreadAction(
          icon: Icons.groups_outlined,
          tooltip: 'Control Rooms',
          onPressed: () => _deskToggleRightPane('rooms'),
          selected: _deskRightPane == 'rooms',
        ),
        if (agent != null)
          AgentsThreadAction(
            icon: Icons.tune,
            tooltip: 'Details (${deskShortcutLabel('Ctrl+.')})',
            onPressed: () => _deskToggleRightPane('details'),
            selected: _deskRightPane == 'details',
          ),
        AgentsThreadAction(
          icon: Icons.copy_all_rounded,
          tooltip: 'Copy full chat',
          onPressed: () => unawaited(_copyFullChat()),
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
      ];

  Widget _buildDesktopBody(
    BuildContext context,
    double width,
    AgentsAgent? agent,
  ) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;

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
    final double roomForRight = width - rosterW - 320;
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

    // The Chat | Agents switch: at the top centre of the window on the line
    // of the thread's buttons, kept between the roster and those buttons.
    // What the buttons take is counted from what this layout hands the
    // thread (the thread adds its screen, Documents and "…"), or a room's
    // two. When the centre pane cannot hold both, the switch takes a line of
    // its own and the centre pane starts under it.
    final Widget? modeSwitch = _agentsModeSwitch();
    double centreTop = 0;
    Widget? switchSlot;
    if (modeSwitch != null) {
      final double buttons =
          (room != null ? 2 : _deskBarActions(agent).length + 3) *
          AgentsThreadHeader.slot;
      final double left = rosterW + 12;
      final double paneRight = (showRight ? rightW : 0) + 12;
      final double besideButtons = paneRight + buttons + 8;
      final bool inline =
          width - left - besideButtons >= AppModeSwitch.preferredWidth(context);
      if (!inline) centreTop = kTopInitialSpacing + kButtonVisualHeight;
      switchSlot = Positioned(
        key: const ValueKey<String>('desk-mode-switch'),
        top:
            kTopInitialSpacing +
            (kButtonVisualHeight - AppModeSwitch.boxHeight) / 2,
        left: 0,
        right: 0,
        height: AppModeSwitch.boxHeight,
        child: TopCentreSlot(
          left: left,
          right: inline ? besideButtons : paneRight,
          child: modeSwitch,
        ),
      );
    }

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
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: centreTop),
                child: centre,
              ),
            ),
            if (right != null)
              // chuk's artifact panel slot: the page colour, a left border.
              Container(
                key: const ValueKey<String>('desk-right-pane'),
                width: rightW,
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  border: Border(
                    left: BorderSide(color: iconFg.withValues(alpha: 0.2)),
                  ),
                ),
                child: right,
              ),
          ],
        ),
        if (!rail)
          Positioned(
            key: const ValueKey<String>('desk-roster-resize'),
            left: rosterW - 3,
            top: 0,
            bottom: 0,
            // No line: the panel colour already changes at this border, as
            // it does at chuk's sidebar.
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
            right: rightW - 3,
            top: 0,
            bottom: 0,
            child: PaneResizeHandle(
              semanticLabel: 'Resize the details pane',
              lineColor: iconFg.withValues(alpha: 0.15),
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
        ?switchSlot,
      ],
    );

    return Focus(
      focusNode: _deskFocus,
      autofocus: true,
      onKeyEvent: _deskOnKey,
      child: ColoredBox(color: theme.scaffoldBackgroundColor, child: body),
    );
  }

  /// The details pane: the agent panel under chuk's panel header.
  Widget _buildDeskDetailsPane(BuildContext context, AgentsAgent agent) {
    final String sessionKey = agent.threads.isEmpty
        ? agent.id
        : agent.threads.first.key;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader.text(
            icon: Icons.tune,
            text: 'Details',
            actions: <Widget>[
              IconButton(
                icon: const AppIcon(Icons.refresh, size: 18),
                tooltip: 'Refresh',
                onPressed: () => unawaited(_deskRefreshDetails(sessionKey)),
              ),
              IconButton(
                icon: const AppIcon(Icons.close, size: 18),
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

  /// Refresh in the details pane. A host that cannot answer says so; the
  /// error itself is not shown or logged — it may carry host detail.
  Future<void> _deskRefreshDetails(String sessionKey) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    try {
      await _controlSource.refresh(sessionKey);
    } catch (_) {
      if (!mounted || messenger == null) return;
      AppNotifications.showOn(
        messenger,
        'Could not refresh the details. Try again in a moment.',
        kind: AppNotificationKind.error,
        duration: const Duration(seconds: 4),
      );
    }
  }

  /// Control Rooms in the right pane: the room list under chuk's panel header.
  Widget _buildDeskRoomsPane(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneHeader.text(
            icon: Icons.groups_outlined,
            text: 'Control Rooms',
            actions: <Widget>[
              IconButton(
                icon: const AppIcon(Icons.group_add_outlined, size: 18),
                tooltip: 'New room (${deskShortcutLabel('Ctrl+Shift+N')})',
                onPressed: () => unawaited(_openRoomCreate()),
              ),
              IconButton(
                icon: const AppIcon(Icons.close, size: 18),
                tooltip: 'Close',
                onPressed: _deskCloseRightPane,
              ),
            ],
          ),
          Expanded(child: _buildRoomList(showHeader: false)),
        ],
      ),
    );
  }

  /// A room in the centre pane. Its name and faces are the room's own intro
  /// line; its two actions float at the top right, where the thread's do.
  Widget _buildDeskRoom(BuildContext context, AgentsRoom room) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: KeyedSubtree(
            key: ValueKey<String>('desk-room-${room.id}'),
            child: _buildRoomBody(room),
          ),
        ),
        Positioned(
          top: kTopInitialSpacing,
          right: 12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ChromeIconButton(
                icon: Icons.group_outlined,
                tooltip: 'Members',
                onPressed: () => unawaited(_manageRoomMembers(room.id)),
              ),
              ChromeIconButton(
                icon: Icons.close,
                tooltip: 'Close room (Esc)',
                onPressed: _deskCloseRoom,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
