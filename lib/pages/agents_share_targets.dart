part of 'messenger_shell.dart';

/// The Android share sheet, Agents half (`share_intent_service.dart`).
///
///  * Every visible agent is a Direct Share contact: its face, its name, the
///    app badge the system adds. The main agent comes first.
///  * A share picked on an agent's contact opens that agent's thread with the
///    shared text in the composer and the shared files attached. Nothing is
///    sent.
///  * A share for the app itself goes to chuk's chats (`RootWrapperMobile`
///    takes it); this side only brings the Chats half to the front. Without
///    a Chats half it goes to the main agent.
mixin _AgentsShareTargets
    on State<MessengerShell>, AgentsShellHost, _AgentsDesktopLayout {
  // --- hooks the state implements --------------------------------------------

  AppModeService get _appMode;
  AppMode get _shownMode;
  bool get _chatModeAvailable;
  bool get _isPhone;
  AgentsAgent? get _mainAgent;

  // --- state -------------------------------------------------------------------

  Timer? _shareTargetsTimer;
  Timer? _shareWaitTimer;

  /// Painted icons by their inputs, so a roster tick repaints nothing.
  final Map<String, Uint8List?> _shareIconCache = <String, Uint8List?>{};

  /// Most contacts the sheet is given. It shows four per row.
  static const int _kMaxShareTargets = 8;

  void _shareInit() {
    if (!ShareIntentService.isSupported) return;
    ShareIntentService.instance.incoming.addListener(_onShareForAgents);
    _roster.addListener(_onShareRosterChanged);
    _agentProfiles.addListener(_scheduleShareTargets);
    RosterPins.instance.addListener(_scheduleShareTargets);
    _scheduleShareTargets();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onShareForAgents());
  }

  void _shareDispose() {
    if (!ShareIntentService.isSupported) return;
    ShareIntentService.instance.incoming.removeListener(_onShareForAgents);
    _roster.removeListener(_onShareRosterChanged);
    _agentProfiles.removeListener(_scheduleShareTargets);
    RosterPins.instance.removeListener(_scheduleShareTargets);
    _shareTargetsTimer?.cancel();
    _shareWaitTimer?.cancel();
  }

  void _onShareRosterChanged() {
    _scheduleShareTargets();
    // A share for an agent the cold roster did not know yet.
    if (ShareIntentService.instance.incoming.value?.agentId != null) {
      _onShareForAgents();
    }
  }

  // --- routing -----------------------------------------------------------------

  void _onShareForAgents() {
    if (!mounted) return;
    final SharedContent? share = ShareIntentService.instance.incoming.value;
    if (share == null) return;
    final String? agentId = share.agentId;
    if (agentId == null) {
      if (_chatModeAvailable) {
        // RootWrapperMobile, inside the Chats half, takes it.
        if (_shownMode != AppMode.chats) _appMode.show(AppMode.chats);
        return;
      }
      final AgentsAgent? main = _mainAgent;
      if (main != null) _openShareIn(main, share);
      return;
    }
    final AgentsAgent? agent = _roster.byId(agentId);
    if (agent != null && agent.threads.isNotEmpty) {
      _shareWaitTimer?.cancel();
      _openShareIn(agent, share);
      return;
    }
    // Unknown agent: the roster may still be loading. If it does not turn
    // up, the share goes to the app instead of being lost.
    _shareWaitTimer ??= Timer(const Duration(seconds: 4), () {
      _shareWaitTimer = null;
      final SharedContent? still = ShareIntentService.instance.incoming.value;
      if (!mounted || still == null || still.agentId != agentId) return;
      ShareIntentService.instance.incoming.value = SharedContent(
        text: still.text,
        subject: still.subject,
        files: still.files,
      );
    });
  }

  void _openShareIn(AgentsAgent agent, SharedContent share) {
    ShareIntentService.instance.take();
    Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    if (_chatModeAvailable && _shownMode != AppMode.agents) {
      _appMode.show(AppMode.agents);
    }
    _leaveAgentsHome();
    if (!_isPhone) _deskCloseRoom();
    final String threadKey = agent.threads.first.key;
    _select(agent.id, threadKey);
    // After this frame: a thread switch clears the composer while it loads
    // (see _runPendingLaunch).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedThreadKey != threadKey) return;
      ShareIntentService.instance.parkFiles(threadKey, share.files);
      AgentsThreadComposer.prefill(threadKey, share.composerText);
    });
  }

  // --- Direct Share contacts ------------------------------------------------

  void _scheduleShareTargets() {
    _shareTargetsTimer?.cancel();
    _shareTargetsTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_publishShareTargets()),
    );
  }

  Future<void> _publishShareTargets() async {
    if (!mounted) return;
    final AgentsAgent? main = _mainAgent;
    final List<AgentsAgent> agents =
        <AgentsAgent>[
              ?main,
              for (final AgentsAgent a in _roster.visibleAgents)
                if (a.id != main?.id) a,
            ]
            .where((AgentsAgent a) => a.threads.isNotEmpty)
            .take(_kMaxShareTargets)
            .toList();
    final List<ShareTarget> targets = <ShareTarget>[];
    for (final AgentsAgent agent in agents) {
      final AgentProfile profile = _agentProfiles.profileOf(agent.id);
      final String key =
          '${agent.id}|${agent.name}|${profile.colorValue}|'
          '${profile.shape}|${profile.photoPath}';
      final Uint8List? icon = _shareIconCache.containsKey(key)
          ? _shareIconCache[key]
          : _shareIconCache[key] = await paintShareTargetIcon(
              agentId: agent.id,
              name: agent.name,
              store: _agentProfiles,
            );
      if (!mounted) return;
      targets.add(ShareTarget(id: agent.id, label: agent.name, icon: icon));
    }
    await ShareIntentService.instance.publishTargets(targets);
  }
}
