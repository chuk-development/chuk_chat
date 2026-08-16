// The terms and privacy links of every offered connector, against the real
// sites.
//
// These addresses are typed in by hand, because no MCP server publishes them:
// RFC 9728 reserves `resource_tos_uri` and `resource_policy_uri` in the
// protected-resource metadata, and every server checked leaves both out. A
// hand-typed link rots — companies move `/terms` to `/legal/terms` — and a
// dead link under a "by connecting you agree" sentence is worse than no
// sentence at all. This test is what notices.
//
// It talks to the internet, so it is off by default. Run it on purpose:
//
//     flutter test test/mcp/mcp_legal_links_live_test.dart --dart-define=MCP_LIVE=true

// `package:http` rather than `dart:io`: a Chrome test build compiles this
// file before it ever evaluates the live flag, and an IO-only import fails
// that build even with every case skipped.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';

const bool _live = bool.fromEnvironment('MCP_LIVE');

/// A browser user agent. Several of these sites answer a bare Dart client
/// with a challenge page, which would fail the test for the wrong reason.
const String _userAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/139.0.0.0 Safari/537.36';

Future<int> _statusOf(String url) async {
  final client = http.Client();
  try {
    final response = await client
        .get(Uri.parse(url), headers: const {'user-agent': _userAgent})
        .timeout(const Duration(seconds: 20));
    return response.statusCode;
  } finally {
    client.close();
  }
}

void main() {
  final entries = [...firstPartyConnectors(), ...kMcpCatalogue];

  test('every offered connector names its terms and its privacy policy', () {
    final missing = entries
        .where((e) => e.termsUrl == null || e.privacyUrl == null)
        .map((e) => e.id)
        .toList();
    expect(missing, isEmpty, reason: 'connectors without legal links');
  });

  test('the links are https, not a scheme the platform would hand on', () {
    for (final entry in entries) {
      for (final url in [entry.termsUrl, entry.privacyUrl]) {
        if (url == null) continue;
        expect(url, startsWith('https://'), reason: '${entry.id}: $url');
      }
    }
  });

  for (final entry in entries) {
    for (final pair in [
      ('terms', entry.termsUrl),
      ('privacy policy', entry.privacyUrl),
    ]) {
      final (label, url) = pair;
      test(
        '${entry.name} still serves its $label',
        () async {
          // What this test is for is the link that MOVED — 404 and 410. A
          // 401/403/429 is the site's bot wall answering a Dart client
          // (Canva and Notion both do this, and both serve the same page
          // fine to a browser), so it says nothing about the address.
          // 404/410 is the link that moved. 500s are the site being broken
          // — also worth knowing. Only the three bot-wall codes pass.
          const botWall = [401, 403, 429];
          final status = await _statusOf(url!);
          expect(
            status == 200 || botWall.contains(status),
            isTrue,
            reason: '$url answered $status — find where the page moved',
          );
          if (status != 200) {
            // ignore: avoid_print
            print('  note: $url answered $status (bot wall, not a dead link)');
          }
        },
        skip: !_live || url == null
            ? 'live check — pass --dart-define=MCP_LIVE=true'
            : null,
      );
    }
  }
}
