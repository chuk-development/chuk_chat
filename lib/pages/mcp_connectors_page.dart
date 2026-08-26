// lib/pages/mcp_connectors_page.dart
//
// Connectors: the servers this app can borrow tools from, and the one
// screen that connects them. A connector is a URL plus a sign-in, so the
// list is the catalogue, the registry search, and a field to paste any
// other MCP address into.

import 'package:flutter/material.dart';
// Carries both PlatformException and the Uint8List the icon cache hands back.
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_icon_cache.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class McpConnectorsPage extends StatefulWidget {
  const McpConnectorsPage({super.key, this.isCoworkActive = false});

  /// Whether CoWork mode is active. CoWork-only servers (which duplicate a
  /// built-in or need command execution) are hidden in normal chat and only
  /// shown here when this is true. CoWork is an M0 placeholder today, so the
  /// effective behaviour is "hidden"; the path is kept so they appear later.
  final bool isCoworkActive;

  @override
  State<McpConnectorsPage> createState() => _McpConnectorsPageState();
}

class _McpConnectorsPageState extends State<McpConnectorsPage> {
  final TextEditingController _search = TextEditingController();
  List<McpCatalogueEntry> _registryHits = const [];
  bool _searchingRegistry = false;

  /// The query the shown hits belong to. Without it an empty result and a
  /// registry never asked look the same, and the reader is offered a button
  /// they already pressed.
  String? _searchedQuery;

  /// The query of the search still in flight. An older answer arriving late
  /// must not take the spinner down from under the newer one.
  String? _inFlightQuery;

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
    _inFlightQuery = query;
    setState(() => _searchingRegistry = true);
    final hits = await searchMcpRegistry(query);
    if (!mounted || _inFlightQuery != query) return;
    // The flag has to fall even when the reader typed on: leaving it up
    // pins a spinner over the section and the button never comes back.
    setState(() {
      _searchingRegistry = false;
      if (_query == query) {
        _registryHits = hits;
        _searchedQuery = query;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('MCP servers')),
      body: ValueListenableBuilder<List<McpConnection>>(
        valueListenable: McpService.connections,
        builder: (context, connections, _) {
          final connectedIds = {for (final c in connections) c.id};
          // The connectors our own server fronts come first: they are the
          // ones that need no browser sign-in.
          final catalogue = [...firstPartyConnectors(), ...kMcpCatalogue]
              .where(
                (entry) =>
                    !connectedIds.contains(entry.id) &&
                    // CoWork-only servers stay hidden until CoWork is active.
                    (widget.isCoworkActive || !entry.coworkOnly) &&
                    (_query.isEmpty ||
                        entry.name.toLowerCase().contains(_query) ||
                        entry.description.toLowerCase().contains(_query)),
              )
              .toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                'MCP servers let the assistant use tools and data from other '
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
                const ExpressiveSectionHeader('Verified in the MCP registry'),
                if (_searchingRegistry)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_registryHits.isEmpty)
                  _searchedQuery == _query
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: Text(
                            'No server whose own publisher serves it. Only '
                            'servers hosted by the domain that published '
                            'them are offered here; anything else can be '
                            'added under "Add by URL".',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.resolvedIconColor.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                        )
                      : TextButton(
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
                            // The publisher leads the line: the reader is
                            // about to sign in to whoever runs that domain,
                            // and the name alone does not say who that is.
                            subtitle: [
                              if (entry.publisher != null) entry.publisher!,
                              if (entry.description.isNotEmpty)
                                entry.description,
                            ].join(' · '),
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
        _searchedQuery = null;
        _inFlightQuery = null;
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
              const SizedBox(height: 20),
              // Before the button, not after it: a disclosure the reader
              // meets only once they have already signed in is no
              // disclosure at all.
              if (connection == null) _legalNote(theme, url),
              const SizedBox(height: 12),
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

  /// Who the reader is about to hand their data to, and where their terms
  /// are. Connecting signs in to another company's service: whatever the
  /// assistant sends through this connector leaves our servers and lands
  /// under that company's terms, so the name and the link belong on the
  /// screen before the button, not in a help page afterwards.
  Widget _legalNote(ThemeData theme, String url) {
    final entry = widget.entry;
    final host = Uri.tryParse(url)?.host ?? '';
    final party = entry?.publisher ?? McpCatalogueEntry.brandDomain(host);
    if (party.isEmpty) return const SizedBox.shrink();

    final legal = entry?.legalUrl ?? (host.isEmpty ? null : 'https://$party');
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.resolvedIconColor.withValues(alpha: 0.7),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Text(
            'Connecting signs you in to $party. What you send through this '
            'connector is handled by them, under their terms and privacy '
            'policy.',
            textAlign: TextAlign.center,
            style: muted,
          ),
          // The two documents by name where they are known, and only the
          // publisher's own page where they are not — a guessed `/terms`
          // that 404s reads as if we made the promise up.
          if (entry?.termsUrl != null || entry?.privacyUrl != null)
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                if (entry?.termsUrl != null)
                  TextButton(
                    onPressed: () => _openLegal(entry!.termsUrl!),
                    child: const Text('Terms'),
                  ),
                if (entry?.privacyUrl != null)
                  TextButton(
                    onPressed: () => _openLegal(entry!.privacyUrl!),
                    child: const Text('Privacy policy'),
                  ),
              ],
            )
          else if (legal != null)
            TextButton(
              onPressed: () => _openLegal(legal),
              child: Text('Terms and privacy at $party'),
            ),
        ],
      ),
    );
  }

  Future<void> _openLegal(String url) async {
    // The address can come from the registry, which is written by strangers.
    // Anything but https would hand the platform a scheme of their choosing —
    // a deep link into another app, a dialler, a mail composer.
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open legal information.')),
        );
      }
      return;
    }
    // A missing browser reaches us as a thrown PlatformException, not as a
    // false — both mean the same thing to the reader, so both end up in the
    // same message rather than in an uncaught error.
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  Future<void> _connect(String url, String name) async {
    setState(() => _busy = true);
    final result = await McpService.connect(
      id: widget.id,
      name: name,
      url: url,
      description: widget.entry?.description ?? '',
      iconUrl: widget.entry?.iconUrl,
      auth: widget.entry?.auth ?? McpAuth.oauth,
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
