// lib/pages/mcp_connectors_page.dart
//
// Connectors: the servers this app can borrow tools from, and the one
// screen that connects them. A connector is a URL plus a sign-in, so the
// list is the catalogue, the registry search, and a field to paste any
// other MCP address into.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_icon_cache.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class McpConnectorsPage extends StatefulWidget {
  const McpConnectorsPage({super.key});

  @override
  State<McpConnectorsPage> createState() => _McpConnectorsPageState();
}

class _McpConnectorsPageState extends State<McpConnectorsPage> {
  final TextEditingController _search = TextEditingController();
  List<McpCatalogueEntry> _registryHits = const [];
  bool _searchingRegistry = false;

  @override
  void initState() {
    super.initState();
    McpService.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim().toLowerCase();

  /// The registry is only asked once the catalogue runs dry, so typing
  /// stays instant for the names that are offered anyway.
  Future<void> _searchRegistry() async {
    final query = _query;
    if (query.length < 3) return;
    setState(() => _searchingRegistry = true);
    final hits = await searchMcpRegistry(query);
    if (!mounted) return;
    // The flag has to fall even when the reader typed on: leaving it up
    // pins a spinner over the section and the button never comes back.
    setState(() {
      _searchingRegistry = false;
      if (_query == query) _registryHits = hits;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Connectors')),
      body: ValueListenableBuilder<List<McpConnection>>(
        valueListenable: McpService.connections,
        builder: (context, connections, _) {
          final connectedIds = {for (final c in connections) c.id};
          final catalogue = kMcpCatalogue
              .where(
                (entry) =>
                    !connectedIds.contains(entry.id) &&
                    (_query.isEmpty ||
                        entry.name.toLowerCase().contains(_query) ||
                        entry.description.toLowerCase().contains(_query)),
              )
              .toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                'Connectors let the assistant use tools and data from other '
                'services.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.resolvedIconColor.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 16),
              _searchField(theme),
              const SizedBox(height: 20),

              if (connections.isNotEmpty) ...[
                const ExpressiveSectionHeader('Connected'),
                ExpressiveGroup(
                  children: [
                    for (final connection in connections)
                      _row(
                        url: connection.url,
                        icon: connection.iconUrl,
                        name: connection.name,
                        trailing: '${connection.tools.length} tools',
                        onTap: () => _open(connection.id, null),
                      ),
                  ],
                ),
              ],

              for (final category in kMcpCategories)
                if (catalogue.any((e) => e.category == category)) ...[
                  ExpressiveSectionHeader(category),
                  ExpressiveGroup(
                    children: [
                      for (final entry in catalogue.where(
                        (e) => e.category == category,
                      ))
                        _row(
                          url: entry.url,
                          icon: entry.iconUrl,
                          name: entry.name,
                          subtitle: entry.description,
                          trailing: 'Connect',
                          onTap: () => _open(entry.id, entry),
                        ),
                    ],
                  ),
                ],

              if (_query.length >= 3) ...[
                const ExpressiveSectionHeader('From the MCP registry'),
                if (_searchingRegistry)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_registryHits.isEmpty)
                  TextButton(
                    onPressed: _searchRegistry,
                    child: const Text('Search the registry'),
                  )
                else
                  ExpressiveGroup(
                    children: [
                      for (final entry in _registryHits)
                        if (!connectedIds.contains(entry.id))
                          _row(
                            url: entry.url,
                            name: entry.name,
                            subtitle: entry.description,
                            trailing: 'Connect',
                            onTap: () => _open(entry.id, entry),
                          ),
                    ],
                  ),
              ],

              const ExpressiveSectionHeader('Own server'),
              ExpressiveGroup(
                children: [
                  ExpressiveRow(
                    icon: Icons.add_link,
                    title: 'Add by URL',
                    subtitle: 'Any server that speaks MCP',
                    onTap: _addByUrl,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _searchField(ThemeData theme) {
    return TextField(
      controller: _search,
      onChanged: (_) => setState(() {
        _registryHits = const [];
        _searchingRegistry = false;
      }),
      onSubmitted: (_) => _searchRegistry(),
      decoration: InputDecoration(
        hintText: 'Search connectors…',
        prefixIcon: const Icon(Icons.search),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.4,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(26),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _row({
    required String url,
    required String name,
    required String trailing,
    required VoidCallback onTap,
    String? icon,
    String? subtitle,
  }) {
    return ExpressiveRow(
      title: name,
      subtitle: subtitle,
      leading: McpConnectorIcon(
        url: icon,
        serverUrl: url,
        name: name,
        size: 42,
      ),
      trailing: trailing.isEmpty ? null : ExpressiveBadge(trailing),
      onTap: onTap,
    );
  }

  Future<void> _open(String id, McpCatalogueEntry? entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => McpConnectorDetailPage(id: id, entry: entry),
      ),
    );
  }

  Future<void> _addByUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add an MCP server'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://mcp.example.com/mcp',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty || !mounted) return;

    final result = await _withProgress(
      context,
      () => McpService.connectByUrl(url),
    );
    if (!mounted) return;
    _report(result);
  }

  void _report(McpConnectResult result) {
    final message = switch (result.status) {
      McpConnectStatus.connected =>
        '${result.connection?.name ?? 'The server'} is connected.',
      McpConnectStatus.cancelled => 'Sign-in was cancelled.',
      McpConnectStatus.failed => result.message ?? 'Could not connect.',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// One connector: connect or disconnect it, and see what it can do.
class McpConnectorDetailPage extends StatefulWidget {
  const McpConnectorDetailPage({super.key, required this.id, this.entry});

  final String id;
  final McpCatalogueEntry? entry;

  @override
  State<McpConnectorDetailPage> createState() => _McpConnectorDetailPageState();
}

class _McpConnectorDetailPageState extends State<McpConnectorDetailPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder<List<McpConnection>>(
      valueListenable: McpService.connections,
      builder: (context, _, _) {
        final connection = McpService.connectionFor(widget.id);
        final name = connection?.name ?? widget.entry?.name ?? 'Connector';
        final url = connection?.url ?? widget.entry?.url ?? '';
        final description =
            connection?.description ?? widget.entry?.description ?? '';

        return Scaffold(
          appBar: AppBar(title: Text(name)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            children: [
              Center(
                child: McpConnectorIcon(
                  url: connection?.iconUrl ?? widget.entry?.iconUrl,
                  serverUrl: url,
                  name: name,
                  size: 72,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(name, style: theme.textTheme.titleLarge),
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.resolvedIconColor.withValues(alpha: 0.7),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 52,
                child: _busy
                    ? const Center(child: CircularProgressIndicator())
                    : FilledButton(
                        style: FilledButton.styleFrom(
                          shape: const StadiumBorder(),
                        ),
                        onPressed: connection == null
                            ? (url.isEmpty ? null : () => _connect(url, name))
                            : _disconnect,
                        child: Text(
                          connection == null ? 'Connect' : 'Disconnect',
                        ),
                      ),
              ),
              const SizedBox(height: 28),
              Text(
                'Details',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.resolvedIconColor.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Server URL',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.resolvedIconColor.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(url, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
              if (connection != null && connection.tools.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Tools',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.resolvedIconColor.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tool in connection.tools)
                      Chip(
                        label: Text(tool.name),
                        backgroundColor: theme
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.4),
                        side: BorderSide.none,
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _connect(String url, String name) async {
    setState(() => _busy = true);
    final result = await McpService.connect(
      id: widget.id,
      name: name,
      url: url,
      description: widget.entry?.description ?? '',
      iconUrl: widget.entry?.iconUrl,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.status != McpConnectStatus.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.status == McpConnectStatus.cancelled
                ? 'Sign-in was cancelled.'
                : result.message ?? 'Could not connect.',
          ),
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await McpService.disconnect(widget.id);
    if (!mounted) return;
    setState(() => _busy = false);
  }
}

/// A connector logo. The server's own icon when it publishes one, then the
/// brand's favicon, then a second favicon service, and finally the initial
/// on a tinted tile — so a row is never a blank square.
class McpConnectorIcon extends StatefulWidget {
  const McpConnectorIcon({
    super.key,
    this.url,
    this.serverUrl,
    this.name,
    this.size = 32,
    this.fallback,
  });

  /// An icon the server published, if any.
  final String? url;

  /// The server address, which the favicon services are asked about.
  final String? serverUrl;

  /// Used for the initial when no logo loads.
  final String? name;

  final double size;
  final IconData? fallback;

  @override
  State<McpConnectorIcon> createState() => _McpConnectorIconState();
}

class _McpConnectorIconState extends State<McpConnectorIcon> {
  Future<Uint8List?>? _bytes;

  List<String> get _candidates => <String>[
    if (widget.url?.isNotEmpty ?? false) widget.url!,
    if (widget.serverUrl?.isNotEmpty ?? false)
      ...McpCatalogueEntry.faviconCandidates(widget.serverUrl!),
  ];

  @override
  void initState() {
    super.initState();
    _bytes = _loadFirstThatWorks();
  }

  @override
  void didUpdateWidget(McpConnectorIcon old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.serverUrl != widget.serverUrl) {
      _bytes = _loadFirstThatWorks();
    }
  }

  /// Walks the sources in order until one answers. Each answer is cached,
  /// so this costs the network only once per logo, ever.
  Future<Uint8List?> _loadFirstThatWorks() async {
    for (final candidate in _candidates) {
      final bytes = await McpIconCache.load(candidate);
      if (bytes != null) return bytes;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return _placeholder(theme);
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.size * 0.3),
          child: Image.memory(
            bytes,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, _, _) => _placeholder(theme),
          ),
        );
      },
    );
  }

  Widget _placeholder(ThemeData theme) {
    final String initial = (widget.name?.trim().isNotEmpty ?? false)
        ? widget.name!.trim().characters.first.toUpperCase()
        : '';
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(widget.size * 0.3),
      ),
      alignment: Alignment.center,
      child: widget.fallback != null || initial.isEmpty
          ? Icon(
              widget.fallback ?? Icons.extension_outlined,
              size: widget.size * 0.5,
              color: theme.colorScheme.onPrimaryContainer,
            )
          : Text(
              initial,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
    );
  }
}

Future<T> _withProgress<T>(
  BuildContext context,
  Future<T> Function() work,
) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(content: Text('Opening the browser to sign in…')),
  );
  try {
    return await work();
  } finally {
    messenger.hideCurrentSnackBar();
  }
}
