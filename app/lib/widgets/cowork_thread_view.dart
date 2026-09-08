import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/constants.dart';
import 'package:cowork/models/app_shell_config.dart';
import 'package:cowork/platform_config.dart';
import 'package:cowork/platform_specific/chat/chat_ui_desktop.dart';
import 'package:cowork/platform_specific/chat/chat_ui_mobile.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/app_theme_service.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/cowork/agent_file_saver.dart';
import 'package:cowork/services/cowork/chat_debug_export.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/cowork/cowork_replay_loader.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/notifications/cowork_notifications.dart';
import 'package:cowork/services/secrets/secrets_service.dart';
import 'package:cowork/services/settings/verbose_service.dart';
import 'package:cowork/services/automations/automations_source.dart';
import 'package:cowork/services/automations/cowork_automation.dart';
import 'package:cowork/widgets/ask_user_card.dart';
import 'package:cowork/widgets/automation_card.dart';
import 'package:cowork/widgets/chat_documents_panel.dart';
import 'package:cowork/widgets/cowork_thread_header.dart';

/// The CoWork chat surface: the imported chuk_chat chat screen, wired to the
/// agent running on the user's own host.
///
/// This widget owns two halves that never mix:
///
///  * **The transport.** Building the [CoworkRelayController], the pairing /
///    connect bar, auto-reconnect with a watchdog, provisioning the account
///    token, and asking the host to replay the thread. None of that is on
///    screen once the socket is up: the connection is not the user's job.
///  * **The window.** Once paired the body IS `ChukChatUIDesktop` /
///    `ChukChatUIMobile` — chuk_chat's renderer, imported verbatim. It reads
///    the thread out of [ChatStorageService] (the local instant-paint cache
///    the replay loader fills) and sends through
///    `WebSocketChatService.sendStreamingChat`, which is CoWork's relay
///    adapter. Nothing about the chat is drawn here.
///
/// One view serves many threads. [threadKey] is the executor's `session_key`
/// AND the imported screen's `selectedChatId` — one id, so a send, a replay and
/// a cache row all name the same thing.
///
/// All transport lives behind [CoworkRelayController], so the UI is the same
/// whether it drives a real socket or a fake in a widget test.
class CoworkThreadView extends StatefulWidget {
  const CoworkThreadView({
    super.key,
    required this.controllerBuilder,
    required this.sessionSource,
    this.pairingStore,
    this.defaultHostUrl = 'ws://127.0.0.1:8787',
    this.threadKey = 'default',
    this.fileSaver = const DownloadsAgentFileSaver(),
    this.onRunStateChanged,
    this.onActivity,
    this.onPaired,
    this.onController,
    this.onOpenModelScreen,
    this.shellConfig,
    this.title,
    this.subtitle,
    this.headerAgent,
    this.onOpenAgentProfile,
    this.onOpenAgentScreen,
    this.actions = const <CoworkThreadAction>[],
    this.leadingInset = 0,
    this.topInset = 0,
    this.phoneLayout = false,
  });

  /// Builds the transport controller. Async because a real client generates a
  /// device signing key first. Widget tests return a fake synchronously. Called
  /// again to get a fresh controller after a disconnect.
  final Future<CoworkRelayController> Function() controllerBuilder;

  /// Supplies the account session that gets provisioned once paired.
  final AccountSessionSource sessionSource;

  /// Called with the live transport controller whenever it is built or rebuilt,
  /// so a parent (the shell) can share the one socket — e.g. to feed a room
  /// thread the same inbound stream. The parent must not dispose it; this view
  /// owns its lifecycle.
  final void Function(CoworkRelayController controller)? onController;

  /// Persistent trust store. When provided and a pairing is stored, the view
  /// auto-reconnects with no code and offers a separate "Forget" action. When
  /// null the view has no persistence: it always shows the code connect form
  /// (the legacy behaviour, used by widget tests that inject a fake controller).
  final CoworkPairingStore? pairingStore;

  /// Prefilled host URL for a local run.
  final String defaultHostUrl;

  /// The executor-side session this view talks to (§4: many threads per agent),
  /// and the imported screen's chat id.
  final String threadKey;

  /// Where a file card writes when the user saves.
  ///
  /// Kept for API compatibility with the callers. A relayed file now lands in
  /// the local blob store and renders as the imported `sandboxArtifact` card,
  /// which has its own download action, so nothing in this view reads it.
  final AgentFileSaver fileSaver;

  /// Reports whether a run is in flight, and for which thread, so the roster can
  /// show "working" against the right coworker. Driven off [CoworkRunLedger].
  final void Function(String threadKey, bool running)? onRunStateChanged;

  /// Reports that something happened in [threadKey], for "last active".
  final void Function(String threadKey, DateTime when)? onActivity;

  /// Reports the host device id the moment the transport is paired, so the
  /// roster can list the agent that really runs over there.
  final void Function(String peerDeviceId)? onPaired;

  /// Opens the full model catalogue — the composer's "More models" row calls
  /// it. Wired by the shell to the settings Model page.
  final VoidCallback? onOpenModelScreen;

  /// chuk_chat's shell config, handed down from the shell (bead cowork-8y2).
  /// The imported screen reads its display flags from it; null (a widget
  /// test) falls back to the verbose toggle.
  final AppShellConfig? shellConfig;

  /// The coworker this thread belongs to, for the header's title. Null before
  /// one is selected: the header then shows the state and the actions alone
  /// rather than inventing a name.
  final String? title;

  /// The quieter second line under [title] — the coworker's role.
  final String? subtitle;

  /// The coworker whose thread this is. With it the header shows the messenger's
  /// contact pill (face, name, live state) instead of a plain title; a room
  /// thread and a widget test without a roster pass null and keep the text.
  final CoworkAgent? headerAgent;

  /// Tap on the header pill — the coworker's profile page.
  final void Function(CoworkAgent agent)? onOpenAgentProfile;

  /// Opens the live view of the coworker's screen. Null parks the target.
  final VoidCallback? onOpenAgentScreen;

  /// Actions the SHELL owns but this thread's header shows: agent controls,
  /// Control Rooms, the agent's browser, Copy Debug Chat. They used to float
  /// over this view in a row of their own, which is why the top of the screen
  /// read as leftovers; the header groups them with the view's own Documents
  /// button and gives them one size and one spacing.
  final List<CoworkThreadAction> actions;

  /// Left room the header keeps clear for chrome the shell paints OVER this
  /// view: the hamburger, and the mini rail under it while the sidebar is
  /// folded. The view cannot see them, so the shell states the width.
  final double leadingInset;

  /// The same for the top, on a phone: the height of the floating chrome. The
  /// header takes it as padding and starts below the chrome — so the chat
  /// under the header reserves nothing of its own any more.
  final double topInset;

  /// Force chuk's phone screen. The mobile shell sets it below the phone
  /// breakpoint on every platform, so a narrow desktop window renders the
  /// phone layout too — that is how the layout is checked on Linux.
  final bool phoneLayout;

  @override
  State<CoworkThreadView> createState() => CoworkThreadViewState();
}

class CoworkThreadViewState extends State<CoworkThreadView> {
  late final TextEditingController _hostController;
  final TextEditingController _codeController = TextEditingController();

  CoworkRelayController? _controller;
  StreamSubscription<CoworkRelayInbound>? _inboundSub;

  final CoworkRelayLink _link = CoworkRelayLink.instance;
  final CoworkRunLedger _ledger = CoworkRunLedger.instance;
  final CoworkReplayLoader _loader = CoworkReplayLoader.instance;

  /// Mirrors [VerboseService.instance]: the single source of truth for the two
  /// views (§"quiet by default, full log on demand"). It drives the imported
  /// screen's `showToolCalls` / `showTps`, so turning the toggle on or off in
  /// Settings reflows the transcript live, and it rides each task as
  /// `debug: true` so the executor echoes the raw model context.
  ///
  /// The thinking block is NOT part of verbose: like chuk_chat it follows the
  /// user's own "show reasoning" setting ([AppThemeService.showReasoningTokens],
  /// on by default), so a thinking model's reasoning streams into the bubble
  /// even in the quiet view (bead cowork-0ia).
  bool _verbose = false;

  /// The replay revision this view has painted for [CoworkThreadView.threadKey].
  /// The imported screen reads its rows once, in `initState`, so a replay that
  /// rewrites the cache under it has to remount it — the revision is the key.
  int _revision = 0;

  /// A here.now publish waiting on the user. The run is BLOCKED on the executor
  /// until it is answered, so it is a standing card, not a fleeting prompt.
  CoworkRelayApprovalRequest? _approval;
  bool? _approvalDecision;

  /// This thread's schedules and watchers (docs/WIRE_CONTRACT.md,
  /// "Automations"), drawn as a strip above the chat while any is active or
  /// paused. The source folds live and replayed events; this view only reads.
  final AutomationsSource _automations = AutomationsSource.instance;
  bool _automationsCollapsed = true;

  /// A `request_secrets` waiting on the user (docs/WIRE_CONTRACT.md,
  /// "Secrets"). The run is BLOCKED on the executor until a `secrets` frame
  /// with this request id goes back, so it is a standing card too. One field
  /// per name; the values leave this view only through [SecretsService].
  CoworkRelaySecretRequest? _secretRequest;
  final Map<String, TextEditingController> _secretFields =
      <String, TextEditingController>{};
  bool _secretsBusy = false;

  /// Run ids already acknowledged, so a rebuild cannot ack the same run twice.
  final Set<String> _ackedRuns = <String>{};

  String? _localError;
  bool _busy = false;

  /// Whether the local chat cache has been read once.
  ///
  /// The imported chat screen looks its thread up in [ChatStorageService]'s
  /// in-memory map the moment it mounts. When the map has not been filled yet
  /// the lookup misses, and the screen does not wait — it treats the miss as
  /// "new chat", clears its messages and drops the id (`_activeChatId = null`),
  /// so nothing ever loads it again. That is the history that flashes up and
  /// then stays gone (bead cowork-8yb): the mount raced `loadFromCache`.
  ///
  /// So the chat area waits for this one read before it mounts the screen. It
  /// is metadata only and it is local, so the wait is a frame or two.
  bool _cacheReady = false;
  final _startupState = ValueNotifier<CoworkRelayState>(
    const CoworkRelayState(phase: CoworkRelayPhase.connecting),
  );

  /// The persisted trust, loaded once at startup. Non-null means "already
  /// paired": auto-reconnect, hide the code form, offer Forget.
  CoworkStoredPairing? _storedPairing;

  /// The user tapped Disconnect: stay down until they act, no auto-reconnect.
  bool _manuallyDisconnected = false;

  Timer? _autoReconnectTimer;
  int _reconnectAttempts = 0;

  /// How many reconnects have been tried since the link was last up.
  ///
  /// Not [_reconnectAttempts]: that one is the backoff dial, and the watchdog
  /// resets it every few seconds so recovery stays prompt. This one only ever
  /// resets on a real pairing, so it is what tells a hiccup (the socket is
  /// already on its way back) from a host that is genuinely not there —
  /// which is when the bottom bar earns its place again.
  int _failedReconnects = 0;

  /// A safety net that periodically forces a reconnect when the app is down but
  /// paired. The event-driven path (`_onStateChanged` on a `closed` transition →
  /// `_scheduleAutoReconnect`) can be missed after a host process restart: a
  /// dropped socket that never surfaces as a clean `closed` transition, a rebuild
  /// that throws, or a stuck in-flight flag all leave the app idle on a dead
  /// link. This watchdog re-arms the reconnect whenever the controller is in a
  /// down phase (`closed`/`error`) with a stored pairing and nothing already in
  /// flight — so recovery never depends on a single fragile transition.
  Timer? _watchdogTimer;

  /// Capped exponential backoff for auto-reconnect after an unexpected drop.
  static const Duration _baseBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.defaultHostUrl);
    // The link's fan-out outlives every controller, so this one subscription
    // survives reconnects. It carries only what this view still owns: the
    // approval prompt and the live `run_ack`.
    _inboundSub = _link.inbound.listen(_onInbound);
    _loader.attach();
    _ledger.addListener(_onLedgerChanged);
    _loader.addListener(_onLoaderChanged);
    _automations.attach();
    _automations.addListener(_onAutomationsChanged);
    _revision = _loader.revisionFor(widget.threadKey);
    _bootstrap();
    // The verbose flag is one shared singleton: mirror it now and rebuild on
    // every change.
    VerboseService.instance.addListener(_onVerboseChanged);
    _loadVerbose();
    // The "show reasoning" setting reflows the transcript live, like chuk.
    AppThemeService.instance.addListener(_onThemeChanged);
    // Safety net (see [_watchdogTimer]): re-arm reconnect on a slow cadence.
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _watchdogTick(),
    );
  }

  @override
  void didUpdateWidget(CoworkThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.threadKey != widget.threadKey) {
      // A different conversation. Point the link and the cache at it and ask
      // the host for whatever this client is missing.
      _link.sessionKey.value = widget.threadKey;
      ChatStorageService.selectedChatId = widget.threadKey;
      _revision = _loader.revisionFor(widget.threadKey);
      _approval = null;
      _approvalDecision = null;
      _clearSecretRequest();
      _requestReplay();
    }
  }

  @override
  void dispose() {
    _autoReconnectTimer?.cancel();
    _watchdogTimer?.cancel();
    VerboseService.instance.removeListener(_onVerboseChanged);
    AppThemeService.instance.removeListener(_onThemeChanged);
    _ledger.removeListener(_onLedgerChanged);
    _loader.removeListener(_onLoaderChanged);
    _automations.removeListener(_onAutomationsChanged);
    _controller?.state.removeListener(_onStateChanged);
    _startupState.dispose();
    _inboundSub?.cancel();
    _controller?.dispose();
    _hostController.dispose();
    _codeController.dispose();
    _clearSecretRequest();
    super.dispose();
  }

  // --- lifecycle -------------------------------------------------------------

  /// Load any stored pairing first, then build the controller. If a pairing is
  /// stored, auto-reconnect with no code; otherwise show the connect form.
  Future<void> _bootstrap() async {
    // Warm the instant-paint cache before the chat screen mounts, so a known
    // thread paints from disk instead of waiting for the host's replay.
    //
    // From the cache, not from the cloud: `loadChats` pulls every chat out of
    // Supabase and decrypts them all, on every mount. `loadFromCache` reads the
    // local metadata and returns at once, and the thread the reader actually
    // opened is loaded by the chat screen itself through `loadFullChat`, which
    // is cache-first anyway.
    unawaited(_warmCache());
    unawaited(_loader.load());
    _link.sessionKey.value = widget.threadKey;
    ChatStorageService.selectedChatId = widget.threadKey;

    final store = widget.pairingStore;
    if (store != null) {
      try {
        _storedPairing = await store.loadPairing();
      } catch (_) {
        // A storage failure (locked keystore, missing plugin in a test) simply
        // means "not paired yet" — fall back to the code connect form.
        _storedPairing = null;
      }
      if (_storedPairing != null && mounted) {
        _hostController.text = _storedPairing!.hostUrl.toString();
      }
    }
    await _buildController();
    if (_storedPairing != null) {
      await _reconnect();
    }
  }

  /// Reads the local chat cache once and then lets the chat area mount. A
  /// cache that cannot be read is not a reason to withhold the chat — the
  /// host's replay still fills it — so a failure opens the gate too.
  Future<void> _warmCache() async {
    try {
      await ChatStorageService.loadFromCache();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[cowork-thread] chat cache warm failed: $error');
      }
    }
    if (mounted) setState(() => _cacheReady = true);
  }

  Future<void> _buildController() async {
    final controller = await widget.controllerBuilder();
    if (!mounted) {
      controller.dispose();
      return;
    }
    controller.state.addListener(_onStateChanged);
    setState(() => _controller = controller);
    _link.bind(controller);
    widget.onController?.call(controller);
  }

  /// Tears down the live controller and spins up a fresh one, without touching
  /// the stored pairing or the conversation.
  Future<void> _rebuildController() async {
    final old = _controller;
    // Build the replacement FIRST, then swap it in with a single setState. This
    // never leaves the tree pointing at a controller whose state notifier we are
    // about to dispose — repointing and disposing in the wrong order tears the
    // ValueListenableBuilder off a disposed notifier and unmounts the view.
    final controller = await widget.controllerBuilder();
    if (!mounted) {
      controller.dispose();
      return;
    }
    old?.state.removeListener(_onStateChanged);
    controller.state.addListener(_onStateChanged);
    setState(() => _controller = controller);
    // Re-point the link. The open adapter / replay subscriptions ride the
    // link's own long-lived stream, so a run in flight is never torn off.
    _link.bind(controller);
    widget.onController?.call(controller);
    // Tear the old transport down in the background: it is fully detached now.
    if (old != null) unawaited(old.dispose());
  }

  /// Watches the transport state for an unexpected drop after being paired, and
  /// schedules a capped-backoff auto-reconnect when a pairing is stored.
  void _onStateChanged() {
    final controller = _controller;
    if (controller == null) return;
    final state = controller.state.value;
    final phase = state.phase;
    if (phase == CoworkRelayPhase.paired) {
      _reconnectAttempts = 0;
      // The link is up, so the failures behind us are history: a single drop
      // months later must not walk straight into the "it is really broken" bar.
      _failedReconnects = 0;
      final peer = state.peerDeviceId;
      if (peer != null) widget.onPaired?.call(peer);
      _link.bind(controller);
      _link.sessionKey.value = widget.threadKey;
      ChatStorageService.selectedChatId = widget.threadKey;
      // The server holds the whole thread, always. Asking on every pair is
      // cheap (the cursor makes it a delta) and it is what makes a reinstall,
      // a new device and a reconnect all land on the same transcript.
      _requestReplay();
      return;
    }
    if (phase == CoworkRelayPhase.closed &&
        _storedPairing != null &&
        !_manuallyDisconnected) {
      // A run belongs to the host process, not to this socket: a dropped
      // connection does NOT end it, so the run phase is left exactly as it is.
      _scheduleAutoReconnect();
    }
  }

  /// Asks the host to re-stream this thread from the replay cursor.
  void _requestReplay() {
    final controller = _controller;
    if (controller == null || !controller.state.value.isPaired) return;
    final sessionKey = widget.threadKey;
    final afterId = _loader.cursorFor(sessionKey);
    _loader.expect(sessionKey, afterId: afterId);
    unawaited(
      controller
          .requestReplay(sessionKey: sessionKey, afterId: afterId)
          .catchError((Object _) {}),
    );
  }

  /// Force a reconnect if we are paired-but-down and nothing is already trying.
  /// Cheap and idempotent: it does nothing while paired, connecting, or when a
  /// reconnect timer / in-flight attempt already exists.
  void _watchdogTick() {
    if (!mounted || widget.pairingStore == null || _storedPairing == null) {
      return;
    }
    if (_manuallyDisconnected || _busy || _autoReconnectTimer != null) return;
    final phase = _controller?.state.value.phase;
    final down =
        phase == null ||
        phase == CoworkRelayPhase.closed ||
        phase == CoworkRelayPhase.error;
    if (!down) return;
    // A fresh, prompt attempt (reset the backoff so recovery is not delayed by
    // earlier failures); _scheduleAutoReconnect is the single dial path.
    _reconnectAttempts = 0;
    _scheduleAutoReconnect();
  }

  void _scheduleAutoReconnect() {
    if (_autoReconnectTimer != null || widget.pairingStore == null) return;
    final exponent = _reconnectAttempts.clamp(0, 5);
    final delayMs = (_baseBackoff.inMilliseconds * (1 << exponent)).clamp(
      0,
      _maxBackoff.inMilliseconds,
    );
    _reconnectAttempts++;
    _failedReconnects++;
    _autoReconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      _autoReconnectTimer = null;
      if (!mounted || _storedPairing == null || _manuallyDisconnected) return;
      // A fresh controller per attempt: the client is single-shot per socket.
      await _rebuildController();
      await _reconnect();
    });
  }

  /// Reconnects the current controller to the stored host with no code, then
  /// re-provisions the account token so tasks can run again.
  Future<void> _reconnect() async {
    final controller = _controller;
    final stored = _storedPairing;
    // `mounted` too: the auto-reconnect timer awaits `_rebuildController`
    // first, and the view can be disposed during that await (review F6).
    if (!mounted || controller == null || stored == null || _busy) return;
    setState(() {
      _localError = null;
      _busy = true;
      _manuallyDisconnected = false;
    });
    try {
      await controller.reconnect(hostUrl: stored.hostUrl, pairing: stored);
      final session = widget.sessionSource.current();
      if (session != null) {
        await controller.provisionAccount(session);
      }
    } catch (error) {
      if (mounted) setState(() => _localError = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    final controller = _controller;
    if (controller == null || _busy) return;
    final host = _hostController.text.trim();
    final code = _codeController.text.trim();
    if (host.isEmpty || code.isEmpty) {
      setState(() => _localError = 'Enter both a host URL and a pairing code.');
      return;
    }
    setState(() {
      _localError = null;
      _busy = true;
    });
    try {
      await controller.connect(hostUrl: Uri.parse(host), pairingCode: code);
      // Paired: hand the executor the account token (ExecutorProvisioning).
      final session = widget.sessionSource.current();
      if (session != null) {
        await controller.provisionAccount(session);
      }
      // Persist the trust so the next launch reconnects with no code.
      await _persistTrust(controller);
    } catch (error) {
      // The pairing failure is already reflected in controller.state; a
      // provisioning failure is surfaced here.
      if (mounted) setState(() => _localError = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _persistTrust(CoworkRelayController controller) async {
    final store = widget.pairingStore;
    final trust = controller.establishedTrust;
    if (store == null || trust == null) return;
    await store.savePairing(trust);
    if (mounted) setState(() => _storedPairing = trust);
  }

  /// Deletes the stored trust — the next connection needs a fresh code again —
  /// and drops the live connection.
  Future<void> _forget() async {
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
    _manuallyDisconnected = false;
    _reconnectAttempts = 0;
    _failedReconnects = 0;
    await widget.pairingStore?.clearPairing();
    _codeController.clear();
    // Drop the trust from the UI in the same frame the store loses it, so the
    // reconnect bar cannot outlive the pairing it belongs to.
    if (mounted) {
      setState(() {
        _storedPairing = null;
        _localError = null;
        _busy = false;
      });
    }
    await _rebuildController();
  }

  /// Load the persisted verbose flag once at startup. Never throws: a failure
  /// leaves the quiet default, so a normal send is unchanged.
  Future<void> _loadVerbose() async {
    await VerboseService.instance.load();
    if (mounted) setState(() => _verbose = VerboseService.instance.enabled);
  }

  void _onVerboseChanged() {
    if (mounted) setState(() => _verbose = VerboseService.instance.enabled);
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  // --- the inbound this view still owns ---------------------------------------

  void _onInbound(CoworkRelayInbound event) {
    if (!mounted) return;
    switch (event) {
      case CoworkRelayApprovalRequest():
        // A here.now publish is waiting on the user, and the run is blocked on
        // the executor until we answer. The imported renderer records it as an
        // `ask_user` line (through the ledger), but that card only becomes
        // tappable once the turn is idle — which it will not be while the run
        // waits. So the decision is offered here, above the chat.
        //
        // Another coworker's run asked: its own view prompts, not this one
        // (review F9). A host that does not say which thread means this one.
        final forThread = event.sessionKey;
        if (forThread != null && forThread != widget.threadKey) return;
        // A replayed request that is already decided, or whose run is over,
        // is history: never prompt for it (bead cowork-266).
        if (event.replay &&
            (event.isDecided || !_ledger.isRunning(widget.threadKey))) {
          return;
        }
        setState(() {
          _approval = event;
          _approvalDecision = null;
        });
      case CoworkRelaySecretRequest():
        // The model asked for keys by name and the run waits on the answer.
        // Another coworker's run asked: its own view prompts, not this one.
        final forThread = event.sessionKey;
        if (forThread != null && forThread != widget.threadKey) return;
        // Names the user has set are shown as "set", never as a value.
        unawaited(SecretsService.instance.load());
        setState(() {
          _clearSecretRequest();
          _secretRequest = event;
          for (final name in event.names) {
            _secretFields[name] = TextEditingController();
          }
        });
      case CoworkRelayDone():
        if (event.isReplay) return;
        if (event.sessionKey != null && event.sessionKey != widget.threadKey) {
          return;
        }
        if (event.hostNotified) {
          // Background runs have no manual chat stream subscription.
          _requestReplay();
          return;
        }
        // Tell the host the live completion was rendered, so a later replay does
        // not flag the run `while_away`. Best effort: a lost ack only costs a
        // redundant "Answer ready" badge, so a failure is swallowed.
        final runId = event.runId;
        final controller = _controller;
        if (runId != null && controller != null && _ackedRuns.add(runId)) {
          unawaited(controller.sendRunAck(runId).catchError((Object _) {}));
        }
        // WS-7 anti-duplicate rule, app side: the host saw a controller and
        // does not push, so if the app is in the background the toast is
        // ours. The service reads the lifecycle; in the foreground it is a
        // no-op.
        unawaited(
          CoworkNotifications.instance.onLiveDone(
            widget.threadKey,
            runId: runId,
          ),
        );
      case CoworkRelayDelta():
      case CoworkRelayUser():
      case CoworkRelayReasoning():
      case CoworkRelayTool():
      case CoworkRelayFile():
      case CoworkRelaySubagent():
      case CoworkRelayRunError():
      case CoworkRelayRunState():
      case CoworkRelayDebugContext():
      case CoworkRelayRoomTurn():
      case CoworkRelayRoomDone():
      case CoworkRelayRoomHistory():
      case CoworkRelayBrowserData():
      case CoworkRelayBrowserView():
      case CoworkRelayAutomation():
      case CoworkRelayAutomationList():
      case CoworkRelayDocuments():
      case CoworkRelaySkillsList():
      case CoworkRelayAgentList():
        // Transcript events belong to the adapter and the replay loader; room
        // and browser frames to the shell's own pages; automation frames to
        // the automations source; the coworker names (agent_list) to the
        // shell's roster. Nothing to do here.
        break;
    }
  }

  void _clearSecretRequest() {
    for (final c in _secretFields.values) {
      c.dispose();
    }
    _secretFields.clear();
    _secretRequest = null;
    _secretsBusy = false;
  }

  /// Save what the user typed and answer the host. An empty field for a name
  /// that is already set keeps the stored value; an empty field for an unset
  /// name stays missing. The frame carries the request id, so the blocked run
  /// continues whatever was (not) entered.
  Future<void> _submitSecretRequest() async {
    final request = _secretRequest;
    if (request == null || _secretsBusy) return;
    setState(() => _secretsBusy = true);
    final entered = <String, String>{
      for (final e in _secretFields.entries)
        if (e.value.text.isNotEmpty) e.key: e.value.text,
    };
    try {
      if (entered.isEmpty) {
        await SecretsService.instance.answerUnchanged(request.requestId);
      } else {
        await SecretsService.instance.setMany(
          entered,
          requestId: request.requestId,
        );
      }
    } catch (_) {
      // The host times out on its own; nothing to surface.
    }
    if (!mounted) return;
    setState(_clearSecretRequest);
  }

  /// The user does not have (or want to give) the keys: tell the host so the
  /// run continues with `missing` instead of waiting out the timeout.
  Future<void> _skipSecretRequest() async {
    final request = _secretRequest;
    if (request == null || _secretsBusy) return;
    setState(() => _secretsBusy = true);
    try {
      await SecretsService.instance.answerUnchanged(request.requestId);
    } catch (_) {
      // See above.
    }
    if (!mounted) return;
    setState(_clearSecretRequest);
  }

  /// Answer a here.now publish approval. Idempotent: once a decision is sent
  /// the buttons are gone, so the executor never gets two answers for one
  /// publish.
  void _decideApproval(bool approved) {
    final request = _approval;
    if (request == null || _approvalDecision != null) return;
    unawaited(
      _controller
          ?.sendApprovalDecision(
            approvalId: request.approvalId,
            approved: approved,
          )
          .catchError((Object _) {}),
    );
    setState(() => _approvalDecision = approved);
  }

  /// Copies the WHOLE thread to the clipboard for debugging (bd cowork-338):
  /// the full transcript, every tool call and command, every artifact, and the
  /// collected `debug_context` payloads, as one structured JSON blob.
  ///
  /// The export itself lives in [ChatDebugExport] so the shell's top-right
  /// action and this view run the same code. Public so a caller holding a
  /// `GlobalKey<CoworkThreadViewState>` can fire it.
  Future<void> copyFullChat() async {
    final note = await ChatDebugExport.copyToClipboard(
      threadKey: widget.threadKey,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(note)));
  }

  /// The ledger is the run's truth: it knows a run is in flight whether this
  /// client started it or adopted it from a `run_state` header.
  bool _running = false;

  void _onLedgerChanged() {
    if (!mounted) return;
    final running = _ledger.isRunning(widget.threadKey);
    if (running != _running) {
      _running = running;
      widget.onRunStateChanged?.call(widget.threadKey, running);
    }
    widget.onActivity?.call(widget.threadKey, DateTime.now());
    _syncRevision();
  }

  void _onLoaderChanged() {
    if (!mounted) return;
    // A delta replay found no local rows to append to: the loader forgot the
    // cursor, and this view asks for the whole thread again (review F2).
    if (_loader.takeReplayWanted(widget.threadKey)) _requestReplay();
    // A run that finished while nobody was attached just replayed into this
    // thread: the answer is on screen, so the host's notification row is
    // consumed and any OS toast for the thread is cleared (WS-7). Acted on
    // ONCE: the flag is cleared first (it notifies, and re-entry sees it
    // down), so a later loader change does not cancel a fresh toast for the
    // next run (review F8). The run id lets a second answer be told from a
    // re-replay of the first (review F7).
    if (_loader.answerReadyFor(widget.threadKey)) {
      final String? runId = _loader.answerReadyRunFor(widget.threadKey);
      _loader.clearAnswerReady(widget.threadKey);
      unawaited(
        CoworkNotifications.instance.onAnswerReplayed(
          widget.threadKey,
          runId: runId,
        ),
      );
    }
    _syncRevision();
  }

  /// Adopt a new replay revision — but never while a run is in flight: the
  /// remount would throw away the answer streaming into the screen right now.
  /// The ledger notifies when the run ends, and this runs again.
  void _syncRevision() {
    final revision = _loader.revisionFor(widget.threadKey);
    if (revision == _revision) return;
    if (_ledger.isRunning(widget.threadKey)) return;
    setState(() => _revision = revision);
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ValueListenableBuilder<CoworkRelayState>(
      valueListenable: controller?.state ?? _startupState,
      builder: (context, state, _) {
        final connected = state.phase == CoworkRelayPhase.paired;
        final chat = _buildChat(context);
        final approval = _approval;
        final secretRequest = _secretRequest;
        final automations = _automations.liveForSession(widget.threadKey);
        final showAutomations = connected && automations.isNotEmpty;
        // Keep the renderer at the same keyed position across connection
        // changes: local history, scroll position and drafts remain available.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, state, showAutomations ? automations : null),
            if (connected && approval != null)
              _buildApprovalBar(context, approval),
            if (connected && secretRequest != null)
              _buildSecretRequestBar(context, secretRequest),
            if (showAutomations && !_automationsCollapsed)
              _buildAutomationCards(context, automations),
            Expanded(key: const ValueKey('persistent-chat'), child: chat),
            if (!connected && controller != null && _showConnectBar)
              _buildConnectBar(context, state),
          ],
        );
      },
    );
  }

  // --- the header ------------------------------------------------------------

  /// The one bar above the thread. It carries what used to be scattered over
  /// the same band with nothing to group it: the coworker and the connection,
  /// the running automation, and every action on the thread — this view's own
  /// Documents plus whatever the shell hands down ([CoworkThreadView.actions]),
  /// all through one widget so they share a glyph size, a hit box and a
  /// tooltip.
  ///
  /// [automations] is null when there is nothing running, which is what hides
  /// the chip.
  Widget _buildHeader(
    BuildContext context,
    CoworkRelayState state,
    List<CoworkAutomation>? automations,
  ) {
    // The phone gets the dense shape: the floating chrome above already shows
    // the coworker, its face and its presence, and two titles read as two bars.
    final bool dense = !_useDesktopChat(context);
    return CoworkThreadHeader(
      title: widget.title,
      subtitle: widget.subtitle,
      // The phone has its own floating chrome with the coworker on it, so the
      // dense header keeps no subject block and no parked call.
      agent: dense ? null : widget.headerAgent,
      onOpenProfile: widget.onOpenAgentProfile,
      showCallTargets: !dense,
      onOpenScreen: widget.onOpenAgentScreen,
      connection: switch (state.phase) {
        CoworkRelayPhase.paired => CoworkThreadConnection.live,
        CoworkRelayPhase.connecting ||
        CoworkRelayPhase.pairing ||
        CoworkRelayPhase.idle => CoworkThreadConnection.connecting,
        CoworkRelayPhase.error ||
        CoworkRelayPhase.closed => CoworkThreadConnection.down,
      },
      automationLabel: automations == null
          ? null
          : _automationLabel(automations),
      automationPaused:
          automations != null &&
          automations.length == 1 &&
          automations.first.isPaused,
      automationExpanded: !_automationsCollapsed,
      onToggleAutomations: automations == null
          ? null
          : () =>
                setState(() => _automationsCollapsed = !_automationsCollapsed),
      actions: <CoworkThreadAction>[
        CoworkThreadAction(
          icon: Icons.folder_open_outlined,
          tooltip: 'Documents',
          onPressed: () => _openDocuments(context),
        ),
        ...widget.actions,
      ],
      leadingInset: dense ? 0 : widget.leadingInset,
      topInset: dense ? widget.topInset : 0,
      dense: dense,
    );
  }

  /// One automation reads as itself; several read as a count, because the
  /// chip has room for one name and no more.
  String _automationLabel(List<CoworkAutomation> automations) {
    if (automations.length > 1) return '${automations.length} automations';
    final a = automations.first;
    return '${a.name} · ${a.isPaused ? 'Paused' : 'Active'}';
  }

  void _openDocuments(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => ChatDocumentsPanel(
        sessionKey: widget.threadKey,
        controller: _controller,
      ),
    );
  }

  /// The imported chuk_chat renderer. Everything CoWork-specific about it is in
  /// these arguments:
  ///
  ///  * `selectedChatId` is the thread key, so the screen's chat id, the
  ///    executor's session key and the cache row all name one thing.
  ///  * `toolCallingEnabled` / `toolDiscoveryMode` are **false**: the host runs
  ///    every tool, the client must never dispatch one.
  ///  * the three "show" flags follow the verbose toggle — quiet by default,
  ///    full log on demand.
  Widget _buildChat(BuildContext context) {
    // Do not mount the screen before the cache is readable: it would look its
    // thread up, miss, and throw the history away for the rest of the session
    // (see [_cacheReady]). Deliberately blank rather than a spinner — the wait
    // is a frame or two, and a spinner that flashes on every launch reads as
    // trouble.
    if (!_cacheReady) return const SizedBox.expand();
    final config = widget.shellConfig;
    // The screen reads its rows once, on mount. A replay that rewrote the cache
    // bumps the revision, which changes the key, which remounts it on fresh
    // rows — the only way to repaint history without editing an imported file.
    final key = ValueKey<String>('cowork-chat-${widget.threadKey}-$_revision');
    if (_useDesktopChat(context)) {
      return ChukChatUIDesktop(
        key: key,
        onToggleSidebar: _noopToggleSidebar,
        selectedChatId: widget.threadKey,
        onChatIdChanged: _onChatIdChanged,
        isSidebarExpanded: false,
        isCompactMode: false,
        showReasoningTokens: AppThemeService.instance.showReasoningTokens,
        showModelInfo: config?.showModelInfo ?? _verbose,
        showTps: _verbose,
        showToolCalls: _verbose,
        toolCallingEnabled: false,
        toolDiscoveryMode: false,
        autoSendVoiceTranscription: config?.autoSendVoiceTranscription ?? false,
        onOpenModelSettings: widget.onOpenModelScreen == null
            ? null
            : () async => widget.onOpenModelScreen!(),
      );
    }
    return ChukChatUIMobile(
      key: key,
      // Zero, not [CoworkThreadView.topInset]: the header above already sits
      // below the floating chrome, so the list starts under the header and
      // must not reserve the chrome's height a second time.
      topInset: 0,
      onToggleSidebar: _noopToggleSidebar,
      selectedChatId: widget.threadKey,
      onChatIdChanged: _onChatIdChanged,
      isSidebarExpanded: false,
      showReasoningTokens: AppThemeService.instance.showReasoningTokens,
      showModelInfo: config?.showModelInfo ?? _verbose,
      showTps: _verbose,
      showToolCalls: _verbose,
      toolCallingEnabled: false,
      toolDiscoveryMode: false,
      autoSendVoiceTranscription: config?.autoSendVoiceTranscription ?? false,
    );
  }

  /// The sidebar is the shell's (the Agents roster), not the chat screen's.
  void _noopToggleSidebar() {}

  /// CoWork's chat id is the thread key and never changes under the screen, so
  /// this only keeps the shared selection pointer honest.
  void _onChatIdChanged(String? id) {
    ChatStorageService.selectedChatId = id ?? widget.threadKey;
  }

  /// Desktop chrome for desktop, web and tablets; the phone layout only for a
  /// real phone-sized mobile screen. Same rule as chuk's `root_wrapper_io`.
  bool _useDesktopChat(BuildContext context) {
    if (widget.phoneLayout) return false;
    if (kPlatformMobile) return false;
    if (kPlatformDesktop) return true;
    if (kIsWeb) return true;
    final platform = defaultTargetPlatform;
    final isMobilePlatform =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    if (!isMobilePlatform) return true;
    return MediaQuery.sizeOf(context).width >= kTabletBreakpoint;
  }

  // --- how the connection shows -----------------------------------------------

  /// The connection is not something the user manages. Once paired the socket
  /// is simply up, it comes back on its own after a drop, and the app never
  /// waits to be told to reconnect — so the whole state is the small dot in the
  /// header: nothing sits on top of the chat, and a connect in flight no longer
  /// draws a progress bar either. A bar that appears for a second on every
  /// launch reads as breakage; the dot does not (bead cowork-y6q).

  /// Whether the bottom bar has anything worth saying.
  ///
  /// A device with no pairing needs the code form — that is the one case where
  /// the user must act. A paired device reconnects by itself, so the bar earns
  /// its place only once that has visibly failed, or once the user disconnected
  /// on purpose. Anything in between is chatter about a socket that is already
  /// on its way back.
  bool get _showConnectBar {
    if (_storedPairing == null) return true;
    return _manuallyDisconnected || _failedReconnects >= 3;
  }

  // --- the standing secret request --------------------------------------------

  /// One field per name the model asked for. A name already set shows a
  /// "set" badge and may be left blank; values are typed obscured and go
  /// nowhere but [SecretsService]. Skip answers `missing` for the open names.
  Widget _buildSecretRequestBar(
    BuildContext context,
    CoworkRelaySecretRequest request,
  ) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: ValueListenableBuilder<List<String>>(
          valueListenable: SecretsService.instance.names,
          builder: (context, setNames, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.key_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'The agent needs API keys',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (request.purpose.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    request.purpose,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                for (final name in request.names)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      key: ValueKey<String>('secret-field-$name'),
                      controller: _secretFields[name],
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      enabled: !_secretsBusy,
                      decoration: InputDecoration(
                        labelText: name,
                        isDense: true,
                        border: const OutlineInputBorder(),
                        helperText: setNames.contains(name)
                            ? 'Already set. Leave blank to keep it.'
                            : null,
                        suffixIcon: setNames.contains(name)
                            ? const Icon(Icons.check, size: 18)
                            : null,
                      ),
                      onSubmitted: (_) => _submitSecretRequest(),
                    ),
                  ),
                Text(
                  'The agent never sees a value; outputs show '
                  '[REDACTED:NAME]. Values under 8 characters are not masked.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _secretsBusy ? null : _submitSecretRequest,
                      child: const Text('Save keys'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _secretsBusy ? null : _skipSecretRequest,
                      child: const Text('Skip'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // --- this thread's automations -----------------------------------------------

  void _onAutomationsChanged() {
    if (mounted) setState(() {});
  }

  /// The active and paused automations of this thread, with Pause / Resume /
  /// Cancel — the list the header's chip opens. Nothing changes until the
  /// host's event lands; the source folds it and this view repaints.
  Widget _buildAutomationCards(
    BuildContext context,
    List<CoworkAutomation> automations,
  ) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in automations)
            AutomationCard(
              key: ValueKey<String>('thread-automation-${a.id}'),
              automation: a,
              compact: true,
              onPause: () => _automations.control(a.id, 'pause'),
              onResume: () => _automations.control(a.id, 'resume'),
              onCancel: () => _automations.control(a.id, 'cancel'),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  // --- the standing approval --------------------------------------------------

  /// A here.now publish the user must answer before the blocked run continues.
  /// It reuses the imported [AskUserCard], so the two option buttons look and
  /// behave exactly like the ones the renderer draws for an `ask_user` call.
  Widget _buildApprovalBar(
    BuildContext context,
    CoworkRelayApprovalRequest request,
  ) {
    final theme = Theme.of(context);
    final decision = _approvalDecision;
    final files = request.fileCount == 1
        ? '1 file'
        : '${request.fileCount} files';
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.public, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Publish to the web?',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${request.name.isEmpty ? request.path : request.name} · $files · '
              '${_humanBytes(request.totalBytes)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (request.public)
              Text(
                'This site will be PUBLIC — anyone with the link can view it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (decision == null)
              AskUserCard(
                options: const <String>['Publish', 'Deny'],
                onSelect: (answer) => _decideApproval(answer == 'Publish'),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Row(
                  children: [
                    Icon(
                      decision ? Icons.check_circle_outline : Icons.block,
                      size: 16,
                      color: decision
                          ? theme.colorScheme.primary
                          : theme.hintColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      decision ? 'Published' : 'Denied',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: decision
                            ? theme.colorScheme.primary
                            : theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 1024 -> "1.0 KB". A plain binary size, no locale or package dependency.
  static String _humanBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = <String>['KB', 'MB', 'GB'];
    double value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(1)} ${units[unit]}';
  }

  // --- bottom bar: the connect affordance ------------------------------------

  Widget _buildConnectBar(BuildContext context, CoworkRelayState state) {
    final theme = Theme.of(context);
    final banner =
        _localError ??
        (state.phase == CoworkRelayPhase.error ? state.detail : null) ??
        (state.phase == CoworkRelayPhase.closed
            ? (state.detail ?? 'Disconnected')
            : null);
    // Already paired once: no code form. A compact reconnect + forget bar.
    if (widget.pairingStore != null && _storedPairing != null) {
      return _buildReconnectBar(context, banner);
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Connect to a host to start chatting.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.hintColor),
              ),
            ),
            if (banner != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        banner,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 5,
                  child: TextField(
                    controller: _hostController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: TextField(
                    controller: _codeController,
                    enabled: !_busy,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Pairing code',
                      hintText: 'chan1234-428913',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _connect(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _connect,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Connect'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The bottom bar shown when the app is paired but not currently connected:
  /// a status line plus Reconnect (keeps the pairing) and Forget (deletes it).
  Widget _buildReconnectBar(BuildContext context, String? banner) {
    final theme = Theme.of(context);
    final reconnecting = _busy;
    final status =
        banner ??
        (reconnecting
            ? 'Reconnecting…'
            : 'Paired with ${_storedPairing!.peerDeviceId}. Not connected.');
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                status,
                style: banner != null
                    ? TextStyle(color: theme.colorScheme.error)
                    : theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: reconnecting ? null : _forget,
              child: const Text('Forget'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: reconnecting ? null : _reconnect,
              child: reconnecting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Reconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
