/// The messenger shell: chuk_chat's root-wrapper layout around CoWork's content.
///
/// ## What is chuk's here, and what is not
///
/// The LAYOUT is `root_wrapper_desktop.dart` from chuk_chat master, rebuilt
/// with CoWork's content in each slot (plan WS-1, docs/PLAN_2026-09-04_
/// COWORK_CHUK_ALIGN.md): one `Stack`; the chat area in a `Positioned.fill`
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
/// The CONTENT is CoWork's. The sidebar lists coworkers, not chats
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
///   keeping; ours hosts `CoworkThreadView`, which builds the relay controller
///   and reconnects from the stored pairing. Everything the shell owns lives in
///   [CoworkShellHost] (`cowork_shell_state.dart`), ABOVE the desktop / phone
///   split, and the thread view is built by one method with one [GlobalKey], so
///   a resize across any breakpoint moves it and never rebuilds it.
/// * **The sidebar starts open.** chuk's desktop starts collapsed; a
///   messenger's roster is its navigation, so a wide window opens with it in
///   place. The hamburger folds it to chuk's mini rail exactly as upstream.
/// * **Compact mode ends at 720, not chuk's 600.** chuk's compact band covers
///   narrow desktop windows; CoWork hands anything under 600 to the phone layer
///   (cowork-c6), so the band moves up to keep a tablet-width window in it: the
///   sidebar covers 85 % and the chat is off stage while it is open, and
///   picking a coworker closes it so the chat comes forward.
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

import 'package:cowork/constants.dart';
import 'package:cowork/model_selector_page.dart';
import 'package:cowork/models/app_shell_config.dart';
import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/pages/desktop_settings_modal.dart';
import 'package:cowork/pages/settings_page.dart';
import 'package:cowork/platform_specific/mobile/mobile_agent_list.dart';
import 'package:cowork/platform_specific/mobile/mobile_agent_sheet.dart';
import 'package:cowork/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/cowork/agent_control_source.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/browser_presence.dart';
import 'package:cowork/services/cowork/chat_debug_export.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/room_source.dart';
// Built by the persistence agent: restores the account's encrypted pairing from
// Supabase so a fresh install reconnects with no code.
import 'package:cowork/services/cowork/supabase_pairing_sync.dart';
import 'package:cowork/services/herenow/herenow_store.dart';
import 'package:cowork/services/mcp/mcp_store.dart';
import 'package:cowork/services/secrets/secrets_service.dart';
import 'package:cowork/services/notifications/cowork_notifications.dart';
import 'package:cowork/services/notifications/notification_router.dart';
import 'package:cowork/services/settings/theme_controller.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/agent_control_panel.dart';
import 'package:cowork/widgets/agent_roster_view.dart';
import 'package:cowork/widgets/browser_view_page.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';
import 'package:cowork/widgets/room_create_sheet.dart';
import 'package:cowork/widgets/room_list_view.dart';
import 'package:cowork/widgets/room_members_sheet.dart';
import 'package:cowork/widgets/room_thread_page.dart';
import 'package:cowork/widgets/room_thread_view.dart';

part 'cowork_shell_state.dart';

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

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell> with CoworkShellHost {
  /// chuk's compact band, moved up (see the library doc): a window narrower
  /// than this — and not a phone — gets the 85 % overlay sidebar.
  static const double _compactBreakpoint = 720;

  /// chuk's desktop sidebar width outside compact mode.
  static const double _sidebarWidth = 320;

  /// chuk's panel geometry: the chat keeps at least this much, a panel needs at
  /// least this much, and a list panel is capped here.
  static const double _minChatWidth = 300;
  static const double _minPanelWidth = 320;
  static const double _listPanelWidth = 400;

  // chuk's root_wrapper_desktop state, same names.
  bool _isSidebarExpanded = true;
  bool _hasOpenedSidebar = true;

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

  // Read by handlers that run after build (the same trick chuk's settings
  // modal uses for `_compact`): which layout the last frame chose.
  bool _isPhone = false;
  bool _isCompact = false;
  double _lastWidth = 0;

  @override
  void initState() {
    super.initState();
    _hostInit();
    _controller.addListener(_onControllerForBrowser);
  }

  @override
  void dispose() {
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
    if (mounted) setState(() {});
  }

  @override
  void _select(String agentId, String threadKey) {
    setState(() {
      _selectedAgentId = agentId;
      _selectedThreadKey = threadKey;
      _showThreadOnNarrow = true;
      // In the compact band the open sidebar covers the chat; picking a
      // coworker is the request to see its thread, so the sidebar folds.
      if (_isCompact && _isSidebarExpanded) _isSidebarExpanded = false;
    });
  }

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
  void _openBrowserView() {
    final controller = _pairedControllerOrExplain();
    if (controller == null) return;
    BrowserViewPage.open(context, controller);
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
    final config = widget.shellConfig;
    if (config != null && !_isPhone) {
      unawaited(
        showDesktopSettingsModal(
          context,
          config: config,
          initialSectionId: 'model',
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const ModelSelectorPage()),
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
            endDrawer: _buildControlDrawer(context),
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
    CoworkAgent? agent,
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
          child: Offstage(offstage: !showContent, child: _buildThread()),
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
                  selectedAgentId: _selectedAgentId,
                  selectedThreadKey: _selectedThreadKey,
                  onSelect: _select,
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
              icon: Icon(Icons.menu_rounded, color: iconFg, size: 24),
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

        // The floating top-right row (chuk's Copy full chat anchor), four slots.
        if (showContent)
          Positioned(
            top: kTopInitialSpacing,
            right: (showPanel ? panelWidth : 0) + 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _buildTopRightActions(iconFg, agent),
            ),
          ),
      ],
    );
  }

  /// chuk's `_buildMiniRail`, with CoWork's two slots: New coworker and Control
  /// Rooms. The agent's browser lives only in the top-right row (cowork-vzm).
  List<Widget> _buildMiniRail(Color iconFg, CoworkAgent? agent) {
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
            icon: Icon(icon, color: iconFg, size: 24),
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
        tooltip: 'New coworker',
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

  /// The top-right buttons, in chuk's `IconButton` style (icon colour
  /// `resolvedIconColor`, size 20). Copy full chat is chuk's own slot, verbatim
  /// (same icon, size and tooltip). "Agent's browser" is there only while the
  /// agent has a browser open ([_browserOpen]); the button is the only way in.
  List<Widget> _buildTopRightActions(Color iconFg, CoworkAgent? agent) {
    return <Widget>[
      if (agent != null)
        IconButton(
          icon: Icon(Icons.tune, color: iconFg, size: 20),
          onPressed: _openControlDrawer,
          tooltip: 'Agent controls',
        ),
      IconButton(
        icon: Icon(Icons.groups_outlined, color: iconFg, size: 20),
        onPressed: _openRooms,
        tooltip: 'Control Rooms',
      ),
      if (agent != null && _browserOpen)
        IconButton(
          icon: Icon(Icons.desktop_windows_outlined, color: iconFg, size: 20),
          onPressed: _openBrowserView,
          tooltip: "Agent's browser",
        ),
      IconButton(
        icon: Icon(Icons.copy_all_rounded, color: iconFg, size: 20),
        onPressed: _copyFullChat,
        tooltip: 'Copy full chat',
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
                  Icon(Icons.groups_outlined, color: iconFg),
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
                    icon: Icon(Icons.close, color: iconFg),
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
  Widget _buildPhoneBody(BuildContext context, CoworkAgent? agent) {
    if (_showThreadOnNarrow && agent != null) {
      return MobileChatScreen(
        agent: agent,
        onBack: () => setState(() => _showThreadOnNarrow = false),
        onOpenProfile: _openControlDrawer,
        // Same gate as the desktop row: no chip until the agent has a browser.
        onOpenBrowser: _browserOpen ? _openBrowserView : null,
        onMore: () => MobileAgentSheet.show(
          context,
          agent: agent,
          onControls: _openControlDrawer,
          onRooms: _openRooms,
          onCopyChat: _copyFullChat,
          onSettings: _openSettings,
          onSignOut: widget.onSignOut ?? () => const AuthService().signOut(),
        ),
        bodyBuilder: (context, topInset) =>
            _buildThread(topInset: topInset, phone: true),
      );
    }
    // The inbox, with the live thread kept mounted behind it (chuk's own
    // `Positioned.fill(Offstage(chatArea))` pattern, plan WS-1). Without this
    // the phone would build its transport only once a chat is opened: the
    // thread view is what creates the relay controller and reports pairing, so
    // an unmounted one means no socket, no reconnect, and a roster that never
    // learns about the paired host. Offstage keeps it in the tree — and out of
    // the layout — so the list is what the reader sees.
    return Stack(
      children: [
        Positioned.fill(child: Offstage(child: _buildThread(phone: true))),
        Positioned.fill(
          child: MobileAgentList(
            source: _roster,
            selectedAgentId: _selectedAgentId,
            onSelect: _select,
            onAddAgent: _openOnboarding,
            onOpenAccount: _openSettings,
            accountLabel: null,
          ),
        ),
      ],
    );
  }
}
