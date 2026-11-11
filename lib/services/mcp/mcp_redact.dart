// lib/services/mcp/mcp_redact.dart
//
// Masks credentials in MCP error text before the model or the user sees it.
// A server (or an HTTP client exception) can echo the request back: the
// bearer token, an `authorization` header, or the credentialed URL of an
// API-key connector. None of that may reach a chat transcript.

/// What replaces a masked value.
const String kMcpRedacted = '[redacted]';

/// Known secrets shorter than this are not masked by value: a 2-character
/// "secret" would shred ordinary text. Patterns below still catch them.
const int _kMinSecretLength = 6;

final RegExp _authScheme = RegExp(
  r'\b(Bearer|Basic|Token|Bot)\s+[A-Za-z0-9._~+/=-]{4,}',
  caseSensitive: false,
);

final RegExp _secretHeader = RegExp(
  r'''(["']?\b(?:authorization|proxy-authorization|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie)\b["']?\s*[:=]\s*)(["']?)[^"'\r\n,;}]+''',
  caseSensitive: false,
);

final RegExp _secretQuery = RegExp(
  r'''([?&;](?:api[_-]?key|key|token|access[_-]?token|refresh[_-]?token|id[_-]?token|auth|secret|client[_-]?secret|password|passwd|pwd|sig|signature|code)=)[^&\s"'#<>]+''',
  caseSensitive: false,
);

final RegExp _urlUserInfo = RegExp(
  r'\b([a-z][a-z0-9+.-]*://)[^/\s@:]+:[^/\s@]+@',
  caseSensitive: false,
);

/// [text] with credentials masked: every value in [secrets] (also in its
/// URL-encoded form), `Bearer …` tokens, secret header values, secret query
/// parameters and `user:pass@` in URLs.
String redactMcpSecrets(String text, {Iterable<String?> secrets = const []}) {
  if (text.isEmpty) return text;
  var out = text;

  final values =
      <String>{
          for (final s in secrets)
            if (s != null && s.trim().length >= _kMinSecretLength) ...{
              s.trim(),
              Uri.encodeQueryComponent(s.trim()),
              Uri.encodeComponent(s.trim()),
            },
        }.toList()
        // Longest first, so a secret that contains another is masked whole.
        ..sort((a, b) => b.length.compareTo(a.length));
  for (final v in values) {
    out = out.replaceAll(v, kMcpRedacted);
  }

  out = out.replaceAllMapped(_authScheme, (m) => '${m.group(1)} $kMcpRedacted');
  out = out.replaceAllMapped(
    _secretHeader,
    (m) => '${m.group(1)}${m.group(2)}$kMcpRedacted',
  );
  out = out.replaceAllMapped(_secretQuery, (m) => '${m.group(1)}$kMcpRedacted');
  out = out.replaceAllMapped(
    _urlUserInfo,
    (m) => '${m.group(1)}$kMcpRedacted@',
  );
  return out;
}

/// The secret values an MCP request to [endpoint] carries: the bearer
/// [accessToken], every query value and the user-info of the URL.
List<String> mcpSecretsOf(Uri endpoint, {String? accessToken}) => <String>[
  ?accessToken,
  for (final values in endpoint.queryParametersAll.values) ...values,
  if (endpoint.userInfo.isNotEmpty) ...endpoint.userInfo.split(':'),
];
