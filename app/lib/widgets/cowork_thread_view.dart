import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// The thread surface: connect to a local host, run the pairing ceremony,
/// provision the account token, then compose tasks and watch the streamed
/// result. All transport lives behind [CoworkRelayController], so the UI is the
/// same whether it drives a real socket or a fake in a widget test.
class CoworkThreadView extends StatefulWidget {
  const CoworkThreadView({
    super.key,
    required this.controllerBuilder,
    required this.sessionSource,
    this.defaultHostUrl = 'ws://127.0.0.1:8787',
  });

  /// Builds the transport controller. Async because a real client generates a
  /// device signing key first. Widget tests return a fake synchronously.
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
    widget.controllerBuilder().then((controller) {
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _inboundSub = controller.inbound.listen(_onInbound);
      });
    });
  }

  @override
  void dispose() {
    _inboundSub?.cancel();
    _controller?.dispose();
    _hostController.dispose();
    _codeController.dispose();
    _composerController.dispose();
    super.dispose();
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
  }

  _AssistantEntry _startAssistant() {
    final entry = _AssistantEntry();
    _entries.add(entry);
    return entry;
  }

  Future<void> _connect() async {
    final controller = _controller;
    if (controller == null) return;
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

  void _send() {
    final controller = _controller;
    if (controller == null) return;
    final text = _composerController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _entries.add(_UserEntry(text));
      _currentAssistant = null;
    });
    _composerController.clear();
    controller.sendTask(text).catchError((Object error) {
      if (mounted) setState(() => _entries.add(_ErrorEntry('$error')));
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
        switch (state.phase) {
          case CoworkRelayPhase.connecting:
            return _Busy(label: state.detail ?? 'Connecting…');
          case CoworkRelayPhase.pairing:
            return _Busy(label: state.detail ?? 'Pairing…', sas: state.sas);
          case CoworkRelayPhase.paired:
            return _buildThread(context, state);
          case CoworkRelayPhase.idle:
          case CoworkRelayPhase.error:
          case CoworkRelayPhase.closed:
            return _buildConnectForm(context, state);
        }
      },
    );
  }

  Widget _buildConnectForm(BuildContext context, CoworkRelayState state) {
    final theme = Theme.of(context);
    final bannerText = _localError ??
        (state.phase == CoworkRelayPhase.error ? state.detail : null) ??
        (state.phase == CoworkRelayPhase.closed
            ? (state.detail ?? 'Disconnected')
            : null);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Connect to host', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Enter the host URL and the pairing code it printed.',
                style: TextStyle(color: theme.hintColor),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Host URL',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  hintText: 'chan1234-428913',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _connect(),
              ),
              if (bannerText != null) ...[
                const SizedBox(height: 16),
                Text(
                  bannerText,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThread(BuildContext context, CoworkRelayState state) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: theme.colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Icon(Icons.link, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Paired with ${state.peerDeviceId ?? 'host'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (state.sas != null)
                Text('SAS ${state.sas}', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: _entries.isEmpty
              ? Center(
                  child: Text(
                    'Send a task to the agent',
                    style: TextStyle(color: theme.hintColor),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) => _entries[index].build(context),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _composerController,
                  decoration: const InputDecoration(
                    hintText: 'Describe a task…',
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
      ],
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label, this.sas});

  final String label;
  final String? sas;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label),
          if (sas != null) ...[
            const SizedBox(height: 8),
            Text(
              'SAS $sas',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
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
          label: Text(status == null ? name : '$name · $status'),
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
