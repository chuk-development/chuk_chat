/// The messenger shell: chuk_chat's layout around the Agents content.
///
/// ## What it does
///
/// It owns everything a thread needs to live ([AgentsShellHost],
/// `agents_shell_state.dart`) and lays it out for the width it is given:
///
/// * **A desktop window** (`agents_desktop_layout.dart`): the roster on the
///   left is chuk's desktop sidebar with agents and rooms in it
///   ([AgentRosterView]), folding to chuk's mini rail. The thread sits on the
///   page under the phone's top bar in desktop form ([AgentsThreadHeader]):
///   the agent's face, name and status on the left; Documents, Call and
///   Screen on the right, with Details, Copy full chat, Profile and Rename
///   behind "…". The details pane (a tap on the agent, or Ctrl+.) and
///   Control Rooms (from the roster) open on the right, in chuk's artifact
///   panel slot, and
///   push the thread instead of covering it. A room opens in the centre. The
///   keyboard reaches all of it (Ctrl+K switcher, Ctrl+N, Ctrl+Shift+N,
///   Ctrl+1 … Ctrl+9, Ctrl+., Ctrl+B, Esc).
/// * **A phone, or a window under 600 px** (owner's design, 2026-11-05): no
///   drawer, no bottom bar, no list. On top, [MobileTopBar]: the menu chip,
///   the Home | Chats | Agents switch, "new agent", and under them the
///   [ChatTitleStrip] that names the place in view. A horizontal swipe, on
///   the strip or on the body ([SwipeChatPager]), moves to the previous or
///   next place: the main agent, the other agents, the rooms. Home is the
///   switch's own segment, with no strip. The composer is at the bottom on
///   every page: chuk's own in a thread, [MobileHomeComposer] on Home, which
///   sends to the main agent. Settings, Media, Control Rooms and the agent's pages
///   are in the menu chip's sheet.
///
/// Settings is where chuk keeps it: the gear in the roster's account line
/// opens chuk's settings modal on a desktop window; on a phone it is a row of
/// the menu sheet. Pages this shell pushes (Control Rooms and "Host &
/// activity" on a phone, a room, the model list) wear chuk's [FloatingAppBar].
///
/// ## Two halves: Chats and Agents
///
/// The shell holds the whole of chuk_chat too. The Chats | Agents switch
/// ([AppModeSwitch], state in [AppModeService]) sits in the same place in
/// both halves: in the phone's top bar (chuk's title pill slot in Chats, the
/// top centre of the Agents pages), and floating at the top centre of a
/// desktop window. Chats is chuk's own root wrapper — [RootWrapperMobile] for
/// the same narrow widths the Agents half lays out as a phone,
/// [RootWrapperDesktop] otherwise — with chuk's sidebar, history and
/// settings. Agents is everything above.
///
/// Both halves stay mounted once shown, and a switch between them is a cut
/// with no transition ([KeptTabs]; owner, CHAT-18): the thread view owns the
/// socket, and chuk's chat keeps its draft and scroll. Chats is built the first time it is shown, not at
/// startup, so a device that lives in Agents pays nothing for it. Without a
/// shell config there is no chuk_chat to show, and no switch.
///
/// The two halves share one app-wide pointer, `ChatStorageService
/// .selectedChatId`, which each of them sets to its own chat. The pointer
/// belongs to the half in front ([_onSharedChatPointer]); chuk's wrapper reads
/// its own chat from the shell instead ([_readChatModeChatId]), so the
/// Agents thread reconnecting behind it can never swap chuk's chat out.
///
/// ## Inside Agents: Home first
///
/// The Agents half is a row of places ([AgentsHalfPage], in order
/// [_agentsHalfPages]): Home (the dashboard the agents build, [DashboardPage],
/// docs/DASHBOARD.md), then the MAIN agent ([resolveMainAgent]: the user's
/// "Make main agent" choice, else the first agent), the other agents (pinned
/// first) and the rooms. Whether Home is in front is
/// [AgentsShellHost._agentsHomeShown]; any agent pick leaves it.
///
/// * **Desktop**: the roster stays docked on the left (docs/DESIGN.md §14)
///   with a "Home" row at its top. Home takes the centre pane, where the
///   thread is; the right pane closes while Home is in front. A pick in the
///   roster (or Ctrl+K, Ctrl+1 … Ctrl+9) leaves Home. The thread view stays
///   mounted behind Home: it owns the socket.
/// * **Phone**: Home is the first place of the swipe, left of the main
///   agent. A swipe, the strip's list or Android back reaches it. The thread
///   view stays mounted, off stage, while Home is in front.
///
/// A Home widget opens the main agent with a prompt in its composer through
/// [MainAgentLauncher].
///
/// ## Why it is not chuk's root wrapper
///
/// * **The chat area owns a socket.** chuk's root wrappers hold no state worth
///   keeping; this one hosts `AgentsThreadView`, which builds the relay
///   controller and reconnects from the stored pairing. The thread view is
///   built by one method with one [GlobalKey], above the desktop / phone
///   split, so a resize across any breakpoint moves it and never rebuilds it.
/// * **The roster is docked.** It is the navigation, not an overlay the user
///   pulls out, so opening settings or a pane leaves it alone; a pane that
///   cannot share the width with it folds it to the rail instead.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/pages/agent_host_activity_page.dart';
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_home_composer.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_media_page.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_top_bar.dart';
import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';
import 'package:chuk_chat/widgets/kept_tabs.dart';
import 'package:chuk_chat/pages/mobile_agents_settings_page.dart';
import 'package:chuk_chat/pages/agent_profile_edit_page.dart';
import 'package:chuk_chat/pages/automations_page.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/pages/secrets_settings_page.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_desktop.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_mobile.dart';
import 'package:chuk_chat/services/app_mode_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/widgets/app_mode_switch.dart';
import 'package:chuk_chat/widgets/room_faces.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_page.dart';
import 'package:chuk_chat/services/dashboard/dashboard_controller.dart';
import 'package:chuk_chat/services/agents/agents_thread_composer.dart';
import 'package:chuk_chat/services/share/share_intent_service.dart';
import 'package:chuk_chat/services/share/share_target_icon.dart';
import 'package:chuk_chat/services/agents/main_agent_launcher.dart';
import 'package:chuk_chat/widgets/chat_documents_panel.dart';
import 'package:chuk_chat/widgets/top_centre_slot.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart'
    show ChromeChip;
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/pages/agents_install_page.dart';
import 'package:chuk_chat/services/agents/agents_checkpoints.dart';
import 'package:chuk_chat/services/agents/agents_derived_threads.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_mail_key_handover.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/media_index.dart';
import 'package:chuk_chat/services/agents/thread_preview_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/roster_pins.dart';
import 'package:chuk_chat/services/agents/browser_presence.dart';
import 'package:chuk_chat/services/agents/chat_debug_export.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_install_flow.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';
import 'package:chuk_chat/services/agents/agents_invite_pairing.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents/agents_pairing_restore.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_factory.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_shell_status.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/settings/theme_controller.dart';
import 'package:chuk_chat/services/window_title_service.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/agent_roster_view.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_controls.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_dialog.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_metrics.dart';
import 'package:chuk_chat/widgets/agents_desktop/quick_switcher.dart';
import 'package:chuk_chat/widgets/browser_view_page.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/pane_header.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agents_status_panel.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/room_create_sheet.dart';
import 'package:chuk_chat/widgets/room_list_view.dart';
import 'package:chuk_chat/widgets/room_members_sheet.dart';
import 'package:chuk_chat/widgets/room_thread_page.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';
// ── templates ──
import 'package:chuk_chat/services/agents/agent_templates.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/widgets/agent_template_picker.dart';
// ── end templates ──

part 'agents_shell_state.dart';
part 'agents_desktop_layout.dart';
part 'agents_share_targets.dart';

/// The messenger: agents down the left, the selected thread in the middle,
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
    this.pairingRestoreBuilder,
    this.appMode,
    this.chatModeBuilder,
    this.homeBuilder,
    this.installClaimWaiter,
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

  /// The roster of agents. Built by the state when omitted.
  final AgentRosterSource? rosterSource;

  /// The group rooms the user has built. Built by the state when omitted.
  final RoomSource? roomSource;

  /// The control surface's data source. The default reports every block as not
  /// connected, because the host serves none of it yet.
  final AgentControlSource? controlSource;

  /// Sign-out hook. Defaults to the real [AuthService].
  final VoidCallback? onSignOut;

  /// The app's theme controller. Kept as the bridge `main.dart` and
  /// `auth_gate.dart` still take (see
  /// docs/notes/archived/2026-09-05-handover-shell-settings-cowork-5c.md);
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
  /// "Copy full chat" in the thread header's "…" menu, the same affordance
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

  /// The agents' display profiles (picture, colour, role, brief).
  final AgentProfileStore? agentProfiles;

  /// Builds the cloud-pairing restore supervisor. Null builds the real one.
  /// A widget test injects one with a scripted key and mirror, so each status
  /// the shell shows ("Looking for your computer…", "Add your computer") can
  /// be reached without Supabase.
  @visibleForTesting
  final AgentsPairingRestore Function(
    AgentsPairingStore store,
    AccountSessionSource sessionSource,
    Future<void> Function() onRestored,
  )?
  pairingRestoreBuilder;

  /// Which half is in front: Chats or Agents. Null builds one that remembers
  /// the choice in the preferences and, with nothing remembered, opens on
  /// Agents when this device holds a pairing and on Chats otherwise.
  final AppModeService? appMode;

  /// Builds the Chats half. Null builds chuk_chat's own root wrapper from
  /// [shellConfig]. A widget test hands in a light stand-in, because chuk's
  /// wrapper starts the whole chat stack. [modeSwitch] is the switch, for the
  /// stand-in's top bar; [onAddComputer] opens the install page, and is null
  /// unless the device has no computer. [phone] is the shell's phone rule.
  @visibleForTesting
  final Widget Function(
    BuildContext context, {
    required bool phone,
    required Widget? modeSwitch,
    required VoidCallback? onAddComputer,
  })?
  chatModeBuilder;

  /// Builds Home, the first page of the Agents half. Null builds the
  /// dashboard ([DashboardPage]). A widget test hands in a light stand-in.
  @visibleForTesting
  final WidgetBuilder? homeBuilder;

  /// Replaces the install page's wait for the computer (the relay claim). A
  /// widget test injects one, so the page opens with no socket.
  @visibleForTesting
  final AgentsInstallClaimWaiter? installClaimWaiter;

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell>
    with AgentsShellHost, _AgentsDesktopLayout, _AgentsShareTargets {
  /// Whether the agent has a browser open, derived from the live transport's
  /// frames (see [BrowserPresence]). Rebuilt on every reconnect; null while
  /// there is no transport. The "Agent's browser" button exists only while
  /// this reads true.
  BrowserPresence? _browserPresence;
  bool get _browserOpen => _browserPresence?.value ?? false;
  bool _browserViewVisible = false;

  // Read by handlers that run after build (the same trick chuk's settings
  // modal uses for `_compact`): which layout the last frame chose.
  @override
  bool _isPhone = false;

  /// The phone's swipe between the places of the Agents half. Its progress
  /// drives the title strip under the switch.
  final SwipeChatPagerController _phonePager = SwipeChatPagerController();

  /// The room a phone shows as a route on top of the thread, while that
  /// route is open: the strip names it. Null again when the route closes,
  /// so the strip names the thread that is still open underneath.
  String? _phoneRoomId;

  /// Whether Home has been shown on the phone yet. It is built on first
  /// show and kept from then on, so it keeps its scroll and its state.
  bool _phoneHomeBuilt = false;

  /// The thread we already cleared the unread mark for while it was the
  /// phone's open conversation. Kept so a rebuild does not write it again.
  String? _phoneReadKey;

  // --- Chats | Agents --------------------------------------------------------

  @override
  late final AppModeService _appMode = widget.appMode ?? AppModeService();
  late final bool _ownsAppMode = widget.appMode == null;

  /// Whether [initState] added the mode and chat-pointer listeners. Kept
  /// apart from [_chatModeAvailable], which a parent rebuild can change, so
  /// [dispose] removes exactly what was added.
  bool _chatListening = false;

  /// Whether there is a chuk_chat to switch to. Without a shell config (a
  /// widget test, the auth gate's fallback) the shell is Agents alone.
  @override
  bool get _chatModeAvailable =>
      widget.shellConfig != null || widget.chatModeBuilder != null;

  /// The half on screen. Follows [_appMode], and is always Agents when there
  /// is no Chats half.
  @override
  AppMode _shownMode = AppMode.agents;

  /// Whether the Chats half has been shown yet. It is built on first show and
  /// kept from then on.
  bool _chatModeBuilt = false;

  /// chuk_chat's chat as the Chats half last had it: null is a new chat. See
  /// [_onSharedChatPointer].
  String? _chatModeChatId;

  /// A [MainAgentLauncher] request that waits for an agent to open.
  String? _pendingLaunch;

  /// Whether the host has sent its agent names since this shell mounted:
  /// only after that does an empty roster mean "no agent at all".
  bool _hostListed = false;

  /// The first agent is created once per session at most.
  bool _firstAgentCreated = false;

  StreamSubscription<AgentsRelayInbound>? _attachSub;

  @override
  void initState() {
    super.initState();
    _hostInit();
    _deskInit();
    // checkpoints: a fork opens its new thread.
    _forkOpens = AgentsCheckpoints.openRequests.listen(_openForkedThread);
    _controller.addListener(_onControllerForBrowser);
    _agentsHomeShown.addListener(_onAgentsHomeChanged);
    _chatListening = _chatModeAvailable;
    if (_chatListening) {
      _shownMode = _appMode.value;
      _chatModeBuilt = _shownMode == AppMode.chats;
      _appMode.addListener(_onModeChanged);
      _hasComputer.addListener(_onHasComputerChanged);
      ChatStorageService.selectedChatIdNotifier.addListener(
        _onSharedChatPointer,
      );
      if (!_appMode.loaded) {
        unawaited(_appMode.load(hasPairing: _hasPairing));
      }
      if (_shownMode == AppMode.chats) {
        // After the frame: the pointer notifies, and nothing may listen to it
        // from inside this build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handOverChatPointer();
        });
      }
    }
    MainAgentLauncher.instance.requests.addListener(_onLaunchRequest);
    RosterPins.instance.addListener(_onMainInputsChanged);
    _roster.addListener(_onMainInputsChanged);
    _hasComputer.addListener(_onMainInputsChanged);
    // The host's `agent_list` is the "attached" signal: it answers every
    // pairing (`_onPaired` asks for it). The host's own handler, which adds
    // the names to the roster, was subscribed first and runs first.
    _attachSub = AgentsRelayLink.instance.inbound.listen((
      AgentsRelayInbound event,
    ) {
      if (event is! AgentsRelayAgentList) return;
      _hostListed = true;
      scheduleMicrotask(() {
        if (mounted) _maybeCreateFirstAgent();
      });
    });
    // A request made before this shell existed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onLaunchRequest());
    _shareInit();
    // Home's data (docs/DASHBOARD.md): this shell mounts once the user is
    // signed in, and the controller follows the relay's attachment itself
    // (it reads its cache, flushes pending taps and asks the host on every
    // attach). Idempotent.
    DashboardController.instance.init();
  }

  /// Whether this device holds a pairing: the default half with nothing
  /// remembered.
  Future<bool> _hasPairing() async =>
      (await _pairingStore.loadPairing()) != null;

  /// The install entry's action in chuk's sidebar: only on a device that has
  /// no computer.
  VoidCallback? get _addComputerAction =>
      _chatModeAvailable && _hasComputer.value == false
      ? () => unawaited(_addComputer())
      : null;

  /// The switch, wired to [_appMode]. One widget for every place it sits.
  ///
  /// On a phone it is Home | Chats | Agents (owner, 2026-11-05): Home is a
  /// segment of its own, not a page the swipe passes through. Agents then
  /// means the conversations, so picking it leaves Home.
  Widget _buildModeSwitch() => AppModeSwitch(
    mode: _shownMode,
    home: _isPhone && _agentsHomeShown.value,
    onHome: _isPhone
        ? () {
            _showAgentsHome();
            unawaited(_appMode.select(AppMode.agents));
          }
        : null,
    onChanged: (AppMode mode) {
      if (_isPhone && mode == AppMode.agents) _leaveAgentsHome();
      unawaited(_appMode.select(mode));
    },
  );

  /// The switch for the Agents half's own layouts, or null without a Chats
  /// half.
  @override
  Widget? _agentsModeSwitch() => _chatModeAvailable ? _buildModeSwitch() : null;

  /// "Add your computer": the install page, and the Agents half once the
  /// computer is linked.
  Future<void> _addComputer() async {
    final bool linked = await _openInstallPage();
    if (!linked || !mounted) return;
    unawaited(_appMode.select(AppMode.agents));
  }

  void _onHasComputerChanged() {
    if (!mounted) return;
    // chuk's sidebar entry follows the answer.
    setState(() {});
  }

  void _onModeChanged() {
    if (!mounted) return;
    final AppMode next = _appMode.value;
    if (next == _shownMode) return;
    setState(() {
      _shownMode = next;
      if (next == AppMode.chats) _chatModeBuilt = true;
    });
    _handOverChatPointer();
    _schedulePhoneRead();
    // Back on the Agents desktop: its keyboard (Ctrl+K and the rest) listens
    // on the shell's focus node, which lost the focus while Chats was in
    // front.
    if (next == AppMode.agents && !_isPhone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _shownMode != AppMode.agents) return;
        if (!_deskFocus.hasFocus) _deskFocus.requestFocus();
      });
    }
  }

  /// Points the shared pointer at the chat of the half in front.
  void _handOverChatPointer() {
    if (_shownMode == AppMode.chats) {
      ChatStorageService.selectedChatId = _chatModeChatId;
    } else if (_selectedThreadKey.isNotEmpty) {
      ChatStorageService.selectedChatId = _selectedThreadKey;
    }
  }

  /// What chuk's wrapper reads as the chat in view.
  String? _readChatModeChatId() => _chatModeChatId;

  bool _isAgentsChatId(String id) =>
      ChatOrigin.isAgentsThread(id) || _agentIdForThread(id) != null;

  /// The shared pointer moved.
  ///
  /// `ChatStorageService.selectedChatId` is one value for the whole app, and
  /// each half sets it to its own chat: chuk's wrapper when the user opens or
  /// starts a chat, the Agents thread view on mount, on a thread switch and on
  /// every reconnect. The half in front owns it. A write by the half in front
  /// is taken as it is (for Chats, it is also what chuk's wrapper shows
  /// next). A write by the half behind is noted — chuk's chat, off stage, may
  /// have just created its chat with a reply — and the pointer goes back to
  /// the half in front after the current call stack, never inside it.
  void _onSharedChatPointer() {
    if (!mounted) return;
    final String? id = ChatStorageService.selectedChatId;
    final bool agentsId = id != null && _isAgentsChatId(id);
    if (_shownMode == AppMode.chats) {
      if (!agentsId) {
        _chatModeChatId = id;
        return;
      }
    } else {
      // A cleared pointer or an Agents thread is the Agents half's own.
      if (id == null || agentsId) return;
      _chatModeChatId = id;
    }
    scheduleMicrotask(() {
      if (!mounted || ChatStorageService.selectedChatId != id) return;
      _handOverChatPointer();
    });
  }

  /// The Chats half: chuk_chat's own root wrapper, with the switch in its top
  /// bar. A narrow window gets chuk's phone wrapper, by the same rule the
  /// Agents half uses — on Linux too, where chuk's own `RootWrapper` always
  /// picks the desktop one. The web keeps the desktop wrapper at every width,
  /// as chuk_chat's web does: the phone wrapper asks the platform for
  /// permissions, and a browser has no such platform.
  ///
  /// A device with no computer also gets chuk's sidebar entry "Add your
  /// computer" ([_addComputerAction]).
  Widget _buildChatMode(BuildContext context, bool phone) {
    final Widget modeSwitch = _buildModeSwitch();
    final VoidCallback? addComputer = _addComputerAction;
    final builder = widget.chatModeBuilder;
    if (builder != null) {
      return builder(
        context,
        phone: phone,
        modeSwitch: modeSwitch,
        onAddComputer: addComputer,
      );
    }
    final AppShellConfig config = widget.shellConfig!;
    if (phone && !kIsWeb) {
      return RootWrapperMobile(
        config: config,
        headerCenter: modeSwitch,
        selectedChatIdReader: _readChatModeChatId,
        onAddComputer: addComputer,
        // The Agents build's phone: no drawer, swipe between chats, the
        // title strip under the switch (owner, 2026-11-05).
        swipeNavigation: true,
      );
    }
    return RootWrapperDesktop(
      config: config,
      headerCenter: modeSwitch,
      selectedChatIdReader: _readChatModeChatId,
      onAddComputer: addComputer,
    );
  }

  // --- inside Agents: Home first ---------------------------------------------

  /// Home, the first page of the Agents half: the dashboard.
  @override
  Widget _buildHome(BuildContext context) =>
      widget.homeBuilder?.call(context) ?? const DashboardPage();

  @override
  bool get _homeInFront => _agentsHomeShown.value;

  /// The places of the Agents half, in order: Home, the main agent, the
  /// other agents (pinned first, then the roster's order), the rooms. The
  /// order the desktop roster lists them in and the phone swipes through.
  List<AgentsHalfPage> get _agentsHalfPages => <AgentsHalfPage>[
    const AgentsHalfPage.home(),
    for (final AgentsAgent agent in rosterMainOrder(
      _roster.visibleAgents,
      RosterPins.instance.ids,
      RosterPins.instance.mainAgentId,
    ))
      AgentsHalfPage.agent(agent),
    for (final AgentsRoom room in _rooms.rooms) AgentsHalfPage.room(room),
  ];

  /// Brings [page] to the front of the Agents half (and the Agents half to
  /// the front of the app): Home, an agent's thread, or a room.
  void _openAgentsHalfPage(AgentsHalfPage page) {
    if (_shownMode != AppMode.agents) _appMode.show(AppMode.agents);
    if (page.isHome) {
      _showAgentsHome();
      return;
    }
    final AgentsAgent? agent = page.agent;
    if (agent != null) {
      if (agent.threads.isEmpty) return;
      if (!_isPhone) _deskCloseRoom();
      _select(agent.id, agent.threads.first.key);
      return;
    }
    final AgentsRoom? room = page.room;
    if (room != null) {
      _leaveAgentsHome();
      unawaited(_openRoom(room.id));
    }
  }

  void _onAgentsHomeChanged() {
    if (!mounted) return;
    setState(() {});
    _schedulePhoneRead();
    // Home holds no shortcut of its own: the desktop's keyboard stays on the
    // shell's focus node.
    if (!_isPhone && _shownMode == AppMode.agents) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_deskFocus.hasFocus) _deskFocus.requestFocus();
      });
    }
  }

  // --- main agent ------------------------------------------------------------

  /// The agent the roster draws first and a Home widget opens.
  @override
  AgentsAgent? get _mainAgent =>
      resolveMainAgent(_roster.visibleAgents, RosterPins.instance.mainAgentId);

  void _onMainInputsChanged() {
    if (!mounted) return;
    if (_pendingLaunch != null) _runPendingLaunch();
    _maybeCreateFirstAgent();
  }

  void _onLaunchRequest() {
    if (!mounted) return;
    final String? text = MainAgentLauncher.instance.take();
    if (text == null) return;
    _pendingLaunch = text;
    _runPendingLaunch();
  }

  /// Opens the main agent's thread with the pending text in its composer
  /// (an empty text: the composer only takes the focus).
  /// Without an agent yet, the Agents conversation comes to the front (it
  /// says how to get one) and the text waits for the first agent.
  void _runPendingLaunch() {
    final String? text = _pendingLaunch;
    if (text == null || !mounted) return;
    if (_shownMode != AppMode.agents) _appMode.show(AppMode.agents);
    _leaveAgentsHome();
    final AgentsAgent? main = _mainAgent;
    if (main == null || main.threads.isEmpty) return;
    _pendingLaunch = null;
    if (!_isPhone) _deskCloseRoom();
    final String threadKey = main.threads.first.key;
    _select(main.id, threadKey);
    // After this frame, not now: a thread switch clears the composer while
    // it loads, and a prefill parked before that clear is wiped with the
    // draft it replaced.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedThreadKey != threadKey) return;
      AgentsThreadComposer.prefill(threadKey, text);
    });
  }

  /// A computer with no agent at all gets one, named for its job
  /// ([_firstAgentName]), once per session. "No agent at all" is only known
  /// once the host has listed its agents: before that an empty roster may
  /// just be a cold cache. In practice the computer's own agent ("Your
  /// computer") is always there after a pairing, so this only runs when the
  /// user removed every agent.
  void _maybeCreateFirstAgent() {
    if (!mounted || _firstAgentCreated || !_hostListed) return;
    if (_hasComputer.value != true) return;
    final AgentsRelayController? controller = _controller.value;
    if (controller == null || !controller.state.value.isPaired) return;
    if (_roster.agents.isNotEmpty) return;
    _firstAgentCreated = true;
    final AgentsAgent agent = _roster.addAgent(name: _firstAgentName());
    unawaited(_createOnHost(agent, null, startAutomation: false));
  }

  /// "Assistant" (localised): it is the user's main agent, so it is named for
  /// that job, not with a random adjective-noun. A taken name gets a number.
  String _firstAgentName() {
    final String base = _l10n.agentsDefaultAssistantName;
    final Set<String> taken = <String>{
      for (final AgentsAgent a in _roster.agents) a.name,
    };
    if (!taken.contains(base)) return base;
    for (int n = 2; ; n++) {
      final String name = '$base $n';
      if (!taken.contains(name)) return name;
    }
  }

  // ── checkpoints ──
  StreamSubscription<String>? _forkOpens;

  /// A fork from a message opens its new thread under the agent that owns
  /// it (docs/WIRE_CONTRACT.md, "Checkpoints, rewind and fork").
  void _openForkedThread(String key) {
    if (!mounted) return;
    final String? owner = AgentsDerivedThreads.instance.byKey(key)?.ownerKey;
    if (owner == null) return;
    for (final AgentsAgent agent in _roster.agents) {
      if (agent.threads.isNotEmpty && agent.threads.first.key == owner) {
        _select(agent.id, key);
        return;
      }
    }
  }
  // ── end checkpoints ──

  @override
  void dispose() {
    unawaited(_forkOpens?.cancel()); // checkpoints
    if (_chatListening) {
      _appMode.removeListener(_onModeChanged);
      _hasComputer.removeListener(_onHasComputerChanged);
      ChatStorageService.selectedChatIdNotifier.removeListener(
        _onSharedChatPointer,
      );
    }
    _agentsHomeShown.removeListener(_onAgentsHomeChanged);
    MainAgentLauncher.instance.requests.removeListener(_onLaunchRequest);
    RosterPins.instance.removeListener(_onMainInputsChanged);
    _roster.removeListener(_onMainInputsChanged);
    _hasComputer.removeListener(_onMainInputsChanged);
    unawaited(_attachSub?.cancel());
    if (_ownsAppMode) _appMode.dispose();
    _phonePager.dispose();
    _controller.removeListener(_onControllerForBrowser);
    _browserPresence?.dispose();
    _browserPresence = null;
    _shareDispose();
    _deskDispose();
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

  /// The screen target, tapped while the agent has no screen. Says what has
  /// to happen first instead of leaving the tap unanswered. It replaces
  /// whatever snack is up, because it answers a tap the user just made.
  void _explainNoScreen() {
    if (!mounted) return;
    // The host says WHY in a code of its own (`browser_view.reason`, bead
    // cowork-qp5i), and the app parks the target itself when the host falls
    // silent (bead cowork-8ptj). Both beat "no screen yet", which is only the
    // answer when nobody ever said anything about a screen.
    // ── own browser ──
    // An agent in the user's own browser never has a screen here.
    if (_browserPresence?.usesUserBrowserIn(_selectedThreadKey) ?? false) {
      AppNotifications.show(
        context,
        AppLocalizations.of(context)?.ubScreenExplain ??
            'This agent works in your own browser. There is no screen '
                'to show here.',
        duration: const Duration(seconds: 4),
      );
      return;
    }
    // ── end own browser ──
    final String text = switch (_browserPresence?.parkedBecause ?? '') {
      'no_browser' => 'The agent has no page open right now.',
      'no_sandbox' =>
        'This agent runs without a sandbox, so there is no screen to show.',
      'no_display' => 'The agent has no browser screen running.',
      'vnc_start_failed' =>
        'The screen server would not start on the agent\'s machine.',
      'exec_failed' => 'The agent\'s machine could not be reached.',
      'bridge_failed' => 'The connection to the screen broke.',
      BrowserPresence.staleReason =>
        'No word about the screen for a while, so it is off the table. Ask '
            'the agent to open a page again.',
      _ =>
        'No screen yet. Ask the agent to open a page, then take over '
            'here.',
    };
    AppNotifications.show(context, text, duration: const Duration(seconds: 4));
  }

  @override
  void _select(String agentId, String threadKey) {
    final agent = _roster.byId(agentId);
    // A stale notification or callback must never open a second conversation
    // (or another agent's session) under this agent's identity.
    if (agent == null ||
        agent.threads.isEmpty ||
        (agent.threads.first.key != threadKey &&
            // A chat one of its automations made (`<owner>#auto-<id>`) is
            // this agent's too.
            AgentsDerivedThreads.ownerOf(threadKey) !=
                agent.threads.first.key &&
            // A thread forked from a message is this agent's too.
            AgentsDerivedThreads.instance.byKey(threadKey)?.ownerKey !=
                agent.threads.first.key)) {
      return;
    }
    // A thread opened from behind chuk's chats (a tapped notification): the
    // Agents half comes to the front with it. Shown, not remembered: the
    // user did not pick where to land. Any pick leaves Home.
    if (_chatModeAvailable && _shownMode != AppMode.agents) {
      _appMode.show(AppMode.agents);
    }
    _leaveAgentsHome();
    // The user picked this one: remember it for the next launch, and stop the
    // restore from moving the selection out from under them.
    _rememberSelection(agentId, threadKey);
    // Opening a thread is reading it: the unread dot clears here, not when the
    // next frame happens to arrive. A thread with nothing unread keeps its
    // mark: moving it forward changes no dot and costs a preference write.
    // The old mark is kept for this visit, so the thread can offer a jump
    // to the first new message (bead chuk_chat-f5wd).
    if (_readMarks.isThreadUnread(agent, agent.threads.first)) {
      unawaited(_readMarks.markOpened(threadKey));
    } else {
      _readMarks.clearUnreadSince(threadKey);
    }
    setState(() {
      _selectedAgentId = agentId;
      _selectedThreadKey = threadKey;
    });
    _schedulePhoneRead();
  }

  /// The conversation the reader is actually shown. Chats and Home cover
  /// it everywhere; on a phone a room's route does too. Read by the read
  /// marks in [AgentsShellHost].
  @override
  bool get _threadIsOnScreen {
    if (_shownMode != AppMode.agents || _agentsHomeShown.value) return false;
    if (!_isPhone) return true;
    return _phoneRoomId == null && _selectedAgent != null;
  }

  /// The open phone conversation is being read. A thread that is only
  /// selected while Home is in front keeps its dot.
  void _schedulePhoneRead() {
    if (!_threadIsOnScreen) {
      _phoneReadKey = null;
      return;
    }
    final AgentsAgent? agent = _selectedAgent;
    final String key = _selectedThreadKey;
    if (agent == null || agent.threads.isEmpty || key.isEmpty) return;
    if (key == _phoneReadKey) return;
    if (!_readMarks.isThreadUnread(agent, agent.threads.first)) {
      _phoneReadKey = key;
      return;
    }
    _phoneReadKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedThreadKey != key || !_threadIsOnScreen) {
        if (_phoneReadKey == key) _phoneReadKey = null;
        return;
      }
      unawaited(_readMarks.markOpened(key));
    });
  }

  /// The screen target's action, or null while the agent has no screen open.
  /// It sits in the header's video-call slot now, not in the action row.
  @override
  VoidCallback? get _openAgentScreenOrNull =>
      _browserOpen ? _openBrowserView : null;

  // --- the four surfaces -----------------------------------------------------

  /// Control Rooms: the right panel on a desktop window, a route on a phone.
  void _openRooms() {
    if (!_isPhone) {
      _deskToggleRightPane('rooms');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          // The page runs underneath the floating header; the list reads
          // the bar's height from the media query.
          extendBodyBehindAppBar: true,
          appBar: FloatingAppBar(
            title: const Text('Control Rooms'),
            actions: <Widget>[
              FloatingHeaderButton(
                icon: Icons.group_add_outlined,
                tooltip: 'New room',
                onPressed: () => unawaited(_openRoomCreate()),
              ),
            ],
          ),
          body: _buildRoomList(showHeader: false),
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

  /// An agent's settings: the face, the name, the role, and a row for every
  /// screen that owns something about it. Reached from the chat header pill,
  /// the inbox row menu and the desktop roster row. Every form factor opens
  /// the same page (bead chuk_chat-8hz4); the desktop details pane shows the
  /// same content ([_agentSettings] with `page: false`).
  @override
  void _openAgentProfile(AgentsAgent agent) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => _agentSettings(agent)),
    );
  }

  /// The one agent settings content. [page] true: the phone-style page with
  /// the shared transparent header. False: the bare list for the desktop
  /// details pane, which closes the pane where the page goes back.
  @override
  AgentSettingsView _agentSettings(AgentsAgent agent, {bool page = true}) {
    final String? chatKey = agent.id == _selectedAgentId
        ? _selectedThreadKey
        : (agent.threads.isEmpty ? null : agent.threads.first.key);
    void open(Widget target) =>
        Navigator.of(context)
            .push<void>(MaterialPageRoute<void>(builder: (_) => target));
    void onChat() {
      if (agent.threads.isNotEmpty) {
        _select(
          agent.id,
          agent.id == _selectedAgentId
              ? _selectedThreadKey
              : agent.threads.first.key,
        );
      }
    }

    void onEdit() => AgentProfileEditPage.open(
      context,
      agent: _roster.byId(agent.id) ?? agent,
      source: _roster,
      profiles: _agentProfiles,
      onRename: (updated) => _renameAgent(updated.id, updated.name),
    );
    void onControls() => open(
      AgentHostActivityPage(
        agent: _roster.byId(agent.id) ?? agent,
        source: _controlSource,
      ),
    );
    void onModel() {
      if (chatKey != null) _openChatModel(chatKey);
    }

    void onAutomations() {
      if (chatKey == null) return;
      open(AutomationsPage(sessionKey: chatKey, chatName: agent.name));
    }

    void onSkills() => open(const AgentsSkillsSettingsPage());
    void onConnectors() => open(const McpConnectorsPage());
    void onSecrets() => open(const SecretsSettingsPage());
    final VoidCallback? onDocuments = chatKey == null
        ? null
        : () => _openChatFiles(chatKey, agent.name);
    final VoidCallback? onCopyChat = agent.id == _selectedAgentId
        ? _copyFullChat
        : null;
    final VoidCallback? onBrowser = agent.id == _selectedAgentId && _browserOpen
        ? _openBrowserView
        : null;
    void onDelete() => _deleteAgent(agent.id);
    if (page) {
      return MobileAgentsSettingsPage(
        agentId: agent.id,
        chatId: chatKey,
        source: _roster,
        profiles: _agentProfiles,
        onChat: onChat,
        onEdit: onEdit,
        onControls: onControls,
        onModel: onModel,
        onAutomations: onAutomations,
        onSkills: onSkills,
        onConnectors: onConnectors,
        onSecrets: onSecrets,
        onRooms: _openRooms,
        onSettings: _openSettings,
        onDocuments: onDocuments,
        onCopyChat: onCopyChat,
        onBrowser: onBrowser,
        onDelete: onDelete,
      );
    }
    return AgentSettingsView(
      key: ValueKey<String>('desk-settings-${agent.id}'),
      onClose: _deskCloseRightPane,
      agentId: agent.id,
      chatId: chatKey,
      source: _roster,
      profiles: _agentProfiles,
      onChat: onChat,
      onEdit: onEdit,
      onControls: onControls,
      onModel: onModel,
      onAutomations: onAutomations,
      onSkills: onSkills,
      onConnectors: onConnectors,
      onSecrets: onSecrets,
      onRooms: _openRooms,
      onSettings: _openSettings,
      onDocuments: onDocuments,
      onCopyChat: onCopyChat,
      onBrowser: onBrowser,
      onDelete: onDelete,
    );
  }

  /// chuk's settings entry: the modal over the chat on a desktop window
  /// (`showDesktopSettingsModal`), the hub as a route on a phone
  /// (`SettingsPage`). Both take the `AppShellConfig` handed down the tree.
  @override
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
          agentName: name,
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
      // sizeOf, not a LayoutBuilder: the shell only needs the width, and a
      // LayoutBuilder here ran on every keyboard frame and rebuilt both
      // halves, the sidebar and its whole chat list included.
      builder: (context, _) => Builder(
        builder: (context) {
          final double width = MediaQuery.sizeOf(context).width;
          final bool phone = MobileLayout.isPhoneWidth(width);
          _isPhone = phone;
          final agent = _selectedAgent;

          final Widget agents = phone
              ? _buildPhoneBody(context)
              : _buildDesktopBody(context, width, agent);

          return Scaffold(
            key: _scaffoldKey,
            // No end drawer any more: the agent controls are the desktop's
            // details pane, in chuk's artifact panel slot.
            endDrawerEnableOpenDragGesture: false,
            // The two halves are peers: a switch shows the other one on the
            // next frame, with no transition, and both stay mounted (see the
            // library doc). The slots follow [AppMode]: Chats first, Agents
            // second. Home is inside Agents.
            body: _chatModeAvailable
                ? KeptTabs(
                    index: _shownMode.index,
                    children: <Widget>[
                      _chatModeBuilt
                          ? _buildChatMode(context, phone)
                          : const SizedBox.shrink(),
                      agents,
                    ],
                  )
                : agents,
          );
        },
      ),
    );
  }

  /// A room: in the centre pane on a desktop window, a route on a phone.
  /// While the phone route is open the strip names the room; when it closes
  /// the strip names the thread that stayed open underneath it again.
  @override
  Future<void> _openRoom(String roomId) async {
    if (!_isPhone) {
      _deskOpenRoom(roomId);
      return;
    }
    if (_rooms.byId(roomId) == null) return;
    setState(() => _phoneRoomId = roomId);
    try {
      await super._openRoom(roomId);
    } finally {
      if (mounted && _phoneRoomId == roomId) {
        setState(() => _phoneRoomId = null);
        _schedulePhoneRead();
      }
    }
  }

  // --- phone -----------------------------------------------------------------

  /// The strip's entry for the link status, when there is no conversation to
  /// show.
  static const String _kPhoneStatusId = '__status__';

  /// Whether the phone shows the link status instead of a conversation: no
  /// agent yet, or none selected.
  bool get _phoneShowsStatus =>
      _selectedAgent == null || _roster.visibleAgents.isEmpty;

  /// The places the phone swipes through, as the strip draws them: the main
  /// agent, the other agents, the rooms ([_agentsHalfPages]). Home is not
  /// one of them: it is the switch's own segment. With no conversation to
  /// show: the status alone.
  List<SwipeChatEntry> _phoneEntries(BuildContext context, bool status) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (status) {
      return <SwipeChatEntry>[
        SwipeChatEntry(
          id: _kPhoneStatusId,
          title: l?.agentsModeAgents ?? 'Agents',
          leading: _PhoneEntryIcon(
            icon: Icons.computer_rounded,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ];
    }
    final String working = l?.chatSwipeWorking ?? 'working';
    return <SwipeChatEntry>[
      for (final AgentsHalfPage page in _agentsHalfPages)
        if (page.agent case final AgentsAgent agent
            when agent.threads.isNotEmpty)
          SwipeChatEntry(
            id: agent.id,
            title: agent.name,
            subtitle: _phonePreview(agent) ?? (agent.running ? working : null),
            unread: _readMarks.isUnread(agent),
            working: agent.running,
            leading: AgentFace(
              agent: agent,
              size: 32,
              showPresence: false,
              store: _agentProfiles,
            ),
          )
        else if (page.room case final AgentsRoom room)
          SwipeChatEntry(
            id: room.id,
            title: room.name,
            subtitle: roomMembersLabel(room),
            leading: RoomFaces(
              members: room.members,
              size: 32,
              store: _agentProfiles,
            ),
          ),
    ];
  }

  /// The entry the strip names and the pager stands on.
  String _phoneSelectedId(bool status) {
    final String? room = _phoneRoomId;
    if (room != null) return room;
    if (status) return _kPhoneStatusId;
    return _selectedAgentId ?? _kPhoneStatusId;
  }

  /// A swipe landed on [id]. Called while the body is off screen, so the
  /// selection changes synchronously: the body comes back in showing the
  /// new place.
  void _onPhoneSelected(String id) {
    if (id == _kPhoneStatusId) return;
    for (final AgentsHalfPage page in _agentsHalfPages) {
      if (page.id == id) {
        _openAgentsHalfPage(page);
        return;
      }
    }
  }

  /// The menu chip's sheet: the pages that used to be tabs and chips.
  Future<void> _openPhoneMenu() {
    final AppLocalizations? l = AppLocalizations.of(context);
    final bool onThread =
        !_agentsHomeShown.value && _phoneRoomId == null && !_phoneShowsStatus;
    final AgentsAgent? agent = onThread ? _selectedAgent : null;
    final AgentsAgent? anyAgent = _selectedAgent ?? _mainAgent;
    final String threadKey = _selectedThreadKey;
    final AppShellConfig? config = widget.shellConfig;
    return showMobileMenuSheet(
      context,
      shortcuts: <MobileMenuItem>[
        if (config != null)
          MobileMenuItem(
            icon: Icons.settings_outlined,
            label: l?.settings ?? 'Settings',
            onTap: _openSettings,
          )
        else if (anyAgent != null)
          // No chuk_chat settings to open (a shell without a config): the
          // agent's own settings are the settings there are.
          MobileMenuItem(
            icon: Icons.settings_outlined,
            label: l?.settings ?? 'Settings',
            onTap: () => _openAgentProfile(anyAgent),
          ),
        MobileMenuItem(
          icon: Icons.photo_library_outlined,
          label: l?.media ?? 'Media',
          onTap: _openPhoneMedia,
        ),
        MobileMenuItem(
          icon: Icons.groups_outlined,
          label: l?.agentsCwControlRooms ?? 'Control rooms',
          onTap: _openRooms,
        ),
      ],
      sectionTitle: agent?.name,
      items: <MobileMenuItem>[
        if (agent != null) ...<MobileMenuItem>[
          MobileMenuItem(
            icon: Icons.person_outline_rounded,
            label: l?.agentsAgentProfile ?? 'Agent profile',
            onTap: () => _openAgentProfile(agent),
          ),
          MobileMenuItem(
            icon: Icons.monitor_heart_outlined,
            label: l?.agentsCwHost ?? 'Host & activity',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => AgentHostActivityPage(
                  agent: _roster.byId(agent.id) ?? agent,
                  source: _controlSource,
                ),
              ),
            ),
          ),
          // The screen is listed whether or not one is open: a parked tap
          // says why there is none, so the row is never a dead button.
          MobileMenuItem(
            icon: Icons.desktop_windows_outlined,
            label: l?.agentsCwOpenScreen ?? 'Open screen',
            onTap: () => _browserOpen
                ? unawaited(_openBrowserView())
                : _explainNoScreen(),
          ),
          MobileMenuItem(
            icon: Icons.folder_outlined,
            label: l?.files ?? 'Files',
            onTap: () => _openChatFiles(threadKey, agent.name),
          ),
          MobileMenuItem(
            icon: Icons.copy_all_rounded,
            label: l?.chatSwipeCopyChat ?? 'Copy full chat',
            onTap: () => unawaited(_copyFullChat()),
          ),
        ],
      ],
    );
  }

  /// Media: every picture and file the agents have sent, as a route.
  void _openPhoneMedia() {
    final List<AgentsAgent> agents = _roster.visibleAgents;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: MobileMediaPage(
            threadKeys: <String>[
              for (final AgentsAgent agent in agents)
                for (final AgentsThreadInfo thread in agent.threads) thread.key,
            ],
            agentNames: <String, String>{
              for (final AgentsAgent agent in agents)
                for (final AgentsThreadInfo thread in agent.threads)
                  thread.key: agent.name,
            },
          ),
        ),
      ),
    );
  }

  /// Home's composer: the main agent's thread comes to the front and the
  /// text is sent there, the way its own composer sends it. Without an agent
  /// yet, the launcher keeps the text for the first one, in its composer.
  void _sendFromHome(String text) {
    final AgentsAgent? main = _mainAgent;
    if (main == null || main.threads.isEmpty) {
      MainAgentLauncher.instance.openWithPrompt(text);
      return;
    }
    final String threadKey = main.threads.first.key;
    _select(main.id, threadKey);
    unawaited(_sendWhenThreadShows(threadKey, text));
  }

  /// Sends [text] into [threadKey] once the thread view shows it and has
  /// loaded it: its composer refuses a thread it is still switching to.
  /// After a few seconds without a taker (a reply still streams, or the user
  /// moved on) the text waits in that thread's composer instead, unsent.
  Future<void> _sendWhenThreadShows(String threadKey, String text) async {
    for (int i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      if (_selectedThreadKey != threadKey) break;
      if (AgentsThreadComposer.send(threadKey, text)) return;
    }
    if (!mounted) return;
    AgentsThreadComposer.prefill(threadKey, text);
  }

  /// Home on a phone: the dashboard under the top bar, Home's composer at
  /// the bottom.
  Widget _buildPhoneHome(BuildContext context, double top) {
    final AppLocalizations? l = AppLocalizations.of(context);
    final String? name = _mainAgent?.name.trim();
    final MediaQueryData media = MediaQuery.of(context);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: MediaQuery(
            // The dashboard adds its top chrome to the safe area itself.
            data: media.copyWith(
              padding: media.padding.copyWith(
                top: MediaQuery.viewPaddingOf(context).top,
              ),
            ),
            child:
                widget.homeBuilder?.call(context) ??
                DashboardPage(
                  assistantName: name,
                  topChrome: top - MediaQuery.viewPaddingOf(context).top,
                  showAskPill: false,
                  bottomChrome: kMobileHomeComposerSpace,
                ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: MobileHomeComposer(
              hintText: name == null || name.isEmpty
                  ? (l?.agentsHomeAskAssistant ?? 'Ask your assistant…')
                  : (l?.agentsHomeAskNamed(name) ?? 'Ask $name…'),
              onSend: _sendFromHome,
            ),
          ),
        ),
      ],
    );
  }

  /// The phone's Agents half (owner's design, 2026-11-05): the top bar with
  /// the menu, the Chats | Agents switch and "new agent", and under it the
  /// strip that names the place in view. Below, one body that a horizontal
  /// swipe moves to the previous or next place: Home, the main agent, the
  /// other agents, the rooms. No drawer, no bottom bar; the composer is at
  /// the bottom on every page.
  ///
  /// The thread view keeps one place in the tree whatever is in front: it
  /// owns the socket. Home lies over it, off stage while a thread is in
  /// front. A room opens as a route on top. The scaffold body shrinks for
  /// the keyboard, so both composers ride it.
  Widget _buildPhoneBody(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _rooms,
        _readMarks,
        _agentProfiles,
        RosterPins.instance,
        ThreadPreviewStore.instance,
      ]),
      builder: (BuildContext context, Widget? _) {
        final AppLocalizations? l = AppLocalizations.of(context);
        final bool home = _agentsHomeShown.value;
        if (home) _phoneHomeBuilt = true;
        final bool status = _phoneShowsStatus;
        final bool thread = !home && !status;
        final List<SwipeChatEntry> entries = _phoneEntries(context, status);
        final String selectedId = _phoneSelectedId(status);
        final double top =
            MediaQuery.viewPaddingOf(context).top + kMobileTopBarHeight;
        // Home has no strip: the dashboard starts under the switch row.
        final double homeTop =
            MediaQuery.viewPaddingOf(context).top + kMobileTopBarRowOnlyHeight;
        if (thread) _schedulePhoneRead();

        final Widget body = Stack(
          children: <Widget>[
            Positioned.fill(
              key: const ValueKey<String>('phone-thread'),
              child: Offstage(
                offstage: !thread,
                child: TickerMode(
                  enabled: thread,
                  child: ExcludeFocus(
                    excluding: !thread,
                    child: _buildThread(topInset: top, phone: true),
                  ),
                ),
              ),
            ),
            if (status && !home)
              Positioned.fill(
                key: const ValueKey<String>('phone-status'),
                child: _buildStatusPanel(topInset: top),
              ),
            if (_phoneHomeBuilt)
              Positioned.fill(
                key: const ValueKey<String>('phone-home'),
                child: Offstage(
                  offstage: !home,
                  child: TickerMode(
                    enabled: home,
                    child: ExcludeFocus(
                      excluding: !home,
                      child: ColoredBox(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: _buildPhoneHome(context, homeTop),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );

        return PopScope(
          // Android back on an agent (or a room's place) goes to Home; on
          // Home it leaves the app. Behind chuk's chats it is not ours.
          canPop: home || _shownMode != AppMode.agents,
          onPopInvokedWithResult: (bool didPop, Object? _) {
            if (didPop) return;
            _showAgentsHome();
          },
          child: RepaintBoundary(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: SwipeChatPager(
                    key: const ValueKey<String>('phone-agents-pager'),
                    entries: entries,
                    selectedId: selectedId,
                    onSelected: _onPhoneSelected,
                    controller: _phonePager,
                    enabled: !home,
                    // Only the name in the strip moves (owner, 2026-11-05).
                    moveChild: false,
                    child: body,
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: MobileTopBar(
                    onMenu: () => unawaited(_openPhoneMenu()),
                    centre: _agentsModeSwitch(),
                    onAdd: () => unawaited(_openOnboarding()),
                    menuTooltip: l?.chatSwipeMenu ?? 'Menu',
                    addTooltip: l?.agentsNewAgent ?? 'New agent',
                    addIcon: Icons.person_add_alt_1_rounded,
                    strip: home
                        ? null
                        : ChatTitleStrip(
                            key: const ValueKey<String>('phone-agents-strip'),
                            entries: entries,
                            selectedId: selectedId,
                            controller: _phonePager,
                            semanticsHint:
                                l?.agentsStripHint ?? 'Swipe to switch agents',
                            workingLabel: l?.chatSwipeWorking ?? 'working',
                            emptyTitle: l?.agentsModeAgents ?? 'Agents',
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The last line of [agent], the way the old inbox said it.
  String? _phonePreview(AgentsAgent agent) {
    final ThreadPreview? preview = ThreadPreviewStore.instance.newestOf(
      agent.threads.map((AgentsThreadInfo thread) => thread.key),
    );
    if (preview == null || preview.text.isEmpty) return null;
    return preview.fromUser ? 'You: ${preview.text}' : preview.text;
  }
}

/// One place of the Agents half: Home, an agent or a room. The shell lists
/// them in order ([_MessengerShellState._agentsHalfPages]): Home first, then
/// the main agent, the other agents and the rooms.
@immutable
class AgentsHalfPage {
  /// Home, the dashboard.
  const AgentsHalfPage.home() : agent = null, room = null;

  /// An agent's thread.
  const AgentsHalfPage.agent(AgentsAgent this.agent) : room = null;

  /// A room.
  const AgentsHalfPage.room(AgentsRoom this.room) : agent = null;

  /// The [id] of Home.
  static const String homeId = '__home__';

  final AgentsAgent? agent;
  final AgentsRoom? room;

  bool get isHome => agent == null && room == null;

  /// A stable id: [homeId], the agent's id or the room's id.
  String get id => agent?.id ?? room?.id ?? homeId;
}

/// The round icon an entry of the phone strip carries when it has no face:
/// Home's house, the status page's computer. The size of an agent's face.
class _PhoneEntryIcon extends StatelessWidget {
  const _PhoneEntryIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 18, color: color),
    );
  }
}
