import 'package:flutter/material.dart';

import 'package:cowork/services/mcp/mcp_connection.dart';
import 'package:cowork/services/mcp/mcp_store.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// The MCP connectors config: the servers the host may reach on the user's
/// behalf. Each row is a stored connection; adding or editing one opens a
/// sheet for its name, URL, auth kind and — for an OAuth server — a bearer
/// token. Config lives in SharedPreferences (`mcp_connections_v1`); the token
/// lives in secure storage (`mcp_secrets_<id>`).
///
/// Live connection, tool discovery and the OAuth browser flow run host-side
/// (a later step); this screen only manages what CoWork forwards.
class McpConnectorsPage extends StatefulWidget {
  const McpConnectorsPage({super.key, McpStore? store})
      : _injectedStore = store;

  final McpStore? _injectedStore;

  @override
  State<McpConnectorsPage> createState() => _McpConnectorsPageState();
}

class _McpConnectorsPageState extends State<McpConnectorsPage> {
  late final McpStore _store = widget._injectedStore ?? McpStore();

  List<McpConnection> _connections = const <McpConnection>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await _store.load();
    if (!mounted) return;
    setState(() {
      _connections = list;
      _loading = false;
    });
  }

  Future<void> _openEditor([McpConnection? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _McpEditorSheet(
        store: _store,
        existing: existing,
      ),
    );
    if (saved == true) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MCP Connectors')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                const ExpressiveTitle(
                  'MCP Connectors',
                  subtitle: 'Model Context Protocol servers the host may use',
                ),
                if (_connections.isNotEmpty) ...[
                  const ExpressiveSectionHeader('Connected'),
                  ExpressiveGroup(
                    children: [
                      for (final c in _connections)
                        ExpressiveRow(
                          icon: c.auth == McpAuth.appSession
                              ? Icons.verified_user_outlined
                              : Icons.hub_outlined,
                          title: c.name.isEmpty ? c.url : c.name,
                          subtitle: c.url,
                          trailing: ExpressiveBadge(
                            c.auth == McpAuth.appSession
                                ? 'Account'
                                : 'OAuth',
                          ),
                          onTap: () => _openEditor(c),
                        ),
                    ],
                  ),
                ],
                const ExpressiveSectionHeader('Add'),
                ExpressiveGroup(
                  children: [
                    ExpressiveRow(
                      icon: Icons.add,
                      title: 'Add a connector',
                      subtitle: 'Point the host at an MCP server by URL',
                      onTap: () => _openEditor(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const ExpressiveInfoCard(
                  text:
                      'The host connects to each server and discovers its tools '
                      'when a task runs. OAuth servers hold a bearer token on '
                      'this device; account servers use your CoWork session, '
                      'resolved host-side.',
                ),
              ],
            ),
    );
  }
}

/// The add/edit sheet for one connection. Saves config to the store and, for
/// an OAuth server, the token to secure storage.
class _McpEditorSheet extends StatefulWidget {
  const _McpEditorSheet({required this.store, this.existing});

  final McpStore store;
  final McpConnection? existing;

  @override
  State<_McpEditorSheet> createState() => _McpEditorSheetState();
}

class _McpEditorSheetState extends State<_McpEditorSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _url =
      TextEditingController(text: widget.existing?.url ?? '');
  late final TextEditingController _token = TextEditingController();
  late McpAuth _auth = widget.existing?.auth ?? McpAuth.oauth;
  bool _busy = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  Future<void> _loadToken() async {
    final existing = widget.existing;
    if (existing == null) return;
    final token = await widget.store.tokenFor(existing.id);
    if (token != null && mounted) _token.text = token;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'A server URL is required.');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.isAbsolute) {
      setState(() => _error = 'Enter a full URL, e.g. https://server/mcp');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final connection = (widget.existing ??
            McpConnection(
              id: _newId(),
              name: name,
              url: url,
            ))
        .copyWith(name: name, url: url, auth: _auth);
    // Only an OAuth server holds a token on the device. Switching a server to
    // account-auth clears any token it had.
    final String token = _auth == McpAuth.oauth ? _token.text.trim() : '';
    await widget.store.upsert(connection, accessToken: token);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    setState(() => _busy = true);
    await widget.store.remove(existing.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  static String _newId() =>
      'mcp_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _isEdit ? 'Edit connector' : 'Add connector',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'GitHub',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://api.example.com/mcp',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text('Authentication', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<McpAuth>(
                segments: const <ButtonSegment<McpAuth>>[
                  ButtonSegment<McpAuth>(
                    value: McpAuth.oauth,
                    icon: Icon(Icons.key_outlined),
                    label: Text('OAuth / token'),
                  ),
                  ButtonSegment<McpAuth>(
                    value: McpAuth.appSession,
                    icon: Icon(Icons.verified_user_outlined),
                    label: Text('Account'),
                  ),
                ],
                selected: <McpAuth>{_auth},
                onSelectionChanged: (set) =>
                    setState(() => _auth = set.first),
              ),
              if (_auth == McpAuth.oauth) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: true,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Access token (optional)',
                    hintText: 'Bearer token for this server',
                    helperText: 'Stored in secure storage on this device.',
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Text(
                  'This server uses your CoWork account. The host resolves the '
                  'credential; nothing is stored on this device.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  if (_isEdit)
                    TextButton.icon(
                      onPressed: _busy ? null : _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove'),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isEdit ? 'Save' : 'Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
