// lib/widgets/mcp_connect_card.dart
//
// The inline "Connect" card the assistant can show when a request needs an
// MCP server that is available but not connected. Mirrors AskUserCard: it
// lives at the bottom of the message bubble, connects the server on tap, and
// calls back so the same conversation resumes once its tools are live.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:chuk_chat/pages/mcp_connectors_page.dart'
    show McpConnectorIcon, showMcpCredentialDialog;
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';

/// A single Connect button for one catalogue server, shown inline under an
/// assistant message that asked for it. Manages its own busy spinner and
/// inline error text; calls [onConnected] only on a real connection.
class McpConnectCard extends StatefulWidget {
  const McpConnectCard({
    super.key,
    required this.entry,
    required this.onConnected,
  });

  /// The catalogue server to connect.
  final McpCatalogueEntry entry;

  /// Called once the server is connected and its tools are registered — the
  /// caller resumes the conversation. Never called on cancel or failure.
  final VoidCallback onConnected;

  @override
  State<McpConnectCard> createState() => _McpConnectCardState();
}

class _McpConnectCardState extends State<McpConnectCard> {
  bool _busy = false;
  String? _error;

  bool get _isActivate => widget.entry.auth == McpAuth.appSession;

  /// Loopback OAuth cannot run on the web, so an OAuth server cannot be
  /// connected there. Keyless and app-session servers still work.
  bool get _blockedOnWeb => kIsWeb && widget.entry.auth == McpAuth.oauth;

  Future<void> _connect() async {
    final entry = widget.entry;

    // An API-key server takes the reader's own credentials, not a browser
    // sign-in — collect them first, exactly as the Connectors page does.
    Map<String, String>? credentials;
    if (entry.credentials.isNotEmpty) {
      credentials = await showMcpCredentialDialog(
        context,
        entry.credentials,
        entry.name,
      );
      if (credentials == null || !mounted) return; // cancelled
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final result = credentials != null
        ? await McpService.connectWithCredentials(
            id: entry.id,
            name: entry.name,
            url: entry.url,
            description: entry.description,
            iconUrl: entry.iconUrl,
            credentials: credentials,
          )
        : await McpService.connect(
            id: entry.id,
            name: entry.name,
            url: entry.url,
            description: entry.description,
            iconUrl: entry.iconUrl,
            auth: entry.auth,
          );
    if (!mounted) return;

    if (result.status == McpConnectStatus.connected) {
      // The connections notifier already re-registered the tools. Resume.
      widget.onConnected();
      return;
    }

    // Cancel or failure: never claim a connection. Keep the button, show why.
    setState(() {
      _busy = false;
      _error = result.status == McpConnectStatus.cancelled
          ? 'Sign-in was cancelled.'
          : (result.message ?? 'Could not connect.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final accent = theme.colorScheme.primary;

    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        color: accent.withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              McpConnectorIcon(
                url: entry.iconUrl,
                serverUrl: entry.url,
                name: entry.name,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (entry.description.isNotEmpty)
                      Text(
                        entry.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_blockedOnWeb)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                onPressed: null,
                child: const Text('Open the Chuk Chat app to connect this server'),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: _busy
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                    )
                  : FilledButton(
                      style: FilledButton.styleFrom(
                        shape: const StadiumBorder(),
                      ),
                      onPressed: _connect,
                      child: Text(_isActivate ? 'Activate' : 'Connect'),
                    ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
