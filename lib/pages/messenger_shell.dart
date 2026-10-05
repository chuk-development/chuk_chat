/// The messenger shell: chuk_chat's layout around the Agents content.
///
/// ## What it does
///
/// It owns everything a thread needs to live ([AgentsShellHost],
/// `agents_shell_state.dart`) and lays it out for the width it is given:
///
/// * **A desktop window** (`agents_desktop_layout.dart`): the roster on the
///   left is chuk's desktop sidebar with coworkers and rooms in it
///   ([AgentRosterView]), folding to chuk's mini rail. The thread sits on the
///   page under the phone's top bar in desktop form ([AgentsThreadHeader]):
///   the coworker's face, name and status on the left; Documents, Call and
///   Screen on the right, with Details, Copy full chat, Profile and Rename
///   behind "…". The details pane (a tap on the coworker, or Ctrl+.) and
///   Control Rooms (from the roster) open on the right, in chuk's artifact
///   panel slot, and
///   push the thread instead of covering it. A room opens in the centre. The
///   keyboard reaches all of it (Ctrl+K switcher, Ctrl+N, Ctrl+Shift+N,
///   Ctrl+1 … Ctrl+9, Ctrl+., Ctrl+B, Esc).
/// * **A phone, or a window under 600 px**: the home (inbox, media and
///   settings behind the floating navigation pill) and, over it, the chat
///   with chuk's floating top bar ([MobileChatScreen]). The thread view stays
///   mounted off stage behind the inbox.
///
/// Settings is where chuk keeps it: the gear in the roster's account line
/// opens chuk's settings modal on a desktop window; on a phone it is the
/// Settings tab. Pages this shell pushes (Control Rooms and "Host & activity"
/// on a phone, a room, the model list) wear chuk's [FloatingAppBar].
///
/// ## Two halves: Chat and Agents
///
/// The shell holds the whole of chuk_chat too. The Chat | Agents switch
/// ([AppModeSwitch], state in [AppModeService]) sits in the same place in
/// both halves: in the phone's top bar (chuk's title pill slot in Chat, the
/// inbox header in Agents), and floating at the top centre of a desktop
/// window. Chat is chuk's own root wrapper — [RootWrapperMobile] for the same
/// narrow widths the Agents half lays out as a phone, [RootWrapperDesktop]
/// otherwise — with chuk's sidebar, history and settings. Agents is
/// everything above.
///
/// Both halves stay mounted once shown and fade through each other
/// ([FadeThroughTabs]): the thread view owns the socket, and chuk's chat keeps
/// its draft and scroll. Chat is built the first time it is shown, not at
/// startup, so a device that lives in Agents pays nothing for it. Without a
/// shell config there is no chuk_chat to show, and no switch.
///
/// The two halves share one app-wide pointer, `ChatStorageService
/// .selectedChatId`, which each of them sets to its own chat. The pointer
/// belongs to the half in front ([_onSharedChatPointer]); chuk's wrapper reads
/// its own chat from the shell instead ([_readChatModeChatId]), so the
/// Agents thread reconnecting behind it can never swap chuk's chat out.
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
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/settings_page.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_agent_list.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_home.dart';
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
import 'package:chuk_chat/widgets/app_mode_switch.dart';
import 'package:chuk_chat/widgets/chat_documents_panel.dart';
import 'package:chuk_chat/widgets/top_centre_slot.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_chrome.dart'
    show ChromeChip;
import 'package:chuk_chat/platform_specific/mobile/mobile_chat_screen.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_container_transform.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/pages/agent_profile_page.dart';
import 'package:chuk_chat/pages/agents_install_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_mail_key_handover.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/media_index.dart';
import 'package:chuk_chat/services/agents/thread_preview_store.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
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
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_shell_status.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/services/herenow/herenow_store.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/session_recovery.dart';
import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/settings/theme_controller.dart';
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
import 'package:chuk_chat/widgets/icons/icon_map.dart';
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
import 'package:chuk_chat/services/agents/coworker_templates.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/widgets/coworker_template_picker.dart';
// ── end templates ──

part 'agents_shell_state.dart';
part 'agents_desktop_layout.dart';

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
    this.pairingRestoreBuilder,
    this.appMode,
    this.chatModeBuilder,
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

  /// The coworkers' display profiles (picture, colour, role, brief).
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

  /// Which half is in front: Chat or Agents. Null builds one that remembers
  /// the choice in the preferences and, with nothing remembered, opens on
  /// Agents when this device holds a pairing and on Chat otherwise.
  final AppModeService? appMode;

  /// Builds the Chat half. Null builds chuk_chat's own root wrapper from
  /// [shellConfig]. A widget test hands in a light stand-in, because chuk's
  /// wrapper starts the whole chat stack. [modeSwitch] is the switch, for the
  /// stand-in's top bar, and null while the device has no computer;
  /// [onAddComputer] opens the install page, and is null unless the device
  /// has no computer. [phone] is the shell's phone rule.
  @visibleForTesting
  final Widget Function(
    BuildContext context, {
    required bool phone,
    required Widget? modeSwitch,
    required VoidCallback? onAddComputer,
  })?
  chatModeBuilder;

  /// Replaces the install page's wait for the computer (the relay claim). A
  /// widget test injects one, so the page opens with no socket.
  @visibleForTesting
  final AgentsInstallClaimWaiter? installClaimWaiter;

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell>
    with AgentsShellHost, _AgentsDesktopLayout, SingleTickerProviderStateMixin {
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

  // --- Chat | Agents ---------------------------------------------------------

  late final AppModeService _appMode = widget.appMode ?? AppModeService();
  late final bool _ownsAppMode = widget.appMode == null;

  /// Whether there is a chuk_chat to switch to. Without a shell config (a
  /// widget test, the auth gate's fallback) the shell is Agents alone.
  /// Whether [initState] added the mode and chat-pointer listeners. Kept
  /// apart from [_chatModeAvailable], which a parent rebuild can change, so
  /// [dispose] removes exactly what was added.
  bool _chatListening = false;

  bool get _chatModeAvailable =>
      widget.shellConfig != null || widget.chatModeBuilder != null;

  /// The half on screen. Follows [_appMode], and is always Agents when there
  /// is no Chat half.
  AppMode _shownMode = AppMode.agents;

  /// Whether the Chat half has been shown yet. It is built on first show and
  /// kept from then on.
  bool _chatModeBuilt = false;

  /// chuk_chat's chat as the Chat half last had it: null is a new chat. See
  /// [_onSharedChatPointer].
  String? _chatModeChatId;

  @override
  void initState() {
    super.initState();
    _hostInit();
    _deskInit();
    _push.addStatusListener(_onPushStatus);
    _controller.addListener(_onControllerForBrowser);
    _chatListening = _chatModeAvailable;
    if (_chatListening) {
      _shownMode = _wantedMode;
      _chatModeBuilt = _shownMode == AppMode.chat;
      _appMode.addListener(_onModeChanged);
      _hasComputer.addListener(_onHasComputerChanged);
      ChatStorageService.selectedChatIdNotifier.addListener(
        _onSharedChatPointer,
      );
      if (!_appMode.loaded) {
        unawaited(_appMode.load(hasPairing: _hasPairing));
      }
      if (_shownMode == AppMode.chat) {
        // After the frame: the pointer notifies, and nothing may listen to it
        // from inside this build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handOverChatPointer();
        });
      }
    }
  }

  /// Whether this device holds a pairing: the default half with nothing
  /// remembered.
  Future<bool> _hasPairing() async =>
      (await _pairingStore.loadPairing()) != null;

  /// The half the shell should show: what [_appMode] says, except that a
  /// device with no computer stays on Chat. The stored choice is left alone,
  /// so a computer that comes back (a restore, a new install) finds it.
  AppMode get _wantedMode =>
      _hasComputer.value == false ? AppMode.chat : _appMode.value;

  /// The switch shows only when there is a computer to switch to. While that
  /// is not known yet it stays away, and so does the install entry.
  bool get _showModeSwitch => _hasComputer.value == true;

  /// The install entry's action: only on a device that has no computer.
  VoidCallback? get _addComputerAction =>
      _chatModeAvailable && _hasComputer.value == false
      ? () => unawaited(_addComputer())
      : null;

  /// The switch, wired to [_appMode]. One widget for every place it sits.
  /// Null while the device has no computer to switch to.
  Widget? _buildModeSwitch() => _showModeSwitch
      ? AppModeSwitch(
          mode: _shownMode,
          onChanged: (AppMode mode) => unawaited(_appMode.select(mode)),
        )
      : null;

  /// "Add your computer": the install page, and the Agents half once the
  /// computer is linked.
  Future<void> _addComputer() async {
    final bool linked = await _openInstallPage();
    if (!linked || !mounted) return;
    unawaited(_appMode.select(AppMode.agents));
  }

  void _onHasComputerChanged() {
    if (!mounted) return;
    // The switch and the entry follow the answer; the half may too.
    setState(() {});
    _onModeChanged();
  }

  void _onModeChanged() {
    if (!mounted) return;
    final AppMode next = _wantedMode;
    if (next == _shownMode) return;
    setState(() {
      _shownMode = next;
      if (next == AppMode.chat) _chatModeBuilt = true;
    });
    _handOverChatPointer();
    // Back on the Agents desktop: its keyboard (Ctrl+K and the rest) listens
    // on the shell's focus node, which lost the focus while Chat was in front.
    if (next == AppMode.agents && !_isPhone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _shownMode != AppMode.agents) return;
        if (!_deskFocus.hasFocus) _deskFocus.requestFocus();
      });
    }
  }

  /// Points the shared pointer at the chat of the half in front.
  void _handOverChatPointer() {
    if (_shownMode == AppMode.chat) {
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
  /// is taken as it is (for Chat, it is also what chuk's wrapper shows next).
  /// A write by the half behind is noted — chuk's chat, off stage, may have
  /// just created its chat with a reply — and the pointer goes back to the
  /// half in front after the current call stack, never inside it.
  void _onSharedChatPointer() {
    if (!mounted) return;
    final String? id = ChatStorageService.selectedChatId;
    final bool agentsId = id != null && _isAgentsChatId(id);
    if (_shownMode == AppMode.chat) {
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

  /// The Chat half: chuk_chat's own root wrapper, with the switch in its top
  /// bar. A narrow window gets chuk's phone wrapper, by the same rule the
  /// Agents half uses — on Linux too, where chuk's own `RootWrapper` always
  /// picks the desktop one. The web keeps the desktop wrapper at every width,
  /// as chuk_chat's web does: the phone wrapper asks the platform for
  /// permissions, and a browser has no such platform.
  ///
  /// A device with no computer gets no switch; chuk's sidebar carries the
  /// "Add your computer" entry instead ([_addComputerAction]).
  Widget _buildChatMode(BuildContext context, bool phone) {
    final Widget? modeSwitch = _buildModeSwitch();
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
      );
    }
    return RootWrapperDesktop(
      config: config,
      headerCenter: modeSwitch,
      selectedChatIdReader: _readChatModeChatId,
      onAddComputer: addComputer,
    );
  }

  /// The switch for the Agents half's own layouts, or null without a Chat
  /// half or without a computer.
  @override
  Widget? _agentsModeSwitch() =>
      _chatModeAvailable ? _buildModeSwitch() : null;

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
    if (_chatListening) {
      _appMode.removeListener(_onModeChanged);
      _hasComputer.removeListener(_onHasComputerChanged);
      ChatStorageService.selectedChatIdNotifier.removeListener(
        _onSharedChatPointer,
      );
    }
    if (_ownsAppMode) _appMode.dispose();
    _push.removeStatusListener(_onPushStatus);
    _push.dispose();
    _controller.removeListener(_onControllerForBrowser);
    _browserPresence?.dispose();
    _browserPresence = null;
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

  /// The screen target, tapped while the coworker has no screen. Says what has
  /// to happen first instead of leaving the tap unanswered. It replaces
  /// whatever snack is up, because it answers a tap the user just made.
  void _explainNoScreen() {
    if (!mounted) return;
    // The host says WHY in a code of its own (`browser_view.reason`, bead
    // cowork-qp5i), and the app parks the target itself when the host falls
    // silent (bead cowork-8ptj). Both beat "no screen yet", which is only the
    // answer when nobody ever said anything about a screen.
    // ── own browser ──
    // A coworker in the user's own browser never has a screen here.
    if (_browserPresence?.usesUserBrowser ?? false) {
      AppNotifications.show(
        context,
        AppLocalizations.of(context)?.ubScreenExplain ??
            'This coworker works in your own browser. There is no screen '
                'to show here.',
        duration: const Duration(seconds: 4),
      );
      return;
    }
    // ── end own browser ──
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
    AppNotifications.show(
      context,
      text,
      duration: const Duration(seconds: 4),
    );
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
    // A thread opened from behind chuk's chat (a tapped notification): the
    // Agents half comes to the front with it.
    if (_chatModeAvailable && _shownMode == AppMode.chat) {
      unawaited(_appMode.select(AppMode.agents));
    }
    // The user picked this one: remember it for the next launch, and stop the
    // restore from moving the selection out from under them.
    _rememberSelection(agentId, threadKey);
    // Opening a thread is reading it: the unread dot clears here, not when the
    // next frame happens to arrive. A thread with nothing unread keeps its
    // mark: moving it forward changes no dot and costs a preference write.
    if (_readMarks.isThreadUnread(agent, agent.threads.first)) {
      unawaited(_readMarks.markRead(threadKey));
    }
    setState(() {
      // The row this selection came from, if it came from one. Claimed here so
      // every other way in clears it (see [_pendingOpenFrom]).
      _openFrom = _pendingOpenFrom;
      _openFromAgentId = _pendingOpenFrom == null ? null : agentId;
      _pendingOpenFrom = null;
      _selectedAgentId = agentId;
      _selectedThreadKey = threadKey;
      _showThreadOnNarrow = true;
    });
  }

  /// On a phone the inbox can cover the thread; a desktop window always shows
  /// it, unless chuk's chat is in front. Read by the read marks in
  /// [AgentsShellHost].
  @override
  bool get _threadIsOnScreen =>
      _shownMode == AppMode.agents && (!_isPhone || _showThreadOnNarrow);

  /// The screen target's action, or null while the coworker has no screen open.
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

  /// A coworker's profile page: the face, the state, the brief, and everything
  /// the user can set or manage about it. Reached from the chat header pill, the
  /// inbox row menu and the desktop roster row.
  @override
  void _openAgentProfile(AgentsAgent agent) {
    if (_isPhone) {
      final chatKey = agent.id == _selectedAgentId
          ? _selectedThreadKey
          : (agent.threads.isEmpty ? null : agent.threads.first.key);
      void open(Widget page) =>
          Navigator.of(context)
              .push<void>(MaterialPageRoute<void>(builder: (_) => page));
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
              appBar: FloatingAppBar(title: const Text('Host & activity')),
              body: SafeArea(
                top: false,
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
          onSkills: () => open(const AgentsSkillsSettingsPage()),
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
          final agent = _selectedAgent;

          final Widget agents = phone
              ? _buildPhoneBody(context, agent)
              : _buildDesktopBody(context, width, agent);

          return Scaffold(
            key: _scaffoldKey,
            // No end drawer any more: the agent controls are the desktop's
            // details pane, in chuk's artifact panel slot.
            endDrawerEnableOpenDragGesture: false,
            // The two halves are peers, so they fade through each other, and
            // both stay mounted (see the library doc). The slots follow
            // [AppMode]: Chat first, Agents second.
            body: _chatModeAvailable
                ? FadeThroughTabs(
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

  /// The agent controls: the details pane on a desktop window. The phone
  /// reaches them through the profile page instead.
  void _openControlDrawer() {
    if (_isPhone) return;
    _deskShowRightPane('details');
  }

  /// A room: in the centre pane on a desktop window, a route on a phone.
  @override
  void _openRoom(String roomId) {
    if (!_isPhone) {
      _deskOpenRoom(roomId);
      return;
    }
    super._openRoom(roomId);
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
                  // own browser: "Works in your browser", like the desktop.
                  usesUserBrowser: _browserPresence?.usesUserBrowser ?? false,
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

    // The home is three places, not one list (docs/DESIGN.md): chats,
    // media, settings.
    final Widget home = RepaintBoundary(
      child: MobileHome(
        roster: _roster,
        readMarks: _readMarks,
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
          // A room is a conversation, so it sits in the inbox with the
          // coworkers. The "+" target asks which of the two to create.
          rooms: _rooms,
          onOpenRoom: _openRoom,
          onCreateRoom: _openRoomCreate,
          onOpenAccount: _openSettings,
          onOpenProfile: _openAgentProfile,
          onRenameAgent: _openAgentRename,
          onDeleteAgent: (AgentsAgent target) => _deleteAgent(target.id),
          readMarks: _readMarks,
          profiles: _agentProfiles,
          accountLabel: null,
          // With no coworker and no room the inbox says what is going on
          // with the computer — never a bare "no agents" while there is no
          // computer to hold one.
          emptyState: _buildStatusPanel(),
          // The Chat | Agents switch, where it sits over chuk's chat too.
          headerCenter: _agentsModeSwitch(),
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
