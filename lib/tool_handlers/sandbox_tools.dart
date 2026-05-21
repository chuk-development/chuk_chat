import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chuk_chat/services/sandbox_service.dart';

// Per-chat sandbox cache. A chat keeps the same session_id across tool
// calls so state (files, installed packages, variables) persists.
final Map<String, String> _sessionByChat = {};

// Coalesces concurrent _ensureSession calls for the same chat — both the
// "validate cached id" path AND the "create new sandbox" path. Without a
// single in-flight future covering both phases, two simultaneous tool
// calls can both look up a stale cache entry, both fail validation, and
// both create a sandbox.
final Map<String, Future<String>> _inflightEnsure = {};

const int _stdStreamCap = 8000;
const int _textFileCap = 16000;
const int _textInlineByteLimit = 64 * 1024;
const int _maxTimeoutSeconds = 300;

// Hard ceiling on a single ensure attempt. Both SandboxService.get_ and
// SandboxService.create have their own 30s control-plane timeouts, so a
// well-behaved upstream finishes well under this. The wrapper exists as
// belt-and-braces against TLS-handshake stalls or platform-level socket
// hangs that bypass the HTTP-layer timeout — without it a hung ensure
// would block every subsequent code_run for that chat indefinitely.
const Duration _ensureTimeout = Duration(seconds: 75);

Future<String> _ensureSession(String accessToken, String chatId) {
  final inflight = _inflightEnsure[chatId];
  if (inflight != null) return inflight;

  final future = _ensureSessionImpl(accessToken, chatId)
      .timeout(_ensureTimeout);
  _inflightEnsure[chatId] = future;
  // Always clear the in-flight slot regardless of success/error. Using
  // whenComplete keeps the original future's value or error intact for
  // any other awaiters that have already taken a reference to it.
  future.whenComplete(() => _inflightEnsure.remove(chatId));
  return future;
}

Future<String> _ensureSessionImpl(String accessToken, String chatId) async {
  final cached = _sessionByChat[chatId];
  if (cached != null) {
    try {
      final info = await SandboxService.get_(
        accessToken: accessToken,
        sessionId: cached,
      );
      if (info != null) {
        return cached;
      }
      // Server says it's gone — drop the cache entry and fall through
      // to recreate.
      _sessionByChat.remove(chatId);
    } on SandboxServiceException catch (e) {
      // Only treat 404 as "session is genuinely gone". A 502/timeout
      // is transient — propagating it lets the caller decide whether
      // to retry, and keeps the cached id around so we don't churn
      // sandboxes on every blip.
      if (e.statusCode == 404) {
        _sessionByChat.remove(chatId);
      } else {
        rethrow;
      }
    }
  }

  final info = await SandboxService.create(
    accessToken: accessToken,
    chatId: chatId,
  );
  _sessionByChat[chatId] = info.sessionId;
  return info.sessionId;
}

/// Wipe all per-chat sandbox session bookkeeping. Call on sign-out so
/// the next signed-in user doesn't reuse the previous user's cached
/// session id (which would 404 on the server anyway because the owner
/// tag wouldn't match, but the eviction saves a round-trip).
void clearSandboxCache() {
  _sessionByChat.clear();
  _inflightEnsure.clear();
}

String _capStream(String s) {
  if (s.length <= _stdStreamCap) return s;
  final omitted = s.length - _stdStreamCap;
  return '${s.substring(0, _stdStreamCap)}\n'
      '(truncated, $omitted chars omitted)';
}

bool _looksLikeText(Uint8List bytes) {
  if (bytes.length > _textInlineByteLimit) return false;
  for (final b in bytes) {
    if (b == 0) return false;
  }
  try {
    utf8.decode(bytes);
    return true;
  } catch (_) {
    return false;
  }
}

({String dir, String name}) _splitPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  if (idx < 0) {
    return (dir: '/home/sandbox', name: normalized);
  }
  final dir = idx == 0 ? '/' : normalized.substring(0, idx);
  final name = normalized.substring(idx + 1);
  return (dir: dir, name: name);
}

bool _isUnderSandbox(String path) {
  final normalized = path.replaceAll('\\', '/');
  // Reject any path that contains a parent-directory segment — even
  // though the server normalises and re-checks, surfacing the error
  // here means the model gets a clean "path must be under /home/sandbox"
  // instead of a generic upstream 400, and avoids a wasted round-trip.
  final segments = normalized.split('/');
  for (final seg in segments) {
    if (seg == '..') return false;
  }
  return normalized == '/home/sandbox' ||
      normalized.startsWith('/home/sandbox/');
}

String _formatError(SandboxServiceException e) {
  // Include the HTTP status in the message so the AI can distinguish
  // "retry later" (429/502/504) from "give up" (400/404/413) without
  // needing to parse natural language. Keep the literal "Error:" prefix
  // so ToolExecutor's startsWith('Error:') is-error detection still
  // flags these correctly — adding "Error (HTTP …)" broke that.
  return 'Error: HTTP ${e.statusCode} — ${e.message}';
}

Future<String> executeCodeRun({
  required String? accessToken,
  required String? chatId,
  required Map<String, dynamic> args,
}) async {
  if (accessToken == null || accessToken.isEmpty) {
    return 'Error: Not authenticated.';
  }
  if (chatId == null || chatId.isEmpty) {
    return 'Error: No active chat. Start or select a chat first.';
  }

  final rawCode = args['code'];
  final code = rawCode is String ? rawCode : '';
  if (code.isEmpty) {
    return 'Error: "code" parameter required.';
  }

  final rawLanguage = args['language'];
  var language = rawLanguage is String ? rawLanguage.trim() : 'python';
  if (language.isEmpty) language = 'python';
  if (language != 'python' && language != 'shell') {
    return 'Error: "language" must be "python" or "shell".';
  }

  int? timeout;
  final rawTimeout = args['timeout'];
  if (rawTimeout is int) {
    timeout = rawTimeout;
  } else if (rawTimeout is num) {
    timeout = rawTimeout.toInt();
  } else if (rawTimeout is String && rawTimeout.trim().isNotEmpty) {
    timeout = int.tryParse(rawTimeout.trim());
  }
  if (timeout != null) {
    if (timeout <= 0) {
      return 'Error: "timeout" must be a positive integer (seconds).';
    }
    if (timeout > _maxTimeoutSeconds) {
      return 'Error: "timeout" capped at $_maxTimeoutSeconds seconds.';
    }
  }

  try {
    final sessionId = await _ensureSession(accessToken, chatId);
    final result = await SandboxService.execute(
      accessToken: accessToken,
      sessionId: sessionId,
      code: code,
      language: language,
      timeout: timeout,
    );
    final stdout = _capStream(result.stdout);
    final stderr = _capStream(result.stderr);
    final buf = StringBuffer();
    buf.writeln('exit_code: ${result.exitCode}');
    buf.writeln('duration_ms: ${result.executionTimeMs}');
    buf.writeln('--- stdout ---');
    buf.writeln(stdout.isEmpty ? '(empty)' : stdout);
    if (stderr.isNotEmpty) {
      buf.writeln('--- stderr ---');
      buf.writeln(stderr);
    }
    return buf.toString().trimRight();
  } on SandboxServiceException catch (e) {
    return _formatError(e);
  } catch (e) {
    return 'Error: Sandbox failed: $e';
  }
}

Future<String> executeSandboxListFiles({
  required String? accessToken,
  required String? chatId,
  required Map<String, dynamic> args,
}) async {
  if (accessToken == null || accessToken.isEmpty) {
    return 'Error: Not authenticated.';
  }
  if (chatId == null || chatId.isEmpty) {
    return 'Error: No active chat. Start or select a chat first.';
  }

  final rawPath = args['path'];
  var path = rawPath is String ? rawPath.trim() : '';
  if (path.isEmpty) path = '/home/sandbox';
  if (!_isUnderSandbox(path)) {
    return 'Error: "path" must be under /home/sandbox.';
  }

  try {
    final sessionId = await _ensureSession(accessToken, chatId);
    final entries = await SandboxService.listFiles(
      accessToken: accessToken,
      sessionId: sessionId,
      path: path,
    );
    if (entries.isEmpty) {
      return 'Empty directory: $path';
    }
    final buf = StringBuffer()..writeln('Contents of $path:');
    for (final e in entries) {
      final sizeStr = e.size != null ? '${e.size}B' : '-';
      final kind = e.isDir ? 'dir' : 'file';
      buf.writeln('${e.name} ($sizeStr, $kind, ${e.permissions})');
    }
    return buf.toString().trimRight();
  } on SandboxServiceException catch (e) {
    return _formatError(e);
  } catch (e) {
    return 'Error: Sandbox failed: $e';
  }
}

Future<String> executeSandboxReadFile({
  required String? accessToken,
  required String? chatId,
  required Map<String, dynamic> args,
}) async {
  if (accessToken == null || accessToken.isEmpty) {
    return 'Error: Not authenticated.';
  }
  if (chatId == null || chatId.isEmpty) {
    return 'Error: No active chat. Start or select a chat first.';
  }

  final rawPath = args['path'];
  final path = rawPath is String ? rawPath.trim() : '';
  if (path.isEmpty) {
    return 'Error: "path" parameter required.';
  }
  if (!_isUnderSandbox(path)) {
    return 'Error: "path" must be under /home/sandbox.';
  }

  try {
    final sessionId = await _ensureSession(accessToken, chatId);
    final result = await SandboxService.downloadFile(
      accessToken: accessToken,
      sessionId: sessionId,
      path: path,
    );
    final bytes = result.bytes;
    if (_looksLikeText(bytes)) {
      final text = utf8.decode(bytes);
      if (text.length <= _textFileCap) {
        return text;
      }
      final omitted = text.length - _textFileCap;
      return '${text.substring(0, _textFileCap)}\n'
          '(truncated, $omitted chars omitted)';
    }
    return 'Binary file (${bytes.length} bytes, type=${result.contentType}). '
        'Have code_run base64-encode it (e.g. `import base64; '
        "print(base64.b64encode(open('$path','rb').read()).decode())`) "
        'to read it inline.';
  } on SandboxServiceException catch (e) {
    return _formatError(e);
  } catch (e) {
    return 'Error: Sandbox failed: $e';
  }
}

Future<String> executeSandboxWriteFile({
  required String? accessToken,
  required String? chatId,
  required Map<String, dynamic> args,
}) async {
  if (accessToken == null || accessToken.isEmpty) {
    return 'Error: Not authenticated.';
  }
  if (chatId == null || chatId.isEmpty) {
    return 'Error: No active chat. Start or select a chat first.';
  }

  final rawPath = args['path'];
  final path = rawPath is String ? rawPath.trim() : '';
  if (path.isEmpty) {
    return 'Error: "path" parameter required.';
  }
  if (!_isUnderSandbox(path)) {
    return 'Error: "path" must be under /home/sandbox.';
  }

  final rawContent = args['content'];
  if (rawContent is! String) {
    return 'Error: "content" parameter required.';
  }
  final content = rawContent;

  final rawMode = args['mode'];
  var mode = rawMode is String ? rawMode.trim() : 'text';
  if (mode.isEmpty) mode = 'text';
  if (mode != 'text' && mode != 'base64') {
    return 'Error: "mode" must be "text" or "base64".';
  }

  Uint8List bytes;
  try {
    if (mode == 'base64') {
      bytes = base64Decode(content);
    } else {
      bytes = Uint8List.fromList(utf8.encode(content));
    }
  } catch (e) {
    return 'Error: Could not decode content as $mode: $e';
  }

  final parts = _splitPath(path);
  if (parts.name.isEmpty) {
    return 'Error: "path" must include a filename.';
  }

  try {
    final sessionId = await _ensureSession(accessToken, chatId);
    await SandboxService.uploadFile(
      accessToken: accessToken,
      sessionId: sessionId,
      path: parts.dir,
      filename: parts.name,
      data: bytes,
    );
    return 'Wrote $path (${bytes.length} bytes)';
  } on SandboxServiceException catch (e) {
    return _formatError(e);
  } catch (e) {
    return 'Error: Sandbox failed: $e';
  }
}

Future<String> executeSandboxReset({
  required String? accessToken,
  required String? chatId,
  required Map<String, dynamic> args,
}) async {
  if (accessToken == null || accessToken.isEmpty) {
    return 'Error: Not authenticated.';
  }
  if (chatId == null || chatId.isEmpty) {
    return 'Error: No active chat. Start or select a chat first.';
  }

  // Clear both the cache and any in-flight ensure — if an ensure is
  // racing the reset, we don't want it to repopulate _sessionByChat
  // with a session id that's already been (or is about to be) destroyed.
  final sessionId = _sessionByChat.remove(chatId);
  _inflightEnsure.remove(chatId);
  if (sessionId == null) {
    return 'Sandbox destroyed for this chat. Next code_run call will '
        'create a fresh one.';
  }
  try {
    await SandboxService.destroy(
      accessToken: accessToken,
      sessionId: sessionId,
    );
  } on SandboxServiceException catch (e) {
    return _formatError(e);
  } catch (e) {
    return 'Error: Sandbox failed: $e';
  }
  return 'Sandbox destroyed for this chat. Next code_run call will '
      'create a fresh one.';
}
