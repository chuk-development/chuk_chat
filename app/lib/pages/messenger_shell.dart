import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/cowork/agent_control_source.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/agent_control_panel.dart';
import 'package:cowork/widgets/agent_onboarding_sheet.dart';
import 'package:cowork/widgets/agent_roster_view.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

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
  );
}

/// The messenger: a roster of coworkers on one side, the selected thread on the
/// other, and the control surface behind one button (§1, §16).
///
/// On a wide window the roster and the thread sit side by side. On a phone the
/// roster is the first screen and the thread slides in — through an
/// [IndexedStack], not a route, so the socket is never rebuilt by navigation.
/// The thread view carries a [GlobalKey] so crossing the width breakpoint moves
/// it instead of recreating it (which would open a second connection).
class MessengerShell extends StatefulWidget {
  const MessengerShell({
    super.key,
    this.relayControllerBuilder,
    this.sessionSource = const SupabaseAccountSession(),
    this.pairingStore,
    this.rosterSource,
    this.controlSource,
    this.onSignOut,
  });

  /// Builds the relay transport controller. Injectable so widget tests supply
  /// a fake without a socket. Defaults to a real [CoworkRelayClient] with the
  /// stable persisted identity.
  final Future<CoworkRelayController> Function()? relayControllerBuilder;

  /// Account session provisioned to the executor once paired.
  final AccountSessionSource sessionSource;

  /// Persistent trust store: the stable device identity and the stored pairing
  /// that drives code-free reconnect. Built by the state when omitted.
  final CoworkPairingStore? pairingStore;

  /// The roster of coworkers. Built by the state when omitted.
  final AgentRosterSource? rosterSource;

  /// The control surface's data source. The default reports every block as not
  /// connected, because the host serves none of it yet.
  final AgentControlSource? controlSource;

  /// Sign-out hook. Defaults to the real [AuthService].
  final VoidCallback? onSignOut;

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Owned by the state, not the widget: a parent rebuild must never hand the
  /// tree a fresh, empty roster or a second pairing store.
  late final CoworkPairingStore _pairingStore =
      widget.pairingStore ?? CoworkPairingStore();
  late final AgentRosterSource _roster =
      widget.rosterSource ?? LocalAgentRosterSource();
  late final AgentControlSource _controlSource =
      widget.controlSource ?? HostUnavailableControlSource();

  /// Only a source this state created is this state's to dispose.
  late final bool _ownsControlSource = widget.controlSource == null;

  /// Keeps the one live thread view (and its socket) alive when the layout
  /// moves it between the wide Row and the narrow IndexedStack.
  final GlobalKey _threadViewKey = GlobalKey();

  static const double _wideBreakpoint = 720;

  String? _selectedAgentId;
  String _selectedThreadKey = 'default';
  bool _showThreadOnNarrow = false;

  CoworkAgent? get _selectedAgent =>
      _selectedAgentId == null ? null : _roster.byId(_selectedAgentId!);

  @override
  void dispose() {
    if (_ownsControlSource) _controlSource.dispose();
    super.dispose();
  }

  /// Which coworker owns [threadKey]. A run's events belong to the thread that
  /// started it, which is not always the one on screen.
  String? _agentIdForThread(String threadKey) {
    for (final agent in _roster.agents) {
      if (agent.threads.any((thread) => thread.key == threadKey)) return agent.id;
    }
    return _selectedAgentId;
  }

  void _select(String agentId, String threadKey) {
    setState(() {
      _selectedAgentId = agentId;
      _selectedThreadKey = threadKey;
      _showThreadOnNarrow = true;
    });
  }

  void _onPaired(String peerDeviceId) {
    final agent = _roster.ensureHostAgent(peerDeviceId);
    if (_selectedAgentId == null) {
      setState(() {
        _selectedAgentId = agent.id;
        _selectedThreadKey = agent.threads.first.key;
      });
    }
  }

  Future<void> _openOnboarding() async {
    final taken = _roster.agents.map((agent) => agent.name);
    final suggested = const AgentNameGenerator().next(taken: taken);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => AgentOnboardingSheet(
        suggestedName: suggested,
        onCancel: () => Navigator.of(sheetContext).pop(),
        onSubmit: (draft) {
          final agent = _roster.addAgent(
            name: draft.name,
            brief: draft.brief,
            schedule: draft.schedule,
            attachmentNames: draft.attachmentNames,
          );
          Navigator.of(sheetContext).pop();
          _select(agent.id, agent.threads.first.key);
        },
      ),
    );
  }

  void _newThread() {
    final agentId = _selectedAgentId;
    if (agentId == null) return;
    final thread = _roster.addThread(agentId);
    _select(agentId, thread.key);
  }

  @override
  Widget build(BuildContext context) {
    // The whole shell listens to the roster: the app-bar title, the control
    // panel and the list all read from it, so they must refresh together.
    return AnimatedBuilder(
      animation: _roster,
      builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;
        final roster = AgentRosterView(
          source: _roster,
          selectedAgentId: _selectedAgentId,
          selectedThreadKey: _selectedThreadKey,
          onSelect: _select,
          onAddAgent: _openOnboarding,
        );
        final thread = CoworkThreadView(
          key: _threadViewKey,
          controllerBuilder: widget.relayControllerBuilder ??
              () => _buildRelayController(_pairingStore),
          sessionSource: widget.sessionSource,
          pairingStore: _pairingStore,
          threadKey: _selectedThreadKey,
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
        );

        return Scaffold(
          key: _scaffoldKey,
          appBar: _buildAppBar(context, wide),
          endDrawer: _buildControlDrawer(context),
          body: wide
              ? Row(
                  children: [
                    SizedBox(width: 300, child: roster),
                    const VerticalDivider(width: 1),
                    Expanded(child: thread),
                  ],
                )
              : IndexedStack(
                  index: _showThreadOnNarrow ? 1 : 0,
                  children: [roster, thread],
                ),
        );
      },
      ),
    );
  }

  AppBar _buildAppBar(BuildContext context, bool wide) {
    final agent = _selectedAgent;
    final showBack = !wide && _showThreadOnNarrow;
    return AppBar(
      leading: showBack
          ? IconButton(
              tooltip: 'Coworkers',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _showThreadOnNarrow = false),
            )
          : null,
      title: Text(agent?.name ?? 'CoWork'),
      actions: [
        if (agent != null)
          IconButton(
            tooltip: 'New thread',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _newThread,
          ),
        if (agent != null)
          IconButton(
            tooltip: 'Agent controls',
            icon: const Icon(Icons.tune),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: widget.onSignOut ?? () => const AuthService().signOut(),
        ),
      ],
    );
  }

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
