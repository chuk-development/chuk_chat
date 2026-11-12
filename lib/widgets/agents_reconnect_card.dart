// lib/widgets/agents_reconnect_card.dart
//
// "Fastmail: sign-in expired" + "Reconnect Fastmail", right in the Agents
// thread (CHAT-77). The host answers a call to a connector whose sign-in
// lapsed with a structured `auth_required` result (docs/WIRE_CONTRACT.md,
// "auth_required"); this card is drawn from that field, never from text.
// The tap runs the browser sign-in here, without a trip to Settings; when it
// worked, the agent is told to go on.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/app_notification.dart';

/// The `auth_required` block of a tool result: which connector lost its
/// sign-in.
class AgentsAuthRequired {
  const AgentsAuthRequired({
    required this.server,
    this.connectorId = '',
    this.url = '',
  });

  final String server;
  final String connectorId;
  final String url;

  /// Reads [call]'s result. Null unless the host said `auth_required`.
  static AgentsAuthRequired? fromToolCall(ToolCall call) {
    final String? raw = call.result;
    if (raw == null || !raw.contains('auth_required')) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Object? block = decoded['auth_required'];
    if (block is! Map) return null;
    final Object? server = block['server'];
    if (server is! String || server.isEmpty) return null;
    final Object? id = block['connector_id'];
    final Object? url = block['url'];
    return AgentsAuthRequired(
      server: server,
      connectorId: id is String ? id : '',
      url: url is String ? url : '',
    );
  }

  /// One card per connector in a message.
  String get dedupeKey => connectorId.isNotEmpty ? connectorId : server;
}

/// Tells the agent to go on after a reconnect. A plain task of the thread,
/// tracked by the run ledger like any send, so its heartbeats and its answer
/// reach the thread. Test seam: [debugSend].
abstract final class AgentsContinueSender {
  @visibleForTesting
  static Future<bool> Function(String threadKey, String text)? debugSend;

  static Future<bool> send(String threadKey, String text) async {
    final override = debugSend;
    if (override != null) return override(threadKey, text);
    final controller = AgentsRelayLink.instance.controller.value;
    if (controller == null) return false;
    final String taskId = 'reconnect-${DateTime.now().microsecondsSinceEpoch}';
    final AgentsRunLedger ledger = AgentsRunLedger.instance;
    // A run that still goes on (the agent works on with other tools) keeps
    // its place in the ledger; the host takes this task after it.
    if (!ledger.isRunning(threadKey)) {
      ledger.begin(threadKey);
      ledger.taskSent(threadKey, taskId);
    }
    try {
      await controller.sendTask(text, sessionKey: threadKey, taskId: taskId);
      return true;
    } catch (_) {
      return false;
    }
  }
}

enum _ReconnectState { idle, busy, done }

class AgentsReconnectCard extends StatefulWidget {
  const AgentsReconnectCard({
    super.key,
    required this.auth,
    required this.threadKey,
    this.connect,
  });

  final AgentsAuthRequired auth;
  final String threadKey;

  /// Test seam: the sign-in. Default [McpService.connect] with
  /// `forceSignIn`.
  final Future<McpConnectStatus> Function(AgentsAuthRequired auth)? connect;

  @override
  State<AgentsReconnectCard> createState() => _AgentsReconnectCardState();
}

class _AgentsReconnectCardState extends State<AgentsReconnectCard> {
  _ReconnectState _state = _ReconnectState.idle;

  /// The device's record of the connector: by id, else by address.
  static McpConnection? _connectionOf(AgentsAuthRequired auth) {
    if (auth.connectorId.isNotEmpty) {
      final McpConnection? byId = McpService.connectionFor(auth.connectorId);
      if (byId != null) return byId;
    }
    if (auth.url.isEmpty) return null;
    for (final McpConnection c in McpService.connections.value) {
      if (Uri.tryParse(c.url)?.replace(query: '').toString() ==
          Uri.tryParse(auth.url)?.replace(query: '').toString()) {
        return c;
      }
    }
    return null;
  }

  static Future<McpConnectStatus> _signIn(AgentsAuthRequired auth) async {
    final McpConnection? connection = _connectionOf(auth);
    final String url = connection?.url ?? auth.url;
    if (url.isEmpty) return McpConnectStatus.failed;
    final McpConnectResult result = await McpService.connect(
      id: connection?.id ?? auth.connectorId,
      name: connection?.name ?? auth.server,
      url: url,
      description: connection?.description ?? '',
      iconUrl: connection?.iconUrl,
      auth: connection?.auth ?? McpAuth.oauth,
      forceSignIn: true,
    );
    return result.status;
  }

  Future<void> _reconnect() async {
    if (_state != _ReconnectState.idle) return;
    setState(() => _state = _ReconnectState.busy);
    final AppLocalizations? l = AppLocalizations.of(context);
    final String name = widget.auth.server;
    McpConnectStatus status;
    try {
      status = await (widget.connect ?? _signIn)(widget.auth);
    } catch (_) {
      status = McpConnectStatus.failed;
    }
    if (!mounted) return;
    if (status != McpConnectStatus.connected) {
      setState(() => _state = _ReconnectState.idle);
      if (status == McpConnectStatus.failed) {
        AppNotifications.show(
          context,
          l?.agentsReconnectFailed(name) ?? 'Could not reconnect $name.',
        );
      }
      return;
    }
    setState(() => _state = _ReconnectState.done);
    // The sign-in worked: the agent goes on with what it was asked.
    unawaited(
      AgentsContinueSender.send(
        widget.threadKey,
        l?.agentsReconnectContinue(name) ??
            '$name is connected again. Please continue.',
      ).catchError((Object _) => false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final String name = widget.auth.server;
    final bool done = _state == _ReconnectState.done;
    final String text = done
        ? (l?.agentsReconnectDone(name) ?? '$name is connected again')
        : (l?.agentsReconnectTitle(name) ?? '$name: sign-in expired');
    return Semantics(
      container: true,
      child: Container(
        key: ValueKey<String>('agents-reconnect-${widget.auth.dedupeKey}'),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            HugeIcon(
              done ? HugeIcons.checkmarkCircle02 : HugeIcons.unlink01,
              size: 18,
              color: done ? scheme.primary : scheme.error,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                text,
                key: const ValueKey<String>('agents-reconnect-text'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (!done) ...<Widget>[
              const SizedBox(width: 10),
              ExpressiveButton(
                key: const ValueKey<String>('agents-reconnect-button'),
                label: _state == _ReconnectState.busy
                    ? (l?.agentsReconnectBusy ?? 'Signing in…')
                    : (l?.agentsReconnectButton(name) ?? 'Reconnect $name'),
                dense: true,
                onTap: () => unawaited(_reconnect()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
