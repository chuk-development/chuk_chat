// lib/utils/secret_mask.dart
//
// Finds credentials (API keys, access tokens, JWTs) in free text, so a user
// bubble can show a pasted key masked instead of in full on screen.
//
// The patterns follow the published token formats. Each one asks for a
// minimum length and a word boundary on the left, and every match must
// contain at least one digit, so normal words ("sk-learn", "task-runner")
// are never masked. The list is reusable: the composer can call
// [containsSecret] to warn before a send.

/// One credential found in a text.
class SecretMatch {
  const SecretMatch({
    required this.start,
    required this.end,
    required this.value,
    required this.kind,
  });

  /// Start offset in the source text (inclusive).
  final int start;

  /// End offset in the source text (exclusive).
  final int end;

  /// The credential as written.
  final String value;

  /// The format that matched, e.g. `openai`, `github`, `jwt`.
  final String kind;
}

/// A named credential format.
class SecretPattern {
  const SecretPattern(this.kind, this.pattern);

  final String kind;
  final String pattern;
}

/// Left boundary: the key must not continue a longer word.
const String _lb = r'(?<![A-Za-z0-9_\-])';

/// Right boundary: the key must not run on into more key characters.
const String _rb = r'(?![A-Za-z0-9_\-])';

/// The credential formats, most specific first. Overlaps resolve to the
/// match that starts first, then the longer one.
const List<SecretPattern> kSecretPatterns = <SecretPattern>[
  SecretPattern('anthropic', '${_lb}sk-ant-[A-Za-z0-9_\\-]{20,}$_rb'),
  SecretPattern('openai', '${_lb}sk-(?!ant-)[A-Za-z0-9_\\-]{20,}$_rb'),
  SecretPattern('github', '${_lb}gh[pousr]_[A-Za-z0-9]{30,}$_rb'),
  SecretPattern('github', '${_lb}github_pat_[A-Za-z0-9_]{22,}$_rb'),
  SecretPattern('gitlab', '${_lb}glpat-[A-Za-z0-9_\\-]{20,}$_rb'),
  SecretPattern('npm', '${_lb}npm_[A-Za-z0-9]{36,}$_rb'),
  SecretPattern('huggingface', '${_lb}hf_[A-Za-z0-9]{30,}$_rb'),
  SecretPattern('aws', '${_lb}AKIA[0-9A-Z]{16}$_rb'),
  SecretPattern('google', '${_lb}AIza[0-9A-Za-z_\\-]{35}$_rb'),
  // Bot, user, app, refresh (`xoxe-`, `xoxe.xoxp-`), legacy and session.
  SecretPattern(
    'slack',
    '${_lb}xox[abeprs](?:\\.xox[bp])?-[0-9A-Za-z\\-]{10,}$_rb',
  ),
  // Stripe secret and restricted keys, live and test mode.
  SecretPattern('stripe', '$_lb[sr]k_(?:live|test)_[0-9A-Za-z]{16,}$_rb'),
  SecretPattern(
    'jwt',
    '${_lb}eyJ[A-Za-z0-9_\\-]{10,}\\.eyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}$_rb',
  ),
];

final List<(String, RegExp)> _compiled = <(String, RegExp)>[
  for (final SecretPattern p in kSecretPatterns) (p.kind, RegExp(p.pattern)),
];

final RegExp _digit = RegExp(r'[0-9]');

/// Every credential in [text], in order, without overlaps.
List<SecretMatch> findSecrets(String text) {
  if (text.length < 16) return const <SecretMatch>[];
  final List<SecretMatch> all = <SecretMatch>[];
  for (final (String kind, RegExp re) in _compiled) {
    for (final RegExpMatch m in re.allMatches(text)) {
      final String value = m.group(0)!;
      if (!_digit.hasMatch(value)) continue;
      all.add(
        SecretMatch(start: m.start, end: m.end, value: value, kind: kind),
      );
    }
  }
  if (all.isEmpty) return const <SecretMatch>[];
  all.sort((a, b) {
    final int byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    return (b.end - b.start).compareTo(a.end - a.start);
  });
  final List<SecretMatch> out = <SecretMatch>[];
  int lastEnd = -1;
  for (final SecretMatch m in all) {
    if (m.start < lastEnd) continue;
    out.add(m);
    lastEnd = m.end;
  }
  return out;
}

/// Whether [text] holds at least one credential. For a warning before send.
bool containsSecret(String text) => findSecrets(text).isNotEmpty;

/// How many characters of a credential stay readable.
const int kSecretVisiblePrefix = 8;

/// Most mask characters drawn after the prefix; a 900-character JWT does not
/// need 892 dots to say "hidden".
const int kSecretMaxMaskChars = 16;

/// The masked form: the first [kSecretVisiblePrefix] characters, then dots.
String maskSecret(String value) {
  if (value.length <= kSecretVisiblePrefix) return value;
  final int hidden = value.length - kSecretVisiblePrefix;
  final int dots = hidden > kSecretMaxMaskChars ? kSecretMaxMaskChars : hidden;
  return '${value.substring(0, kSecretVisiblePrefix)}${'•' * dots}';
}

/// [text] with every credential masked. For previews (notifications, the
/// sidebar line) where no toggle exists.
String maskSecretsIn(String text) {
  final List<SecretMatch> matches = findSecrets(text);
  if (matches.isEmpty) return text;
  final StringBuffer out = StringBuffer();
  int pos = 0;
  for (final SecretMatch m in matches) {
    out.write(text.substring(pos, m.start));
    out.write(maskSecret(m.value));
    pos = m.end;
  }
  out.write(text.substring(pos));
  return out.toString();
}
