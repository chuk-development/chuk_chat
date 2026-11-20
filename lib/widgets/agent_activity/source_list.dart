// lib/widgets/agent_activity/source_list.dart
//
// The list behind the "N sources" pill: one row per page, never the same
// page twice, and never the same text as title and as subtitle.

import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';

/// The key that says two links point to the same page.
///
/// The scheme, a leading `www.`, the `#fragment`, a trailing slash and the
/// case of the host do not change the page, so they do not count.
String sourcePageKey(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return url.trim().toLowerCase();
  final String host = uri.host.toLowerCase().replaceFirst(
    RegExp(r'^www\.'),
    '',
  );
  String path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final String query = uri.hasQuery ? '?${uri.query}' : '';
  return '$host$path$query';
}

/// [sources] with each page once, in first-seen order.
///
/// When a page comes twice, the row keeps the first real title it finds, so
/// a bare link seen first does not hide the title a search gave later.
List<AgentActivitySource> dedupeSources(Iterable<AgentActivitySource> sources) {
  final Map<String, AgentActivitySource> byKey =
      <String, AgentActivitySource>{};
  for (final AgentActivitySource source in sources) {
    final String key = sourcePageKey(source.url);
    final AgentActivitySource? seen = byKey[key];
    if (seen == null) {
      byKey[key] = source;
    } else if (sourceRealTitle(seen) == null &&
        sourceRealTitle(source) != null) {
      byKey[key] = AgentActivitySource(
        url: seen.url,
        host: seen.host,
        title: source.title,
      );
    }
  }
  return byKey.values.toList(growable: false);
}

/// The page title of [source], or null when it only repeats the link or the
/// domain (a result with no title gets its host as title).
String? sourceRealTitle(AgentActivitySource source) {
  final String title = source.title.trim();
  if (title.isEmpty) return null;
  final String bare = title.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  if (bare == source.host.toLowerCase()) return null;
  if (RegExp(r'^https?://').hasMatch(title)) return null;
  if (sourcePageKey(title) == sourcePageKey(source.url)) return null;
  return title;
}

/// A readable name from the last part of the link's path, e.g.
/// `.../wiki/Brandenburger_Tor` gives "Brandenburger Tor". Null when the
/// path has no such part (a home page).
String? sourcePathTitle(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  final List<String> parts = uri.pathSegments
      .where((String p) => p.trim().isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return null;
  String last = parts.last;
  try {
    last = Uri.decodeComponent(last);
  } on FormatException {
    // Keep the raw segment.
  }
  last = last
      .replaceFirst(RegExp(r'\.(html?|php|aspx?)$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[_+-]+'), ' ')
      .trim();
  // A language code or an id alone ("en", "123") says nothing.
  if (last.length < 3 || RegExp(r'^[0-9 ]+$').hasMatch(last)) return null;
  return last;
}

/// The two lines of a source row.
///
/// Title: the page title, else a name from the link's path, else the domain.
/// Subtitle: the domain, only when the title is not the domain already.
({String title, String? subtitle}) sourceRowLabels(AgentActivitySource source) {
  final String? title = sourceRealTitle(source) ?? sourcePathTitle(source.url);
  if (title == null) return (title: source.host, subtitle: null);
  return (title: title, subtitle: source.host);
}
