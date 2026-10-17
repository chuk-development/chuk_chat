// Safety rules for every app run of the agent driver.
//
// 1. The app gets its own data folders (XDG_DATA_HOME, XDG_CACHE_HOME,
//    XDG_STATE_HOME) under _scratch/. Without them the debug app uses
//    ~/.local/share/dev.chuk.chat, the folder of the installed app, and
//    replaces the session and the chat cache of the real login.
// 2. CHUK_MULTI_INSTANCE=1, so the Linux single-instance lock does not stop
//    the app while the installed app runs.
// 3. The app talks only to the local E2E stack: API_BASE_URL and
//    SUPABASE_URL must be loopback addresses.
//
// These are the same rules as _scratch/run_it.sh and
// docs/INTEGRATION_TESTS.md.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when a start would break a safety rule.
class IsolationError implements Exception {
  IsolationError(this.message);
  final String message;
  @override
  String toString() => 'IsolationError: $message';
}

/// The data folders of one isolated app run.
class AppHome {
  AppHome(this.root);

  /// For example `<repo>/_scratch/agent_home`.
  final String root;

  String get data => p.join(root, 'data');
  String get cache => p.join(root, 'cache');
  String get state => p.join(root, 'state');

  /// Creates the folders. With [fresh], removes the old ones first (this
  /// signs the app out, so it starts on the sign-in page).
  void prepare({required bool fresh}) {
    final Directory dir = Directory(root);
    if (fresh && dir.existsSync()) dir.deleteSync(recursive: true);
    for (final String d in <String>[data, cache, state]) {
      Directory(d).createSync(recursive: true);
    }
  }
}

/// Returns the environment for the app process: [base] plus the isolated
/// XDG folders and CHUK_MULTI_INSTANCE=1.
///
/// Throws [IsolationError] when [home] is not strictly inside [scratchDir]
/// (the `_scratch/` folder of the repository). The real data folders of the
/// user (~/.local/share, ~/.cache, ~/.local/state) are never inside it.
Map<String, String> isolatedEnvironment({
  required Map<String, String> base,
  required AppHome home,
  required String scratchDir,
}) {
  final String root = p.normalize(p.absolute(home.root));
  final String scratch = p.normalize(p.absolute(scratchDir));
  if (!p.isWithin(scratch, root)) {
    throw IsolationError(
      'The app home "$root" is not inside "$scratch". '
      'The app must not use the real data folders.',
    );
  }
  return <String, String>{
    ...base,
    'XDG_DATA_HOME': home.data,
    'XDG_CACHE_HOME': home.cache,
    'XDG_STATE_HOME': home.state,
    'CHUK_MULTI_INSTANCE': '1',
  };
}

/// URL defines that the app reads. Each one that is set must point to a
/// loopback address. Otherwise one of them (for example PRODUCTION_API_URL,
/// which wins over API_BASE_URL) could send traffic to production.
const List<String> optionalUrlDefines = <String>[
  'PRODUCTION_API_URL',
  'LOCAL_API_URL',
  'AGENTS_RELAY_URL',
  'AGENTS_DEV_HOST',
  'ARTIFACTS_BASE_URL',
  'SKILLS_CATALOG_BASE',
  'VOICE_TOKEN_URL',
];

/// True for `localhost`, `127.0.0.1` and `::1` (also in brackets).
bool isLoopbackHost(String host) {
  String h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  return h == '127.0.0.1' || h == 'localhost' || h == '::1';
}

bool _isLoopbackUrl(Object? value) {
  final Uri? uri = value is String ? Uri.tryParse(value.trim()) : null;
  return uri != null && isLoopbackHost(uri.host);
}

/// Throws [IsolationError] unless API_BASE_URL and SUPABASE_URL in
/// [defines] point to a loopback address, and every other URL define that
/// is set ([optionalUrlDefines], API_HOST) does too. FEATURE_LINUX_KEYRING
/// must be false or not set.
void checkLocalDefines(Map<String, Object?> defines) {
  for (final String key in <String>['API_BASE_URL', 'SUPABASE_URL']) {
    final Object? value = defines[key];
    if (!_isLoopbackUrl(value)) {
      throw IsolationError(
        '$key must point to the local E2E stack (got "${value ?? ''}"). '
        'Start it with scripts/e2e_stack.sh up and use '
        '_scratch/e2e.defines.json.',
      );
    }
  }
  for (final String key in optionalUrlDefines) {
    final Object? value = defines[key];
    if (value == null || (value is String && value.trim().isEmpty)) continue;
    if (!_isLoopbackUrl(value)) {
      throw IsolationError(
        '$key must be empty or point to a loopback address '
        '(got "$value").',
      );
    }
  }
  final Object? apiHost = defines['API_HOST'];
  if (apiHost != null && '$apiHost'.trim().isNotEmpty) {
    if (apiHost is! String || !isLoopbackHost(apiHost)) {
      throw IsolationError(
        'API_HOST must be empty or a loopback host (got "$apiHost").',
      );
    }
  }
  // The XDG folders do not isolate the system keyring. With the keyring on,
  // the test app would read and overwrite the installed app's entries.
  final String keyring =
      '${defines['FEATURE_LINUX_KEYRING'] ?? 'false'}'.trim().toLowerCase();
  if (keyring != 'false') {
    throw IsolationError(
      'FEATURE_LINUX_KEYRING must be false: the system keyring is shared '
      'with the installed app (got "$keyring").',
    );
  }
}
