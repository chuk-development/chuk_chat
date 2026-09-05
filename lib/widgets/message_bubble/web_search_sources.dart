// lib/widgets/message_bubble/web_search_sources.dart
//
// Formatted rendering for `web_search` / `web_crawl` tool results. The raw
// tool result is a numbered plain-text list of hits (title, indented URL, a
// snippet, an `age:` line, and extended bullets). Rather than dumping that as
// monospace text with the model's `<strong>` tags showing, we parse it into
// source cards: a favicon, the title, the host, and a bit of snippet text.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// One parsed hit from a web_search result.
class WebSearchSource {
  const WebSearchSource({
    required this.title,
    required this.url,
    required this.host,
    required this.snippet,
    this.age,
  });

  final String title;
  final String url;
  final String host;
  final String snippet;
  final String? age;
}

/// Strip HTML tags + the handful of entities the search backend emits, and
/// collapse whitespace. The model marks a match with `<strong>…</strong>`;
/// those tags are noise in a rendered card.
String _clean(String s) => s
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _hostOf(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.replaceFirst(RegExp(r'^www\.'), '');
}

/// Parse a `web_search` result into ordered source hits. Returns an empty
/// list when the text is not the numbered-hit shape (the caller then falls
/// back to the raw text section).
List<WebSearchSource> parseWebSearchSources(String result) {
  final List<String> lines = result.split('\n');
  final List<WebSearchSource> items = <WebSearchSource>[];

  final RegExp numbered = RegExp(r'^\s*\d+\.\s+(.+)$');
  final RegExp urlRe = RegExp(r'^\s*(https?://\S+)');
  final RegExp ageRe = RegExp(r'^\s*age:\s*(.+)$', caseSensitive: false);
  final RegExp bulletLead = RegExp(r'^[•\-*]\s*');

  String? title;
  String? url;
  String? age;
  final List<String> snippetParts = <String>[];

  void flush() {
    final String? u = url;
    if (u != null && u.trim().isNotEmpty) {
      final String host = _hostOf(u);
      items.add(
        WebSearchSource(
          title: (title != null && title!.trim().isNotEmpty)
              ? _clean(title!)
              : (host.isNotEmpty ? host : u.trim()),
          url: u.trim(),
          host: host,
          snippet: _clean(snippetParts.join(' ')),
          age: age?.trim(),
        ),
      );
    }
    title = null;
    url = null;
    age = null;
    snippetParts.clear();
  }

  for (final String line in lines) {
    final RegExpMatch? m = numbered.firstMatch(line);
    if (m != null) {
      flush();
      title = m.group(1);
      continue;
    }
    // Skip the preamble before the first numbered hit.
    if (title == null && url == null) continue;

    final RegExpMatch? u = urlRe.firstMatch(line);
    if (u != null && url == null) {
      url = u.group(1);
      continue;
    }
    final RegExpMatch? a = ageRe.firstMatch(line);
    if (a != null) {
      age ??= a.group(1);
      continue;
    }
    // Everything else is snippet prose. Keep a bounded amount so one very long
    // hit doesn't dominate the card.
    final String t = line.trim().replaceFirst(bulletLead, '');
    if (t.isNotEmpty && snippetParts.join(' ').length < 240) {
      snippetParts.add(t);
    }
  }
  flush();
  return items;
}

/// Renders parsed [WebSearchSource]s as tappable source cards.
class WebSearchSourcesCard extends StatelessWidget {
  const WebSearchSourcesCard({
    super.key,
    required this.sources,
    required this.textColor,
    required this.accentColor,
  });

  final List<WebSearchSource> sources;
  final Color textColor;
  final Color accentColor;

  Future<void> _open(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final bool launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {
      // No handler for the URL — nothing to do.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final WebSearchSource s in sources)
          _SourceCard(
            source: s,
            textColor: textColor,
            accentColor: accentColor,
            onTap: () => _open(s.url),
          ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.textColor,
    required this.accentColor,
    required this.onTap,
  });

  final WebSearchSource source;
  final Color textColor;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color border = textColor.withValues(alpha: 0.12);
    final Color muted = textColor.withValues(alpha: 0.55);
    final Color bodyColor = textColor.withValues(alpha: 0.82);

    final String meta = <String>[
      if (source.host.isNotEmpty) source.host,
      if (source.age != null && source.age!.isNotEmpty) source.age!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: border),
              color: textColor.withValues(alpha: 0.02),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _Favicon(host: source.host, accent: accentColor, muted: muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        source.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: accentColor,
                        ),
                      ),
                      if (meta.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                      ],
                      if (source.snippet.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          source.snippet,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: bodyColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Favicon for [host] via Google's public favicon service, with a globe
/// fallback while it loads or when the host has no icon.
class _Favicon extends StatelessWidget {
  const _Favicon({
    required this.host,
    required this.accent,
    required this.muted,
  });

  final String host;
  final Color accent;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    const double size = 20;
    final Widget fallback = Icon(Icons.public_rounded, size: 14, color: muted);

    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        width: size,
        height: size,
        child: host.isEmpty
            ? Center(child: fallback)
            : Image.network(
                'https://www.google.com/s2/favicons?domain=$host&sz=64',
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(child: fallback),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : Center(child: fallback),
              ),
      ),
    );
  }
}
