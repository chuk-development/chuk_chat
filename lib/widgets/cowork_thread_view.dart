import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

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
    this.defaultHostUrl = 'ws://127.0.0.1:8787',
  });

  /// Builds the transport controller. Async because a real client generates a
  /// device signing key first. Widget tests return a fake synchronously. Called
  /// again to get a fresh controller after a disconnect.
  final Future<CoworkRelayController> Function() controllerBuilder;

  /// Supplies the account session that gets provisioned once paired.
  final AccountSessionSource sessionSource;

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

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.defaultHostUrl);
    _buildController();
  }

  @override
  void dispose() {
    _inboundSub?.cancel();
    _controller?.dispose();
    _hostController.dispose();
    _codeController.dispose();
    _composerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _buildController() async {
    final controller = await widget.controllerBuilder();
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _inboundSub = controller.inbound.listen(_onInbound);
    });
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
    } catch (error) {
      // The pairing failure is already reflected in controller.state; a
      // provisioning failure is surfaced here.
      if (mounted) setState(() => _localError = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Drops the current session and spins up a fresh controller, returning to
  /// the connect affordance. The conversation stays on screen.
  Future<void> _disconnect() async {
    final old = _controller;
    await _inboundSub?.cancel();
    _inboundSub = null;
    setState(() {
      _controller = null;
      _currentAssistant = null;
      _localError = null;
      _busy = false;
    });
    await old?.dispose();
    _codeController.clear();
    await _buildController();
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

  Widget _buildStatusStrip(BuildContext context, CoworkRelayState state) {
    final theme = Theme.of(context);
    switch (state.phase) {
      case CoworkRelayPhase.paired:
        return Material(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(Icons.check_circle,
                    size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Connected to ${_hostController.text.trim()}',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (state.sas != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('SAS ${state.sas}',
                        style: theme.textTheme.bodySmall),
                  ),
                IconButton(
                  tooltip: 'Disconnect',
                  icon: const Icon(Icons.link_off, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: _disconnect,
                ),
              ],
            ),
          ),
        );
      case CoworkRelayPhase.connecting:
      case CoworkRelayPhase.pairing:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.detail ??
                          (state.phase == CoworkRelayPhase.pairing
                              ? 'Pairing…'
                              : 'Connecting…'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (state.sas != null)
                    Text('SAS ${state.sas}', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        );
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
        child: Text(text.isEmpty ? '…' : text),
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
