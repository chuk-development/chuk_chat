/// The messenger shell: chuk_chat's root-wrapper layout around Agents's content.
///
/// ## What is chuk's here, and what is not
///
/// The LAYOUT is `root_wrapper_desktop.dart` from chuk_chat master, rebuilt
/// with Agents's content in each slot (plan WS-1, docs/PLAN_2026-09-04_
/// AGENTS_CHUK_ALIGN.md): one `Stack`; the chat area in a `Positioned.fill`
/// that is inset by the sidebar and the right panel and hidden with `Offstage`
/// rather than unmounted; a sidebar that slides in from the left and is faded
/// out and pointer-blocked when closed; the hamburger anchored top-left at
/// chuk's `kTopInitialSpacing` / `kFixedLeftPadding`; the mini rail under it
/// when the sidebar is closed, one `kButtonVisualHeight` per row so the icons
/// line up with the sidebar's rail rows; a right panel at chuk's
/// Workspaces / Media / Artifacts slot with the same header, the same 400 px
/// cap and the same draggable divider for the one panel the user resizes; and
/// the floating top-right row at chuk's anchor. There is no `AppBar`: chuk has
/// none.
///
/// The CONTENT is Agents's. The sidebar lists coworkers, not chats
/// (`AgentRosterView`, on chuk's sidebar chrome). The two mini-rail slots are
/// New coworker and Control Rooms. The right panel shows the room list. The
/// top-right row has up to FOUR buttons — Agent controls, Control Rooms,
/// Agent's browser (only while the agent has a browser open; it opens as a
/// full-screen route, Bead cowork-vzm) and, in chuk's own slot, Copy full
/// chat. Settings is where chuk keeps it: the gear in the sidebar's footer
/// pill, opening chuk's settings modal (desktop) or hub (phone); Sign out is
/// in the settings footer and in the phone sheet.
///
/// ## Deliberate divergences from chuk
///
/// * **The chat area owns a socket.** chuk's root wrappers hold no state worth
///   keeping; ours hosts `AgentsThreadView`, which builds the relay controller
///   and reconnects from the stored pairing. Everything the shell owns lives in
///   [AgentsShellHost] (`agents_shell_state.dart`), ABOVE the desktop / phone
///   split, and the thread view is built by one method with one [GlobalKey], so
///   a resize across any breakpoint moves it and never rebuilds it.
/// * **Opening a panel folds the sidebar when they cannot share the width.**
///   chuk drops the panel silently in that case; with a sidebar that is open by
///   default that would make Control Rooms look broken at 800 px.
/// * **Opening settings leaves the sidebar alone.** chuk closes it first; here
///   it is the navigation, not an overlay the user pulled out.
///
/// Below 600 px (or on a real phone) the body is cowork-c6's mobile layer
/// (`platform_specific/mobile/**`): the coworker inbox and the chat with the
/// floating chrome, the thread view kept mounted off stage behind the inbox.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_home.dart';
import 'package:chuk_chat/pages/mobile_agents_settings_page.dart';
import 'package:chuk_chat/pages/agent_profile_edit_page.dart';
import 'package:chuk_chat/pages/automations_page.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/settings/mcp_connectors_page.dart';
import 'package:chuk_chat/pages/secrets_settings_page.dart';
import 'package:chuk_chat/widgets/chat_documents_panel.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_container_transform.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/pages/agent_profile_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/media_index.dart';
import 'package:chuk_chat/services/agents/thread_preview_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/browser_presence.dart';
import 'package:chuk_chat/services/agents/chat_debug_export.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_pairing_restore.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/herenow/herenow_store.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/session_recovery.dart';
import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/settings/theme_controller.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/widgets/browser_view_page.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/room_create_sheet.dart';
import 'package:chuk_chat/widgets/room_list_view.dart';
import 'package:chuk_chat/widgets/room_members_sheet.dart';
import 'package:chuk_chat/widgets/room_thread_page.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

part 'agents_shell_state.dart';

/// The messenger: coworkers down the left, the selected thread in the middle,
/// Control Rooms on the right, the agent's browser as a full-screen route, the
/// control surface
/// behind one button (§1, §16). Layout: see the library doc above.
class MessengerShell extends StatefulWidget {
  const MessengerShell({
    super.key,
    this.relayControllerBuilder,
    this.sessionSource = const SupabaseAccountSession(),
    this.pairingStore,
    this.rosterSource,
    this.roomSource,
    this.controlSource,
    this.onSignOut,
    this.themeController,
    this.shellConfig,
    this.chatDebugExport,
    this.readMarks,
    this.agentProfiles,
  });

  /// Builds the relay transport controller. Injectable so widget tests supply
  /// a fake without a socket. Defaults to a real [AgentsRelayClient] with the
  /// stable persisted identity.
  final Future<AgentsRelayController> Function()? relayControllerBuilder;

  /// Account session provisioned to the executor once paired.
  final AccountSessionSource sessionSource;

  /// Persistent trust store: the stable device identity and the stored pairing
  /// that drives code-free reconnect. Built by the state when omitted.
  final AgentsPairingStore? pairingStore;

  /// The roster of coworkers. Built by the state when omitted.
  final AgentRosterSource? rosterSource;

  /// The group rooms the user has built. Built by the state when omitted.
  final RoomSource? roomSource;

  /// The control surface's data source. The default reports every block as not
  /// connected, because the host serves none of it yet.
  final AgentControlSource? controlSource;

  /// Sign-out hook. Defaults to the real [AuthService].
  final VoidCallback? onSignOut;

  /// The app's theme controller. Kept as the bridge `main.dart` and
  /// `auth_gate.dart` still take (see HANDOVER_2026-09-05_SHELL_SETTINGS);
  /// chuk's settings surfaces write the theme through [shellConfig].
  final ThemeController? themeController;

  /// chuk_chat's `AppShellConfig` — the theme, typography and display settings
  /// with their setters — handed down the tree from `main.dart`, exactly as
  /// chuk hands it to `RootWrapper(config: …)` (bead `cowork-8y2`). Every
  /// imported settings surface and the chat screen read it from here. A shell
  /// built without one (a widget test) has no settings entry; the entries do
  /// nothing rather than crash.
  final AppShellConfig? shellConfig;

  /// Copies one thread's debug export and returns the short note to show —
  /// the "Copy full chat" button at the top right, the same affordance
  /// chuk_chat master has above its chat area (`root_wrapper_desktop.dart`,
  /// `_copyDebugChat`).
  ///
  /// Defaults to [ChatDebugExport.copyToClipboard], which reads the local row
  /// cache and the run ledger. Injectable so a widget test can drive the
  /// button without those.
  final Future<String> Function(String threadKey)? chatDebugExport;

  /// What the reader has already seen, per thread — the inbox's unread answer.
  /// Injectable so a widget test drives it without touching the app-wide store.
  final AgentReadMarks? readMarks;

  /// The coworkers' display profiles (picture, colour, role, brief).
  final AgentProfileStore? agentProfiles;

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell>
    with AgentsShellHost, SingleTickerProviderStateMixin {
  /// Keep the upstream desktop breakpoint; smaller windows use the phone UI.
  static const double _compactBreakpoint = 600;

  /// chuk's desktop sidebar width outside compact mode.
  static const double _sidebarWidth = 320;

  /// chuk's panel geometry: the chat keeps at least this much, a panel needs at
  /// least this much, and a list panel is capped here.
  static const double _minChatWidth = 300;
  static const double _minPanelWidth = 320;
  static const double _listPanelWidth = 400;

  // chuk's root_wrapper_desktop state, same names.
  bool _isSidebarExpanded = false;
  bool _hasOpenedSidebar = false;

  /// 'rooms' | null — chuk's `_activePanel` ('projects'). The agent's browser
  /// is not a panel any more (Bead cowork-vzm): it opens as a full-screen
  /// route from the one top-right button.
  String? _activePanel;

  /// Whether the agent has a browser open, derived from the live transport's
  /// frames (see [BrowserPresence]). Rebuilt on every reconnect; null while
  /// there is no transport. The "Agent's browser" button exists only while
  /// this reads true.
  BrowserPresence? _browserPresence;
  bool get _browserOpen => _browserPresence?.value ?? false;
  bool _browserViewVisible = false;

  // Read by handlers that run after build (the same trick chuk's settings
  // modal uses for `_compact`): which layout the last frame chose.
  bool _isPhone = false;
  bool _isCompact = false;
  double _lastWidth = 0;

  /// The chat-open travel (see [_buildPhoneBody]). One explicit controller,
  /// because an implicit tween starts in the very frame that mounts the thread
  /// view — and that frame costs over 100 ms, so by the time anything reached
  /// the screen the curve had already spent most of the travel. The controller
  /// is started from a post-frame callback instead, so the expensive frame is
  /// frame zero of the travel and every millimetre of it is painted.
  ///
  /// It runs LINEARLY and for the reference messenger's 300 ms.
  /// [MobileContainerTransform] curves it itself, because the container
  /// transform reads a curved value for the rect and the shape and the raw one
  /// for the colour and the opacity.
  late final AnimationController _push = AnimationController(
    vsync: this,
    duration: MobileContainerTransform.duration,
  );

  /// The row the open travel starts from, captured on the tap that opened the
  /// thread. Null until a row has been tapped — a restored selection or a
  /// notification has no row to grow out of.
  ContainerTransformSource? _openFrom;

  /// Which coworker's row [_openFrom] is a copy of, so the list can hide the
  /// original while the copy is on screen.
  String? _openFromAgentId;

  /// The row handed up by the list on THIS tap, claimed by the [_select] that
  /// follows it. A selection that arrives any other way (a notification, the
  /// restored selection, the desktop sidebar) finds it empty and clears the
  /// source, so the travel does not grow out of a row nobody touched.
  ContainerTransformSource? _pendingOpenFrom;

  /// Where [_push] has been told to go, so a rebuild does not re-fire it.
  /// Null until the phone layout has been built once: the first phone frame
  /// (a cold start, or a window that just narrowed past the breakpoint) shows
  /// the layout it is in, it does not travel into it.
  double? _pushTarget;

  @override
  void initState() {
    super.initState();
    _hostInit();
    _push.addStatusListener(_onPushStatus);
    _controller.addListener(_onControllerForBrowser);
  }

  /// The travel is fully back: the row the chat grew out of belongs to the list
  /// again. Held until now so the row is not drawn twice — once in the list and
  /// once inside the shrinking container — on the way out.
  void _onPushStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    if (!mounted || _openFromAgentId == null) return;
    setState(() {
      _openFrom = null;
      _openFromAgentId = null;
    });
  }

  @override
  void dispose() {
    _push.removeStatusListener(_onPushStatus);
    _push.dispose();
    _controller.removeListener(_onControllerForBrowser);
    _browserPresence?.dispose();
    _browserPresence = null;
    _hostDispose();
    super.dispose();
  }

  /// A transport arrived or changed: follow it with a fresh [BrowserPresence]
  /// (its replay re-derives the browser state), and repaint the button when the
  /// state flips.
  void _onControllerForBrowser() {
    final controller = _controller.value;
    final old = _browserPresence;
    if (old != null && old.controller == controller) return;
    old?.dispose();
    _browserPresence = controller == null ? null : BrowserPresence(controller);
    _browserPresence?.addListener(_onBrowserPresenceChanged);
    if (mounted) setState(() {});
  }

  void _onBrowserPresenceChanged() {
    // The screen target lights up on its own; that is the whole announcement.
    // A banner over the thread interrupts the reader to say something the
    // chrome already shows (bead cowork-egrg, reverted on request).
    if (!mounted) return;
    setState(() {});
  }

  /// The screen target, tapped while the coworker has no screen. Says what has
  /// to happen first instead of leaving the tap unanswered. It replaces
  /// whatever snack is up, because it answers a tap the user just made.
  void _explainNoScreen() {
    if (!mounted) return;
    // The host says WHY in a code of its own (`browser_view.reason`, bead
    // cowork-qp5i), and the app parks the target itself when the host falls
    // silent (bead cowork-8ptj). Both beat "no screen yet", which is only the
    // answer when nobody ever said anything about a screen.
    final String text = switch (_browserPresence?.parkedBecause ?? '') {
      'no_browser' => 'The coworker has no page open right now.',
      'no_sandbox' =>
        'This coworker runs without a sandbox, so there is no screen to show.',
      'no_display' => 'The coworker has no browser screen running.',
      'vnc_start_failed' =>
        'The screen server would not start on the coworker\'s machine.',
      'exec_failed' => 'The coworker\'s machine could not be reached.',
      'bridge_failed' => 'The connection to the screen broke.',
      BrowserPresence.staleReason =>
        'No word about the screen for a while, so it is off the table. Ask '
            'the coworker to open a page again.',
      _ =>
        'No screen yet. Ask the coworker to open a page, then take over '
            'here.',
    };
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void _select(String agentId, String threadKey) {
    final agent = _roster.byId(agentId);
    // A stale notification or callback must never open a second conversation
    // (or another agent's session) under this agent's identity.
    if (agent == null ||
        agent.threads.isEmpty ||
        agent.threads.first.key != threadKey) {
      return;
    }
    // The user picked this one: remember it for the next launch, and stop the
    // restore from moving the selection out from under them.
    _rememberSelection(agentId, threadKey);
    // Opening a thread is reading it: the unread dot clears here, not when the
    // next frame happens to arrive.
    unawaited(_readMarks.markRead(threadKey));
    setState(() {
      // The row this selection came from, if it came from one. Claimed here so
      // every other way in clears it (see [_pendingOpenFrom]).
      _openFrom = _pendingOpenFrom;
      _openFromAgentId = _pendingOpenFrom == null ? null : agentId;
      _pendingOpenFrom = null;
      _selectedAgentId = agentId;
      _selectedThreadKey = threadKey;
      _showThreadOnNarrow = true;
      // In the compact band the open sidebar covers the chat; picking a
      // coworker is the request to see its thread, so the sidebar folds.
      if (_isCompact && _isSidebarExpanded) _isSidebarExpanded = false;
    });
  }

  /// On a phone the inbox can cover the thread; a desktop window always shows
  /// it. Read by the read marks in [AgentsShellHost].
  @override
  bool get _threadIsOnScreen => !_isPhone || _showThreadOnNarrow;

  /// The screen target's action, or null while the coworker has no screen open.
  /// It sits in the header's video-call slot now, not in the action row.
  @override
  VoidCallback? get _openAgentScreenOrNull =>
      _browserOpen ? _openBrowserView : null;

  void _toggleSidebar() {
    setState(() {
      if (!_isSidebarExpanded) _hasOpenedSidebar = true;
      _isSidebarExpanded = !_isSidebarExpanded;
    });
  }

  // --- the four surfaces -----------------------------------------------------

  /// Control Rooms: the right panel on a desktop window, a route on a phone.
  void _openRooms() {
    if (!_isPhone) {
      _togglePanel('rooms');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Control Rooms')),
          body: _buildRoomList(),
        ),
      ),
    );
  }

  /// The agent's browser: a full-screen route on every form factor (Bead
  /// cowork-vzm), never a side panel. Nothing to show before the transport is
  /// paired.
  Future<void> _openBrowserView() async {
    if (_browserViewVisible || !_browserOpen) return;
    final controller = _pairedControllerOrExplain();
    if (controller == null) return;
    _browserViewVisible = true;
    try {
      // Which box to look in: the thread on screen. The executor guesses
      // without it (bead cowork-5eo6).
      await BrowserViewPage.open(
        context,
        controller,
        sessionKey: _selectedThreadKey,
      );
    } finally {
      _browserViewVisible = false;
    }
  }

  /// chuk's `_openWorkspacesPage` / `_openMediaPage`: the same id toggles the
  /// panel off, another id switches it.
  void _togglePanel(String id) {
    setState(() {
      if (_activePanel == id) {
        _activePanel = null;
        return;
      }
      _activePanel = id;
      // No room for both next to the chat: fold the sidebar rather than let
      // the panel be dropped silently (see the library doc).
      if (_isSidebarExpanded &&
          _lastWidth - _sidebarWidth - _minChatWidth < _minPanelWidth) {
        _isSidebarExpanded = false;
      }
    });
  }

  void _closePanel() => setState(() => _activePanel = null);

  /// A coworker's profile page: the face, the state, the brief, and everything
  /// the user can set or manage about it. Reached from the chat header pill, the
  /// inbox row menu and the desktop roster row.
  @override
  void _openAgentProfile(AgentsAgent agent) {
    if (_isPhone) {
      final chatKey = agent.id == _selectedAgentId
          ? _selectedThreadKey
          : (agent.threads.isEmpty ? null : agent.threads.first.key);
      void open(Widget page) => Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: (_) => page));
      open(
        MobileAgentsSettingsPage(
          agentId: agent.id,
          chatId: chatKey,
          source: _roster,
          profiles: _agentProfiles,
          onChat: () {
            if (agent.threads.isNotEmpty) {
              _select(
                agent.id,
                agent.id == _selectedAgentId
                    ? _selectedThreadKey
                    : agent.threads.first.key,
              );
            }
          },
          onEdit: () => AgentProfileEditPage.open(
            context,
            agent: _roster.byId(agent.id) ?? agent,
            source: _roster,
            profiles: _agentProfiles,
            onRename: (updated) => _renameAgent(updated.id, updated.name),
          ),
          onControls: () => open(
            Scaffold(
              appBar: AppBar(title: const Text('Host & activity')),
              body: SafeArea(
                child: AgentControlPanel(agent: agent, source: _controlSource),
              ),
            ),
          ),
          onModel: () {
            if (chatKey != null) _openChatModel(chatKey);
          },
          onAutomations: () {
            if (chatKey == null) return;
            open(AutomationsPage(sessionKey: chatKey, chatName: agent.name));
          },
          onSkills: () => open(const SkillsSettingsPage()),
          onConnectors: () => open(const McpConnectorsPage()),
          onSecrets: () => open(const SecretsSettingsPage()),
          onRooms: _openRooms,
          onSettings: _openSettings,
          onDocuments: chatKey == null
              ? null
              : () => _openChatFiles(chatKey, agent.name),
          onCopyChat: agent.id == _selectedAgentId ? _copyFullChat : null,
          onBrowser: agent.id == _selectedAgentId && _browserOpen
              ? _openBrowserView
              : null,
          onDelete: () => _deleteAgent(agent.id),
        ),
      );
      return;
    }
    unawaited(
      AgentProfilePage.open(
        context,
        agentId: agent.id,
        source: _roster,
        profiles: _agentProfiles,
        onRename: (AgentsAgent target) => _openAgentRename(target),
        onDelete: (AgentsAgent target) => _deleteAgent(target.id),
        onOpenControls: _openControlDrawer,
        onOpenBrowser: _browserOpen ? _openBrowserView : null,
      ),
    );
  }

  /// chuk's settings entry: the modal over the chat on a desktop window
  /// (`showDesktopSettingsModal`), the hub as a route on a phone
  /// (`SettingsPage`). Both take the `AppShellConfig` handed down the tree.
  void _openSettings() {
    final config = widget.shellConfig;
    if (config == null) return;
    if (_isPhone) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => SettingsPage(config: config),
        ),
      );
      return;
    }
    unawaited(showDesktopSettingsModal(context, config: config));
  }

  /// The composer's "More models" way out, wired as chuk wires it: the settings
  /// modal opened on the model section on a desktop window, chuk's own
  /// `ModelSelectorPage` as a route on a phone (bead `cowork-acu`). Without a
  /// config the desktop falls back to the page too, so the entry always opens.
  @override
  void _openModelScreen() {
    _openChatModel(_selectedThreadKey);
  }

  void _openChatModel(String chatKey) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ModelSelectorPage(chatId: chatKey),
      ),
    );
  }

  void _openChatFiles(String chatKey, String name) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatDocumentsPanel(
          sessionKey: chatKey,
          coworkerName: name,
          controller: _controller.value,
          fullPage: true,
        ),
      ),
    );
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // The whole shell listens to the roster: the sidebar, the top-right row
    // (which buttons apply) and the control panel all read from it.
    return AnimatedBuilder(
      animation: _roster,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final double width = constraints.maxWidth;
          final bool phone = MobileLayout.isPhoneWidth(width);
          _isPhone = phone;
          _isCompact = !phone && width < _compactBreakpoint;
          _lastWidth = width;
          final agent = _selectedAgent;

          return Scaffold(
            key: _scaffoldKey,
            endDrawer: phone ? null : _buildControlDrawer(context),
            endDrawerEnableOpenDragGesture: !phone,
            body: phone
                ? _buildPhoneBody(context, agent)
                : _buildDesktopBody(context, width, agent),
          );
        },
      ),
    );
  }

  /// chuk's `_RootWrapperDesktopState.build`, slot for slot.
  Widget _buildDesktopBody(
    BuildContext context,
    double screenWidth,
    AgentsAgent? agent,
  ) {
    final Color iconFg = Theme.of(context).resolvedIconColor;
    final bool isCompactMode = _isCompact;

    final double sidebarVisibleWidth = isCompactMode
        ? screenWidth * 0.85
        : _sidebarWidth;
    final double effectiveSidebarWidth = math.min(
      screenWidth,
      sidebarVisibleWidth,
    );
    final bool showContent = !isCompactMode || !_isSidebarExpanded;

    // Right panel width for Control Rooms. Minimum chat width of 300 px
    // required to show a panel; the room list caps at 400 px — chuk's list
    // split.
    final double sidebarWidth = _isSidebarExpanded ? effectiveSidebarWidth : 0;
    final double availableForPanel = screenWidth - sidebarWidth - _minChatWidth;
    final double panelWidth = availableForPanel >= _minPanelWidth
        ? math.min(_listPanelWidth, availableForPanel)
        : 0;
    final bool showPanel =
        _activePanel != null && !isCompactMode && panelWidth > 0;

    return Stack(
      children: [
        // Always keep the chat area in the tree: it owns the socket, and a
        // GlobalKey removal/insertion would rebuild it. Hide via Offstage when
        // the sidebar covers the full screen in compact mode.
        Positioned.fill(
          left: (!isCompactMode && _isSidebarExpanded)
              ? effectiveSidebarWidth
              : 0,
          right: showPanel ? panelWidth : 0,
          child: Offstage(
            offstage: !showContent,
            child: _buildThread(
              actions: _threadActions(agent),
              // The hamburger, and the mini rail under it, are painted over
              // the chat: the header keeps their column clear so a title never
              // starts underneath them. With the sidebar open they sit over the
              // sidebar instead, and the header needs nothing.
              leadingInset: _isSidebarExpanded
                  ? 0
                  : kFixedLeftPadding + kMenuButtonHeight,
            ),
          ),
        ),

        // Right panel (Control Rooms)
        if (showPanel)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: panelWidth,
            child: _buildPanel(context, iconFg),
          ),

        // The sidebar. Lazy-mounted in chuk; it starts open here, so it is in
        // the tree from the first frame.
        if (_isSidebarExpanded || _hasOpenedSidebar)
          Positioned(
            left: _isSidebarExpanded ? 0 : -effectiveSidebarWidth,
            top: 0,
            bottom: 0,
            width: effectiveSidebarWidth,
            child: AnimatedOpacity(
              opacity: _isSidebarExpanded ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_isSidebarExpanded,
                child: AgentRosterView(
                  source: _roster,
                  readMarks: _readMarks,
                  profiles: _agentProfiles,
                  selectedAgentId: _selectedAgentId,
                  selectedThreadKey: _selectedThreadKey,
                  onSelect: _select,
                  onOpenProfile: _openAgentProfile,
                  onAddAgent: _openOnboarding,
                  onDeleteAgent: _deleteAgent,
                  onRenameAgent: _renameAgent,
                  onOpenRooms: _openRooms,
                  // No browser row in the sidebar (cowork-vzm): the top-right
                  // button is the one way in, and only while a browser is open.
                  onOpenSettings: widget.shellConfig == null
                      ? null
                      : _openSettings,
                ),
              ),
            ),
          ),

        // Hamburger menu — stays anchored at the top-left, never moves. Sized
        // 48×40 like chuk's so its splash matches the mini-rail icons below.
        Positioned(
          top:
              kTopInitialSpacing +
              (kMenuButtonHeight - kButtonVisualHeight) / 2,
          left: kFixedLeftPadding,
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
              onPressed: _toggleSidebar,
            ),
          ),
        ),

        // Mini rail — visible only when the sidebar is collapsed. Each icon's
        // visual centre lines up with the matching rail row in the open
        // sidebar: brand row kMenuButtonHeight (48) tall, then rows of
        // kButtonVisualHeight (40).
        if (!_isSidebarExpanded) ..._buildMiniRail(iconFg, agent),
      ],
    );
  }

  /// chuk's `_buildMiniRail`, with Agents's two slots: New coworker and Control
  /// Rooms. The agent's browser lives only in the top-right row (cowork-vzm).
  List<Widget> _buildMiniRail(Color iconFg, AgentsAgent? agent) {
    final List<Widget> items = [];
    int rowIndex = 0;
    Widget railIcon({
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
    }) {
      final double top =
          kTopInitialSpacing +
          kMenuButtonHeight +
          rowIndex * kButtonVisualHeight;
      rowIndex++;
      return Positioned(
        top: top,
        left: kFixedLeftPadding,
        child: SizedBox(
          width: kMenuButtonHeight,
          height: kButtonVisualHeight,
          child: IconButton(
            icon: AppIcon(icon, color: iconFg, size: 24),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.standard,
            constraints: const BoxConstraints.tightFor(
              width: kMenuButtonHeight,
              height: kButtonVisualHeight,
            ),
            tooltip: tooltip,
            onPressed: onPressed,
          ),
        ),
      );
    }

    items.add(
      railIcon(
        icon: Icons.person_add_alt,
        tooltip: 'New agent',
        onPressed: _openOnboarding,
      ),
    );
    items.add(
      railIcon(
        icon: Icons.groups_outlined,
        tooltip: 'Control Rooms',
        onPressed: _openRooms,
      ),
    );
    return items;
  }

  /// The shell's actions on the open thread. They used to float over the chat
  /// in a row of their own at chuk's top-right anchor; they now go into the
  /// thread's own header, which owns the glyph size, the hit box and the
  /// spacing, so they cannot drift apart from the thread's own buttons.
  /// Copy full chat stays last — chuk's own slot. "Agent's browser" is there
  /// only while the agent has a browser open ([_browserOpen]); the button is
  /// the only way in.
  List<AgentsThreadAction> _threadActions(AgentsAgent? agent) {
    return <AgentsThreadAction>[
      if (agent != null)
        AgentsThreadAction(
          icon: Icons.tune,
          onPressed: _openControlDrawer,
          tooltip: 'Agent controls',
        ),
      AgentsThreadAction(
        icon: Icons.groups_outlined,
        onPressed: _openRooms,
        tooltip: 'Control Rooms',
      ),
      AgentsThreadAction(
        icon: Icons.copy_all_rounded,
        onPressed: _copyFullChat,
        tooltip: 'Copy Debug Chat',
      ),
    ];
  }

  /// chuk's right panel: the same container, header (icon, title, close) and
  /// content slot. Control Rooms embeds the room list (a room still opens as
  /// its own route, so `rebind` keeps working).
  Widget _buildPanel(BuildContext context, Color iconFg) {
    // A Material paints the background (chuk uses a coloured Container; the
    // room list's ListTiles need a Material to paint their ink on, so the
    // colour moves there and the DecoratedBox keeps only the border).
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: iconFg.withValues(alpha: 0.2)),
          ),
        ),
        child: Column(
          children: [
            // Panel header with close button
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: iconFg.withValues(alpha: 0.1)),
                ),
              ),
              child: Row(
                children: [
                  AppIcon(Icons.groups_outlined, color: iconFg),
                  const SizedBox(width: 12),
                  Text(
                    'Control Rooms',
                    style: TextStyle(
                      color: iconFg,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: AppIcon(Icons.close, color: iconFg),
                    onPressed: _closePanel,
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            // Panel content
            Expanded(child: _buildRoomList()),
          ],
        ),
      ),
    );
  }

  /// The phone layout (docs/MOBILE_GROKBOT_STRUCTURE.md, cowork-c6): the
  /// coworker list as an inbox, the chat with the floating chrome on top.
  /// Back (chip, system back, edge swipe) flips the same flag [_select] sets.
  ///
  /// Both layers stay in the tree the whole time. The chat area owns the socket
  /// (see the library doc), so it may never be unmounted; and the inbox keeps
  /// its search and filter while a chat is open. Opening a chat therefore does
  /// not swap one widget for another — it drives ONE progress value, and the two
  /// layers slide past each other on it, which is the shared-axis motion of the
  /// reference messenger without a second thread view.
  ///
  /// The motion is a messenger push: the thread travels the full width in from
  /// the right over the inbox, and the inbox walks a third of that distance to
  /// the left and darkens under it, so it reads as the page underneath rather
  /// than as a second page leaving. Back plays the same thing backwards. The
  /// thread carries the scaffold colour with it, because chuk's phone screen is
  /// a transparent `Scaffold` and would otherwise let the inbox show through it
  /// mid-travel.
  /// Aim [_push] at the layout the shell is in now.
  ///
  /// Called from build, so it may not call `setState` and it may not start the
  /// controller inline either: the frame that flips the flag is the frame that
  /// builds and paints the whole thread, and a ticker started there loses that
  /// frame and every frame the build overran. Starting it after the frame costs
  /// one frame of delay and buys the entire travel.
  void _drivePush(bool open, bool reducedMotion) {
    final double target = open ? 1 : 0;
    if (_pushTarget == null) {
      _pushTarget = target;
      _push.value = target;
      return;
    }
    if (reducedMotion) {
      _pushTarget = target;
      if (_push.value != target) {
        _push.stop();
        _push.value = target;
      }
      return;
    }
    if (_pushTarget == target) return;
    _pushTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || _pushTarget != target) return;
      if (target == 1) {
        _push.forward();
      } else {
        _push.reverse();
      }
    });
  }

  Widget _buildPhoneBody(BuildContext context, AgentsAgent? agent) {
    final bool showChat = _showThreadOnNarrow && agent != null;
    _drivePush(showChat, MediaQuery.disableAnimationsOf(context));

    // Both layers are built HERE, not inside the animated builder: the travel
    // must re-run nothing but the container's own geometry. Building the roster
    // and the thread once per frame is what made a 300 ms transform land in
    // three frames.
    final Color surface = Theme.of(context).scaffoldBackgroundColor;
    final Widget thread = agent == null
        ? const SizedBox.shrink()
        : RepaintBoundary(
            child: ColoredBox(
              color: surface,
              // Behind the inbox this layer is mounted but not on screen (it
              // owns the socket). Nothing in it may hold the focus then, or
              // the composer opens the soft keyboard over the coworker list.
              // Flipping this to true also drops the focus the composer has,
              // so walking back closes the keyboard with the thread.
              child: ExcludeFocus(
                excluding: !showChat,
                child: MobileChatScreen(
                  active: showChat,
                  agent: agent,
                  onBack: () => setState(() => _showThreadOnNarrow = false),
                  // The pill opens the coworker's profile, like a messenger
                  // contact header. The controls moved into the profile and the
                  // "more" sheet.
                  onOpenProfile: () => _openAgentProfile(agent),
                  // The target is always there. Lit when a screen is open,
                  // parked when none is — and a parked tap says why instead of
                  // doing nothing (bead cowork-egrg).
                  onOpenBrowser: _browserOpen
                      ? _openBrowserView
                      : _explainNoScreen,
                  browserAvailable: _browserOpen,
                  onReconnect: () {
                    final view = _threadViewKey.currentState;
                    if (view is AgentsThreadViewState) {
                      unawaited(view.reconnect());
                    }
                  },
                  onOpenFiles: () =>
                      _openChatFiles(_selectedThreadKey, agent.name),
                  bodyBuilder: (BuildContext context, double topInset) =>
                      _buildThread(topInset: topInset, phone: true),
                ),
              ),
            ),
          );

    // The home is four places now, not one list (docs/DESIGN.md): chats,
    // artefacts, files, settings.
    final Widget home = RepaintBoundary(
      child: MobileHome(
        roster: _roster,
        controller: _controller.value,
        readMarks: _readMarks,
        profiles: _agentProfiles,
        chats: MobileAgentList(
          source: _roster,
          selectedAgentId: _selectedAgentId,
          onSelect: _select,
          onOpenFrom: (ContainerTransformSource source) =>
              _pendingOpenFrom = source,
          // The row the copy was taken from is not drawn while the copy is
          // inside the container. Cleared when the travel is fully back
          // (the status listener in [initState]), not when it starts, so the
          // row does not appear twice on the way out.
          hiddenAgentId: _openFromAgentId,
          selectedThreadKey: _selectedThreadKey,
          onAddAgent: _openOnboarding,
          onOpenAccount: _openSettings,
          onOpenProfile: _openAgentProfile,
          onRenameAgent: _openAgentRename,
          onDeleteAgent: (AgentsAgent target) => _deleteAgent(target.id),
          readMarks: _readMarks,
          profiles: _agentProfiles,
          accountLabel: null,
        ),
        settings: widget.shellConfig == null
            ? const SizedBox.shrink()
            : SettingsPage(config: widget.shellConfig!),
      ),
    );

    // The size the chat layer is LAID OUT at is the size of the shell's body,
    // NOT the size of the screen. The shell's `Scaffold` resizes its body for
    // the keyboard and strips `viewInsets` from it (that is the contract
    // chuk's phone screen builds on: it runs `resizeToAvoidBottomInset: false`
    // and lets the host do the work). A layer pinned to the screen height
    // would therefore keep its composer and its last messages under the
    // keyboard, and nothing inside it could react, because the inset it reads
    // is already zero.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size openSize = Size(constraints.maxWidth, constraints.maxHeight);
        return AnimatedBuilder(
          animation: _push,
          builder: (BuildContext context, Widget? _) {
            final double p = _push.value.clamp(0.0, 1.0);
            final bool reverse = _push.status == AnimationStatus.reverse;

            final Widget chatLayer = agent == null
                // No coworker selected: the thread view still has to exist, because
                // it is what builds the transport.
                ? Offstage(
                    child: ExcludeFocus(child: _buildThread(phone: true)),
                  )
                : Offstage(
                    // Onstage from the frame the thread is asked for, not from the
                    // first frame of the travel: that way the one expensive build
                    // and its first paint happen while the container is still the
                    // size of the row, and the travel itself is cheap re-paints.
                    offstage: !showChat && p == 0,
                    child: MobileContainerTransform(
                      progress: p,
                      reverse: reverse,
                      openSize: openSize,
                      openColor: surface,
                      closed: _openFrom,
                      open: thread,
                    ),
                  );

            return Stack(
              children: <Widget>[
                // The inbox stays exactly where it is: a container transform does
                // not push the page it came from, it dims it and lets the chat grow
                // over it. The dim is the transform's own scrim.
                Positioned.fill(
                  child: Offstage(
                    offstage: p == 1,
                    child: IgnorePointer(ignoring: p > 0, child: home),
                  ),
                ),
                Positioned.fill(child: chatLayer),
              ],
            );
          },
        );
      },
    );
  }
}
