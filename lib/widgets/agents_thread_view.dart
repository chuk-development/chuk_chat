import 'dart:async';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kDebugMode, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/chat_debug_export.dart';
import 'package:chuk_chat/pages/agents_pairing_page.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/notifications/agents_notifications.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/widgets/ask_user_card.dart';
import 'package:chuk_chat/widgets/automation_card.dart';
import 'package:chuk_chat/widgets/chat_documents_panel.dart';
import 'package:chuk_chat/widgets/agents_thread_header.dart';

/// The Agents chat surface: the imported chuk_chat chat screen, wired to the
/// agent running on the user's own host.
///
/// This widget owns two halves that never mix:
///
///  * **The transport.** Building the [AgentsRelayController], the pairing /
///    connect bar, auto-reconnect with a watchdog, provisioning the account
///    token, and asking the host to replay the thread. None of that is on
///    screen once the socket is up: the connection is not the user's job.
///  * **The window.** Once paired the body IS `ChukChatUIDesktop` /
///    `ChukChatUIMobile` — chuk_chat's renderer, imported verbatim. It reads
///    the thread out of [ChatStorageService] (the local instant-paint cache
///    the replay loader fills) and sends through
///    `WebSocketChatService.sendStreamingChat`, which is Agents's relay
///    adapter. Nothing about the chat is drawn here.
///
/// One view serves many threads. [threadKey] is the executor's `session_key`
/// AND the imported screen's `selectedChatId` — one id, so a send, a replay and
/// a cache row all name the same thing.
///
/// All transport lives behind [AgentsRelayController], so the UI is the same
/// whether it drives a real socket or a fake in a widget test.
class AgentsThreadView extends StatefulWidget {
  const AgentsThreadView({
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
    this.actions = const <AgentsThreadAction>[],
    this.leadingInset = 0,
    this.topInset = 0,
    this.phoneLayout = false,
  });

  /// Builds the transport controller. Async because a real client generates a
  /// device signing key first. Widget tests return a fake synchronously. Called
  /// again to get a fresh controller after a disconnect.
  final Future<AgentsRelayController> Function() controllerBuilder;

  /// Supplies the account session that gets provisioned once paired.
  final AccountSessionSource sessionSource;

  /// Called with the live transport controller whenever it is built or rebuilt,
  /// so a parent (the shell) can share the one socket — e.g. to feed a room
  /// thread the same inbound stream. The parent must not dispose it; this view
  /// owns its lifecycle.
  final void Function(AgentsRelayController controller)? onController;

  /// Persistent trust store. When provided and a pairing is stored, the view
  /// auto-reconnects with no code and offers a separate "Forget" action. When
  /// null the view has no persistence: it always shows the code connect form
  /// (the legacy behaviour, used by widget tests that inject a fake controller).
  final AgentsPairingStore? pairingStore;

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
  /// show "working" against the right coworker. Driven off [AgentsRunLedger].
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
  final AgentsAgent? headerAgent;

  /// Tap on the header pill — the coworker's profile page.
  final void Function(AgentsAgent agent)? onOpenAgentProfile;

  /// Opens the live view of the coworker's screen. Null parks the target.
  final VoidCallback? onOpenAgentScreen;

  /// Actions the SHELL owns but this thread's header shows: agent controls,
  /// Control Rooms, the agent's browser, Copy Debug Chat. They used to float
  /// over this view in a row of their own, which is why the top of the screen
  /// read as leftovers; the header groups them with the view's own Documents
  /// button and gives them one size and one spacing.
  final List<AgentsThreadAction> actions;

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
  State<AgentsThreadView> createState() => AgentsThreadViewState();
}

class AgentsThreadViewState extends State<AgentsThreadView>
    with WidgetsBindingObserver {
  bool _wasBackgrounded = false;
  bool _rebuildingForResume = false;
  late final TextEditingController _hostController;
  final TextEditingController _codeController = TextEditingController();

  AgentsRelayController? _controller;
  StreamSubscription<AgentsRelayInbound>? _inboundSub;

  final AgentsRelayLink _link = AgentsRelayLink.instance;
  final AgentsRunLedger _ledger = AgentsRunLedger.instance;
  final AgentsReplayLoader _loader = AgentsReplayLoader.instance;

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

  /// The replay revision this view has painted for [AgentsThreadView.threadKey].
  /// The imported screen reads its rows once, in `initState`, so a replay that
  /// rewrites the cache under it has to remount it — the revision is the key.
  int _revision = 0;

  /// Extra turns of the same key, for rows that arrive from the CACHE rather
  /// than from a replay. Only a completed replay moves the loader's revision,
  /// so a screen that mounted on a cache miss — the SQLite read landed a beat
  /// after the mount, which is the whole cold-start case — would keep its
  /// empty transcript for the rest of the session (bead cowork-91pn).
  int _cacheRevision = 0;

  /// Watches the chat store for the late arrival described above.
  StreamSubscription<String?>? _storeSub;

  /// Whether this thread already had rows in memory when the screen mounted.
  /// True means the screen is showing a transcript, and a later cache write is
  /// then the app's OWN write (a send, a live turn) — never a reason to remount
  /// and throw away what the reader is looking at or typing.
  bool _mountedWithRows = false;

  /// A here.now publish waiting on the user. The run is BLOCKED on the executor
  /// until it is answered, so it is a standing card, not a fleeting prompt.
  AgentsRelayApprovalRequest? _approval;
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
  AgentsRelaySecretRequest? _secretRequest;
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
  final _startupState = ValueNotifier<AgentsRelayState>(
    const AgentsRelayState(phase: AgentsRelayPhase.connecting),
  );

  /// The persisted trust, loaded once at startup. Non-null means "already
  /// paired": auto-reconnect, hide the code form, offer Forget.
  AgentsStoredPairing? _storedPairing;

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
    WidgetsBinding.instance.addObserver(this);
    _hostController = TextEditingController(text: widget.defaultHostUrl);
    // The link's fan-out outlives every controller, so this one subscription
    // survives reconnects. It carries only what this view still owns: the
    // approval prompt and the live `run_ack`.
    _inboundSub = _link.inbound.listen(_onInbound);
    _loader.attach();
    _running = _ledger.isRunning(widget.threadKey);
    _ledger.addListener(_onLedgerChanged);
    // A run that goes quiet is asked about rather than animated for ever.
    _ledger.onRunSilent = _onRunSilent;
    _reconcileOnOpen();
    _loader.addListener(_onLoaderChanged);
    _automations.attach();
    _automations.addListener(_onAutomationsChanged);
    _revision = _loader.revisionFor(widget.threadKey);
    _storeSub = ChatStorageService.changes.listen(_onChatStoreChanged);
    // The Retry button in the imported bubble calls
    // `OfflineRetryManager.instance.retryNow()`. With no host on the other end
    // that must mean "go get the host": the manager has no transport of its
    // own, so this view lends it one for as long as it is mounted.
    OfflineRetryManager.instance.registerReconnect(
      () => reconnect(force: true),
    );
    _bootstrap();
    // The verbose flag is one shared singleton: mirror it now and rebuild on
    // every change.
    VerboseService.instance.addListener(_onVerboseChanged);
    _loadVerbose();
    // The "show reasoning" setting reflows the transcript live, like chuk.
    AppThemeService.instance.addListener(_onThemeChanged);
    MobileChatPreferences.instance.addListener(_onThemeChanged);
    unawaited(MobileChatPreferences.instance.load());
    // Safety net (see [_watchdogTimer]): re-arm reconnect on a slow cadence.
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _watchdogTick(),
    );
  }

  @override
  void didUpdateWidget(AgentsThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.threadKey != widget.threadKey) {
      _running = _ledger.isRunning(widget.threadKey);
      _reconcileOnOpen();
      // A different conversation. Point the link and the cache at it and ask
      // the host for whatever this client is missing.
      if (widget.threadKey.isNotEmpty) {
        _link.sessionKey.value = widget.threadKey;
        ChatStorageService.selectedChatId = widget.threadKey;
      }
      _revision = _loader.revisionFor(widget.threadKey);
      _cacheRevision = 0;
      _mountedWithRows = _threadHasRows;
      _approval = null;
      _approvalDecision = null;
      _clearSecretRequest();
      _requestReplay();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    OfflineRetryManager.instance.registerFlush(widget.threadKey, null);
    OfflineRetryManager.instance.registerReconnect(null);
    _autoReconnectTimer?.cancel();
    _watchdogTimer?.cancel();
    VerboseService.instance.removeListener(_onVerboseChanged);
    AppThemeService.instance.removeListener(_onThemeChanged);
    MobileChatPreferences.instance.removeListener(_onThemeChanged);
    _ledger.removeListener(_onLedgerChanged);
    // Tear-offs of the same method on the same state object compare equal,
    // so this only clears the hook when it is still ours.
    if (_ledger.onRunSilent == _onRunSilent) _ledger.onRunSilent = null;
    _loader.removeListener(_onLoaderChanged);
    _automations.removeListener(_onAutomationsChanged);
    _controller?.state.removeListener(_onStateChanged);
    _startupState.dispose();
    _inboundSub?.cancel();
    _storeSub?.cancel();
    _controller?.dispose();
    _hostController.dispose();
    _codeController.dispose();
    _clearSecretRequest();
    super.dispose();
  }

  // --- lifecycle -------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wasBackgrounded = true;
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      // Android may leave a suspended socket marked paired. Replace it on
      // resume rather than waiting for a heartbeat or an old backoff timer.
      if (_storedPairing != null && !_manuallyDisconnected) {
        unawaited(reconnect(force: true));
        return;
      }
      // Still paired and nothing to reconnect: the queue may still hold a
      // prompt typed while the phone was away. The `paired` transition is not
      // the only moment a flush is owed — that transition may never come
      // again on a socket that stayed up (bead cowork-i7sd follow-up). Each
      // entry has its own backoff, so a resume cannot hammer the host.
      final controller = _controller;
      if (controller != null && controller.state.value.isPaired) {
        unawaited(_flushOutbox(controller));
      }
    }
  }

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
    // An empty key means "nothing selected yet"; pointing the link and the
    // store at it would only name a conversation that does not exist.
    if (widget.threadKey.isNotEmpty) {
      _link.sessionKey.value = widget.threadKey;
      ChatStorageService.selectedChatId = widget.threadKey;
    }

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
    // The metadata read above fills the sidebar, not this thread. The screen
    // looks its thread up in memory ONCE on mount and treats a miss as a new
    // chat, so the one thread the reader actually opened is read in full
    // before the gate opens: that is what puts the conversation on screen in
    // the first frame of a cold start, with no socket and no cloud (bead
    // cowork-91pn). A miss is not an error — the host's replay still fills it.
    if (widget.threadKey.isNotEmpty) {
      try {
        await ChatStorageService.loadFullChat(widget.threadKey);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[cowork-thread] thread cache read failed: $error');
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _mountedWithRows = _threadHasRows;
      _cacheReady = true;
    });
  }

  /// Whether the store holds a transcript for this thread right now.
  bool get _threadHasRows {
    if (widget.threadKey.isEmpty) return false;
    final rows = ChatStorageService.getChatById(
      widget.threadKey,
    )?.messagesOrNull;
    return rows != null && rows.isNotEmpty;
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
    if (phase == AgentsRelayPhase.paired) {
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
      // Then, and only then, the prompts that were typed while the socket was
      // down. Replay first: the host's transcript is the base every local row
      // aligns against, and a prompt sent before it races its own echo back up
      // the wire (beads cowork-i7sd, cowork-4rpt).
      //
      // The same closure is what the Retry button runs: while a host is on the
      // other end, "retry" means "send the backlog now", not "reconnect".
      OfflineRetryManager.instance.registerFlush(
        widget.threadKey,
        () => _flushOutbox(controller),
      );
      unawaited(_flushOutbox(controller));
      return;
    }
    // Not paired any more: Retry falls back to fetching the host.
    OfflineRetryManager.instance.registerFlush(widget.threadKey, null);
    if ((phase == AgentsRelayPhase.closed || phase == AgentsRelayPhase.error) &&
        _storedPairing != null &&
        !_manuallyDisconnected) {
      // A run belongs to the host process, not to this socket: a dropped
      // connection does NOT end it, so the run phase is left exactly as it is.
      _scheduleAutoReconnect();
    }
  }

  /// Sends what the user typed while the host was unreachable.
  ///
  /// Nothing is retried forever: [AgentsTaskOutbox] gives up on an entry after
  /// its own attempt cap, so one prompt the host will never take cannot block
  /// the queue behind it.
  Future<int> _flushOutbox(AgentsRelayController controller) async {
    final String sessionKey = widget.threadKey;
    if (sessionKey.isEmpty) return 0;
    try {
      final int sent = await AgentsTaskOutbox.flush(sessionKey, (task) async {
        await controller.sendTask(
          task.prompt,
          sessionKey: sessionKey,
          modelId: task.modelId,
          providerSlug: task.providerSlug,
          reasoningEffort: task.reasoningEffort,
        );
        // It is on the wire: the bubble stops saying "waiting" and stops
        // offering Retry for something already on its way.
        await AgentsQueuedMarks.clearMark(
          sessionKey: sessionKey,
          queueId: task.localId,
        );
      });
      if (sent > 0 && kDebugMode) {
        debugPrint(
          '[agents-outbox] sent $sent queued prompt(s) for $sessionKey',
        );
      }
      return sent;
    } catch (error) {
      // A flush that fails leaves the queue where it is; the next pair tries
      // again. It must never take the reconnect down with it.
      if (kDebugMode) {
        debugPrint('[agents-outbox] flush failed for $sessionKey: $error');
      }
      return 0;
    }
  }

  /// Asks the host to re-stream this thread from the replay cursor.
  void _requestReplay() {
    final controller = _controller;
    if (controller == null || !controller.state.value.isPaired) return;
    final sessionKey = widget.threadKey;
    // Nothing is selected: there is no conversation to replay, and asking for
    // one would mint a cursor namespace for a key nobody ever writes.
    if (sessionKey.isEmpty) return;
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
    if (!mounted) return;
    // The run ceiling rides this tick rather than a timer of the ledger's own:
    // the ledger is process-wide, and a timer it armed would go on firing long
    // after the thread that cared about the run was gone. A run that has
    // produced nothing for minutes is asked about here, and declared lost if
    // nothing answers (bead cowork-gnr8).
    _ledger.sweep();
    if (widget.pairingStore == null || _storedPairing == null) return;
    if (_manuallyDisconnected || _busy || _autoReconnectTimer != null) return;
    final phase = _controller?.state.value.phase;
    final down =
        phase == null ||
        phase == AgentsRelayPhase.closed ||
        phase == AgentsRelayPhase.error;
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
      // The authenticated host may have migrated our loopback trust to its
      // cloud route since this view was mounted. Do not keep dialling a stale
      // in-memory URL after a host restart.
      final latest = await widget.pairingStore?.loadPairing() ?? stored;
      if (!mounted) return;
      _storedPairing = latest;
      await controller.reconnect(hostUrl: latest.hostUrl, pairing: latest);
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

  /// Retry stored trust without exposing transport controls in the chat.
  Future<void> reconnect({bool force = false}) async {
    if (_busy ||
        _rebuildingForResume ||
        (!force && _controller?.state.value.isPaired == true)) {
      return;
    }
    _autoReconnectTimer?.cancel();
    _autoReconnectTimer = null;
    _manuallyDisconnected = false;
    _reconnectAttempts = 0;
    _rebuildingForResume = true;
    try {
      await _rebuildController();
      await _reconnect();
    } finally {
      _rebuildingForResume = false;
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

  Future<void> _persistTrust(
    AgentsRelayController controller, {
    Uri? hostUrl,
  }) async {
    final store = widget.pairingStore;
    final established = controller.establishedTrust;
    if (store == null || established == null) return;
    // The address that gets remembered is the RECONNECT form: the relay plus
    // the host's device id. The pairing form carries the single-use pairing
    // channel, which must never be dialled twice and is worthless after the
    // ceremony — a trust record holding it would ask the relay to claim a
    // channel that no longer exists, on every launch, forever.
    final trust = hostUrl == null
        ? established
        : AgentsStoredPairing(
            hostUrl: hostUrl,
            channelId: established.channelId,
            channelKey: established.channelKey,
            peerDeviceId: established.peerDeviceId,
            peerPublicKey: established.peerPublicKey,
          );
    await store.savePairing(trust);
    if (mounted) setState(() => _storedPairing = trust);
  }

  /// The QR path, and the whole of what a phone ever does to get linked: open
  /// the camera, scan the code the computer shows, done. The typed code lands
  /// here too — same invite, same ceremony, same result.
  Future<void> _pairFromInvite(AgentsPairingInvite invite) async {
    final controller = _controller;
    if (controller == null || _busy) return;
    setState(() {
      _localError = null;
      _busy = true;
    });
    try {
      final address = AgentsCloudRelayAddress.forInvite(invite);
      await controller.connect(
        hostUrl: address.toUri(),
        pairingCode: invite.pairingCode,
      );
      // Paired: hand the executor the account token (ExecutorProvisioning).
      final session = widget.sessionSource.current();
      if (session != null) {
        await controller.provisionAccount(session);
      }
      // The relay's own answer to the claim is the ONLY place the host's relay
      // device id comes from, so that is what the trust record remembers — not
      // the id the ceremony carried, which is the host's, not the relay's view
      // of it. Falls back to the ceremony's when the dial was local.
      final targetDeviceId =
          AgentsCloudRelaySocket.learnedTarget(
            base: invite.relayBase,
            pairingChannel: invite.pairingChannel,
          ) ??
          controller.establishedTrust?.peerDeviceId;
      await _persistTrust(
        controller,
        hostUrl: targetDeviceId == null
            ? null
            : AgentsCloudRelayAddress.forHost(
                base: invite.relayBase,
                targetDeviceId: targetDeviceId,
              ).toUri(),
      );
    } catch (error) {
      if (mounted) setState(() => _localError = _pairingFailureText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One plain sentence for whatever went wrong. The user is not shown a code,
  /// a URL or an exception type — there is nothing they could do with any of it.
  static String _pairingFailureText(Object error) {
    if (error is AgentsCloudRelayException) return error.message;
    return 'That did not work. Make sure Agents is running on your computer, '
        'then scan the code again.';
  }

  Future<void> _openPairingScreen() async {
    final invite = await AgentsPairingPage.show(context);
    if (invite == null || !mounted) return;
    await _pairFromInvite(invite);
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

  void _onInbound(AgentsRelayInbound event) {
    if (!mounted) return;
    switch (event) {
      case AgentsRelayApprovalRequest():
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
      case AgentsRelaySecretRequest():
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
      case AgentsRelayDone():
        if (event.isReplay) return;
        if (event.sessionKey != null && event.sessionKey != widget.threadKey) {
          return;
        }
        final runtime = ChatRuntimeRegistry.instance.lookup(widget.threadKey);
        final localStreamActive =
            runtime?.isStreaming.value == true ||
            runtime?.isSending.value == true;
        // A terminal ENDS the run, whatever else is going on. The adapter's
        // own subscription is gone after a stop or a page teardown, so this is
        // often the only listener left to see it; leaving the run open here is
        // what left the thread typing for ever (bead cowork-gnr8). Finishing
        // twice is harmless — the ledger's terminal is idempotent — and the
        // replay is still only asked for when no local stream owns the turn.
        if (_ledger.isRunning(widget.threadKey)) {
          _ledger.finish(
            widget.threadKey,
            finalAnswer: event.finalAnswer,
            reason: event.reason,
            runId: event.runId,
            startedAt: event.startedAt,
            finishedAt: event.finishedAt,
          );
          if (!localStreamActive && !event.hostNotified) _requestReplay();
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
          AgentsNotifications.instance.onLiveDone(
            widget.threadKey,
            runId: runId,
          ),
        );
      case AgentsRelayHeartbeat():
      case AgentsRelayDelta():
      case AgentsRelayUser():
      case AgentsRelayReasoning():
      case AgentsRelayTool():
      case AgentsRelayFile():
      case AgentsRelaySubagent():
      case AgentsRelayRunError():
      case AgentsRelayRunState():
      case AgentsRelayDebugContext():
      case AgentsRelayRoomTurn():
      case AgentsRelayRoomDone():
      case AgentsRelayRoomHistory():
      case AgentsRelayBrowserData():
      case AgentsRelayBrowserView():
      case AgentsRelayAutomation():
      case AgentsRelayAutomationList():
      case AgentsRelayDocuments():
      case AgentsRelaySkillsList():
      case AgentsRelayAgentList():
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
  /// `GlobalKey<AgentsThreadViewState>` can fire it.
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
      setState(() => _running = running);
      widget.onRunStateChanged?.call(widget.threadKey, running);
      if (!running) _onRunClosed();
    }
    widget.onActivity?.call(widget.threadKey, DateTime.now());
    _syncRevision();
  }

  /// A run just ended and left the thread with nothing to show. Never silence:
  /// the reader must be able to tell "stopped" from "still thinking" (bead
  /// cowork-gnr8), so the same line the replay loader writes for the host's
  /// stored terminal is written here for the live one.
  ///
  /// It also puts the composer back to the send target. The wording of the
  /// line is shared with the loader, so the host's copy of the same line folds
  /// into this one on the next replay instead of doubling it
  /// (`appendWithoutRepeats` compares sender and text).
  void _onRunClosed() {
    final key = widget.threadKey;
    // After the frame, not on a timer: a timer would outlive the tree, and the
    // work here is only ever a follow-up to a run that is already over.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.threadKey != key) return;
      final run = _ledger.runFor(key);
      if (run == null || run.running) return;
      _releaseStaleComposer(key);
      final outcome = run.outcome;
      if (outcome == null || !run.endedWithoutAnswer) return;
      final notice = agentsRunEndNotice(outcome);
      if (notice == null) return;
      // Appended to what is on disk. If the imported screen saves the turn it
      // was drawing a moment later, its save wins and the line is simply not
      // there — the host's own copy of it comes back with the next replay,
      // where the loader writes the same wording (`agentsRunEndNotice`).
      unawaited(_loader.appendNotice(key, notice));
    });
  }

  /// The composer goes back to the send target when the run is over.
  ///
  /// The imported screen reads its send-in-flight flag from the thread's
  /// [ChatRuntime], and clears it when the stream finalizes. A stream that was
  /// cancelled instead — the page was disposed while the answer was still
  /// coming — never finalizes, so the flag stays up and the next mount of the
  /// screen shows the red stop target on a thread where nothing runs. The run
  /// is over here, so the flag has nothing left to protect.
  void _releaseStaleComposer(String key) {
    final runtime = ChatRuntimeRegistry.instance.lookup(key);
    if (runtime == null) return;
    if (!runtime.isSending.value && !runtime.isStreaming.value) return;
    // A local stream that is still live owns the turn; leave it alone.
    if (StreamingManager().isStreaming(key)) return;
    runtime.endStream();
  }

  /// The run for [sessionKey] has produced nothing for the ledger's ceiling.
  /// Ask the host what happened to it: the `run_state` header of the answer
  /// either revives the run (the host is still on it) or reconciles it away.
  /// If nothing answers, the ledger's own grace declares it lost.
  void _onRunSilent(String sessionKey) {
    if (!mounted || sessionKey != widget.threadKey) return;
    _requestReplay();
  }

  /// The thread is being opened. A run the ledger still draws as live is
  /// checked against what the host says before the dots come back.
  ///
  /// While paired the check is the replay this view asks for anyway: its
  /// `run_state` header either adopts the run or reconciles it away. With no
  /// socket there is nobody to ask, so a run that has produced nothing for
  /// longer than the ceiling is declared lost rather than animated again.
  void _reconcileOnOpen() {
    final key = widget.threadKey;
    final run = _ledger.runFor(key);
    if (run == null || !run.running) return;
    if (_controller?.state.value.isPaired ?? false) return;
    if (DateTime.now().difference(run.lastActivity) < AgentsRunLedger.ceiling) {
      return;
    }
    _ledger.markLost(key);
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
        AgentsNotifications.instance.onAnswerReplayed(
          widget.threadKey,
          runId: runId,
        ),
      );
    }
    _syncRevision();
  }

  /// The chat cache changed. Remount the screen ONLY when this thread's rows
  /// arrived after it had already mounted with nothing — the cold-start miss.
  ///
  /// Three conditions, all of them load-bearing:
  ///  * the event names THIS thread (a bulk event, id null, names every one);
  ///  * the screen currently has no rows, so nothing on screen is lost;
  ///  * no run is in flight — the same guard [_syncRevision] uses, and for the
  ///    same reason: a remount would eat the answer streaming in right now.
  void _onChatStoreChanged(String? changedId) {
    if (!mounted) return;
    final key = widget.threadKey;
    if (key.isEmpty) return;
    if (changedId != null && changedId != key) return;
    if (_ledger.isRunning(key)) return;
    final chat = ChatStorageService.getChatById(key);
    if (chat == null || !chat.isFullyLoaded || chat.messages.isEmpty) return;
    if (!_screenIsEmpty) return;
    setState(() => _cacheRevision++);
  }

  /// Whether the screen on the tree is showing an empty transcript. The
  /// imported screen owns its rows; what this view can say is that it has
  /// painted no revision of them yet, which is exactly the mount-on-a-miss
  /// case the remount is for.
  bool get _screenIsEmpty =>
      !_mountedWithRows && _revision == 0 && _cacheRevision == 0;

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
    return ValueListenableBuilder<AgentsRelayState>(
      valueListenable: controller?.state ?? _startupState,
      builder: (context, state, _) {
        final connected = state.phase == AgentsRelayPhase.paired;
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
            if (_useDesktopChat(context))
              _buildHeader(context, state, showAutomations ? automations : null)
            else if (approval != null || secretRequest != null)
              SizedBox(height: widget.topInset),
            if (connected && approval != null)
              _buildApprovalBar(context, approval),
            if (connected && secretRequest != null)
              _buildSecretRequestBar(context, secretRequest),
            if (showAutomations &&
                !_automationsCollapsed &&
                (_useDesktopChat(context) ||
                    MobileChatPreferences.instance.showActivity))
              _buildAutomationCards(context, automations),
            Expanded(key: const ValueKey('persistent-chat'), child: chat),
            if (_useDesktopChat(context) &&
                !connected &&
                controller != null &&
                _showConnectBar)
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
  /// Documents plus whatever the shell hands down ([AgentsThreadView.actions]),
  /// all through one widget so they share a glyph size, a hit box and a
  /// tooltip.
  ///
  /// [automations] is null when there is nothing running, which is what hides
  /// the chip.
  Widget _buildHeader(
    BuildContext context,
    AgentsRelayState state,
    List<AgentsAutomation>? automations,
  ) {
    // The phone gets the dense shape: the floating chrome above already shows
    // the coworker, its face and its presence, and two titles read as two bars.
    final bool dense = !_useDesktopChat(context);
    return AgentsThreadHeader(
      title: widget.title,
      subtitle: widget.subtitle,
      // The phone has its own floating chrome with the coworker on it, so the
      // dense header keeps no subject block and no parked call.
      agent: dense ? null : widget.headerAgent,
      onOpenProfile: widget.onOpenAgentProfile,
      showCallTargets: !dense,
      onOpenScreen: widget.onOpenAgentScreen,
      connection: switch (state.phase) {
        AgentsRelayPhase.paired => AgentsThreadConnection.live,
        AgentsRelayPhase.connecting ||
        AgentsRelayPhase.pairing ||
        AgentsRelayPhase.idle => AgentsThreadConnection.connecting,
        AgentsRelayPhase.error ||
        AgentsRelayPhase.closed => AgentsThreadConnection.down,
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
      actions: <AgentsThreadAction>[
        AgentsThreadAction(
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
  String _automationLabel(List<AgentsAutomation> automations) {
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

  /// The imported chuk_chat renderer. Everything Agents-specific about it is in
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
    // No thread selected (a first launch with no roster and no host). The
    // shell no longer invents a placeholder key, so there is nothing to open;
    // mounting the screen on an empty id would give the cache a row nobody
    // asked for and a replay cursor for a conversation that does not exist.
    if (widget.threadKey.isEmpty) return const SizedBox.expand();
    final config = widget.shellConfig;
    // The screen reads its rows once, on mount. A replay that rewrote the cache
    // bumps the revision, which changes the key, which remounts it on fresh
    // rows — the only way to repaint history without editing an imported file.
    final key = ValueKey<String>(
      'agents-chat-${widget.threadKey}-$_revision-$_cacheRevision',
    );
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
      messengerMode: true,
      hostRunActive: _ledger.isRunning(widget.threadKey),
      // Reserve chrome inside the scrollable, not above its viewport: messages
      // can pass behind the floating contact pill like the messenger reference.
      // Action-required bars remain below the header and own their inset.
      topInset: _approval != null || _secretRequest != null
          ? 0
          : widget.topInset,
      onToggleSidebar: _noopToggleSidebar,
      selectedChatId: widget.threadKey,
      onChatIdChanged: _onChatIdChanged,
      isSidebarExpanded: false,
      showReasoningTokens: MobileChatPreferences.instance.showThinking,
      showModelInfo: false,
      showTps: false,
      showToolCalls: MobileChatPreferences.instance.showActivity,
      toolCallingEnabled: false,
      toolDiscoveryMode: false,
      autoSendVoiceTranscription: config?.autoSendVoiceTranscription ?? false,
    );
  }

  /// The sidebar is the shell's (the Agents roster), not the chat screen's.
  void _noopToggleSidebar() {}

  /// Agents's chat id is the thread key and never changes under the screen, so
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
    AgentsRelaySecretRequest request,
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
                    AppIcon(
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
                            ? const AppIcon(Icons.check, size: 18)
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
    List<AgentsAutomation> automations,
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
    AgentsRelayApprovalRequest request,
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
                AppIcon(
                  Icons.public,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
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
                    AppIcon(
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

  Widget _buildConnectBar(BuildContext context, AgentsRelayState state) {
    final theme = Theme.of(context);
    final banner =
        _localError ??
        (state.phase == AgentsRelayPhase.error ? state.detail : null) ??
        (state.phase == AgentsRelayPhase.closed
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
            // The one path a person is meant to take: scan the code the
            // computer shows. Everything below it is the developer's
            // same-machine path and is on its way out.
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FilledButton.icon(
                key: const ValueKey<String>('agents-add-computer'),
                onPressed: _busy ? null : _openPairingScreen,
                icon: const AppIcon(Icons.qr_code_scanner),
                label: const Text('Add your computer'),
              ),
            ),
            if (banner != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    AppIcon(
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
            // The same-machine developer path, and only that: a release build
            // shows no address, no port and no code field. A phone reaches its
            // host through the relay, and the QR above is the whole flow.
            if (kDebugMode)
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
