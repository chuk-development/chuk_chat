// lib/services/mcp/mcp_catalogue.dart
//
// The connectors offered by name, and the search that finds the rest.
//
// Every entry here is a remote MCP server: an HTTPS endpoint that signs the
// reader in through the browser. Nothing is installed, so the list works
// the same on a phone as on a laptop. Servers that need a package to be run
// locally are deliberately absent — they cannot work on a phone.
//
// The rest of the world is reachable through [search], which queries the
// official MCP registry, and through "add by URL", which needs no catalogue
// entry at all.

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A connector as offered to the reader.
class McpCatalogueEntry {
  const McpCatalogueEntry({
    required this.id,
    required this.name,
    required this.url,
    required this.category,
    this.description = '',
    this.iconUrl,
  });

  /// Stable id, used as the tool-name prefix and the storage key.
  final String id;
  final String name;
  final String url;
  final String category;
  final String description;
  final String? iconUrl;

  /// The logo. Servers rarely publish one in `serverInfo.icons`, so the
  /// site's own favicon is the fallback that works for every host.
  String get icon => iconUrl ?? faviconFor(url);

  static String faviconFor(String url) => faviconCandidates(url).first;

  /// Places a logo can come from, best first. `mcp.figma.com` has no icon
  /// of its own — `figma.com` does — so the brand domain is asked first,
  /// and a second service is kept in reserve for hosts the first misses.
  static List<String> faviconCandidates(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return const <String>[];
    final brand = brandDomain(host);
    return <String>[
      'https://www.google.com/s2/favicons?domain=$brand&sz=128',
      'https://icons.duckduckgo.com/ip3/$brand.ico',
      if (brand != host) 'https://www.google.com/s2/favicons?domain=$host&sz=128',
    ];
  }

  /// `mcp.figma.com` → `figma.com`: the host without the part that only
  /// says which service of the brand this is.
  static String brandDomain(String host) {
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    const strip = {'mcp', 'api', 'www', 'server', 'app'};
    if (strip.contains(parts.first)) return parts.sublist(1).join('.');
    return host;
  }
}

/// Categories, in the order they are shown.
const List<String> kMcpCategories = [
  'Recommended',
  'Productivity',
  'Developer',
  'Creative',
  'Finance',
];

/// The offered connectors. Only servers that speak Streamable HTTP and sign
/// in through OAuth, because that is what a phone can do.
///
/// They must also register clients dynamically (RFC 7591): no client id is
/// baked into this app, so a server that expects a pre-registered one
/// cannot be connected and must not be listed. GitHub's MCP server is the
/// known case — it points at `github.com/login/oauth`, which has no
/// registration endpoint. `mcp_endpoints_live_test.dart` checks this
/// against the real servers.
const List<McpCatalogueEntry> kMcpCatalogue = [
  // ─── Recommended ───────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'excalidraw',
    name: 'Excalidraw',
    url: 'https://mcp.excalidraw.com/mcp',
    category: 'Recommended',
    description: 'Draw diagrams and hand them back as editable scenes.',
  ),
  McpCatalogueEntry(
    id: 'canva',
    name: 'Canva',
    url: 'https://mcp.canva.com/mcp',
    category: 'Recommended',
    description: 'Create and edit designs, export them, search your folders.',
  ),
  McpCatalogueEntry(
    id: 'notion',
    name: 'Notion',
    url: 'https://mcp.notion.com/mcp',
    category: 'Recommended',
    description: 'Search, read and write pages and databases.',
  ),
  McpCatalogueEntry(
    id: 'stripe',
    name: 'Stripe',
    url: 'https://mcp.stripe.com',
    category: 'Recommended',
    description:
        'Look up customers, payments, subscriptions and products, and '
        'create payment links.',
  ),

  // ─── Productivity ──────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'linear',
    name: 'Linear',
    url: 'https://mcp.linear.app/mcp',
    category: 'Productivity',
    description: 'Issues, projects and cycles.',
  ),
  McpCatalogueEntry(
    id: 'atlassian',
    name: 'Atlassian',
    url: 'https://mcp.atlassian.com/v1/mcp',
    category: 'Productivity',
    description: 'Jira issues and Confluence pages.',
  ),
  McpCatalogueEntry(
    id: 'asana',
    name: 'Asana',
    url: 'https://mcp.asana.com/sse',
    category: 'Productivity',
    description: 'Tasks, projects and workspaces.',
  ),

  McpCatalogueEntry(
    id: 'monday',
    name: 'monday.com',
    url: 'https://mcp.monday.com/sse',
    category: 'Productivity',
    description: 'Boards, items and updates.',
  ),
  McpCatalogueEntry(
    id: 'airtable',
    name: 'Airtable',
    url: 'https://mcp.airtable.com/mcp',
    category: 'Productivity',
    description: 'Bases, tables and records.',
  ),
  McpCatalogueEntry(
    id: 'zapier',
    name: 'Zapier',
    url: 'https://mcp.zapier.com/api/mcp/mcp',
    category: 'Productivity',
    description: 'Whatever you wired up in Zapier, across thousands of apps.',
  ),

  // ─── Developer ─────────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'sentry',
    name: 'Sentry',
    url: 'https://mcp.sentry.dev/mcp',
    category: 'Developer',
    description: 'Issues, events and stack traces from your projects.',
  ),
  McpCatalogueEntry(
    id: 'vercel',
    name: 'Vercel',
    url: 'https://mcp.vercel.com',
    category: 'Developer',
    description: 'Projects, deployments and logs.',
  ),
  McpCatalogueEntry(
    id: 'supabase',
    name: 'Supabase',
    url: 'https://mcp.supabase.com/mcp',
    category: 'Developer',
    description: 'Projects, tables, SQL and logs.',
  ),
  McpCatalogueEntry(
    id: 'neon',
    name: 'Neon',
    url: 'https://mcp.neon.tech/mcp',
    category: 'Developer',
    description: 'Postgres branches, queries and migrations.',
  ),
  McpCatalogueEntry(
    id: 'webflow',
    name: 'Webflow',
    url: 'https://mcp.webflow.com/sse',
    category: 'Developer',
    description: 'Sites, collections and CMS items.',
  ),
  McpCatalogueEntry(
    id: 'huggingface',
    name: 'Hugging Face',
    url: 'https://huggingface.co/mcp',
    category: 'Developer',
    description: 'Search models, datasets, spaces and papers.',
  ),

  // ─── Creative ──────────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'figma',
    name: 'Figma',
    url: 'https://mcp.figma.com/mcp',
    category: 'Creative',
    description:
        'Read design files and design data, and turn frames into code.',
  ),
  McpCatalogueEntry(
    id: 'higgsfield',
    name: 'Higgsfield',
    url: 'https://mcp.higgsfield.ai/mcp',
    category: 'Creative',
    description: 'Generate images and video across 30+ models.',
  ),
  McpCatalogueEntry(
    id: 'heygen-hyperframes',
    name: 'HyperFrames by HeyGen',
    url: 'https://mcp.heygen.com/mcp/hyperframes/',
    category: 'Creative',
    description: 'Avatar video generation.',
  ),

  // ─── Finance ───────────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'paypal',
    name: 'PayPal',
    url: 'https://mcp.paypal.com/mcp',
    category: 'Finance',
    description: 'Invoices, orders, payments and disputes.',
  ),
];

/// Search the official MCP registry for anything not in the catalogue.
///
/// Only entries with a remote endpoint come back: a package that has to be
/// run locally is of no use to this app.
Future<List<McpCatalogueEntry>> searchMcpRegistry(
  String query, {
  http.Client? httpClient,
  int limit = 20,
}) async {
  if (query.trim().isEmpty) return const [];
  final client = httpClient ?? http.Client();
  try {
    final response = await client
        .get(
          Uri.https('registry.modelcontextprotocol.io', '/v0/servers', {
            'search': query.trim(),
            'version': 'latest',
            'limit': '$limit',
          }),
          headers: const {'accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return const [];

    final json = jsonDecode(response.body);
    final servers = (json is Map ? json['servers'] : null);
    if (servers is! List) return const [];

    final results = <McpCatalogueEntry>[];
    for (final entry in servers) {
      final server = entry is Map ? entry['server'] : null;
      if (server is! Map) continue;

      final remotes = server['remotes'];
      if (remotes is! List) continue;
      final remote = remotes.cast<Object?>().firstWhere(
        (r) => r is Map && (r['type'] == 'streamable-http' || r['type'] == 'sse'),
        orElse: () => null,
      );
      if (remote is! Map) continue;
      final url = remote['url']?.toString();
      if (url == null || !url.startsWith('https://')) continue;

      final name = server['name']?.toString() ?? url;
      results.add(
        McpCatalogueEntry(
          id: slugFor(name),
          name: server['title']?.toString().trim().isNotEmpty == true
              ? server['title'].toString()
              : name.split('/').last,
          url: url,
          category: 'Registry',
          description: server['description']?.toString() ?? '',
        ),
      );
    }
    return results;
  } catch (_) {
    return const [];
  } finally {
    if (httpClient == null) client.close();
  }
}

/// A short, stable id for a server: used to prefix its tool names, so two
/// servers that both offer `search` stay apart.
String slugFor(String nameOrUrl) {
  final raw = Uri.tryParse(nameOrUrl)?.host.isNotEmpty == true
      ? Uri.parse(nameOrUrl).host.replaceAll(RegExp(r'^(www|mcp|api)\.'), '')
      : nameOrUrl;
  final slug = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final trimmed = slug.length > 24 ? slug.substring(0, 24) : slug;
  return trimmed.isEmpty ? 'server' : trimmed;
}
