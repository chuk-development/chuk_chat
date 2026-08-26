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

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';

/// A connector as offered to the reader.
class McpCatalogueEntry {
  const McpCatalogueEntry({
    required this.id,
    required this.name,
    required this.url,
    required this.category,
    this.description = '',
    this.iconUrl,
    this.publisher,
    this.websiteUrl,
    this.termsUrl,
    this.privacyUrl,
    this.auth = McpAuth.oauth,
    this.coworkOnly = false,
  });

  /// Stable id, used as the tool-name prefix and the storage key.
  final String id;
  final String name;
  final String url;
  final String category;
  final String description;
  final String? iconUrl;

  /// The domain that publishes this server, for entries that come out of the
  /// registry. Shown to the reader because the name alone does not say who
  /// is on the other end — `notion.com` does.
  final String? publisher;

  /// The publisher's own page, where their terms and privacy policy live.
  /// Connecting sends the reader's data to that company, under their terms
  /// and not ours, so the page has to be reachable before the sign-in.
  final String? websiteUrl;

  /// The two documents the reader agrees to by connecting. Filled in by
  /// hand for the offered connectors, because no server publishes them:
  /// RFC 9728 reserves `resource_tos_uri` and `resource_policy_uri` in the
  /// protected-resource metadata, and every server checked leaves both out.
  /// Each address here was fetched and answered 200 —
  /// `mcp_legal_links_live_test.dart` keeps it that way.
  final String? termsUrl;
  final String? privacyUrl;

  /// Where to send a reader who wants the terms before signing in. The
  /// registry carries `websiteUrl`; for everything else the publishing
  /// domain is the honest answer. Never a guessed `/terms` path — a link
  /// that 404s is worse than the home page.
  String? get legalUrl {
    final domain = publisher ?? Uri.tryParse(url)?.host;
    final site = websiteUrl?.trim();
    if (site != null && site.startsWith('https://')) {
      // The registry's `websiteUrl` is written by the publisher but checked
      // by no one, so a row that passed the endpoint filter could still
      // send the reader to a legal page on someone else's domain. It only
      // counts when it sits on the domain the namespace proves.
      final host = Uri.tryParse(site)?.host.toLowerCase();
      if (host != null &&
          domain != null &&
          (host == domain || host.endsWith('.$domain'))) {
        return site;
      }
    }
    if (domain == null || domain.isEmpty) return null;
    return 'https://$domain';
  }

  /// Where the token comes from. Everything in the catalogue signs in
  /// through the browser except the connectors our own server fronts.
  final McpAuth auth;

  /// True for servers that only make sense in CoWork mode — they duplicate a
  /// built-in (web search / crawl) or need command execution the normal chat
  /// cannot use. Kept in the catalogue so Add-by-URL and CoWork still reach
  /// them, but hidden from the normal chat UI and the model-awareness list.
  final bool coworkOnly;

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
    // Service subdomains that only say which service of the brand this is.
    // `ai` and `mail` join the list so `ai.todoist.net` and `mail.<brand>.com`
    // resolve to the brand instead of a subdomain a favicon service does not
    // know. Only the first label is stripped, so a host like
    // `mcp.mail.superhuman.com` still needs an explicit iconUrl.
    const strip = {'mcp', 'api', 'www', 'server', 'app', 'ai', 'mail'};
    if (strip.contains(parts.first)) return parts.sublist(1).join('.');
    return host;
  }
}

/// Categories, in the order they are shown. Consumer-relevant groups lead;
/// Developer sits near the end and Registry (search results) is always last.
const List<String> kMcpCategories = [
  'Recommended',
  'Productivity',
  'Finance',
  'Creative',
  'Developer',
  'Registry',
];

/// Connectors our own API server fronts.
///
/// Not in [kMcpCatalogue] because their address is not a constant — it
/// follows whichever API server this build talks to — and because they are
/// the one case that needs no browser sign-in: the reader is already signed
/// in to us, so the app session is the credential.
///
/// GitHub is here rather than in the catalogue for a concrete reason. Its
/// MCP server takes an ordinary GitHub token but offers no dynamic client
/// registration, and this app carries no pre-registered OAuth app, so it
/// cannot be connected directly. It does not have to be: the device flow in
/// Settings → Sandboxes → GitHub already left a token on our server, and
/// `/v1/mcp/github` uses that one. The token never reaches the device.
List<McpCatalogueEntry> firstPartyConnectors() => <McpCatalogueEntry>[
  McpCatalogueEntry(
    id: 'github',
    termsUrl: 'https://docs.github.com/en/site-policy/github-terms/github-terms-of-service',
    privacyUrl: 'https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement',
    name: 'GitHub',
    url: '${ApiConfigService.apiBaseUrl}/v1/mcp/github',
    category: 'Developer',
    description:
        'Issues, pull requests, code search and Actions on your own '
        'repositories. Connect GitHub under Sandboxes first.',
    iconUrl: 'https://www.google.com/s2/favicons?domain=github.com&sz=128',
    auth: McpAuth.appSession,
  ),
];

/// The offered connectors. Only servers that speak Streamable HTTP and sign
/// in through OAuth, because that is what a phone can do.
///
/// They must also register clients dynamically (RFC 7591): no client id is
/// baked into this app, so a server that expects a pre-registered one
/// cannot be connected and must not be listed. GitHub used to be the known
/// case; it is now reachable through [firstPartyConnectors] instead.
/// `mcp_endpoints_live_test.dart` checks the rest against the real servers.
const List<McpCatalogueEntry> kMcpCatalogue = [
  // ─── Recommended ───────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'excalidraw',
    // Not `excalidraw.com/terms`: that host is the drawing app itself and
    // answers 200 with the canvas for any path. The documents live on the
    // Plus site.
    termsUrl: 'https://plus.excalidraw.com/terms-of-service',
    privacyUrl: 'https://plus.excalidraw.com/privacy-policy',
    name: 'Excalidraw',
    url: 'https://mcp.excalidraw.com/mcp',
    category: 'Recommended',
    description: 'Draw diagrams and hand them back as editable scenes.',
  ),
  McpCatalogueEntry(
    id: 'canva',
    termsUrl: 'https://www.canva.com/policies/terms-of-use/',
    privacyUrl: 'https://www.canva.com/policies/privacy-policy/',
    name: 'Canva',
    url: 'https://mcp.canva.com/mcp',
    category: 'Recommended',
    description: 'Create and edit designs, export them, search your folders.',
  ),
  McpCatalogueEntry(
    id: 'notion',
    // Notion's own terms page is a Notion page — `notion.com/terms`
    // redirects here. `notion.com/privacy` redirects into the app and
    // answers 401 to anyone not signed in, so the trust site is used for
    // the policy instead.
    termsUrl:
        'https://notion.notion.site/Terms-and-Privacy-28ffdd083dc3473e9c2da6ec011b58ac',
    privacyUrl: 'https://www.notion.com/trust/privacy-policy',
    name: 'Notion',
    url: 'https://mcp.notion.com/mcp',
    category: 'Recommended',
    description: 'Search, read and write pages and databases.',
  ),
  McpCatalogueEntry(
    id: 'stripe',
    termsUrl: 'https://stripe.com/legal/ssa',
    privacyUrl: 'https://stripe.com/privacy',
    name: 'Stripe',
    url: 'https://mcp.stripe.com',
    category: 'Recommended',
    description:
        'Look up customers, payments, subscriptions and products, and '
        'create payment links.',
  ),

  // ─── Productivity ──────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'box',
    name: 'Box',
    url: 'https://mcp.box.com/mcp',
    category: 'Productivity',
    description: 'Files, folders and content in Box.',
    publisher: 'box.com',
    iconUrl: 'https://www.google.com/s2/favicons?domain=box.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'linear',
    termsUrl: 'https://linear.app/terms',
    privacyUrl: 'https://linear.app/privacy',
    name: 'Linear',
    url: 'https://mcp.linear.app/mcp',
    category: 'Productivity',
    description: 'Issues, projects and cycles.',
  ),
  McpCatalogueEntry(
    id: 'atlassian',
    termsUrl: 'https://www.atlassian.com/legal/atlassian-customer-agreement',
    privacyUrl: 'https://www.atlassian.com/legal/privacy-policy',
    name: 'Atlassian',
    url: 'https://mcp.atlassian.com/v1/mcp',
    category: 'Productivity',
    description: 'Jira issues and Confluence pages.',
  ),
  McpCatalogueEntry(
    id: 'asana',
    termsUrl: 'https://asana.com/terms',
    privacyUrl: 'https://asana.com/privacy',
    name: 'Asana',
    url: 'https://mcp.asana.com/sse',
    category: 'Productivity',
    description: 'Tasks, projects and workspaces.',
  ),

  McpCatalogueEntry(
    id: 'monday',
    termsUrl: 'https://monday.com/l/legal/tos/',
    privacyUrl: 'https://monday.com/l/privacy/privacy-policy/',
    name: 'monday.com',
    url: 'https://mcp.monday.com/sse',
    category: 'Productivity',
    description: 'Boards, items and updates.',
  ),
  McpCatalogueEntry(
    id: 'plane',
    termsUrl: 'https://app.plane.so/legal/terms',
    privacyUrl: 'https://plane.so/privacy-policy',
    name: 'Plane',
    // The `/http/mcp` OAuth endpoint, not the `/http/api-key/mcp` PAT one.
    url: 'https://mcp.plane.so/http/mcp',
    category: 'Productivity',
    description: 'Issues, cycles, modules and projects.',
  ),
  McpCatalogueEntry(
    id: 'todoist',
    termsUrl: 'https://todoist.com/terms',
    privacyUrl: 'https://todoist.com/privacy',
    name: 'Todoist',
    url: 'https://ai.todoist.net/mcp',
    category: 'Productivity',
    description: 'Tasks, projects and due dates.',
    // The `ai.todoist.net` host resolves the brand only after the subdomain
    // strip, and the favicon service still misses it — pin the real logo.
    iconUrl: 'https://www.google.com/s2/favicons?domain=todoist.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'buffer',
    termsUrl: 'https://buffer.com/terms',
    privacyUrl: 'https://buffer.com/privacy',
    name: 'Buffer',
    url: 'https://mcp.buffer.com/mcp',
    category: 'Productivity',
    description:
        'Draft, schedule and publish social posts, and read their metrics.',
  ),
  McpCatalogueEntry(
    id: 'dropbox',
    termsUrl: 'https://www.dropbox.com/terms',
    privacyUrl: 'https://www.dropbox.com/privacy',
    name: 'Dropbox',
    url: 'https://mcp.dropbox.com/mcp',
    category: 'Productivity',
    description: 'Search, read and manage your files and folders.',
  ),
  McpCatalogueEntry(
    id: 'clickup',
    termsUrl: 'https://clickup.com/terms',
    privacyUrl: 'https://clickup.com/privacy',
    name: 'ClickUp',
    url: 'https://mcp.clickup.com/mcp',
    category: 'Productivity',
    description: 'Tasks, lists, docs and spaces.',
  ),
  McpCatalogueEntry(
    id: 'fastmail',
    termsUrl: 'https://www.fastmail.com/about/tos/',
    privacyUrl: 'https://www.fastmail.com/about/privacy/',
    name: 'Fastmail',
    url: 'https://api.fastmail.com/mcp',
    category: 'Productivity',
    description: 'Search and read mail, and manage your calendar and contacts.',
  ),
  McpCatalogueEntry(
    id: 'superhuman',
    termsUrl: 'https://superhuman.com/terms',
    privacyUrl: 'https://superhuman.com/privacy',
    name: 'Superhuman Mail',
    url: 'https://mcp.mail.superhuman.com/mcp',
    category: 'Productivity',
    // `mcp.mail.superhuman.com` keeps a `mail.` label after the first strip,
    // so the favicon fallback lands on a wrong icon — pin the real logo.
    iconUrl: 'https://www.google.com/s2/favicons?domain=superhuman.com&sz=128',
    // Connectable via dynamic registration, but the account behind the sign-in
    // needs a Superhuman Business plan with Ask AI enabled — a rejected token
    // is the server's to explain, not ours to gate.
    description:
        'Search mail, draft and send replies, and manage your calendar. '
        'Needs a Superhuman Business plan.',
  ),
  McpCatalogueEntry(
    id: 'airtable',
    termsUrl: 'https://www.airtable.com/company/tos',
    privacyUrl: 'https://www.airtable.com/company/privacy',
    name: 'Airtable',
    url: 'https://mcp.airtable.com/mcp',
    category: 'Productivity',
    description: 'Bases, tables and records.',
  ),
  McpCatalogueEntry(
    id: 'zapier',
    termsUrl: 'https://zapier.com/legal/terms-of-service',
    privacyUrl: 'https://zapier.com/privacy',
    name: 'Zapier',
    url: 'https://mcp.zapier.com/api/mcp/mcp',
    category: 'Productivity',
    description: 'Whatever you wired up in Zapier, across thousands of apps.',
  ),
  McpCatalogueEntry(
    id: 'calcom',
    name: 'Cal.com',
    url: 'https://mcp.cal.com/mcp',
    category: 'Productivity',
    description: 'Scheduling, availability and bookings.',
    publisher: 'cal.com',
    iconUrl: 'https://www.google.com/s2/favicons?domain=cal.com&sz=128',
  ),

  // ─── Developer ─────────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'sentry',
    termsUrl: 'https://sentry.io/terms/',
    privacyUrl: 'https://sentry.io/privacy/',
    name: 'Sentry',
    url: 'https://mcp.sentry.dev/mcp',
    category: 'Developer',
    description: 'Issues, events and stack traces from your projects.',
  ),
  McpCatalogueEntry(
    id: 'vercel',
    termsUrl: 'https://vercel.com/legal/terms',
    privacyUrl: 'https://vercel.com/legal/privacy-notice',
    name: 'Vercel',
    url: 'https://mcp.vercel.com',
    category: 'Developer',
    description: 'Projects, deployments and logs.',
  ),
  McpCatalogueEntry(
    id: 'gitlab',
    termsUrl: 'https://about.gitlab.com/terms/',
    privacyUrl: 'https://about.gitlab.com/privacy/',
    name: 'GitLab',
    url: 'https://gitlab.com/api/v4/mcp',
    category: 'Developer',
    description: 'Issues, merge requests, pipelines and projects.',
  ),
  McpCatalogueEntry(
    id: 'supabase',
    termsUrl: 'https://supabase.com/terms',
    privacyUrl: 'https://supabase.com/privacy',
    name: 'Supabase',
    url: 'https://mcp.supabase.com/mcp',
    category: 'Developer',
    description: 'Projects, tables, SQL and logs.',
  ),
  McpCatalogueEntry(
    id: 'webflow',
    termsUrl: 'https://webflow.com/legal/terms',
    privacyUrl: 'https://webflow.com/legal/privacy',
    name: 'Webflow',
    url: 'https://mcp.webflow.com/sse',
    category: 'Developer',
    description: 'Sites, collections and CMS items.',
  ),
  McpCatalogueEntry(
    id: 'huggingface',
    termsUrl: 'https://huggingface.co/terms-of-service',
    privacyUrl: 'https://huggingface.co/privacy',
    name: 'Hugging Face',
    url: 'https://huggingface.co/mcp',
    category: 'Developer',
    description: 'Search models, datasets, spaces and papers.',
  ),
  McpCatalogueEntry(
    id: 'firecrawl',
    termsUrl: 'https://www.firecrawl.dev/terms-of-service',
    privacyUrl: 'https://www.firecrawl.dev/privacy-policy',
    name: 'Firecrawl',
    // The `-oauth` endpoint, not the plain `/v2/mcp` one. The plain endpoint
    // answers 200 keyless (Search/Scrape/Parse with limits) and never sends a
    // 401, so the browser sign-in would never start; `-oauth` returns 401 with
    // the resource-metadata challenge, and its authorization server
    // (`www.firecrawl.dev`) supports RFC 7591 registration + PKCE, so the
    // ordinary connect flow signs the reader in and unlocks the account tools.
    url: 'https://mcp.firecrawl.dev/v2/mcp-oauth',
    category: 'Developer',
    description:
        'Scrape pages to clean markdown, search the web, map a site\'s URLs '
        'and run multi-page research.',
    // Duplicates the built-in web search / crawl — only wanted in CoWork.
    coworkOnly: true,
  ),
  McpCatalogueEntry(
    id: 'posthog',
    termsUrl: 'https://posthog.com/terms',
    privacyUrl: 'https://posthog.com/privacy',
    name: 'PostHog',
    url: 'https://mcp.posthog.com/mcp',
    category: 'Developer',
    description:
        'Query product analytics, insights, feature flags and error tracking.',
  ),
  McpCatalogueEntry(
    id: 'browserbase',
    name: 'Browserbase',
    url: 'https://mcp.browserbase.com/mcp',
    category: 'Developer',
    description: 'Headless browser automation and web scraping.',
    publisher: 'browserbase.com',
    iconUrl: 'https://www.google.com/s2/favicons?domain=browserbase.com&sz=128',
    // Needs command-style execution — only wanted in CoWork.
    coworkOnly: true,
  ),
  McpCatalogueEntry(
    id: 'exa',
    name: 'Exa',
    url: 'https://mcp.exa.ai/mcp',
    category: 'Developer',
    description: 'AI-powered web search and content retrieval.',
    publisher: 'exa.ai',
    iconUrl: 'https://www.google.com/s2/favicons?domain=exa.ai&sz=128',
    // Duplicates the built-in web search — only wanted in CoWork.
    coworkOnly: true,
  ),

  // ─── Creative ──────────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'figma',
    termsUrl: 'https://www.figma.com/legal/tos/',
    privacyUrl: 'https://www.figma.com/legal/privacy/',
    name: 'Figma',
    url: 'https://mcp.figma.com/mcp',
    category: 'Creative',
    description:
        'Read design files and design data, and turn frames into code.',
  ),
  McpCatalogueEntry(
    id: 'mobbin',
    termsUrl: 'https://mobbin.com/terms',
    privacyUrl: 'https://mobbin.com/privacy',
    name: 'Mobbin',
    url: 'https://api.mobbin.com/mcp',
    category: 'Creative',
    description:
        'Search real app screens, flows and UI patterns from thousands of '
        'apps.',
  ),
  McpCatalogueEntry(
    id: 'higgsfield',
    termsUrl: 'https://higgsfield.ai/terms-of-use-agreement',
    privacyUrl: 'https://higgsfield.ai/privacy-policy',
    name: 'Higgsfield',
    url: 'https://mcp.higgsfield.ai/mcp',
    category: 'Creative',
    description: 'Generate images and video across 30+ models.',
  ),
  McpCatalogueEntry(
    id: 'fal',
    termsUrl: 'https://fal.ai/legal/terms-of-service',
    privacyUrl: 'https://fal.ai/legal/privacy-policy',
    name: 'fal.ai',
    url: 'https://mcp.fal.ai/mcp',
    category: 'Creative',
    description:
        'Run image, video and audio models, and check what a run cost.',
    websiteUrl: 'https://fal.ai',
  ),
  McpCatalogueEntry(
    id: 'vidiq',
    termsUrl: 'https://vidiq.com/terms/',
    privacyUrl: 'https://vidiq.com/privacy/',
    name: 'vidIQ',
    url: 'https://mcp.vidiq.com/mcp',
    category: 'Creative',
    description:
        'YouTube keyword research, channel and video stats, titles and '
        'thumbnails.',
    websiteUrl: 'https://vidiq.com',
  ),
  McpCatalogueEntry(
    id: 'heygen-hyperframes',
    termsUrl: 'https://www.heygen.com/terms',
    privacyUrl: 'https://www.heygen.com/privacy',
    name: 'HyperFrames by HeyGen',
    // Direct endpoint — mcp.heygen.com/mcp/hyperframes/ only 307-redirects here.
    url: 'https://hyperframes.heygen.com/mcp',
    category: 'Creative',
    description: 'Avatar video generation.',
    iconUrl: 'https://www.google.com/s2/favicons?domain=heygen.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'gamma',
    name: 'Gamma',
    url: 'https://mcp.gamma.app/mcp',
    category: 'Creative',
    description: 'Generate presentations, decks and documents.',
    publisher: 'gamma.app',
    iconUrl: 'https://www.google.com/s2/favicons?domain=gamma.app&sz=128',
  ),

  // ─── Finance ───────────────────────────────────────────────────────────
  McpCatalogueEntry(
    id: 'square',
    termsUrl: 'https://squareup.com/us/en/legal/general/ua',
    privacyUrl: 'https://squareup.com/us/en/legal/general/privacy-no-account',
    name: 'Square',
    url: 'https://mcp.squareup.com/mcp',
    category: 'Finance',
    description: 'Payments, orders, customers and catalog.',
  ),
  McpCatalogueEntry(
    id: 'paypal',
    termsUrl: 'https://www.paypal.com/us/legalhub/useragreement-full',
    privacyUrl: 'https://www.paypal.com/us/legalhub/paypal/privacy-full',
    name: 'PayPal',
    url: 'https://mcp.paypal.com/mcp',
    category: 'Finance',
    description: 'Invoices, orders, payments and disputes.',
  ),
  McpCatalogueEntry(
    id: 'coingecko',
    name: 'CoinGecko',
    url: 'https://mcp.api.coingecko.com/mcp',
    category: 'Finance',
    description: 'Live crypto prices, market data, coins and exchanges.',
    publisher: 'coingecko.com',
    // `mcp.api.coingecko.com` strips to `api.coingecko.com`, a service host the
    // favicon service does not know — pin the real logo.
    iconUrl: 'https://www.google.com/s2/favicons?domain=coingecko.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'whop',
    name: 'Whop',
    url: 'https://mcp.whop.com/mcp',
    category: 'Finance',
    description: 'Digital products, memberships and payments.',
    publisher: 'whop.com',
    iconUrl: 'https://www.google.com/s2/favicons?domain=whop.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'robinhood',
    name: 'Robinhood',
    url: 'https://agent.robinhood.com/mcp/trading',
    category: 'Finance',
    description: 'Trading, quotes, positions and portfolio.',
    publisher: 'robinhood.com',
    // `agent.robinhood.com` → robinhood.com favicon resolves fine, pinned for safety.
    iconUrl: 'https://www.google.com/s2/favicons?domain=robinhood.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'spglobal',
    name: 'S&P Global',
    url: 'https://kfinance.kensho.com/integrations/mcp',
    category: 'Finance',
    description: 'Company financials and market intelligence (Kensho Kfinance).',
    publisher: 'spglobal.com',
    // Endpoint lives on kfinance.kensho.com — pin the S&P Global logo.
    iconUrl: 'https://www.google.com/s2/favicons?domain=spglobal.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'etoro',
    name: 'eToro',
    url: 'https://mcp.public-api.etoro.com',
    category: 'Finance',
    description: 'Market data, portfolios and trading insights.',
    publisher: 'etoro.com',
    iconUrl: 'https://www.google.com/s2/favicons?domain=etoro.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'webull',
    name: 'Webull',
    url: 'https://api.webull.com/mcp',
    category: 'Finance',
    description: 'Quotes, market data and account information.',
    publisher: 'webull.com',
    iconUrl: 'https://www.google.com/s2/favicons?domain=webull.com&sz=128',
  ),
  McpCatalogueEntry(
    id: 'ibkr',
    name: 'Interactive Brokers',
    url: 'https://api.ibkr.com/v1/api/mcp',
    category: 'Finance',
    description:
        'Portfolio positions, balances, P&L, open orders, real-time quotes '
        'and historical market data.',
    publisher: 'ibkr.com',
    iconUrl: 'https://www.google.com/s2/favicons?domain=ibkr.com&sz=128',
  ),
];

/// The domain a registry namespace stands for: `com.notion` → `notion.com`.
///
/// The registry hands out namespaces only to whoever proves they own the
/// domain, so the namespace is the one field in a registry entry that a
/// stranger cannot claim.
String? namespaceDomain(String serverName) {
  final namespace = serverName.split('/').first.trim().toLowerCase();
  if (namespace.isEmpty) return null;
  final parts = namespace.split('.').where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return null;
  return parts.reversed.join('.');
}

/// Whether [remoteUrl] is served by the same domain that publishes
/// [serverName] — the check that separates a company's own server from a
/// stranger's server that merely mentions the company.
///
/// `io.github.<user>` namespaces are refused outright. They prove only that
/// someone holds a GitHub account, and the endpoint behind them can point
/// anywhere, so a reader searching for "notion" could be handed a look-alike
/// that collects the sign-in instead.
bool isFirstPartyRemote(String serverName, String remoteUrl) {
  final namespace = serverName.split('/').first.trim().toLowerCase();
  if (namespace.startsWith('io.github.')) return false;

  final domain = namespaceDomain(serverName);
  final host = Uri.tryParse(remoteUrl)?.host.toLowerCase();
  if (domain == null || host == null || host.isEmpty) return false;
  return host == domain || host.endsWith('.$domain');
}

/// Whether the registry still stands behind this entry — `active`, and the
/// newest version published. Deleted and superseded rows stay queryable.
bool _isCurrentRegistryEntry(Object? meta) {
  if (meta is! Map) return true;
  final official = meta['io.modelcontextprotocol.registry/official'];
  if (official is! Map) return true;
  final status = official['status'];
  if (status != null && status != 'active') return false;
  return official['isLatest'] != false;
}

/// Search the official MCP registry for anything not in the catalogue.
///
/// Only entries with a remote endpoint come back: a package that has to be
/// run locally is of no use to this app. Of those, only the ones the
/// publishing domain serves itself survive [isFirstPartyRemote] — the
/// registry is open to anyone, so an unfiltered list is a list of
/// look-alikes waiting to be signed in to. Pass [firstPartyOnly] as false
/// to see the rest.
Future<List<McpCatalogueEntry>> searchMcpRegistry(
  String query, {
  http.Client? httpClient,
  int limit = 20,
  bool firstPartyOnly = true,
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
    // The registry answers with every published version of a server, so the
    // same connector arrives several times over. Keeping the first is enough:
    // ids are what the rest of the app connects by.
    final seen = <String>{};
    for (final entry in servers) {
      final server = entry is Map ? entry['server'] : null;
      if (server is! Map) continue;
      if (entry is Map && !_isCurrentRegistryEntry(entry['_meta'])) continue;

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
      if (firstPartyOnly && !isFirstPartyRemote(name, url)) continue;

      final id = slugFor(name);
      if (!seen.add(id)) continue;

      results.add(
        McpCatalogueEntry(
          id: id,
          name: server['title']?.toString().trim().isNotEmpty == true
              ? server['title'].toString()
              : name.split('/').last,
          url: url,
          category: 'Registry',
          description: server['description']?.toString() ?? '',
          publisher: namespaceDomain(name),
          websiteUrl: server['websiteUrl']?.toString(),
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
