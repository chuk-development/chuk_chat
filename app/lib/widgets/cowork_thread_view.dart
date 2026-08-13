import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/agent_file_saver.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/agent_markdown.dart';
import 'package:cowork/widgets/agent_run_views.dart';

/// The CoWork chat surface: one scrolling conversation with the agent running
/// on the user's own host.
///
/// It reads like any messenger — the user's messages, the agent's reply
/// streaming in as deltas arrive, the run's tool calls as quiet collapsible
/// lines, reasoning folded away in its own block, files and screenshots as
/// cards — with the composer pinned at the bottom. While a run is in flight the
/// send button becomes **Stop** (§7.1's kill switch, from the user's side).
///
/// The connection is deliberately not on screen: no "connected to", no SAS, no
/// disconnect. While disconnected the bottom bar is a compact connect bar, and
/// only before the very first pairing does it ask for a code.
///
/// One view serves many threads. [threadKey] is the executor's `session_key`, so
/// switching threads switches the conversation on both sides; the log of each
/// thread is kept, so switching back shows it again.
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
  });

  /// Builds the transport controller. Async because a real client generates a
  /// device signing key first. Widget tests return a fake synchronously. Called
  /// again to get a fresh controller after a disconnect.
  final Future<CoworkRelayController> Function() controllerBuilder;

  /// Supplies the account session that gets provisioned once paired.
  final AccountSessionSource sessionSource;

  /// Persistent trust store. When provided and a pairing is stored, the view
  /// auto-reconnects with no code and offers a separate "Forget" action. When
  /// null the view has no persistence: it always shows the code connect form
  /// (the legacy behaviour, used by widget tests that inject a fake controller).
  final CoworkPairingStore? pairingStore;

  /// Prefilled host URL for a local run.
  final String defaultHostUrl;

  /// The executor-side session this view talks to (§4: many threads per agent).
  final String threadKey;

  /// Where a file card writes when the user saves. Injected so a test can prove
  /// the action without a filesystem.
  final AgentFileSaver fileSaver;

  /// Reports whether a run is in flight, and for which thread, so the roster can
  /// show "working" against the right coworker.
  final void Function(String threadKey, bool running)? onRunStateChanged;

  /// Reports that something happened in [threadKey], for "last active".
  final void Function(String threadKey, DateTime when)? onActivity;

  /// Reports the host device id the moment the transport is paired, so the
  /// roster can list the agent that really runs over there.
  final void Function(String peerDeviceId)? onPaired;

  @override
  State<CoworkThreadView> createState() => _CoworkThreadViewState();
}

/// Where a run is, from the user's point of view.
enum _RunPhase { idle, running, stopping }

class _CoworkThreadViewState extends State<CoworkThreadView> {
  late final TextEditingController _hostController;
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  CoworkRelayController? _controller;
  StreamSubscription<CoworkRelayInbound>? _inboundSub;

  /// One log per thread, so switching threads keeps both conversations.
  final Map<String, List<_ThreadEntry>> _logs = <String, List<_ThreadEntry>>{};
  _AssistantEntry? _currentAssistant;
  _ReasoningEntry? _currentReasoning;

  String? _localError;
  bool _busy = false;

  /// One run at a time: the executor serves tasks one after another, so the
  /// phase is per view, not per thread.
  _RunPhase _runPhase = _RunPhase.idle;

  /// The thread whose run is in flight. Events carry no session key, so they
  /// belong to whichever thread started the run — even if the user has since
  /// switched to another one.
  String? _activeRunThread;

  /// The persisted trust, loaded once at startup. Non-null means "already
  /// paired": auto-reconnect, hide the code form, offer Forget.
  CoworkStoredPairing? _storedPairing;

  /// The user tapped Disconnect: stay down until they act, no auto-reconnect.
  bool _manuallyDisconnected = false;

  Timer? _autoReconnectTimer;
  int _reconnectAttempts = 0;

  /// Capped exponential backoff for auto-reconnect after an unexpected drop.
  static const Duration _baseBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 30);

  List<_ThreadEntry> get _entries => _logFor(widget.threadKey);

  List<_ThreadEntry> _logFor(String threadKey) =>
      _logs.putIfAbsent(threadKey, () => <_ThreadEntry>[]);

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.defaultHostUrl);
    _bootstrap();
  }

  @override
  void didUpdateWidget(CoworkThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.threadKey != widget.threadKey) {
      // A different conversation: no half-streamed turn carries over.
      _currentAssistant = null;
      _currentReasoning = null;
      _scrollToBottom();
    }
  }

  @override
  void dispose() {
    _autoReconnectTimer?.cancel();
    _controller?.state.removeListener(_onStateChanged);
    _inboundSub?.cancel();
    _controller?.dispose();
    _hostController.dispose();
    _codeController.dispose();
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Load any stored pairing first, then build the controller. If a pairing is
  /// stored, auto-reconnect with no code; otherwise show the connect form.
  Future<void> _bootstrap() async {
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

  Future<void> _buildController() async {
    final controller = await widget.controllerBuilder();
    if (!mounted) {
      controller.dispose();
      return;
    }
    controller.state.addListener(_onStateChanged);
    setState(() {
      _controller = controller;
      _inboundSub = controller.inbound.listen(_onInbound);
    });
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
      final peer = state.peerDeviceId;
      if (peer != null) widget.onPaired?.call(peer);
      return;
    }
    if (phase == CoworkRelayPhase.closed &&
        _storedPairing != null &&
        !_manuallyDisconnected) {
      // A run cannot still be in flight over a socket that is gone.
      _setRunPhase(_RunPhase.idle);
      _activeRunThread = null;
      _scheduleAutoReconnect();
    }
  }

  void _scheduleAutoReconnect() {
    if (_autoReconnectTimer != null || widget.pairingStore == null) return;
    final exponent = _reconnectAttempts.clamp(0, 5);
    final delayMs =
        (_baseBackoff.inMilliseconds * (1 << exponent)).clamp(0, _maxBackoff.inMilliseconds);
    _reconnectAttempts++;
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
    if (controller == null || stored == null || _busy) return;
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

  /// Tears down the live controller and spins up a fresh one, without touching
  /// the stored pairing or the conversation.
  Future<void> _rebuildController() async {
    final old = _controller;
    final oldSub = _inboundSub;
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
    // Cancel, but never AWAIT the old subscription. `StreamSubscription.cancel()`
    // on a broadcast stream returns Dart's shared `Future._nullFuture`, which is
    // owned by the ROOT zone: awaiting it parks the rest of this method on the
    // root microtask queue, which a `flutter_test` FakeAsync zone never drains.
    // The reconnect then only ran after the test ended. Cancelling already stops
    // delivery synchronously, so there is nothing to wait for.
    unawaited(oldSub?.cancel() ?? Future<void>.value());
    controller.state.addListener(_onStateChanged);
    setState(() {
      _controller = controller;
      _currentAssistant = null;
      _currentReasoning = null;
      _inboundSub = controller.inbound.listen(_onInbound);
    });
    // Tear the old transport down in the background: it is fully detached now.
    if (old != null) unawaited(old.dispose());
  }

  void _onInbound(CoworkRelayInbound event) {
    if (!mounted) return;
    final target = _activeRunThread ?? widget.threadKey;
    final log = _logFor(target);
    setState(() {
      switch (event) {
        case CoworkRelayDelta(:final text):
          _currentReasoning = null;
          final assistant = _currentAssistant ??= _startAssistant(log);
          assistant.text += text;
        case CoworkRelayReasoning(:final text):
          // Reasoning is its own channel: it never lands in the reply text.
          _currentAssistant = null;
          final reasoning = _currentReasoning ??= _startReasoning(log);
          reasoning.text += text;
        case CoworkRelayTool():
          _currentAssistant = null;
          _currentReasoning = null;
          log.add(_ToolEntry(event));
        case CoworkRelayFile():
          _currentAssistant = null;
          _currentReasoning = null;
          log.add(_FileEntry(event));
        case CoworkRelayDone():
          log.add(_DoneEntry(event));
          _currentAssistant = null;
          _currentReasoning = null;
        case CoworkRelayRunError(:final message):
          log.add(_ErrorEntry(message));
          _currentAssistant = null;
          _currentReasoning = null;
      }
    });
    if (event is CoworkRelayDone || event is CoworkRelayRunError) {
      // The run is over only when the executor closes the stream. Report the
      // phase change first, while the run still knows which thread it was.
      _setRunPhase(_RunPhase.idle);
      _activeRunThread = null;
    }
    widget.onActivity?.call(target, DateTime.now());
    _scrollToBottom();
  }

  _AssistantEntry _startAssistant(List<_ThreadEntry> log) {
    final entry = _AssistantEntry();
    log.add(entry);
    return entry;
  }

  _ReasoningEntry _startReasoning(List<_ThreadEntry> log) {
    final entry = _ReasoningEntry();
    log.add(entry);
    return entry;
  }

  void _setRunPhase(_RunPhase phase) {
    if (_runPhase == phase) return;
    final wasRunning = _runPhase != _RunPhase.idle;
    final thread = _activeRunThread ?? widget.threadKey;
    if (mounted) {
      setState(() => _runPhase = phase);
    } else {
      _runPhase = phase;
    }
    final running = phase != _RunPhase.idle;
    // "Stopping" is still running: only a real change is reported outward.
    if (running != wasRunning) widget.onRunStateChanged?.call(thread, running);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
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

  void _send() {
    final controller = _controller;
    if (controller == null || !controller.state.value.isPaired) return;
    if (_runPhase != _RunPhase.idle) return;
    final text = _composerController.text.trim();
    if (text.isEmpty) return;
    final thread = widget.threadKey;
    setState(() {
      _entries.add(_UserEntry(text));
      _currentAssistant = null;
      _currentReasoning = null;
    });
    _activeRunThread = thread;
    _setRunPhase(_RunPhase.running);
    _composerController.clear();
    widget.onActivity?.call(thread, DateTime.now());
    _scrollToBottom();
    controller.sendTask(text, sessionKey: thread).catchError((Object error) {
      if (mounted) {
        setState(() => _logFor(thread).add(_ErrorEntry('$error')));
        _setRunPhase(_RunPhase.idle);
        _activeRunThread = null;
        _scrollToBottom();
      }
    });
  }

  /// Asks the executor to abort the run. The run is only over when a `done` or
  /// an `error` arrives, so the button goes to "Stopping…" and waits.
  void _stop() {
    final controller = _controller;
    if (controller == null || _runPhase != _RunPhase.running) return;
    _setRunPhase(_RunPhase.stopping);
    final thread = _activeRunThread ?? widget.threadKey;
    // The thread key IS the session key the task was sent with, so it is what
    // names the run on the executor side.
    controller.requestStop(sessionKey: thread).catchError((Object error) {
      if (!mounted) return;
      setState(
        () => _logFor(thread).add(_ErrorEntry('Could not stop the run: $error')),
      );
      // The request never left, so the run is still going: back to Stop.
      _setRunPhase(_RunPhase.running);
      _scrollToBottom();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ValueListenableBuilder<CoworkRelayState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        final connected = state.phase == CoworkRelayPhase.paired;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusStrip(context, state),
            Expanded(child: _buildConversation(context, connected)),
            const Divider(height: 1),
            connected
                ? _buildComposer(context)
                : _buildConnectBar(context, state),
          ],
        );
      },
    );
  }

  // --- top status strip ------------------------------------------------------

  /// The connection is not something the user manages. Once paired the socket
  /// is simply up, and it comes back on its own after a drop — so nothing sits
  /// on top of the chat: no "connected to" line, no host URL, no SAS digits, no
  /// disconnect button. An in-flight connect gets a hairline progress bar, and
  /// it carries no text either. Re-pairing lives in the bottom bar, and only
  /// when the connection is actually down.
  Widget _buildStatusStrip(BuildContext context, CoworkRelayState state) {
    switch (state.phase) {
      case CoworkRelayPhase.connecting:
      case CoworkRelayPhase.pairing:
        return const LinearProgressIndicator(minHeight: 2);
      case CoworkRelayPhase.paired:
      case CoworkRelayPhase.idle:
      case CoworkRelayPhase.error:
      case CoworkRelayPhase.closed:
        return const SizedBox.shrink();
    }
  }

  // --- conversation ----------------------------------------------------------

  Widget _buildConversation(BuildContext context, bool connected) {
    final theme = Theme.of(context);
    final entries = _entries;
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            connected
                ? 'Send a task to the agent'
                : 'Connect to a host to start chatting.',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.hintColor),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      itemBuilder: (context, index) => entries[index].build(context, widget),
    );
  }

  // --- bottom bar: composer or connect affordance ----------------------------

  Widget _buildComposer(BuildContext context) {
    final busy = _runPhase != _RunPhase.idle;
    // The executor serves one task at a time, so a run in another thread blocks
    // this composer too — but Stop belongs to the thread the run came from.
    final runningHere =
        busy && (_activeRunThread == null || _activeRunThread == widget.threadKey);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _composerController,
                textInputAction: TextInputAction.send,
                enabled: !busy,
                decoration: InputDecoration(
                  hintText: busy && !runningHere
                      ? 'The agent is busy in another thread…'
                      : 'Message the agent…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            if (!runningHere)
              IconButton.filled(
                tooltip: 'Send',
                icon: const Icon(Icons.send),
                onPressed: busy ? null : _send,
              )
            else
              FilledButton.tonalIcon(
                onPressed: _runPhase == _RunPhase.running ? _stop : null,
                icon: _runPhase == _RunPhase.stopping
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.stop),
                label: Text(_runPhase == _RunPhase.stopping ? 'Stopping…' : 'Stop'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectBar(BuildContext context, CoworkRelayState state) {
    final theme = Theme.of(context);
    final banner = _localError ??
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
            if (banner != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        size: 16, color: theme.colorScheme.error),
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
    final status = banner ??
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

// --- thread entries ----------------------------------------------------------

sealed class _ThreadEntry {
  const _ThreadEntry();
  Widget build(BuildContext context, CoworkThreadView view);
}

class _UserEntry extends _ThreadEntry {
  _UserEntry(this.text);
  final String text;

  @override
  Widget build(BuildContext context, CoworkThreadView view) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, left: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text),
      ),
    );
  }
}

class _AssistantEntry extends _ThreadEntry {
  _AssistantEntry();
  String text = '';

  @override
  Widget build(BuildContext context, CoworkThreadView view) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 40),
        width: double.infinity,
        // The agent answers in Markdown; a half-streamed reply is still valid
        // Markdown, so it renders the same on every delta.
        child: text.isEmpty ? const Text('…') : AgentMarkdown(text),
      ),
    );
  }
}

class _ReasoningEntry extends _ThreadEntry {
  _ReasoningEntry();
  String text = '';

  @override
  Widget build(BuildContext context, CoworkThreadView view) =>
      AgentReasoningBlock(text: text);
}

class _ToolEntry extends _ThreadEntry {
  _ToolEntry(this.call);
  final CoworkRelayTool call;

  @override
  Widget build(BuildContext context, CoworkThreadView view) =>
      AgentToolLine(call: call);
}

class _FileEntry extends _ThreadEntry {
  _FileEntry(this.file);
  final CoworkRelayFile file;

  @override
  Widget build(BuildContext context, CoworkThreadView view) =>
      AgentFileCard(file: file, saver: view.fileSaver);
}

class _DoneEntry extends _ThreadEntry {
  const _DoneEntry(this.done);
  final CoworkRelayDone done;

  @override
  Widget build(BuildContext context, CoworkThreadView view) {
    final theme = Theme.of(context);
    // The label comes from the protocol's reason, never from the text.
    final label = done.wasStopped ? 'stopped' : 'done';
    final rounds = done.iterations;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              rounds == null ? label : '$label · $rounds rounds',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _ErrorEntry extends _ThreadEntry {
  _ErrorEntry(this.message);
  final String message;

  @override
  Widget build(BuildContext context, CoworkThreadView view) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        message,
        style: TextStyle(color: theme.colorScheme.error),
      ),
    );
  }
}
