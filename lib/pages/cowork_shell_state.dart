part of 'messenger_shell.dart';

/// Builds the default production relay controller: a real [CoworkRelayClient]
/// with the app's **stable** long-term device identity, loaded from (or created
/// in) [store] on first use. A stable key is what lets the host's stored trust
/// keep matching us across restarts, so the reconnect handshake authenticates
/// with no code.
Future<CoworkRelayController> _buildRelayController(
  CoworkPairingStore store,
) async {
  final identity = await store.loadOrCreateIdentity();
  return CoworkRelayClient(
    deviceId: identity.deviceId,
    signingKeyPair: identity.keyPair,
    // The user's UI-configured MCP servers ride along on each task frame,
    // resolved with their live bearers at launch (WS-D).
    mcpStore: McpStore(),
    // The here.now publishing connector setting rides along the same way, so a
    // public publish is gated on the user's yes (or their auto-approve opt-in).
    hereNowStore: HereNowStore(),
    // The user's secret set follows every provision (docs/WIRE_CONTRACT.md,
    // "Secrets"), so a restarted host holds what the device holds.
    secretsForwarder: SecretsService.instance.forwardToHost,
  );
}

/// Everything the shell OWNS, as opposed to how it lays it out.
///
/// chuk_chat's root wrappers (`root_wrapper_desktop.dart`,
/// `root_wrapper_mobile.dart`) own nothing but layout: their chat area reads
/// its state from process-wide services. CoWork's chat area owns a socket —
/// `CoworkThreadView` builds the relay controller, reconnects from the stored
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
mixin CoworkShellHost on State<MessengerShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Owned by the state, not the widget: a parent rebuild must never hand the
  /// tree a fresh, empty roster or a second pairing store.
  late final CoworkPairingStore _pairingStore =
      widget.pairingStore ?? CoworkPairingStore();
  late final AgentRosterSource _roster =
      widget.rosterSource ?? LocalAgentRosterSource();
  late final RoomSource _rooms = widget.roomSource ?? LocalRoomSource();

  /// The live transport, handed up by the thread view so a room can stream over
  /// the same socket. Null until the thread view has built it; it changes on a
  /// reconnect, which is what lets an open room re-bind to the new socket.
  final ValueNotifier<CoworkRelayController?> _controller =
      ValueNotifier<CoworkRelayController?>(null);

  /// Rooms deleted while the socket was down. The host never heard the delete
  /// (a deleted room has no later "open" to reconcile it, unlike an edit), so it
  /// would keep an orphan. These flush the moment a transport arrives.
  final Set<String> _pendingHostDeletes = <String>{};
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

  String? _selectedAgentId;
  String _selectedThreadKey = 'default';

  /// Where the last session left off. Written on every pick, read once at
  /// startup. Two keys, not one: a thread is only meaningful with its coworker.
  static const String _kLastAgentKey = 'cowork.last_agent_id';
  static const String _kLastThreadKey = 'cowork.last_thread_key';

  String? _restoredAgentId;
  String? _restoredThreadKey;

  /// Whether the remembered pick has been read off disk yet. Nothing is
  /// auto-selected before it has: picking the first coworker and then jumping
  /// to the remembered one a moment later is worse than opening a beat late.
  bool _restoreLoaded = false;

  /// Whether the current selection is the app's own choice rather than the
  /// user's. Only an automatic selection may be replaced when the remembered
  /// coworker finally arrives in the roster (the host sends its names after the
  /// pairing, so it is not there on the first frame).
  bool _selectionIsAuto = false;

  /// On a phone: the chat is in front of the inbox. Flipped by [_select], by
  /// the back chip, and cleared when the selected agent is deleted.
  bool _showThreadOnNarrow = false;

  /// Selects a coworker's thread. Implemented by the layout, which also
  /// decides what the selection does to the sidebar on a narrow window.
  void _select(String agentId, String threadKey);

  CoworkAgent? get _selectedAgent =>
      _selectedAgentId == null ? null : _roster.byId(_selectedAgentId!);

  /// The `initState` half of the host. Called by the state after `super`.
  void _hostInit() {
    // Open where the user left off. The roster fills in stages — nothing at
    // first, the host coworker on pairing, the rest when the host sends its
    // names — so the restore is not one shot at startup: it watches the roster
    // and lands as soon as its target exists (bead cowork-8yb).
    _roster.addListener(_onRosterChanged);
    unawaited(_loadLastSelection());
    // Auto-reconnect at startup. Deferred to after the first frame so the app's
    // sign-in / key-unlock flow (which gates showing this shell) has completed —
    // the cloud pairing cannot be decrypted before the EncryptionService key is
    // unlocked, so running any earlier would just read null.
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreCloudPairing());
    // WS-7: a tapped "answer ready" toast (local or push) names a thread. The
    // router keeps the target until this shell takes it, so a tap that
    // launched the app cold is picked up right after the first frame.
    NotificationRouter.instance.pending.addListener(_onNotificationTap);
    // The toast carries the coworker's name, never the answer.
    CoworkNotifications.instance.threadLabel = _threadLabel;
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotificationTap());
    // The host's coworker names (bead cowork-817): the link fans out every
    // inbound frame of the bound controller, so this sees each `agent_list`
    // without owning the socket.
    _hostInboundSub = CoworkRelayLink.instance.inbound.listen(_onHostInbound);
  }

  StreamSubscription<CoworkRelayInbound>? _hostInboundSub;

  /// Ids deleted in this session. The host still lists them (delete is not on
  /// the wire yet, see WIRE_CONTRACT "Coworker names"); a list must not bring
  /// a coworker back the user just removed.
  final Set<String> _deletedAgentIds = <String>{};

  void _onHostInbound(CoworkRelayInbound event) {
    if (event is! CoworkRelayAgentList) return;
    _roster.applyHostNames(
      event.agents,
      peerDeviceId: _controller.value?.state.value.peerDeviceId,
      ignore: _deletedAgentIds,
    );
  }

  /// Reads the remembered pick, then tries to land on it.
  Future<void> _loadLastSelection() async {
    String? agentId;
    String? threadKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      agentId = prefs.getString(_kLastAgentKey);
      threadKey = prefs.getString(_kLastThreadKey);
    } catch (_) {
      // No preferences (a test, a locked store): fall back to the first
      // coworker, which is still better than an empty chat.
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
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kLastAgentKey, agentId);
        await prefs.setString(_kLastThreadKey, threadKey);
      } catch (_) {
        // Losing the pointer costs the next launch its position, nothing more.
      }
    }());
  }

  void _onRosterChanged() {
    if (!mounted) return;
    _autoSelect();
  }

  /// Lands on a thread without waiting for the user.
  ///
  /// The rule the user asked for, and the one every desktop messenger follows:
  /// you come back to where you were; failing that, to the top of the list.
  /// Never to an empty chat.
  ///
  /// It runs again on every roster change, because the remembered coworker may
  /// only show up once the host has sent its names. A selection this method
  /// made may be replaced by the remembered one when it arrives; a selection
  /// the user made never is.
  void _autoSelect() {
    if (!_restoreLoaded) return;
    final String? restoredId = _restoredAgentId;
    final CoworkAgent? restored = restoredId == null
        ? null
        : _roster.byId(restoredId);
    final CoworkAgent? current = _selectedAgentId == null
        ? null
        : _roster.byId(_selectedAgentId!);
    if (current != null) {
      final bool upgradeToRemembered =
          _selectionIsAuto && restored != null && restored.id != current.id;
      if (!upgradeToRemembered) return;
    }
    final List<CoworkAgent> visible = _roster.visibleAgents;
    final CoworkAgent? target =
        restored ?? (visible.isEmpty ? null : visible.first);
    if (target == null || target.threads.isEmpty) return;
    final String threadKey = target.threads.any(
      (thread) => thread.key == _restoredThreadKey,
    )
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
    _roster.removeListener(_onRosterChanged);
    NotificationRouter.instance.pending.removeListener(_onNotificationTap);
    _hostInboundSub?.cancel();
    _controller.dispose();
    if (_ownsControlSource) _controlSource.dispose();
    if (_ownsThemeController) _themeController.dispose();
  }

  String _threadLabel(String threadKey) {
    final String? agentId = _agentIdForThread(threadKey);
    if (agentId == null) return 'CoWork';
    return _roster.byId(agentId)?.name ?? 'CoWork';
  }

  /// Opens the thread a notification named. Selecting it is enough: the
  /// thread view replays from its cursor when its thread changes, and the
  /// "Answer ready" affordance comes from the replayed `while_away` done.
  void _onNotificationTap() {
    final NotificationTarget? target = NotificationRouter.instance.take();
    if (target == null || !mounted) return;
    final String? agentId = _agentIdForThread(target.sessionKey);
    if (agentId == null) return;
    _select(agentId, target.sessionKey);
    // Close the host's row and clear the OS toast for this thread.
    unawaited(
      CoworkNotifications.instance.onOpenedFromNotification(
        target.sessionKey,
        runId: target.runId,
      ),
    );
  }

  /// Restores this account's pairing from Supabase when the device has none
  /// locally, then feeds it into the EXISTING code-free reconnect path.
  ///
  /// The product promise (see docs/PRODUCT_PHILOSOPHY.md): reinstall anywhere,
  /// sign in, and the client reconnects to the same running host on its own —
  /// no re-pairing ritual. The connection info lives encrypted in Supabase.
  ///
  /// Wiring, without touching the thread view: the thread view reads the local
  /// pairing store exactly once at bootstrap and reconnects from it. So this
  /// writes the restored pairing into that same store with [savePairing], then
  /// swaps the thread view's [GlobalKey] once, which re-runs its bootstrap — the
  /// very path a fresh local pairing already takes. Best-effort throughout: a
  /// missing service, a locked key, a network error, or simply no stored pairing
  /// all leave the manual connect bar in place.
  Future<void> _restoreCloudPairing() async {
    if (!mounted) return;
    // Only after the user is signed in — the encrypted pairing is keyed to the
    // account.
    if (widget.sessionSource.current() == null) return;
    try {
      // A device that is already paired locally has nothing to restore.
      final existing = await _pairingStore.loadPairing();
      if (existing != null) return;
      // Built by the persistence agent. Returns null until the EncryptionService
      // key is unlocked, and null when the account has no stored pairing.
      final CoworkStoredPairing? restored = await SupabasePairingSync()
          .loadEncryptedPairing();
      if (!mounted || restored == null) return;
      // Persist locally so the next launch reconnects straight from the store.
      await _pairingStore.savePairing(restored);
      // Force the thread view to re-bootstrap so it reads the freshly restored
      // pairing and reconnects through its own no-code path.
      if (mounted) setState(() => _threadViewKey = GlobalKey());
    } catch (_) {
      // Best effort: fall back to the manual connect path.
    }
  }

  /// Which coworker owns [threadKey]. A run's events belong to the thread that
  /// started it, which is not always the one on screen.
  String? _agentIdForThread(String threadKey) {
    for (final agent in _roster.agents) {
      if (agent.threads.any((thread) => thread.key == threadKey)) {
        return agent.id;
      }
    }
    return null;
  }

  void _onPaired(String peerDeviceId) {
    final agent = _roster.ensureHostAgent(peerDeviceId);
    // The names the host keeps (bead cowork-817): asked on every pair, so a
    // reinstall and a second device show the same coworkers. The answer
    // lands in [_onHostInbound].
    unawaited(_controller.value?.requestAgentList());
    // `ensureHostAgent` notifies the roster, which lands the restore; this only
    // covers the case where the agent was already listed, so nothing notified.
    if (_selectedAgentId == null) _autoSelect();
    // A roster that is still empty of the remembered coworker leaves the host
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
  /// [actions] are the shell's own thread actions — they render inside the
  /// thread's header, not in a row floating over it, so the top of the screen
  /// is one bar. [leadingInset] is the width the
  /// hamburger and the mini rail cover on the left.
  CoworkThreadView _buildThread({
    double topInset = 0,
    bool phone = false,
    List<CoworkThreadAction> actions = const <CoworkThreadAction>[],
    double leadingInset = 0,
  }) {
    final agent = _selectedAgent;
    return CoworkThreadView(
      key: _threadViewKey,
      controllerBuilder:
          widget.relayControllerBuilder ??
          () => _buildRelayController(_pairingStore),
      sessionSource: widget.sessionSource,
      pairingStore: _pairingStore,
      threadKey: _selectedThreadKey,
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
      },
      onController: _onController,
      onOpenModelScreen: _openModelScreen,
      title: agent?.name,
      subtitle: agent?.role,
      actions: actions,
      leadingInset: leadingInset,
      topInset: topInset,
      phoneLayout: phone,
    );
  }

  /// Opens the full model catalogue from the composer's "More models" way out.
  /// Implemented by the layout: chuk's settings modal on the model section on
  /// a desktop window, chuk's `ModelSelectorPage` as a route on a phone.
  void _openModelScreen();

  /// New coworker (bead cowork-817): chuk's rename dialog shape — one
  /// `TextField` in an `AlertDialog` — pre-filled with a suggested name. The
  /// coworker is created with that name and its thread opens; the host is told
  /// so the name outlives this install (`agent_create`, WIRE_CONTRACT).
  Future<void> _openOnboarding() async {
    final taken = _roster.agents.map((agent) => agent.name);
    final suggested = const AgentNameGenerator().next(taken: taken);
    final name = await showCoworkerNameDialog(
      context,
      title: 'New agent',
      initialName: suggested,
      submitLabel: 'Create',
    );
    if (!mounted || name == null || name.isEmpty) return;
    final agent = _roster.addAgent(name: name);
    unawaited(_controller.value?.createAgent(agent.id, agent.name));
    _select(agent.id, agent.threads.first.key);
  }

  /// Rename (bead cowork-817): the roster row's menu → chuk's dialog → here.
  /// Local first, then the host, like [_renameRoom].
  void _renameAgent(String agentId, String name) {
    _roster.renameAgent(agentId, name);
    final agent = _roster.byId(agentId);
    if (agent == null) return;
    unawaited(_controller.value?.renameAgent(agentId, agent.name));
  }

  Future<void> _openAgentRename(CoworkAgent agent) async {
    final name = await showCoworkerNameDialog(
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
  Widget _buildRoomList() => RoomListView(
    source: _rooms,
    onCreate: _openRoomCreate,
    onSelect: _openRoom,
    onDelete: _deleteRoom,
    onRename: _renameRoom,
    onManageMembers: _manageRoomMembers,
  );

  Future<void> _openRoomCreate() async {
    // Only coworkers the app can actually name can join a room.
    final agents = _roster.visibleAgents;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
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
          );
          Navigator.of(sheetContext).pop();
        },
      ),
    );
  }

  void _openRoom(String roomId) {
    final room = _rooms.byId(roomId);
    if (room == null) return;
    final controller = _controller.value;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(room.name)),
          // With a live socket the room streams over it (RoomThreadPage keeps
          // only its own room's frames); without one — the thread view has not
          // built the transport yet — it shows an honest waiting state. Driving
          // a room is still the host-gated step; the page renders whatever
          // turns the host sends.
          body: controller == null
              ? RoomThreadView(
                  roomName: room.name,
                  userMessage: 'Connect your host to start this room.',
                  turns: const <CoworkRoomTurn>[],
                  members: room.members,
                )
              : RoomThreadPage(
                  roomId: room.id,
                  roomName: room.name,
                  members: room.members,
                  userMessage: 'Message the room to start.',
                  inbound: controller.inbound,
                  // Re-bind to the new socket on a reconnect: the page follows
                  // _controller, re-subscribes to the fresh inbound and re-runs
                  // onReady (re-create + re-request history) automatically.
                  rebind: _controller,
                  // Read the live controller each time, not the one captured at
                  // open, so a send after a reconnect goes to the new socket.
                  onSend: (message) =>
                      _controller.value?.sendRoomTask(room.id, message),
                  onReady: () {
                    final c = _controller.value;
                    if (c != null) _onRoomOpened(c, room);
                  },
                ),
        ),
      ),
    );
  }

  /// Called once a room page is ready. Re-sync the room to the host first — it
  /// is idempotent there, and it repairs the case where the room was created
  /// while the host was offline, so the host has it before any task or history
  /// request lands. Then ask for its stored history.
  void _onRoomOpened(CoworkRelayController controller, CoworkRoom room) {
    controller.createRoom(room.id, room.name, <Map<String, String>>[
      for (final m in room.members)
        <String, String>{'agent_id': m.agentId, 'handle': m.handle},
    ]);
    controller.requestRoomHistory(room.id);
  }

  Future<void> _manageRoomMembers(String roomId) async {
    void showSheet(BuildContext ctx) {
      final room = _rooms.byId(roomId);
      if (room == null) {
        Navigator.of(ctx).pop();
        return;
      }
      final inRoom = room.members.map((m) => m.agentId).toSet();
      final candidates = <CoworkAgent>[
        for (final a in _roster.visibleAgents)
          if (!inRoom.contains(a.id)) a,
      ];
      showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
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

  void _onController(CoworkRelayController controller) {
    _controller.value = controller;
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

  void _deleteAgent(String agentId) {
    // Drop the agent, and cascade: pull it out of every room it is in (a room
    // that falls below two members is deleted), telling the host to forget each
    // deleted room so nothing is orphaned. If the deleted agent was selected,
    // clear the selection so the thread pane does not point at a ghost.
    _deletedAgentIds.add(agentId);
    _roster.removeAgent(agentId);
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
        _showThreadOnNarrow = false;
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

  /// Copies the selected thread's full debug export, like chuk_chat's
  /// top-right "Copy full chat". The service does the clipboard write and
  /// hands back the note; a failure says so rather than staying silent.
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
    messenger.showSnackBar(
      SnackBar(content: Text(note), duration: const Duration(seconds: 2)),
    );
  }

  /// The paired transport, or null (with a note to the user) when there is
  /// none yet. The browser view streams over the live socket, so it has
  /// nothing to show before pairing.
  CoworkRelayController? _pairedControllerOrExplain() {
    final controller = _controller.value;
    if (controller == null || !controller.state.value.isPaired) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to the agent first.')),
      );
      return null;
    }
    return controller;
  }

  void _openControlDrawer() => _scaffoldKey.currentState?.openEndDrawer();

  Widget? _buildControlDrawer(BuildContext context) {
    final agent = _selectedAgent;
    if (agent == null) return null;
    return Drawer(
      width: 360,
      child: SafeArea(
        child: AgentControlPanel(
          agent: agent,
          source: _controlSource,
          onScheduleSubmitted: (spec) {
            // The schedule is real and it is the user's, but it runs in the app's
            // record only: nothing installs it on the host yet.
            _roster.setSchedule(agent.id, spec);
          },
        ),
      ),
    );
  }
}
