part of 'messenger_shell.dart';

/// The Agents desktop layout: chuk_chat's desktop with agents in it.
///
///  * **Left** — the roster, which is chuk's sidebar ([AgentRosterView]).
///    Exactly as wide as chuk's sidebar ([kDeskRosterWidth]), folded to
///    chuk's mini rail with Ctrl+B. A window too narrow for roster and thread
///    folds it on its own, without changing what the user chose.
///  * **Centre** — the thread (or an open room) on the page colour, under
///    the phone's top bar in desktop form ([AgentsThreadHeader]): the
///    agent on the left, Documents, Call, Screen and "…" on the right, on
///    a fade the transcript scrolls under. The one thread view stays mounted
///    behind a room: it owns the socket.
///  * **Right** — the details pane (the agent panel) or Control Rooms, in
///    chuk's artifact panel slot: its header, its left border and its
///    divider. Resizable between [kDeskDetailsMin] and [kDeskDetailsMax]. It
///    pushes the thread; it never covers it.
///  * **Top centre** — the Chats | Agents switch: on the line of the thread
///    header's row, clear of the roster, the agent pill and the chips. A
///    centre pane too narrow for all of them gives the switch a line of its
///    own above the thread.
///  * **Home** — the "Home" row at the top of the roster, above the main
///    agent, puts the dashboard in the centre pane. The roster stays docked
///    (a pick in it, Ctrl+K or Ctrl+1 … Ctrl+9 leaves Home), the right pane
///    closes, and the thread stays mounted behind it.
///
/// The keyboard reaches everything: the shell's focus node sits above the
/// whole body, so a shortcut works from the composer as well as from anywhere
/// else, and the composer still gets first say over the keys it uses itself
/// (Esc while editing, Enter, the arrows).
///
/// Nothing here runs below the desktop breakpoint: the phone layout is built
/// by `_buildPhoneBody` and never reads this state.
mixin _AgentsDesktopLayout on State<MessengerShell>, AgentsShellHost {
  /// The one agent settings content (the shell builds it); the pane shows
  /// it with `page: false`.
  AgentSettingsView _agentSettings(AgentsAgent agent, {bool page = true});

  // --- hooks the state implements --------------------------------------------

  void _openSettings();

  /// The Chats | Agents switch, or null when there is no Chats half.
  Widget? _agentsModeSwitch();

  /// Home (the dashboard), for the centre pane.
  Widget _buildHome(BuildContext context);

  /// Whether Home is in front of the Agents half ([_agentsHomeShown]).
  bool get _homeInFront;

  /// Whether the Agents half is in front (not chuk's chats).
  bool get _agentsHalfInFront;

  // --- state -------------------------------------------------------------------

  bool _deskRosterCollapsed = false;
  double _deskDetailsWidth = kDeskDetailsDefault;

  /// 'details' | 'rooms' | null — what the right pane shows.
  String? _deskRightPane;

  /// The agent whose details pane shows its Settings page (the gear);
  /// null shows the first page (screen and routines). Another agent, or
  /// closing the pane, goes back to the first page.
  String? _deskDetailsSettingsFor;

  /// A sub-page of the details pane's first page: `files` or `model`, for
  /// the agent in [_deskDetailsShownFor]. Null shows Details itself.
  String? _deskDetailsSubpage;

  /// The agent the details pane showed last. A different one resets
  /// [_deskDetailsSettingsFor], so coming back to an agent opens its first
  /// page again.
  String? _deskDetailsShownFor;

  /// The room open in the centre pane, over the (still mounted) thread.
  String? _deskRoomId;

  final FocusNode _deskFocus = FocusNode(debugLabel: 'agents-desktop-shell');

  static const String _kDeskPanesKey = 'agents.desktop.panes_v1';
  Timer? _deskSaveTimer;

  void _deskInit() {
    unawaited(_deskLoad());
    unawaited(RosterPins.instance.load());
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
        final Object? details = data['details'];
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
    setState(() {
      _deskRightPane = _deskRightPane == pane ? null : pane;
      _deskDetailsSettingsFor = null;
      _deskDetailsSubpage = null;
    });
    _deskScheduleSave();
  }

  /// Opens [agent]'s settings ([AgentSettingsView]) in the right pane, the
  /// side panel next to the thread. The chat header's agent pill, the "…"
  /// menu's Settings and the roster row's Profile all land here; on a
  /// desktop window the agent settings never open as a page or a modal.
  /// Another agent is selected first, so the pane and the thread agree.
  ///
  /// [toggle]: a second tap on the pill closes the pane again. Returns false
  /// when the pane cannot show (an agent with no thread, or a window too
  /// narrow for it); the caller then opens the settings surface instead.
  bool _deskOpenAgentSettings(AgentsAgent agent, {bool toggle = false}) {
    if (toggle &&
        _deskRightPane == 'details' &&
        _deskDetailsSettingsFor == agent.id &&
        agent.id == _selectedAgentId) {
      _deskCloseRightPane();
      return true;
    }
    final double width = MediaQuery.sizeOf(context).width;
    if (width < kDeskRailWidth + 320 + 240) return false;
    if (agent.id != _selectedAgentId) {
      if (agent.threads.isEmpty) return false;
      _select(agent.id, agent.threads.first.key);
    }
    _deskCloseRoom();
    _leaveAgentsHome();
    setState(() {
      _deskRightPane = 'details';
      _deskDetailsShownFor = agent.id;
      _deskDetailsSettingsFor = agent.id;
    });
    _deskScheduleSave();
    return true;
  }

  /// Opens [page] ("model" or "files") of the selected agent's details
  /// pane, for the thread [chatKey]. The composer's "More models" lands here,
  /// so every model choice opens in the same right pane (CHAT-152). Returns
  /// false when the pane cannot show; the caller then opens the page its
  /// own way.
  bool _deskOpenDetailsPage(String chatKey, String page) {
    final AgentsAgent? agent = _selectedAgent;
    if (agent == null || chatKey.isEmpty || chatKey != _selectedThreadKey) {
      return false;
    }
    final double width = MediaQuery.sizeOf(context).width;
    if (width < kDeskRailWidth + 320 + 240) return false;
    _deskCloseRoom();
    setState(() {
      _deskRightPane = 'details';
      _deskDetailsShownFor = agent.id;
      _deskDetailsSettingsFor = null;
      _deskDetailsSubpage = page;
    });
    _deskScheduleSave();
    return true;
  }

  void _deskCloseRightPane() {
    if (_deskRightPane == null) return;
    setState(() {
      _deskRightPane = null;
      _deskDetailsSettingsFor = null;
      _deskDetailsSubpage = null;
    });
    _deskScheduleSave();
  }

  void _deskOpenRoom(String roomId) {
    if (_rooms.byId(roomId) == null) return;
    _leaveAgentsHome();
    setState(() => _deskRoomId = roomId);
  }

  void _deskCloseRoom() {
    if (_deskRoomId == null) return;
    setState(() => _deskRoomId = null);
  }

  /// The agents in the order the roster shows them: the main agent, then the
  /// pinned ones, then the rest. Ctrl+1 … Ctrl+9 count this list.
  List<AgentsAgent> get _deskAgentOrder => rosterMainOrder(
    _roster.visibleAgents,
    RosterPins.instance.ids,
    RosterPins.instance.mainAgentId,
  );

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

  /// The thread header's "…" menu on the desktop. Documents, Call and Screen
  /// are the header's own chips, as on the phone; Control Rooms lives in the
  /// roster. The details pane is also Ctrl+.; the agent pill and Settings
  /// open the pane on the agent's settings.
  List<AgentsThreadAction> _deskMenuActions(AgentsAgent? agent) =>
      <AgentsThreadAction>[
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
        if (agent != null)
          AgentsThreadAction(
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
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

    // Home takes the centre pane; the right pane belongs to a thread or the
    // rooms, so it waits while Home is in front.
    final bool home = _homeInFront;

    final AgentsRoom? room = _deskRoomId == null
        ? null
        : _rooms.byId(_deskRoomId!);

    // The right pane first: it is what the user opened last. With a group
    // open, 'details' shows the group's details.
    final AgentsAgent? detailsAgent = agent;
    final bool wantsRight =
        !home &&
        (_deskRightPane == 'rooms' ||
            (_deskRightPane == 'details' &&
                (detailsAgent != null || room != null)));
    double rightW = wantsRight
        ? _deskDetailsWidth.clamp(kDeskDetailsMin, kDeskDetailsMax)
        : 0;

    // The roster folds to the rail when the user asked, or when roster,
    // thread and right pane cannot share the window.
    const double rosterFull = kDeskRosterWidth;
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

    final Widget roster = AgentRosterView(
      source: _roster,
      readMarks: _readMarks,
      profiles: _agentProfiles,
      // Nothing is picked while Home is in front.
      selectedAgentId: home || room != null ? null : _selectedAgentId,
      selectedThreadKey: _selectedThreadKey,
      selectedRoomId: home ? null : room?.id,
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
      mainAgentSection: true,
      // Home is the first place in the list, above the main agent.
      onOpenHome: _showAgentsHome,
      homeSelected: home,
    );

    // The Chats | Agents switch: at the top centre of the window, on the line
    // of the thread header's row, kept clear of the roster, of the agent
    // pill at the left of the header and of its chips at the right (or a
    // room's two). The header's fade is under it, so the transcript never
    // runs into it. When the centre pane cannot hold all three, the switch
    // takes a line of its own and the centre pane starts under it.
    final Widget? modeSwitch = _agentsModeSwitch();
    double centreTop = 0;
    Widget? switchSlot;
    if (modeSwitch != null) {
      // Home has no header row of its own: nothing to clear but the edges.
      final double chips = home
          ? AgentsThreadHeader.edge
          : room != null
          ? AgentsThreadHeader.edge + 2 * AgentsThreadHeader.chipBox
          : AgentsThreadHeader.trailingExtent(panelMode: agent != null);
      final double leading = home || room != null || agent == null
          ? AgentsThreadHeader.edge
          : AgentsThreadHeader.edge + AgentsThreadHeader.leadingMaxWidth;
      final double left = rosterW + leading + 8;
      final double paneRight = (showRight ? rightW : 0) + 12;
      final double besideButtons = (showRight ? rightW : 0) + chips + 8;
      final bool inline =
          width - left - besideButtons >= AppModeSwitch.preferredWidth(context);
      if (!inline) centreTop = AgentsThreadHeader.rowBottom;
      switchSlot = Positioned(
        key: const ValueKey<String>('desk-mode-switch'),
        top: AgentsThreadHeader.rowTop,
        left: 0,
        right: 0,
        height: AppModeSwitch.boxHeight,
        child: TopCentreSlot(
          left: inline ? left : rosterW + 12,
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
            offstage: room != null || home,
            child: _buildThread(
              // The agent pill opens the agent's settings on the right.
              onOpenAgent: agent == null
                  ? null
                  : () => _deskOpenAgentSettings(agent, toggle: true),
              menuActions: _deskMenuActions(agent),
              // The right counterpart of the menu button: the details pane
              // with the screen, routines, model, files and actions.
              onTogglePanel: agent == null
                  ? null
                  : () => _deskToggleRightPane('details'),
              panelOpen: _deskRightPane == 'details',
            ),
          ),
        ),
        if (room != null && !home)
          Positioned.fill(
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor,
              child: _buildDeskRoom(context, room),
            ),
          ),
        if (home)
          Positioned.fill(
            key: const ValueKey<String>('desk-home'),
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor,
              // Home starts under the switch's row, as the thread's first
              // message starts under its header.
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: MediaQuery.paddingOf(context).copyWith(
                    top: centreTop == 0 ? AgentsThreadHeader.rowBottom : 0,
                  ),
                ),
                child: _buildHome(context),
              ),
            ),
          ),
      ],
    );

    Widget? right;
    if (showRight) {
      right = _deskRightPane == 'rooms'
          ? _buildDeskRoomsPane(context)
          : (room != null
                ? _buildDeskRoomDetailsPane(context, room)
                : _buildDeskDetailsPane(context, detailsAgent!));
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

    final Widget focused = Focus(
      focusNode: _deskFocus,
      autofocus: true,
      onKeyEvent: _deskOnKey,
      child: ColoredBox(color: theme.scaffoldBackgroundColor, child: body),
    );
    if (!MobileLayout.isTouchPlatform) return focused;
    // A tablet has a system back. It closes what is open, one step at a
    // time: the right pane, then a room, then the thread goes back to Home.
    // On Home it leaves the app. Behind chuk's chats it is not ours.
    final bool roomShown = room != null && !home;
    final bool open = showRight || roomShown || !home;
    return PopScope(
      canPop: !_agentsHalfInFront || !open,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop || !_agentsHalfInFront) return;
        if (showRight) {
          _deskCloseRightPane();
        } else if (roomShown) {
          _deskCloseRoom();
        } else {
          _showAgentsHome();
        }
      },
      child: focused,
    );
  }

  /// The details pane, in two pages under chuk's panel header.
  ///
  ///  * First page, "Details": the agent's screen (a tap opens the viewer)
  ///    and its routines. The gear opens the second page.
  ///  * Second page, "Settings": the same agent settings content the phone
  ///    page shows ([AgentSettingsView], bead chuk_chat-8hz4): the same
  ///    sections, rows, order and words. The back arrow returns.
  Widget _buildDeskDetailsPane(BuildContext context, AgentsAgent agent) {
    final String sessionKey = agent.threads.isEmpty
        ? agent.id
        : agent.threads.first.key;
    if (_deskDetailsShownFor != agent.id) {
      _deskDetailsShownFor = agent.id;
      _deskDetailsSettingsFor = null;
      _deskDetailsSubpage = null;
    }
    final bool settings = _deskDetailsSettingsFor == agent.id;
    final String? subpage = settings ? null : _deskDetailsSubpage;
    if (subpage == 'model') {
      // The agent's model, inside the pane: the same page the phone opens,
      // in its own navigator so its back chip returns to Details.
      return SettingsSurfaceNavigator(
        key: ValueKey<String>('desk-model-nav-${agent.id}'),
        onClose: _deskCloseRightPane,
        onRootBack: () => setState(() => _deskDetailsSubpage = null),
        builder: (BuildContext context) =>
            ModelSelectorPage(chatId: sessionKey),
      );
    }
    if (subpage == 'files') {
      // The thread's files, inside the pane: the same files page the phone
      // opens, in its own navigator so its back chip returns to Details.
      return SettingsSurfaceNavigator(
        key: ValueKey<String>('desk-files-nav-${agent.id}'),
        onClose: _deskCloseRightPane,
        onRootBack: () => setState(() => _deskDetailsSubpage = null),
        builder: (BuildContext context) => ChatDocumentsPanel(
          sessionKey: sessionKey,
          controller: _controller.value,
          agentName: agent.name,
          fullPage: true,
        ),
      );
    }
    if (!settings) {
      // The first page under the same floating header as every page in
      // this pane (title pill on the left; the gear and the close chip on
      // the right). One gear: the title has no glyph of its own.
      return SettingsSurfaceNavigator(
        key: ValueKey<String>('desk-details-nav-${agent.id}'),
        onClose: _deskCloseRightPane,
        builder: (BuildContext context) => FloatingPageScaffold(
          appBar: FloatingAppBar(
            title: const Text('Details'),
            actions: <Widget>[
              FloatingHeaderButton(
                key: const ValueKey<String>('desk-details-settings'),
                icon: Icons.settings_outlined,
                tooltip: 'Settings',
                onPressed: () =>
                    setState(() => _deskDetailsSettingsFor = agent.id),
              ),
            ],
          ),
          body: AgentDetailsOverview(
            key: ValueKey<String>('desk-overview-${agent.id}'),
            name: agent.name,
            sessionKey: sessionKey,
            headerInset: true,
            onOpenScreen: _openAgentScreenOrNull,
            // The model runs on Auto by default; it is in Settings,
            // under "Advanced" (CHAT-152).
            onOpenFiles: () => setState(() => _deskDetailsSubpage = 'files'),
            actions: <AgentDetailsAction>[
              AgentDetailsAction(
                icon: Icons.history,
                label: AppLocalizations.of(context)?.ckTitle ?? 'Checkpoints',
                onTap: () {
                  final State? thread = _threadViewKey.currentState;
                  if (thread is AgentsThreadViewState) {
                    unawaited(thread.openCheckpoints());
                  }
                },
              ),
              AgentDetailsAction(
                icon: Icons.copy_all_rounded,
                label: 'Copy full chat',
                onTap: () => unawaited(_copyFullChat()),
              ),
              AgentDetailsAction(
                icon: Icons.edit_outlined,
                label: 'Rename',
                onTap: () => unawaited(_openAgentRename(agent)),
              ),
            ],
          ),
        ),
      );
    }
    // The settings run in their own navigator: a row inside them (Model,
    // Profile, Host & activity, ...) opens its page inside this pane, on
    // top of the settings, and its back chip returns here
    // (openSettingsSurface finds this navigator). The header is the same
    // floating header as on the first page.
    return SettingsSurfaceNavigator(
      key: ValueKey<String>('desk-settings-nav-${agent.id}'),
      onClose: _deskCloseRightPane,
      builder: (BuildContext context) => FloatingPageScaffold(
        appBar: FloatingAppBar(
          title: const Text('Settings'),
          leading: FloatingHeaderButton(
            key: const ValueKey<String>('desk-details-back'),
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => setState(() => _deskDetailsSettingsFor = null),
          ),
          actions: <Widget>[
            FloatingHeaderButton(
              icon: Icons.refresh,
              tooltip: 'Refresh',
              onPressed: () => unawaited(_deskRefreshDetails(sessionKey)),
            ),
          ],
        ),
        // The same settings content as the phone page, in the pane.
        body: _agentSettings(agent, page: false),
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

  /// A group's details in the right pane ([RoomDetailsPanel]), under the same
  /// floating header as the agent's details.
  Widget _buildDeskRoomDetailsPane(BuildContext context, AgentsRoom room) {
    return SettingsSurfaceNavigator(
      key: ValueKey<String>('desk-room-details-nav-${room.id}'),
      onClose: _deskCloseRightPane,
      builder: (BuildContext context) => FloatingPageScaffold(
        appBar: FloatingAppBar(title: Text(_l10n.agentsGroupDetails)),
        body: _buildRoomDetails(room.id),
      ),
    );
  }

  /// Groups in the right pane: the group list under the same floating
  /// header as the details pane.
  Widget _buildDeskRoomsPane(BuildContext context) {
    return SettingsSurfaceNavigator(
      key: const ValueKey<String>('desk-rooms-nav'),
      onClose: _deskCloseRightPane,
      builder: (BuildContext context) => FloatingPageScaffold(
        appBar: FloatingAppBar(
          title: Text(_l10n.agentsGroups),
          actions: <Widget>[
            FloatingHeaderButton(
              icon: Icons.group_add_outlined,
              tooltip:
                  '${_l10n.agentsGroupNew} (${deskShortcutLabel('Ctrl+Shift+N')})',
              onPressed: () => unawaited(_openRoomCreate()),
            ),
          ],
        ),
        body: _buildRoomList(showHeader: false),
      ),
    );
  }

  /// A room in the centre pane. Its name and faces are the room's own intro
  /// line; its two actions float at the top right on the thread header's
  /// band, as the same chips.
  Widget _buildDeskRoom(BuildContext context, AgentsRoom room) {
    return Stack(
      children: <Widget>[
        // The room's list starts under the band's row (its intro line would
        // sit behind the row otherwise) and scrolls up into the fade.
        Positioned.fill(
          top: AgentsThreadHeader.rowBottom,
          child: KeyedSubtree(
            key: ValueKey<String>('desk-room-${room.id}'),
            child: _buildRoomBody(room),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AgentsHeaderBand(
            trailing: <Widget>[
              ChromeChip(
                icon: Icons.info_outline_rounded,
                tooltip: _l10n.agentsGroupDetails,
                semanticsId: 'desk_room_details',
                onTap: () => _deskToggleRightPane('details'),
              ),
              ChromeChip(
                icon: Icons.close_rounded,
                tooltip: 'Close room (Esc)',
                semanticsId: 'desk_room_close',
                onTap: _deskCloseRoom,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
