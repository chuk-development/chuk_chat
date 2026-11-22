part of 'messenger_shell.dart';

/// The default production relay controller ([buildDefaultAgentsRelayController]).
Future<AgentsRelayController> _buildRelayController(
  AgentsPairingStore store,
  AccountSessionSource sessionSource,
) => buildDefaultAgentsRelayController(store, sessionSource);

/// Everything the shell OWNS, as opposed to how it lays it out.
///
/// chuk_chat's root wrappers (`root_wrapper_desktop.dart`,
/// `root_wrapper_mobile.dart`) own nothing but layout: their chat area reads
/// its state from process-wide services. Agents's chat area owns a socket —
/// `AgentsThreadView` builds the relay controller, reconnects from the stored
/// pairing and adopts a run in flight — so whatever hosts it must (a) build it
/// exactly once and (b) never let a layout change unmount it. Plan WS-1 puts
/// that in one place, above the desktop / phone split: this mixin.
///
/// It holds the pairing store, the roster, the rooms, the live controller
/// notifier, room CRUD and its host sync, the notification taps, the cloud
/// pairing restore, the thread builder with its [GlobalKey], the control
/// drawer and the debug export. `_MessengerShellState` mixes it in and adds
/// only the chuk layout on top. It is a `part` of `messenger_shell.dart`, the
/// way `desktop_send_logic.dart` is a part of chuk's `chat_ui_desktop.dart`:
/// one ownership unit, private names shared.
mixin AgentsShellHost on State<MessengerShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Owned by the state, not the widget: a parent rebuild must never hand the
  /// tree a fresh, empty roster or a second pairing store.
  late final AgentsPairingStore _pairingStore =
      widget.pairingStore ?? AgentsPairingStore();
  late final AgentRosterSource _roster =
      widget.rosterSource ?? LocalAgentRosterSource();
  late final RoomSource _rooms =
      widget.roomSource ?? LocalRoomSource(store: const SharedPrefsRoomStore());

  /// Groups the host listed (`room_list`). Re-syncing one of them on open
  /// leaves its settings alone: the host's copy is the newer one.
  final Set<String> _hostKnownRooms = <String>{};

  /// The live transport, handed up by the thread view so a room can stream over
  /// the same socket. Null until the thread view has built it; it changes on a
  /// reconnect, which is what lets an open room re-bind to the new socket.
  final ValueNotifier<AgentsRelayController?> _controller =
      ValueNotifier<AgentsRelayController?>(null);

  /// The link as the thread view last reported it. With [_restoreReason], the
  /// heal flag and the roster it decides what the shell shows while there is
  /// no conversation (never an empty area).
  final ValueNotifier<AgentsLinkReport> _linkReport =
      ValueNotifier<AgentsLinkReport>(AgentsLinkReport.initial);

  /// Why the cloud restore last stopped, mirrored from [_pairingRestore] so
  /// the status panel can listen before the supervisor exists.
  final ValueNotifier<AgentsPairingRestoreReason> _restoreReason =
      ValueNotifier<AgentsPairingRestoreReason>(
        AgentsPairingRestoreReason.checking,
      );

  /// Whether this device has a computer to talk to: true with a stored
  /// pairing, false when there is none and the cloud restore has had its
  /// chance, null while that is not known yet.
  ///
  /// It follows the pairing store's change signal and the restore's reason;
  /// nothing polls. The shell reads it to know when an empty roster means a
  /// computer with no agent at all.
  final ValueNotifier<bool?> _hasComputer = ValueNotifier<bool?>(null);

  /// The zero-click cloud computer setup (CHAT-164). It starts when this
  /// device has no computer and the plan includes a cloud computer, and the
  /// status panel draws its screen while it runs. Its pending token is kept
  /// apart from the install page's one, in the same secure store.
  late final AgentsCloudBoxFlow _cloudBox = AgentsCloudBoxFlow(
    api: widget.cloudBoxApi ?? HttpAgentsCloudBoxApi.instance,
    store: AgentsInstallTicketStore(
      backend: _pairingStore.backend,
      storageKey: AgentsInstallTicketStore.cloudBoxStorageKey,
    ),
    sessionSource: widget.sessionSource,
    claimWaiter: widget.installClaimWaiter ?? _waitForInstallClaim,
    pair: _pairCloudBox,
    planIncludesBox: () =>
        agentsPlanIncludesCloudBox(UserStatusService.status.value),
    // CHAT-177: the box is added next to a paired computer, not swapped in.
    hasComputer: () => _hasComputer.value == true,
  );

  /// Starts the cloud computer setup once it is known whether a computer is
  /// paired. Since CHAT-177 the box is ADDED next to a PC: the flow runs with
  /// or without one, and only a cloud computer that is already paired stops
  /// it.
  void _onHasComputerForCloudBox() {
    if (_hasComputer.value == null) return;
    if (_hasCloudHost) return;
    unawaited(_cloudBox.maybeStart());
  }

  /// A new user status (after a payment the pricing page refreshes it) may
  /// now include a cloud computer.
  void _onUserStatusForCloudBox() {
    if (_hasComputer.value != null && !_hasCloudHost) {
      unawaited(_cloudBox.planChanged());
    }
  }

  // ── computers (CHAT-177) ──
  /// Every paired computer, in the order they were added. Read again on
  /// every store change; the host labels, the new-agent picker and Settings
  /// > Computers read it.
  final ValueNotifier<List<AgentsStoredPairing>> _pairedHosts =
      ValueNotifier<List<AgentsStoredPairing>>(const <AgentsStoredPairing>[]);

  /// Keeps a socket up for every computer that is not on screen.
  AgentsHostLinks? _hostLinks;
  StreamSubscription<AgentsHostInbound>? _secondaryInboundSub;

  bool get _hasCloudHost => _pairedHosts.value.any(
    (AgentsStoredPairing p) => p.effectiveKind == AgentsHostKind.cloud,
  );

  /// The paired computer [hostId], or null.
  AgentsStoredPairing? _pairingFor(String? hostId) {
    if (hostId == null) return null;
    for (final AgentsStoredPairing p in _pairedHosts.value) {
      if (p.hostId == hostId) return p;
    }
    return null;
  }

  /// The roster id of [hostId]'s own agent ([AgentsStoredPairing.hostAgentId]).
  /// An unknown computer keeps the old id.
  String _hostAgentIdFor(String? hostId, String peerDeviceId) =>
      _pairingFor(hostId)?.hostAgentId(peerDeviceId) ?? 'host:$peerDeviceId';

  Future<void> _readPairedHosts() async {
    List<AgentsStoredPairing> hosts;
    try {
      hosts = await _pairingStore.listPairings();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    _pairedHosts.value = hosts;
    _publishHostLabels();
    // The agents from before CHAT-177 have no computer: while exactly one
    // is paired, they all live on it.
    if (hosts.length == 1) _roster.assignHost(hosts.single.hostId);
    // A cloud computer that arrived (restore, another device) ends a setup
    // that still waits.
    if (_hasCloudHost && _cloudBox.phase != AgentsCloudBoxPhase.linked) {
      _cloudBox.stop();
    }
  }

  /// Pairs the cloud computer the zero-click setup made. Without a computer
  /// it is the view's own pairing (the box becomes the computer on screen).
  /// With one, it pairs on a transport of its own, so the conversation on
  /// screen keeps its socket: the box is added and gets a secondary link.
  Future<void> _pairCloudBox(AgentsPairingInvite invite) async {
    AgentsStoredPairing? trust;
    if (_pairedHosts.value.isEmpty) {
      trust = await _pairWithInvite(invite);
    } else {
      final AgentsRelayController controller =
          await (widget.relayControllerBuilder ??
              () =>
                  _buildRelayController(_pairingStore, widget.sessionSource))();
      try {
        trust = await pairAgentsFromInvite(
          controller: controller,
          invite: invite,
          sessionSource: widget.sessionSource,
          store: _pairingStore,
        );
      } finally {
        controller.dispose();
      }
    }
    if (trust != null) {
      await _pairingStore.setHostKind(trust.hostId, AgentsHostKind.cloud);
    }
  }

  /// The computer of a new agent: asked only while more than one is paired
  /// (default: the one used last); else the one there is, or null.
  Future<String?> _pickHostForNewAgent() async {
    final List<AgentsStoredPairing> hosts = _pairedHosts.value;
    if (hosts.length < 2) {
      return hosts.isEmpty
          ? AgentsRelayLinks.instance.primaryHostId
          : hosts.single.hostId;
    }
    String? last;
    try {
      last = await _pairingStore.lastUsedHostId();
    } catch (_) {
      last = null;
    }
    if (!mounted) return null;
    return showAgentHostPicker(
      context,
      hosts: hosts,
      initialHostId: last ?? AgentsRelayLinks.instance.primaryHostId,
      isOnline: AgentsRelayLinks.instance.isOnline,
    );
  }

  /// The computer labels the rows draw ([AgentsHostTag]).
  void _publishHostLabels() => AgentsHostLabels.instance.update(
    _pairedHosts.value,
    AgentsRelayLinks.instance.primaryHostId,
  );
  // ── end computers ──

  /// The last local read of the pairing store, and whether one has finished.
  bool _localPairing = false;
  bool _localPairingKnown = false;
  int _pairingReads = 0;

  /// The pairing was here and is gone ("Remove this computer"). That is a
  /// clear "no computer" at once, whatever the restore last said.
  bool _pairingRemoved = false;

  /// How long an unpaired device waits for a restore that can still work
  /// (no session yet, a locked key, no network) before it offers the install
  /// entry anyway. A restore that lands later still wins: the entry goes and
  /// the switch comes.
  static const Duration _kRestoreGrace = Duration(seconds: 10);
  Timer? _restoreGraceTimer;
  bool _restoreGraceOver = false;

  /// Rooms deleted while the socket was down. The host never heard the delete
  /// (a deleted room has no later "open" to reconcile it, unlike an edit), so it
  /// would keep an orphan. These flush the moment a transport arrives.
  final Set<String> _pendingHostDeletes = <String>{};

  /// How long a notification tap may wait for its thread to be listed. A tap
  /// for a thread that never appears (deleted on the host, another account)
  /// must not open it out of nowhere minutes later.
  static const Duration pendingNotificationTapExpiry = Duration(seconds: 30);

  /// Drops [_waitingTap] from the router when it is still pending after
  /// [pendingNotificationTapExpiry].
  Timer? _waitingTapTimer;
  NotificationTarget? _waitingTap;
  late final AgentControlSource _controlSource =
      widget.controlSource ?? HostUnavailableControlSource();

  /// Only a source this state created is this state's to dispose.
  late final bool _ownsControlSource = widget.controlSource == null;

  /// The theme controller the app hands down. Kept alive as the bridge
  /// `main.dart` and `auth_gate.dart` still take; chuk's settings surfaces
  /// write the theme through `AppShellConfig` instead.
  late final ThemeController _themeController =
      widget.themeController ?? ThemeController();
  late final bool _ownsThemeController = widget.themeController == null;

  /// Keeps the one live thread view (and its socket) alive when the layout
  /// moves it between the desktop stack and the phone screens. Not final: a
  /// one-time cloud-pairing restore (see [_restoreCloudPairing]) swaps in a
  /// fresh key so the thread view re-runs its bootstrap and reconnects.
  GlobalKey _threadViewKey = GlobalKey();

  String? _selectedAgentIdValue;

  /// The open agent. Also tells the avatars which agent follows the pointer
  /// when the pointer is over no agent row ([AgentAvatarFocus]).
  String? get _selectedAgentId => _selectedAgentIdValue;
  set _selectedAgentId(String? id) {
    _selectedAgentIdValue = id;
    AgentAvatarFocus.instance.openAgentId = id;
  }

  /// The thread on screen. EMPTY means "nothing to mount yet", and that is
  /// deliberate: the old placeholder `'default'` was a thread key nobody ever
  /// wrote, so the first frame opened a conversation that has no cached
  /// transcript, and the flip to the real key a moment later cost a
  /// `didUpdateWidget` and a second replay round. A thread key is only ever
  /// read back — from preferences or from the persisted roster — never
  /// invented, because a second key means a second replay cursor and a second
  /// cache row for one conversation.
  String _selectedThreadKey = '';

  /// Where the last session left off. Written on every pick, read once at
  /// startup. Two keys, not one: a thread is only meaningful with its agent.
  static const String _kLastAgentKey = 'cowork.last_agent_id';
  static const String _kLastThreadKey = 'cowork.last_thread_key';

  /// Both halves of the pick in ONE key, `[agentId, threadKey]` as JSON: on
  /// desktop Linux every preference write rewrites the whole preferences file,
  /// so a switch costs one write instead of two. The two keys above are still
  /// read when this one is absent (installs from before it).
  static const String _kLastPickKey = 'cowork.last_pick_v2';

  String? _restoredAgentId;
  String? _restoredThreadKey;

  /// Whether the remembered pick has been read off disk yet. Nothing is
  /// auto-selected before it has: picking the first agent and then jumping
  /// to the remembered one a moment later is worse than opening a beat late.
  bool _restoreLoaded = false;

  /// Whether the current selection is the app's own choice rather than the
  /// user's. Only an automatic selection may be replaced when the remembered
  /// agent finally arrives in the roster (the host sends its names after the
  /// pairing, so it is not there on the first frame).
  bool _selectionIsAuto = false;

  /// Home (the dashboard, docs/DASHBOARD.md) is in front inside the Agents
  /// half. Home is the first page of that half: on a desktop window it takes
  /// the centre pane (the roster's "Home" row), on a phone it is the first
  /// page left of the conversation. Not remembered across launches.
  ///
  /// Written only through [_showAgentsHome] and [_leaveAgentsHome]; [_select]
  /// (any agent pick) and a room that opens leave Home. The shell listens to
  /// it and rebuilds.
  final ValueNotifier<bool> _agentsHomeShown = ValueNotifier<bool>(false);

  /// Brings Home to the front of the Agents half. Whether the Agents half
  /// itself is in front is the shell's [AppModeService], not this.
  void _showAgentsHome() => _agentsHomeShown.value = true;

  /// Puts the conversation (or the open room) back in front of Home.
  void _leaveAgentsHome() => _agentsHomeShown.value = false;

  /// Opens an agent's profile page. Implemented by the layout, which owns the
  /// navigator and the callbacks the page needs.
  void _openAgentProfile(AgentsAgent agent);

  /// Opens the agent's screen, or null while it has none open — the header
  /// then parks its target. Implemented by the layout, which follows the live
  /// browser presence.
  VoidCallback? get _openAgentScreenOrNull;

  /// Selects an agent's thread. Implemented by the layout, which also
  /// decides what the selection does to the sidebar on a narrow window.
  void _select(String agentId, String threadKey);

  /// Whether the selected thread is really in front of the reader. On a desktop
  /// window it always is; on a phone the inbox can cover it. Implemented by the
  /// layout, and read by the read marks: only what the reader can see is read.
  bool get _threadIsOnScreen;

  AgentsAgent? get _selectedAgent =>
      _selectedAgentId == null ? null : _roster.byId(_selectedAgentId!);

  /// What the user has already seen, per thread — the inbox's unread answer.
  AgentReadMarks get _readMarks => widget.readMarks ?? AgentReadMarks.instance;

  /// The agents' display profiles (picture, colour, role, brief).
  AgentProfileStore get _agentProfiles =>
      widget.agentProfiles ?? AgentProfileStore.instance;

  /// The `initState` half of the host. Called by the state after `super`.
  AppLifecycleListener? _hostLifecycle;

  void _hostInit() {
    _hostLifecycle = AppLifecycleListener(
      // A backgrounded app may be killed without another callback: write what
      // is still waiting on a debounce timer now.
      onPause: _flushPendingWrites,
      onHide: _flushPendingWrites,
      onResume: () {
        _pairingRestore?.nudge();
        // A cloud computer setup that failed or was left half done is picked
        // up again (CHAT-164). The flow keeps 10 s between two requests.
        if (_hasComputer.value != null && !_hasCloudHost) {
          unawaited(_cloudBox.resumed());
        }
        final controller = _controller.value;
        if (controller != null && controller.state.value.isPaired) {
          unawaited(controller.requestAgentList().catchError((Object _) {}));
        }
      },
    );
    // Both stores read one preferences key each and then notify; the inbox and
    // every face listen to them, so a late load lands on its own.
    unawaited(_readMarks.load());
    unawaited(_agentProfiles.load());
    // The roster's preview lines survive a restart, so they are loaded with the
    // rest of the shell state and not on the first frame of the list.
    unawaited(ThreadPreviewStore.instance.load());
    unawaited(MediaIndex.instance.load());
    // Open where the user left off. The roster fills in stages — nothing at
    // first, the host agent on pairing, the rest when the host sends its
    // names — so the restore is not one shot at startup: it watches the roster
    // and lands as soon as its target exists (bead cowork-8yb).
    _roster.addListener(_onRosterChanged);
    // The window title names the agent of an Agents thread in view.
    WindowTitleService.nameResolver = _windowTitleNameFor;
    // A thread whose history loads (cache, cloud, host replay) tells the roster
    // when its agent was last active, if nothing has yet.
    _historySub = ChatStorageState.changes.listen(_seedActivityFromHistory);
    unawaited(_loadLastSelection());
    // Auto-link at startup. Started after the first frame so the app's sign-in
    // / key-unlock flow (which gates showing this shell) has a head start, but
    // it no longer DEPENDS on that: the restore supervisor retries and wakes on
    // the auth event, because "the key is not unlocked yet" is a not-yet, not a
    // no (see [_restoreCloudPairing]).
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreCloudPairing());
    // Show or hide the Agents half with the pairing, not with a poll: the
    // store signals every write and delete, the restore every new reason.
    _pairingStore.changes.addListener(_onPairingStoreChanged);
    _restoreReason.addListener(_resolveHasComputer);
    _hasComputer.addListener(_onHasComputerForCloudBox);
    UserStatusService.status.addListener(_onUserStatusForCloudBox);
    _restoreGraceTimer = Timer(_kRestoreGrace, () {
      _restoreGraceOver = true;
      _resolveHasComputer();
    });
    unawaited(_readLocalPairing());
    // WS-7: a tapped "answer ready" toast (local or push) names a thread. The
    // router keeps the target until this shell takes it, so a tap that
    // launched the app cold is picked up right after the first frame.
    NotificationRouter.instance.pending.addListener(_onNotificationTap);
    // The toast carries the agent's name and face (CHAT-128). A push for
    // the thread the reader has open shows no toast.
    AgentsNotifications.instance.threadLabel = _threadLabel;
    AgentsNotifications.instance.threadAgentId = _agentIdForThread;
    AgentsNotifications.instance.threadOnScreen = _isThreadOnScreen;
    // The agents' faces as PNG files (notification icons) and on the host
    // (its desktop toast): kept true on every roster or profile change.
    _roster.addListener(_scheduleAvatarSync);
    _agentProfiles.addListener(_scheduleAvatarSync);
    AgentsRelayClient.hostCapabilities.addListener(_scheduleAvatarSync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotificationTap());
    // The host's agent names (bead cowork-817): the link fans out every
    // inbound frame of the bound controller, so this sees each `agent_list`
    // without owning the socket.
    _hostInboundSub = AgentsRelayLink.instance.inbound.listen(_onHostInbound);
    // CHAT-177: the other computers' links, each frame tagged with its
    // computer, and the supervisor that keeps their sockets up.
    _secondaryInboundSub = AgentsRelayLinks.instance.secondaryInbound.listen(
      (AgentsHostInbound e) => _onHostInbound(e.event, hostId: e.hostId),
    );
    _pairingStore.changes.addListener(_onPairedHostsChanged);
    AgentsRelayLinks.instance.primary.hostId.addListener(_publishHostLabels);
    unawaited(_readPairedHosts());
    if (widget.multiHostLinks) {
      _hostLinks = AgentsHostLinks(
        store: _pairingStore,
        build:
            widget.relayControllerBuilder ??
            () => _buildRelayController(_pairingStore, widget.sessionSource),
        sessionSource: widget.sessionSource,
      )..start();
    }
    // A mail key made while the app runs goes to the host at once
    // (docs/AGENT_MAIL.md §6.1); each provision sends it too.
    AgentMailKeyHandover.instance.start();
  }

  StreamSubscription<AgentsRelayInbound>? _hostInboundSub;

  void _onPairedHostsChanged() => unawaited(_readPairedHosts());

  /// Ids deleted in this session. The host still lists them (delete is not on
  /// the wire yet, see WIRE_CONTRACT "Agent names"); a list must not bring
  /// an agent back the user just removed.
  final Set<String> _deletedAgentIds = <String>{};

  /// [hostId] is the computer of a secondary link; null is the primary
  /// link's computer.
  void _onHostInbound(AgentsRelayInbound event, {String? hostId}) {
    final String? host = hostId ?? AgentsRelayLinks.instance.primaryHostId;
    final AgentsRelayController? hostController = hostId == null
        ? _controller.value
        : AgentsRelayLinks.instance.secondaryFor(hostId)?.controller.value;
    // A frame that proves the host ran (or is running) a thread's turn also
    // proves the agent lives on the host (bead chuk_chat-89vl): a held
    // `task_ack`, a heartbeat, a live run, or a run terminal — a replayed one
    // too, which is a run the host has stored.
    final String? ranOnHost = switch (event) {
      AgentsRelayTaskAck(:final sessionKey) when event.isHeld => sessionKey,
      AgentsRelayHeartbeat(:final sessionKey) => sessionKey,
      AgentsRelayRunState(:final sessionKey, :final state)
          when state == 'running' =>
        sessionKey,
      AgentsRelayDone(:final sessionKey) => sessionKey,
      _ => null,
    };
    if (ranOnHost != null) {
      final String? agentId = _agentIdForThread(ranOnHost);
      if (agentId != null) _roster.markKnownToHost(agentId);
      return;
    }
    if (event is AgentsRelayRoomList) {
      // Groups live on the computer on screen (phase 2 spans computers).
      if (hostId == null) _applyHostRooms(event);
      return;
    }
    if (event is! AgentsRelayAgentList) return;
    // Agents deleted on the host (another device, or the host's own
    // cleanup): drop them here too, with the same cascade as a delete in
    // this app, but without sending the delete back.
    for (final String id in event.deleted) {
      if (id.startsWith('host:')) continue;
      if (_roster.byId(id) == null && _deletedAgentIds.contains(id)) continue;
      // A computer deletes only its own agents.
      final AgentsAgent? known = _roster.byId(id);
      if (known != null && !_onHost(known, host)) continue;
      _deleteAgent(id, fromHost: true);
    }
    final String? peer = hostController?.state.value.peerDeviceId;
    if (hostId != null && peer != null) {
      // A secondary computer's own agent: the primary one comes from
      // [_onPaired].
      _roster.ensureHostAgent(
        peer,
        label: _pairingFor(hostId)?.effectiveKind == AgentsHostKind.cloud
            ? 'Cloud computer'
            : _l10n.agentsHostYourComputer,
        hostId: hostId,
        agentId: _hostAgentIdFor(hostId, peer),
      );
    }
    _roster.applyHostNames(
      event.agents,
      peerDeviceId: peer,
      ignore: _deletedAgentIds,
      hostId: host,
      hostAgentId: peer == null ? null : _hostAgentIdFor(host, peer),
    );
    _reannounceMissingAgents(event.agents, host, hostController);
    // The host answered, so it is linked and authenticated: a good time to
    // send the faces it has not got yet.
    _scheduleAvatarSync();
  }

  /// The host's groups (`room_list`): merged into the local list, which keeps
  /// a group the host does not have yet (it is pushed when opened).
  void _applyHostRooms(AgentsRelayRoomList event) {
    final List<AgentsRoom> listed = <AgentsRoom>[
      for (final AgentsRelayRoomListEntry entry in event.rooms)
        ?AgentsRoom.fromJson(entry.payload),
    ];
    _hostKnownRooms.addAll(listed.map((AgentsRoom r) => r.id));
    _rooms.applyHostRooms(listed);
  }

  /// Whether [agent] lives on [hostId]. An agent with no computer yet lives
  /// on the computer on screen.
  bool _onHost(AgentsAgent agent, String? hostId) {
    final String? own = agent.hostId;
    if (own == null || hostId == null) {
      return hostId == null ||
          hostId == AgentsRelayLinks.instance.primaryHostId;
    }
    return own == hostId;
  }

  /// The live controller of [agent]'s computer, or null while it is down.
  AgentsRelayController? _controllerForAgent(AgentsAgent agent) {
    final String? host = agent.hostId;
    if (host == null || host == AgentsRelayLinks.instance.primaryHostId) {
      return _controller.value;
    }
    return AgentsRelayLinks.instance.secondaryFor(host)?.controller.value;
  }

  /// Ids re-sent to the host this session, so a host that keeps dropping an
  /// `agent_create` cannot turn each `agent_list` answer into another send.
  final Set<String> _reannouncedAgentIds = <String>{};

  /// Sends `agent_create` again for every agent this device made that the
  /// host does not list (bead chuk_chat-41k1): without it, an agent whose
  /// first announce was lost stays on this device and never appears on the
  /// user's other devices. The host upserts by id, so a resend is harmless;
  /// its `agent_list` answer comes back through [_onHostInbound].
  void _reannounceMissingAgents(
    List<AgentsHostAgentName> listed,
    String? hostId,
    AgentsRelayController? controller,
  ) {
    if (controller == null) return;
    for (final AgentsAgent agent in agentsMissingOnHost(
      // Only this computer's agents: an agent of another computer is
      // missing here on purpose.
      <AgentsAgent>[
        for (final AgentsAgent a in _roster.agents)
          if (_onHost(a, hostId)) a,
      ],
      listed,
      skip: <String>{..._deletedAgentIds, ..._reannouncedAgentIds},
    )) {
      _reannouncedAgentIds.add(agent.id);
      unawaited(
        controller.createAgent(agent.id, agent.name).catchError((Object _) {
          // Not sent (link down): the next agent_list tries again.
          _reannouncedAgentIds.remove(agent.id);
        }),
      );
    }
  }

  /// Reads the persisted roster and the remembered pick, then lands on it.
  ///
  /// The roster FIRST, and awaited: the remembered pick is an agent id, and
  /// `_autoSelect` can only land on it if that agent is in the roster. Without
  /// the cached roster the restore missed on every cold start and the shell
  /// waited for the relay to pair — which is exactly the wait this closes.
  Future<void> _loadLastSelection() async {
    try {
      await _roster.load();
    } catch (_) {
      // A roster that cannot be read is an empty one, as it always was.
    }
    if (!mounted) return;
    // Deletes outlive the launch they were made in: the host still lists an
    // agent the user removed (delete has no wire frame yet), so the ignore
    // set has to start with what earlier launches deleted.
    _deletedAgentIds.addAll(_roster.deletedIds);
    String? agentId;
    String? threadKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      final (String, String)? pick = _decodePick(
        prefs.getString(_kLastPickKey),
      );
      agentId = pick?.$1 ?? prefs.getString(_kLastAgentKey);
      threadKey = pick?.$2 ?? prefs.getString(_kLastThreadKey);
    } catch (_) {
      // No preferences (a test, a locked store): fall back to the first
      // agent, which is still better than an empty chat.
    }
    if (!mounted) return;
    _restoredAgentId = agentId;
    _restoredThreadKey = threadKey;
    _restoreLoaded = true;
    _autoSelect();
  }

  /// Writes the pick for the next launch and marks the selection as the
  /// user's, so [_autoSelect] leaves it alone from here on.
  void _rememberSelection(String agentId, String threadKey) {
    _selectionIsAuto = false;
    _restoredAgentId = agentId;
    _restoredThreadKey = threadKey;
    // Written once the reader stops clicking, not on the switch itself: on
    // desktop Linux every preference write rewrites the whole preferences
    // file on the UI isolate, and a switch is exactly the frame that must not
    // wait on it. Dispose writes a pick that is still pending.
    _pendingPick = (agentId, threadKey);
    _rememberTimer?.cancel();
    _rememberTimer = Timer(
      _kRememberDelay,
      () => unawaited(_writeRememberedSelection()),
    );
  }

  static const Duration _kRememberDelay = Duration(milliseconds: 1500);
  Timer? _rememberTimer;
  (String, String)? _pendingPick;

  /// Writes the remembered pick, skipping a key that already holds it.
  Future<void> _writeRememberedSelection() async {
    _rememberTimer = null;
    final pick = _pendingPick;
    _pendingPick = null;
    if (pick == null) return;
    final (agentId, threadKey) = pick;
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode(<String>[agentId, threadKey]);
      if (prefs.getString(_kLastPickKey) != encoded) {
        await prefs.setString(_kLastPickKey, encoded);
      }
    } catch (_) {
      // Losing the pointer costs the next launch its position, nothing more.
    }
  }

  static (String, String)? _decodePick(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List &&
          decoded.length == 2 &&
          decoded[0] is String &&
          decoded[1] is String) {
        return (decoded[0] as String, decoded[1] as String);
      }
    } catch (_) {
      // A damaged value falls back to the two old keys.
    }
    return null;
  }

  void _flushPendingWrites() {
    unawaited(_readMarks.flush());
    _roster.flushPendingPersist();
  }

  void _onRosterChanged() {
    if (!mounted) return;
    _seedActivityFromHistory();
    _autoSelect();
    // A notification tapped before its thread was listed opens now.
    if (NotificationRouter.instance.pending.value != null) {
      _onNotificationTap();
    }
    // An agent's name can arrive or change after its thread is in view.
    WindowTitleService.refresh();
  }

  /// The agent's name for an Agents thread, or null for any other chat.
  String? _windowTitleNameFor(String chatId) {
    final String? agentId = _agentIdForThread(chatId);
    return agentId == null ? null : _roster.byId(agentId)?.name;
  }

  StreamSubscription<String?>? _historySub;

  /// True while [_seedActivityFromHistory] scans. Each seeded time notifies
  /// the roster synchronously, and the roster listener seeds again; without
  /// this every seeded thread started a nested scan of the whole roster.
  bool _seedingActivity = false;

  /// Fills in "last active" from the history the app already holds, for every
  /// thread that has no time yet. Before, the roster only learned a time from a
  /// live event, so after a restart every agent read "no activity yet" next
  /// to a full conversation. The time is the newest message's own timestamp,
  /// never an invented one. History that old is not news: a thread the user
  /// never marked read gets its read mark at the same time, so seeding does
  /// not light up every agent as unread.
  void _seedActivityFromHistory([String? onlyKey]) {
    if (!mounted || _seedingActivity) return;
    _seedingActivity = true;
    try {
      for (final AgentsAgent agent in _roster.agents) {
        for (final AgentsThreadInfo thread in agent.threads) {
          if (onlyKey != null && thread.key != onlyKey) continue;
          if (thread.lastActivity != null) continue;
          final when = newestMessageTime(
            ChatStorageState.chatsById[thread.key]?.messagesOrNull,
          );
          if (when == null) continue;
          if (_readMarks.lastRead(thread.key) == null) {
            unawaited(_readMarks.markRead(thread.key, when: when));
          }
          _roster.markActivity(agent.id, thread.key, when);
        }
      }
    } finally {
      _seedingActivity = false;
    }
  }

  /// Lands on a thread without waiting for the user.
  ///
  /// The rule the user asked for, and the one every desktop messenger follows:
  /// you come back to where you were; failing that, to the top of the list.
  /// Never to an empty chat.
  ///
  /// It runs again on every roster change, because the remembered agent may
  /// only show up once the host has sent its names. A selection this method
  /// made may be replaced by the remembered one when it arrives; a selection
  /// the user made never is.
  void _autoSelect() {
    if (!_restoreLoaded) return;
    final String? restoredId = _restoredAgentId;
    final AgentsAgent? restored = restoredId == null
        ? null
        : _roster.byId(restoredId);
    final AgentsAgent? current = _selectedAgentId == null
        ? null
        : _roster.byId(_selectedAgentId!);
    if (current != null) {
      final bool upgradeToRemembered =
          _selectionIsAuto && restored != null && restored.id != current.id;
      if (!upgradeToRemembered) return;
    }
    final List<AgentsAgent> visible = _roster.visibleAgents;
    final AgentsAgent? target =
        restored ?? (visible.isEmpty ? null : visible.first);
    if (target == null || target.threads.isEmpty) return;
    final String threadKey =
        target.threads.any((thread) => thread.key == _restoredThreadKey)
        ? _restoredThreadKey!
        : target.threads.first.key;
    setState(() {
      _selectedAgentId = target.id;
      _selectedThreadKey = threadKey;
      _selectionIsAuto = true;
    });
  }

  /// The `dispose` half of the host. Called by the state before `super`.
  void _hostDispose() {
    _agentsHomeShown.dispose();
    if (_rememberTimer != null) {
      _rememberTimer!.cancel();
      unawaited(_writeRememberedSelection());
    }
    _hostLifecycle?.dispose();
    _flushPendingWrites();
    _roster.removeListener(_onRosterChanged);
    _roster.removeListener(_scheduleAvatarSync);
    _agentProfiles.removeListener(_scheduleAvatarSync);
    AgentsRelayClient.hostCapabilities.removeListener(_scheduleAvatarSync);
    _avatarSyncTimer?.cancel();
    if (WindowTitleService.nameResolver == _windowTitleNameFor) {
      WindowTitleService.nameResolver = null;
    }
    _historySub?.cancel();
    NotificationRouter.instance.pending.removeListener(_onNotificationTap);
    _cancelWaitingTap();
    _hostInboundSub?.cancel();
    _secondaryInboundSub?.cancel();
    _pairingStore.changes.removeListener(_onPairedHostsChanged);
    AgentsRelayLinks.instance.primary.hostId.removeListener(_publishHostLabels);
    unawaited(_hostLinks?.dispose() ?? Future<void>.value());
    _pairedHosts.dispose();
    AgentMailKeyHandover.instance.stop();
    _pairingStore.changes.removeListener(_onPairingStoreChanged);
    _restoreReason.removeListener(_resolveHasComputer);
    _hasComputer.removeListener(_onHasComputerForCloudBox);
    UserStatusService.status.removeListener(_onUserStatusForCloudBox);
    _cloudBox.dispose();
    _restoreGraceTimer?.cancel();
    _pairingRestore?.reason.removeListener(_onRestoreReason);
    unawaited(_pairingRestore?.dispose() ?? Future<void>.value());
    _controller.dispose();
    _linkReport.dispose();
    _restoreReason.dispose();
    _hasComputer.dispose();
    if (_ownsControlSource) _controlSource.dispose();
    if (_ownsThemeController) _themeController.dispose();
  }

  bool _isThreadOnScreen(String threadKey) =>
      mounted && threadKey == _selectedThreadKey && _threadIsOnScreen;

  Timer? _avatarSyncTimer;

  /// Waits for a burst of roster or profile changes to end, then paints the
  /// faces and sends the new ones to the host ([AgentAvatarSync]).
  void _scheduleAvatarSync() {
    _avatarSyncTimer?.cancel();
    _avatarSyncTimer = Timer(const Duration(seconds: 2), _runAvatarSync);
  }

  void _runAvatarSync() {
    if (!mounted) return;
    final controller = _controller.value;
    final String? hostId = controller?.state.value.peerDeviceId;
    // Only a host that names the capability gets the frame; an older one
    // would answer it with an error.
    final bool linked =
        controller != null &&
        controller.state.value.isPaired &&
        AgentsRelayClient.hostCapabilities.value.contains(
          AgentsRelayClient.agentAvatarCapability,
        );
    final AgentsAvatarControl? avatarControl = switch (controller) {
      final AgentsAvatarControl c when linked => c,
      _ => null,
    };
    unawaited(
      AgentAvatarSync.instance.sync(
        agents: <AvatarAgent>[
          for (final AgentsAgent agent in _roster.agents)
            (id: agent.id, name: agent.name),
        ],
        control: avatarControl,
        hostId: linked ? hostId : null,
      ),
    );
  }

  String _threadLabel(String threadKey) {
    final String? agentId = _agentIdForThread(threadKey);
    // The product name, not the mode's: this is what a notification says when
    // no agent can be resolved for the thread. It comes from the same place
    // the About page shows it — the localized product name, with upstream's own
    // hardcoded fallback for the case where no localization is reachable (the
    // callback can fire after this shell is gone).
    final String product =
        (mounted ? AppLocalizations.of(context)?.chukChat : null) ??
        'Chuk Chat';
    if (agentId == null) return product;
    return _roster.byId(agentId)?.name ?? product;
  }

  /// Opens the thread a notification named. Selecting it is enough: the
  /// thread view replays from its cursor when its thread changes, and the
  /// "Answer ready" affordance comes from the replayed `while_away` done.
  ///
  /// A tap whose thread the roster does not list yet (a cold start from the
  /// toast, before the roster is back from disk) is left pending and taken on
  /// the next roster change, instead of being dropped (bead chuk_chat-kl8x).
  /// It waits [pendingNotificationTapExpiry] at most, then it is dropped.
  void _onNotificationTap() {
    final NotificationTarget? pending =
        NotificationRouter.instance.pending.value;
    if (pending == null || !mounted) {
      if (pending == null) _cancelWaitingTap();
      return;
    }
    final String? connectorId = pending.connectorId;
    if (connectorId != null) {
      // "Fastmail: sign-in expired": the tap opens that connector and starts
      // its browser sign-in at once. No thread to select.
      _cancelWaitingTap();
      NotificationRouter.instance.take();
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                McpConnectorDetailPage(id: connectorId, reconnectOnOpen: true),
          ),
        ),
      );
      return;
    }
    final String? agentId = _agentIdForThread(pending.sessionKey);
    if (agentId == null) {
      // Not an agent's thread at all: not this shell's to open.
      if (!ChatOrigin.isAgentsThread(pending.sessionKey)) {
        _cancelWaitingTap();
        NotificationRouter.instance.take();
        return;
      }
      _armWaitingTap(pending);
      return;
    }
    _cancelWaitingTap();
    final NotificationTarget target = NotificationRouter.instance.take()!;
    _select(agentId, target.sessionKey);
    // Close the host's row and clear the OS toast for this thread.
    unawaited(
      AgentsNotifications.instance.onOpenedFromNotification(
        target.sessionKey,
        runId: target.runId,
      ),
    );
  }

  /// Starts the expiry for a tap that waits for its thread. A second look at
  /// the same tap (every roster change) keeps the first deadline.
  void _armWaitingTap(NotificationTarget target) {
    if (identical(_waitingTap, target) && _waitingTapTimer != null) return;
    _waitingTapTimer?.cancel();
    _waitingTap = target;
    _waitingTapTimer = Timer(pendingNotificationTapExpiry, () {
      final NotificationTarget? waited = _waitingTap;
      _waitingTapTimer = null;
      _waitingTap = null;
      // Only the tap this timer was armed for: a newer tap has its own time.
      if (waited != null &&
          identical(NotificationRouter.instance.pending.value, waited)) {
        NotificationRouter.instance.take();
      }
    });
  }

  void _cancelWaitingTap() {
    _waitingTapTimer?.cancel();
    _waitingTapTimer = null;
    _waitingTap = null;
  }

  /// Restores this account's pairing from Supabase when the device has none
  /// locally, then feeds it into the EXISTING code-free reconnect path.
  ///
  /// The product promise (see docs/PRODUCT_PHILOSOPHY.md): reinstall anywhere,
  /// sign in, and the client reconnects to the same running host on its own —
  /// no re-pairing ritual. The connection info lives encrypted in Supabase.
  ///
  /// This used to be one shot in a post-frame callback, and one shot is not
  /// enough. At that moment the Supabase session may not be back off disk yet,
  /// the `EncryptionService` key may not be unlocked yet — and without it the
  /// mirror is unreadable ciphertext — or the network may simply be down for
  /// those two seconds. Every one of those is a "not yet", and the old code read
  /// them all as "never": the user signed in and still faced a pairing screen
  /// for a computer they already owned.
  ///
  /// So it is a supervisor now ([AgentsPairingRestore]): capped backoff, woken
  /// by the auth event that makes a retry meaningful, and a slow heartbeat after
  /// that so a pairing made on another device lands here on its own. It stands
  /// down for good once the device is paired.
  ///
  /// Wiring, without touching the thread view: the thread view reads the local
  /// pairing store exactly once at bootstrap and reconnects from it. So this
  /// writes the restored pairing into that same store with `savePairing`, then
  /// swaps the thread view's [GlobalKey] once, which re-runs its bootstrap — the
  /// very path a fresh local pairing already takes.
  void _restoreCloudPairing() {
    if (_pairingRestore != null || !mounted) return;
    Future<void> onRestored() async {
      if (!mounted) return;
      setState(() => _threadViewKey = GlobalKey());
    }

    final builder = widget.pairingRestoreBuilder;
    final restore = builder != null
        ? builder(_pairingStore, widget.sessionSource, onRestored)
        : AgentsPairingRestore(
            store: _pairingStore,
            sessionSource: widget.sessionSource,
            onRestored: onRestored,
          );
    _pairingRestore = restore;
    restore.reason.addListener(_onRestoreReason);
    restore.start();
  }

  void _onRestoreReason() {
    final restore = _pairingRestore;
    if (!mounted || restore == null) return;
    _restoreReason.value = restore.reason.value;
  }

  void _onPairingStoreChanged() => unawaited(_readLocalPairing());

  /// Reads the pairing store once and folds the answer into [_hasComputer].
  /// Only the newest read counts, so a slow read cannot undo a later write.
  Future<void> _readLocalPairing() async {
    final int read = ++_pairingReads;
    bool paired;
    try {
      paired = await _pairingStore.loadPairing() != null;
    } catch (_) {
      // A locked keystore reads as "no pairing here yet"; the restore keeps
      // trying and its reason decides what the shell offers meanwhile.
      paired = false;
    }
    if (!mounted || read != _pairingReads) return;
    _pairingRemoved = paired ? false : (_pairingRemoved || _localPairing);
    _localPairingKnown = true;
    _localPairing = paired;
    _resolveHasComputer();
  }

  void _resolveHasComputer() {
    if (!mounted) return;
    final bool? next;
    if (!_localPairingKnown) {
      next = null;
    } else if (_localPairing) {
      next = true;
    } else {
      final AgentsPairingRestoreReason reason = _restoreReason.value;
      // `paired` with no local record is the moment between a restore and
      // its store write, or the restore's last word before a removal: not a
      // final "no" by itself.
      final bool restoreSaysNo =
          reason != AgentsPairingRestoreReason.paired &&
          !reason.mayStillRestore;
      next = (_pairingRemoved || restoreSaysNo || _restoreGraceOver)
          ? false
          : null;
    }
    _hasComputer.value = next;
  }

  /// Runs the shared invite pairing for the install page.
  ///
  /// It runs on the live thread view's transport, exactly as a scan does, so
  /// the view takes the new trust, the host agent lands in the roster and
  /// the encrypted mirror is written. Without a thread view (it is always
  /// mounted in practice) it pairs on a transport of its own and then remounts
  /// the view, which reconnects from the stored trust.
  Future<AgentsStoredPairing?> _pairWithInvite(
    AgentsPairingInvite invite,
  ) async {
    final AgentsThreadViewState? view = _threadViewState;
    if (view != null) return view.pairWithInvite(invite);
    final AgentsRelayController controller =
        await (widget.relayControllerBuilder ??
            () => _buildRelayController(_pairingStore, widget.sessionSource))();
    AgentsStoredPairing? trust;
    try {
      trust = await pairAgentsFromInvite(
        controller: controller,
        invite: invite,
        sessionSource: widget.sessionSource,
        store: _pairingStore,
      );
    } finally {
      controller.dispose();
    }
    if (mounted) setState(() => _threadViewKey = GlobalKey());
    return trust;
  }

  /// The install page's wait: the app's own device identity claims the
  /// command's channel on the relay until the computer has parked there.
  Future<String?> _waitForInstallClaim(
    AgentsPairingInvite invite, {
    required DateTime deadline,
    required AgentsClaimCancel cancel,
  }) async {
    final AgentsDeviceIdentity identity = await _pairingStore
        .loadOrCreateIdentity();
    return AgentsCloudRelaySocket.waitForPairingClaim(
      base: invite.relayBase,
      pairingChannel: invite.pairingChannel,
      deviceId: identity.deviceId,
      sessionSource: widget.sessionSource,
      deadline: deadline,
      cancel: cancel,
    );
  }

  /// Opens the install page. Completes with true when a computer was linked.
  Future<bool> _openInstallPage() async {
    bool booked = false;
    final bool linked = await AgentsInstallPage.show(
      context,
      ticketStore: AgentsInstallTicketStore(backend: _pairingStore.backend),
      sessionSource: widget.sessionSource,
      claimWaiter: widget.installClaimWaiter ?? _waitForInstallClaim,
      pair: _pairWithInvite,
      // The other way (CHAT-164): book a cloud computer. A build without
      // direct payments does not offer it.
      bookCloudBox: kFeaturePaymentsDirect
          ? (BuildContext pageContext) async =>
                booked = await showCloudBoxBookSheet(pageContext)
          : null,
    );
    if (booked && mounted) {
      // The booking refreshed the user status; this picks the zero-click
      // setup up even when the flow sat in "failed".
      unawaited(_cloudBox.resumed());
    }
    if (linked && mounted) {
      // The store signalled the write already; this makes sure the answer is
      // in before the caller moves to the Agents half.
      await _readLocalPairing();
    }
    return linked && mounted;
  }

  /// The billing portal for a cloud computer paused by a payment problem.
  /// After it the flow asks the server again.
  Future<void> _openCloudBoxBilling() async {
    try {
      await openBillingPortal();
    } catch (error) {
      if (!mounted) return;
      AppNotifications.show(
        context,
        error.toString().replaceAll('Exception: ', ''),
        kind: AppNotificationKind.error,
      );
    }
  }

  /// The live thread view's state, for the status panel's actions.
  AgentsThreadViewState? get _threadViewState {
    final state = _threadViewKey.currentState;
    return state is AgentsThreadViewState ? state : null;
  }

  /// What the shell shows while there is no conversation: the one status that
  /// [resolveAgentsShellStatus] picks, with its actions wired to the thread
  /// view (pairing, reconnect) and to the roster (a new agent).
  Widget _buildStatusPanel({double topInset = 0}) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _linkReport,
        _restoreReason,
        AgentsCloudRelaySocket.healInProgress,
        _roster,
        _cloudBox,
        _hasComputer,
      ]),
      builder: (BuildContext context, Widget? _) {
        // The cloud computer is being set up (or needs the user): its calm
        // screen takes the place of "Add your computer" (CHAT-164).
        if (_hasComputer.value != true && _cloudBox.phase.visible) {
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: AgentsCloudBoxPanel(
              key: const ValueKey<String>('agents-cloud-box-panel'),
              phase: _cloudBox.phase,
              topInset: topInset,
              onRetry: () => unawaited(_cloudBox.retry()),
              onOpenBilling: () => unawaited(_openCloudBoxBilling()),
              onUseOwnComputer: () => unawaited(_openInstallPage()),
            ),
          );
        }
        final AgentsLinkReport link = _linkReport.value;
        final AgentsShellStatus status = resolveAgentsShellStatus(
          link: link,
          restore: _restoreReason.value,
          healing: AgentsCloudRelaySocket.healInProgress.value,
          rosterEmpty: _roster.visibleAgents.isEmpty,
        );
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: AgentsStatusPanel(
            key: ValueKey<AgentsShellStatus>(status),
            status: status,
            message: link.message,
            busy: link.busy,
            topInset: topInset,
            // The install page (one command to paste), which keeps "Pair
            // with a code instead" one tap away. It used to sit in the plain
            // chats' sidebar, which the Agents build no longer has.
            onAddComputer: () => unawaited(_openInstallPage()),
            onReconnect: () => unawaited(
              _threadViewState?.reconnect(force: true) ?? Future.value(),
            ),
            onAddAgent: () => unawaited(_openOnboarding()),
          ),
        );
      },
    );
  }

  /// Keeps trying until this device is linked. Disposed with the shell.
  AgentsPairingRestore? _pairingRestore;

  /// Which agent owns [threadKey]. A run's events belong to the thread that
  /// started it, which is not always the one on screen.
  String? _agentIdForThread(String threadKey) {
    for (final agent in _roster.agents) {
      if (agent.threads.any((thread) => thread.key == threadKey)) {
        return agent.id;
      }
    }
    return null;
  }

  /// The shell's strings; English when no localizations are in the tree
  /// (some widget tests mount the shell bare).
  AppLocalizations get _l10n =>
      AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

  void _onPaired(String peerDeviceId) {
    final String? hostId = AgentsRelayLinks.instance.primaryHostId;
    // A person reads "Your computer", not the raw device id. The same label
    // in the other languages may be replaced, so a language change follows.
    final AgentsAgent agent = _roster.ensureHostAgent(
      peerDeviceId,
      label: _l10n.agentsHostYourComputer,
      replaceableLabels: <String>{
        for (final Locale locale in AppLocalizations.supportedLocales)
          AppLocalizations(locale).agentsHostYourComputer,
      },
      hostId: hostId,
      agentId: _hostAgentIdFor(hostId, peerDeviceId),
    );
    // The names the host keeps (bead cowork-817): asked on every pair, so a
    // reinstall and a second device show the same agents. The answer
    // lands in [_onHostInbound].
    unawaited(_controller.value?.requestAgentList());
    // `ensureHostAgent` notifies the roster, which lands the restore; this only
    // covers the case where the agent was already listed, so nothing notified.
    if (_selectedAgentId == null) _autoSelect();
    // A roster that is still empty of the remembered agent leaves the host
    // one selected; the agent list that follows brings the remembered one and
    // [_autoSelect] moves to it.
    if (_selectedAgentId == null && agent.threads.isNotEmpty) {
      setState(() {
        _selectedAgentId = agent.id;
        _selectedThreadKey = agent.threads.first.key;
        _selectionIsAuto = true;
      });
    }
  }

  /// The one thread view. Built by exactly one place in the tree at a time;
  /// the [GlobalKey] keeps its state (and its socket) when the layout moves it
  /// between the desktop stack and the phone screens. The phone layout only
  /// adds the floating-bar inset and forces chuk's phone screen.
  ///
  /// [menuActions] are the shell's own thread actions: on a desktop window
  /// they wait behind the header's "…", next to its Documents, Call and
  /// Screen chips. [onOpenAgent] is a tap on the agent in that header.
  AgentsThreadView _buildThread({
    double topInset = 0,
    bool phone = false,
    VoidCallback? onOpenAgent,
    List<AgentsThreadAction> menuActions = const <AgentsThreadAction>[],
    VoidCallback? onTogglePanel,
    bool panelOpen = false,
  }) {
    final agent = _selectedAgent;
    return AgentsThreadView(
      key: _threadViewKey,
      controllerBuilder:
          widget.relayControllerBuilder ??
          () => _buildRelayController(_pairingStore, widget.sessionSource),
      sessionSource: widget.sessionSource,
      pairingStore: _pairingStore,
      // The open agent's computer (CHAT-177); the view moves its link there.
      hostId: agent?.hostId,
      threadKey: _selectedThreadKey,
      // The jump to the first new message (bead chuk_chat-f5wd).
      unreadSince: _readMarks.unreadSince(_selectedThreadKey),
      onUnreadSeen: () => _readMarks.clearUnreadSince(_selectedThreadKey),
      shellConfig: widget.shellConfig,
      onPaired: _onPaired,
      onRunStateChanged: (threadKey, running) {
        final agentId = _agentIdForThread(threadKey);
        if (agentId != null) _roster.markRunning(agentId, running);
      },
      onActivity: (threadKey, when) {
        final agentId = _agentIdForThread(threadKey);
        if (agentId != null) {
          _roster.markActivity(agentId, threadKey, when);
        }
        // The reader has this thread in front of them, so what just arrived is
        // read. A thread that is only selected behind the phone inbox is not.
        if (threadKey == _selectedThreadKey && _threadIsOnScreen) {
          unawaited(_readMarks.markRead(threadKey, when: when));
        }
      },
      onController: _onController,
      onOpenModelScreen: _openModelScreen,
      title: agent?.name,
      onOpenAgentScreen: _openAgentScreenOrNull,
      agent: agent,
      onOpenAgent: onOpenAgent,
      profiles: _agentProfiles,
      menuActions: menuActions,
      onTogglePanel: onTogglePanel,
      panelOpen: panelOpen,
      topInset: topInset,
      phoneLayout: phone,
      linkReport: _linkReport,
      emptyState: _buildStatusPanel(),
    );
  }

  /// Opens the full model catalogue from the composer's "More models" way out.
  /// Implemented by the layout: chuk's settings modal on the model section on
  /// a desktop window, chuk's `ModelSelectorPage` as a route on a phone.
  void _openModelScreen();

  // ── templates ──
  /// New agent (bead cowork-817, templates chuk_chat-dsh0): the template
  /// picker first ("Blank agent" or one of [kAgentTemplates]), then the
  /// name. The agent is created with that name and its thread opens; the
  /// host is told so the name outlives this install, and a template's persona
  /// rides along for its soul.md (`agent_create`, WIRE_CONTRACT "Agent
  /// templates"). A template's face and role land in this device's profile
  /// store. The starter automation is sent only when the user switched it on.
  Future<void> _openOnboarding() async {
    final taken = _roster.agents.map((agent) => agent.name);
    final suggested = const AgentNameGenerator().next(taken: taken);
    final request = await showAgentTemplatePicker(
      context,
      suggestedName: suggested,
    );
    if (!mounted || request == null || request.name.isEmpty) return;
    // CHAT-177: with more than one computer, the user picks where the agent
    // runs; the computer used last is chosen already.
    final String? hostId = await _pickHostForNewAgent();
    if (!mounted) return;
    if (_pairedHosts.value.length > 1 && hostId == null) return;
    final template = request.template;
    final l = _l10n;
    final templateName = template == null ? null : l.tpl(template.nameKey);
    final agent = _roster.addAgent(
      name: request.name,
      // The role line names the template, unless the name already says it.
      role: templateName == request.name ? null : templateName,
      brief: template == null ? null : l.tpl(template.descriptionKey),
      hostId: hostId,
    );
    if (template != null) {
      unawaited(
        _agentProfiles.update(
          agent.id,
          colorValue: template.accent,
          shape: template.shape,
        ),
      );
    }
    unawaited(
      _createOnHost(agent, template, startAutomation: request.startAutomation),
    );
    _select(agent.id, agent.threads.first.key);
  }

  /// Tells the host about a new agent, then — only when the user turned
  /// it on — creates the template's starter automation for it
  /// ([announceAgentToHost]). A failure is said, not swallowed: when
  /// `agent_create` did not go out (no controller, a failed send) the
  /// starter is not sent and the user is told; when only the automation
  /// failed, the agent exists and the schedule does not.
  Future<void> _createOnHost(
    AgentsAgent agent,
    AgentTemplate? template, {
    required bool startAutomation,
  }) async {
    // The agent's own computer (CHAT-177), which may not be the one on
    // screen.
    final controller = _controllerForAgent(agent);
    final starter = template?.starter;
    final l = _l10n;
    final outcome = await announceAgentToHost(
      createAgent: controller == null
          ? null
          : () => controller.createAgent(
              agent.id,
              agent.name,
              template: template?.toWire(),
            ),
      createStarter: !startAutomation || starter == null
          ? null
          : () => AutomationsSource.instance.create(
              sessionKey: agent.id,
              kind: 'schedule',
              spec: starter.cron,
              prompt: starter.prompt,
              name: l.tpl(starter.nameKey),
            ),
    );
    if (outcome.ok || !mounted) return;
    if (outcome.agentFailed && kDebugMode) {
      debugPrint(
        'agent_create failed: ${outcome.agentError ?? 'no controller'}',
      );
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          outcome.agentFailed
              // Names the agent: it is in the roster, not on the host
              // (bead chuk_chat-az1g).
              ? l.tplAgentCreateFailed(agent.name)
              : l.tplStarterFailed(agent.name, outcome.starterError ?? ''),
        ),
      ),
    );
  }
  // ── end templates ──

  /// Rename (bead cowork-817): the roster row's menu → chuk's dialog → here.
  /// Local first, then the host, like [_renameRoom].
  void _renameAgent(String agentId, String name) {
    _roster.renameAgent(agentId, name);
    final agent = _roster.byId(agentId);
    if (agent == null) return;
    unawaited(_controllerForAgent(agent)?.renameAgent(agentId, agent.name));
  }

  Future<void> _openAgentRename(AgentsAgent agent) async {
    final name = await showAgentNameDialog(
      context,
      title: 'Rename agent',
      initialName: agent.name,
      submitLabel: 'Rename',
    );
    if (!mounted || name == null || name.isEmpty || name == agent.name) return;
    _renameAgent(agent.id, name);
  }

  /// The rooms list, for the desktop panel and the phone route alike. A room
  /// open still pushes `RoomThreadPage` as its own route, so the agent thread
  /// and its live socket stay mounted underneath — a room never disturbs the
  /// one-to-one connection.
  Widget _buildRoomList({bool showHeader = true}) => RoomListView(
    source: _rooms,
    showHeader: showHeader,
    onCreate: _openRoomCreate,
    onSelect: _openRoom,
    onDelete: _deleteRoom,
    onRename: _renameRoom,
    onManageMembers: _manageRoomMembers,
  );

  Future<void> _openRoomCreate() async {
    // Only agents the app can actually name can join a room.
    final agents = _roster.visibleAgents;
    await showAgentsSheetOrDialog<void>(
      context: context,
      builder: (sheetContext) => RoomCreateSheet(
        agents: agents,
        onCancel: () => Navigator.of(sheetContext).pop(),
        onSubmit: (draft) {
          final room = _rooms.addRoom(draft);
          // Push the room to the host so a later message can drive it. It rides
          // the shared socket if the transport is up; if not, the create sheet
          // still succeeds locally and the room syncs on the next open/send.
          _controller.value?.createRoom(
            room.id,
            room.name,
            <Map<String, String>>[
              for (final m in room.members)
                <String, String>{'agent_id': m.agentId, 'handle': m.handle},
            ],
            agentToAgent: room.agentToAgent,
            settings: room.settingsWire(),
          );
          Navigator.of(sheetContext).pop();
        },
      ),
    );
  }

  /// Opens a room. The phone pushes it as its own route, so the agent thread
  /// and its live socket stay mounted underneath — a room never disturbs the
  /// one-to-one connection. The desktop layout overrides this and shows the
  /// room in its centre pane instead.
  Future<void> _openRoom(String roomId) async {
    final room = _rooms.byId(roomId);
    if (room == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FloatingPageScaffold(
          appBar: FloatingAppBar(
            title: Text(room.name),
            actions: <Widget>[
              FloatingHeaderButton(
                icon: Icons.info_outline_rounded,
                tooltip: _l10n.agentsGroupDetails,
                onPressed: () => unawaited(_openRoomDetailsPage(room.id)),
              ),
            ],
          ),
          body: _buildRoomBody(room),
        ),
      ),
    );
  }

  /// The phone's group details: the same panel as the desktop's right pane,
  /// as its own page.
  Future<void> _openRoomDetailsPage(String roomId) async {
    if (_rooms.byId(roomId) == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FloatingPageScaffold(
          appBar: FloatingAppBar(title: Text(_l10n.agentsGroupDetails)),
          body: _buildRoomDetails(roomId),
        ),
      ),
    );
  }

  /// A group's details ([RoomDetailsPanel]), for the desktop pane and the
  /// phone page alike. Every change goes local first, then to the host.
  Widget _buildRoomDetails(String roomId) => RoomDetailsPanel(
    key: ValueKey<String>('room-details-$roomId'),
    source: _rooms,
    roomId: roomId,
    agents: _roster.visibleAgents,
    onSettingsChanged: (String id, Map<String, Object?> settings) {
      if (settings.isEmpty) return;
      unawaited(_controller.value?.setRoomSettings(id, settings));
    },
    onAddMember: _addRoomMember,
    onRemoveMember: (String id, String agentId) {
      _removeRoomMember(id, agentId);
    },
    onAgentToAgentChanged: _setRoomAgentToAgent,
  );

  void _addRoomMember(String roomId, AgentsRoomMember member) {
    _rooms.addMemberToRoom(roomId, member);
    unawaited(
      _controller.value?.addRoomMember(roomId, member.agentId, member.handle),
    );
  }

  /// Returns true when the group fell below two members and was deleted.
  bool _removeRoomMember(String roomId, String agentId) {
    final roomDeleted = _rooms.removeMemberFromRoom(roomId, agentId);
    // Keep the host consistent: a group that fell below two members was
    // deleted locally, so the host must delete it, not just drop a member.
    if (roomDeleted) {
      _hostDeleteRoom(roomId);
    } else {
      unawaited(_controller.value?.removeRoomMember(roomId, agentId));
    }
    return roomDeleted;
  }

  void _setRoomAgentToAgent(String roomId, bool enabled) {
    _rooms.setAgentToAgent(roomId, enabled);
    unawaited(_controller.value?.setRoomAgentToAgent(roomId, enabled));
  }

  /// A room's conversation, for the phone route and the desktop centre pane.
  Widget _buildRoomBody(AgentsRoom room) {
    final controller = _controller.value;
    // With a live socket the room streams over it (RoomThreadPage keeps only
    // its own room's frames); without one — the thread view has not built the
    // transport yet — it shows an honest waiting state. Driving a room is
    // still the host-gated step; the page renders whatever turns the host
    // sends.
    if (controller == null) {
      return RoomThreadView(
        roomName: room.name,
        emptyHint: _l10n.agentsRoomConnectHostHint,
        turns: const <AgentsRoomTurn>[],
        members: room.members,
        agents: _roster.agents,
      );
    }
    return RoomThreadPage(
      roomId: room.id,
      roomName: room.name,
      members: room.members,
      // The roster only supplies the display name and role the mention picker
      // shows. A member with no matching agent still gets a row, labelled by
      // its handle.
      agents: _roster.agents,
      emptyHint: _l10n.agentsRoomEmptyHint,
      inbound: controller.inbound,
      // Re-bind to the new socket on a reconnect: the page follows
      // _controller, re-subscribes to the fresh inbound and re-runs onReady
      // (re-create + re-request history) automatically.
      rebind: _controller,
      // Read the live controller each time, not the one captured at open, so
      // a send after a reconnect goes to the new socket.
      onSend: (message) => _controller.value?.sendRoomTask(room.id, message),
      onStop: () => unawaited(_controller.value?.stopRoom(room.id)),
      onReady: () {
        final c = _controller.value;
        if (c != null) _onRoomOpened(c, room);
      },
    );
  }

  /// Called once a room page is ready. Re-sync the room to the host first — it
  /// is idempotent there, and it repairs the case where the room was created
  /// while the host was offline, so the host has it before any task or history
  /// request lands. Then ask for its stored history.
  void _onRoomOpened(AgentsRelayController controller, AgentsRoom room) {
    // The newest local copy, not the one captured when the page opened.
    final AgentsRoom current = _rooms.byId(room.id) ?? room;
    controller.createRoom(
      current.id,
      current.name,
      <Map<String, String>>[
        for (final m in current.members)
          <String, String>{'agent_id': m.agentId, 'handle': m.handle},
      ],
      agentToAgent: current.agentToAgent,
      // A group the host listed keeps the host's settings; one it has not
      // seen yet (made while it was away) brings its own.
      settings: _hostKnownRooms.contains(current.id)
          ? const <String, Object?>{}
          : current.settingsWire(),
    );
    controller.requestRoomHistory(current.id);
  }

  Future<void> _manageRoomMembers(String roomId) async {
    void showSheet(BuildContext ctx) {
      final room = _rooms.byId(roomId);
      if (room == null) {
        Navigator.of(ctx).pop();
        return;
      }
      final inRoom = room.members.map((m) => m.agentId).toSet();
      final candidates = <AgentsAgent>[
        for (final a in _roster.visibleAgents)
          if (!inRoom.contains(a.id)) a,
      ];
      showAgentsSheetOrDialog<void>(
        context: ctx,
        builder: (sheetContext) => RoomMembersSheet(
          room: room,
          candidates: candidates,
          onAdd: (member) {
            _rooms.addMemberToRoom(roomId, member);
            _controller.value?.addRoomMember(
              roomId,
              member.agentId,
              member.handle,
            );
            Navigator.of(sheetContext).pop();
            showSheet(ctx); // reopen with the updated room
          },
          onAgentToAgentChanged: (enabled) {
            _rooms.setAgentToAgent(roomId, enabled);
            _controller.value?.setRoomAgentToAgent(roomId, enabled);
            Navigator.of(sheetContext).pop();
            showSheet(ctx); // reopen with the updated room
          },
          onRemove: (agentId) {
            final roomDeleted = _rooms.removeMemberFromRoom(roomId, agentId);
            // Keep the host consistent: if the room fell below two members it was
            // deleted locally, so the host must delete it, not just drop a
            // member (which would strand a one-member room there).
            if (roomDeleted) {
              _hostDeleteRoom(roomId);
            } else {
              _controller.value?.removeRoomMember(roomId, agentId);
            }
            Navigator.of(sheetContext).pop();
            // If the room survived, reopen the sheet; if it was deleted, stop.
            if (!roomDeleted) showSheet(ctx);
          },
        ),
      );
    }

    showSheet(context);
  }

  void _onController(AgentsRelayController controller) {
    _controller.value = controller;
    // A transport arrived: ask for the host's groups (the answer is merged
    // in [_applyHostRooms]).
    unawaited(controller.requestRoomList());
    // A transport arrived: flush any room deletes made while it was down.
    if (_pendingHostDeletes.isNotEmpty) {
      final pending = List<String>.of(_pendingHostDeletes);
      _pendingHostDeletes.clear();
      for (final roomId in pending) {
        controller.deleteRoom(roomId);
      }
    }
  }

  /// Delete a room on the host, or queue it if the socket is down so it is not
  /// silently dropped and left as an orphan on the host.
  void _hostDeleteRoom(String roomId) {
    final controller = _controller.value;
    if (controller != null) {
      controller.deleteRoom(roomId);
    } else {
      _pendingHostDeletes.add(roomId);
    }
  }

  void _deleteRoom(String roomId) {
    _rooms.removeRoom(roomId);
    _hostDeleteRoom(roomId);
  }

  void _renameRoom(String roomId, String name) {
    _rooms.renameRoom(roomId, name);
    _controller.value?.renameRoom(roomId, name);
  }

  void _deleteAgent(String agentId, {bool fromHost = false}) {
    // Drop the agent, and cascade: pull it out of every room it is in (a room
    // that falls below two members is deleted), telling the host to forget each
    // deleted room so nothing is orphaned. If the deleted agent was selected,
    // clear the selection so the thread pane does not point at a ghost.
    _deletedAgentIds.add(agentId);
    // Tell the host, so every other device drops the agent too
    // (`agent_list.deleted`). Only a host that names the capability gets the
    // frame; an older one would answer it with an error.
    if (!fromHost) _hostDeleteAgent(agentId);
    final removed = _roster.byId(agentId);
    _roster.removeAgent(agentId);
    // Nothing of a deleted agent may survive to be inherited by a later one
    // with the same id: drop its face and its read marks.
    unawaited(_agentProfiles.forget(agentId));
    unawaited(AgentAvatarSync.instance.forget(agentId));
    for (final thread in removed?.threads ?? const <AgentsThreadInfo>[]) {
      unawaited(_readMarks.forget(thread.key));
    }
    // The rooms the agent was in, captured before the cascade rewrites them.
    final wasIn = <String>[
      for (final room in _rooms.rooms)
        if (room.members.any((m) => m.agentId == agentId)) room.id,
    ];
    final deleted = _rooms.removeAgentFromRooms(agentId).toSet();
    // Keep the host consistent: a room that survived lost one member (sync the
    // removal); a room that fell below two members was deleted (sync that).
    for (final roomId in wasIn) {
      if (deleted.contains(roomId)) {
        _hostDeleteRoom(roomId);
      } else {
        _controller.value?.removeRoomMember(roomId, agentId);
      }
    }
    if (_selectedAgentId == agentId) {
      setState(() {
        _selectedAgentId = null;
        // The thread belonged to the deleted agent. Without this the pane
        // kept showing its chat after the last agent was gone, instead of
        // the empty state.
        _selectedThreadKey = '';
        _selectionIsAuto = true;
      });
      if (_restoredAgentId == agentId) {
        _restoredAgentId = null;
        _restoredThreadKey = null;
      }
      // Do not leave the user in an empty chat: fall to the top of the list.
      _autoSelect();
    }
  }

  void _hostDeleteAgent(String agentId) {
    if (agentId.startsWith('host:')) return;
    final AgentsAgent? agent = _roster.byId(agentId);
    final controller = agent == null
        ? _controller.value
        : _controllerForAgent(agent);
    if (controller is! AgentsRelayClient) return;
    if (!AgentsRelayClient.hostCapabilities.value.contains(
      AgentsRelayClient.agentDeleteCapability,
    )) {
      return;
    }
    unawaited(
      controller
          .sendControlFrame(<String, dynamic>{
            'type': 'agent_delete',
            'agent_id': agentId,
          })
          .catchError((Object _) {
            // Not sent (link down): the host keeps the name until the next
            // delete; this device already forgot the agent.
          }),
    );
  }

  /// Copies the selected thread's full debug export, like chuk_chat's
  /// top-right "Copy full chat". The service does the clipboard write and
  /// hands back the note, shown as chuk shows its own; a failure says so
  /// rather than staying silent.
  Future<void> _copyFullChat() async {
    final messenger = ScaffoldMessenger.of(context);
    final export = widget.chatDebugExport;
    String note;
    try {
      note = export != null
          ? await export(_selectedThreadKey)
          : await ChatDebugExport.copyToClipboard(
              threadKey: _selectedThreadKey,
            );
    } catch (error) {
      note = 'could not copy the chat';
      if (kDebugMode) {
        debugPrint('[cowork-shell] copy full chat failed: $error');
      }
    }
    if (!mounted) return;
    AppNotifications.showOn(messenger, note);
  }

  /// The paired transport, or null (with a note to the user) when there is
  /// none yet. The browser view streams over the live socket, so it has
  /// nothing to show before pairing.
  AgentsRelayController? _pairedControllerOrExplain() {
    final controller = _controller.value;
    if (controller == null || !controller.state.value.isPaired) {
      AppNotifications.show(context, 'Connect to the agent first.');
      return null;
    }
    return controller;
  }
}

/// The newest timestamp among [messages] (`sentAt`, else `startedAt`), or
/// null when none carries one.
@visibleForTesting
DateTime? newestMessageTime(List<ChatMessage>? messages) {
  if (messages == null) return null;
  DateTime? newest;
  for (final ChatMessage message in messages) {
    final DateTime? at = DateTime.tryParse(
      message.sentAt ?? message.startedAt ?? '',
    )?.toLocal();
    if (at != null && (newest == null || at.isAfter(newest))) newest = at;
  }
  return newest;
}
