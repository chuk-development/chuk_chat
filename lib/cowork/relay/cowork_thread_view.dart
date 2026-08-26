import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/cowork/cowork_pairing_store.dart';
import 'package:chuk_chat/services/cowork/cowork_relay_client.dart';
import 'package:chuk_chat/cowork/relay/agent_markdown.dart';

/// The CoWork chat surface: one scrolling conversation with the agent running
/// on the user's own host.
///
/// It reads like any messenger — the user's messages, the agent's reply
/// streaming in as deltas arrive, tool activity as compact inline chips, a
/// subtle done marker — with the message input pinned at the bottom. The
/// connection is a small, out-of-the-way affordance: while disconnected the
/// input row is a compact host + pairing-code connect bar; once paired it is
/// the composer, and a tiny "connected" chip with a disconnect button sits at
/// the top.
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

  @override
  State<CoworkThreadView> createState() => _CoworkThreadViewState();
}

class _CoworkThreadViewState extends State<CoworkThreadView> {
  late final TextEditingController _hostController;
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _composerController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  CoworkRelayController? _controller;
  StreamSubscription<CoworkRelayInbound>? _inboundSub;

  final List<_ThreadEntry> _entries = <_ThreadEntry>[];
  _AssistantEntry? _currentAssistant;

  String? _localError;
  bool _busy = false;

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

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.defaultHostUrl);
    _bootstrap();
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
    final phase = controller.state.value.phase;
    if (phase == CoworkRelayPhase.paired) {
      _reconnectAttempts = 0;
      return;
    }
    if (phase == CoworkRelayPhase.closed &&
        _storedPairing != null &&
        !_manuallyDisconnected) {
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
      _inboundSub = controller.inbound.listen(_onInbound);
    });
    // Tear the old transport down in the background: it is fully detached now.
    if (old != null) unawaited(old.dispose());
  }

  void _onInbound(CoworkRelayInbound event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case CoworkRelayDelta(:final text):
          final assistant = _currentAssistant ??= _startAssistant();
          assistant.text += text;
        case CoworkRelayTool(:final name, :final status):
          _entries.add(_ToolEntry(name, status));
        case CoworkRelayDone():
          _entries.add(const _DoneEntry());
          _currentAssistant = null;
        case CoworkRelayRunError(:final message):
          _entries.add(_ErrorEntry(message));
          _currentAssistant = null;
      }
    });
    _scrollToBottom();
  }

  _AssistantEntry _startAssistant() {
    final entry = _AssistantEntry();
    _entries.add(entry);
    return entry;
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
    final text = _composerController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _entries.add(_UserEntry(text));
      _currentAssistant = null;
    });
    _composerController.clear();
    _scrollToBottom();
    controller.sendTask(text).catchError((Object error) {
      if (mounted) {
        setState(() => _entries.add(_ErrorEntry('$error')));
        _scrollToBottom();
      }
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
    if (_entries.isEmpty) {
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
      itemCount: _entries.length,
      itemBuilder: (context, index) => _entries[index].build(context),
    );
  }

  // --- bottom bar: composer or connect affordance ----------------------------

  Widget _buildComposer(BuildContext context) {
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
                decoration: const InputDecoration(
                  hintText: 'Message the agent…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              onPressed: _send,
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
  Widget build(BuildContext context);
}

class _UserEntry extends _ThreadEntry {
  _UserEntry(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
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
  Widget build(BuildContext context) {
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

class _ToolEntry extends _ThreadEntry {
  _ToolEntry(this.name, this.status);
  final String name;
  final String? status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Chip(
          avatar: const Icon(Icons.build, size: 16),
          label: Text(status == null ? 'ran $name' : 'ran $name · $status'),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class _DoneEntry extends _ThreadEntry {
  const _DoneEntry();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('done', style: theme.textTheme.bodySmall),
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
  Widget build(BuildContext context) {
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
