import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chuk_chat/services/sandbox_service.dart';

// Session cache + ensure logic lives in `SandboxSessionCache` so that
// sign-out hooks and other services don't have to import a tool handler
// just to clear the cache.

const int _stdStreamCap = 8000;
const int _textFileCap = 16000;
const int _textInlineByteLimit = 64 * 1024;
const int _maxTimeoutSeconds = 300;

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
    final sessionId = await SandboxSessionCache.ensureSession(accessToken: accessToken, chatId: chatId);
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
    final sessionId = await SandboxSessionCache.ensureSession(accessToken: accessToken, chatId: chatId);
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
    final sessionId = await SandboxSessionCache.ensureSession(accessToken: accessToken, chatId: chatId);
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
    // Either too large for an inline text view (>64 KB) or genuinely
    // binary (NUL byte / not valid UTF-8). Tell the model exactly which
    // so it doesn't try to "fix" a 64 KB+ text file as binary.
    final reason = bytes.length > _textInlineByteLimit
        ? 'too large for inline view (>${_textInlineByteLimit ~/ 1024}KB)'
        : 'binary content';
    return 'File at $path: ${bytes.length} bytes, '
        'type=${result.contentType}, $reason. '
        'Read it via code_run instead, e.g. for text: '
        "`print(open('$path').read())` (after slicing if huge), or for "
        'binary: '
        "`import base64; print(base64.b64encode(open('$path','rb').read()).decode())`.";
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
    final sessionId = await SandboxSessionCache.ensureSession(accessToken: accessToken, chatId: chatId);
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
  // racing the reset, we don't want it to repopulate the cache with a
  // session id that's already been (or is about to be) destroyed.
  final sessionId = SandboxSessionCache.forgetChat(chatId);
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
