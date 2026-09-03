import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';
import 'package:chuk_chat/services/sandbox_service.dart';
import 'package:chuk_chat/services/tool_executor.dart';

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

// ---------------------------------------------------------------------------
// Sandbox-infrastructure circuit breaker (shared with the tool loop)
// ---------------------------------------------------------------------------

/// Tools whose calls are served by (or reach for) the remote sandbox service.
/// The tool loop trips a per-turn circuit breaker when several of these fail
/// in a row with an infrastructure error. `bash` is included because the model
/// reaches for it as a sandbox fallback and it shares the same "no sandbox"
/// failure mode.
const Set<String> kSandboxBackedToolNames = {
  'code_run',
  'bash',
  'sandbox_list',
  'sandbox_read',
  'sandbox_write',
  'sandbox_reset',
  'send_file_to_user',
};

/// True when [name] is a sandbox-backed tool (see [kSandboxBackedToolNames]).
bool isSandboxBackedTool(String name) => kSandboxBackedToolNames.contains(name);

/// Terminal, non-retryable result the tool loop returns for a sandbox tool
/// once the sandbox has failed repeatedly this turn. Keeps the literal
/// "Error:" prefix so is-error detection still flags it.
const String kSandboxUnavailableThisTurnMessage =
    'Error: The code sandbox is unavailable this turn (infrastructure error, '
    'not a problem with your request). Stop calling sandbox and file tools '
    '(code_run, bash, sandbox_*, send_file_to_user) for the rest of this turn '
    'and finish your answer using what you already have.';

/// True when a tool result string signals a sandbox INFRASTRUCTURE failure —
/// the upstream is unreachable or overloaded — as opposed to a user-level
/// error like a bad path (HTTP 400/404/413). Matches the [_formatError] shape
/// (`Error: HTTP <status> — <message>`) for HTTP 0/502/503/504, plus the
/// upstream-unavailable phrasing the gateway emits.
bool isSandboxInfraError(String result) {
  final lower = result.toLowerCase();
  if (lower.contains('upstream unavailable') ||
      lower.contains('sandbox upstream')) {
    return true;
  }
  final match = RegExp(r'error:\s*http\s+(\d+)').firstMatch(lower);
  if (match != null) {
    final status = int.tryParse(match.group(1)!);
    if (status == 0 || status == 502 || status == 503 || status == 504) {
      return true;
    }
  }
  return false;
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
  // Accept "shell" as a legacy alias for "bash" so older chats that
  // already learned the previous tool description keep working.
  if (language == 'shell') language = 'bash';
  if (language != 'python' && language != 'bash') {
    return 'Error: "language" must be "python" or "bash".';
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

// ---------------------------------------------------------------------------
// send_file_to_user
// ---------------------------------------------------------------------------

/// Extension-based mime sniffing for filenames whose upstream content-type
/// is missing or unhelpful (e.g. `application/octet-stream`). Intentionally
/// small — the chat UI only needs to distinguish image / pdf / text / other
/// to pick a renderer.
const Map<String, String> _extensionMimeMap = {
  // Images
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'bmp': 'image/bmp',
  // Documents
  'pdf': 'application/pdf',
  // Text-like
  'csv': 'text/csv',
  'json': 'application/json',
  'md': 'text/markdown',
  'markdown': 'text/markdown',
  'txt': 'text/plain',
  'log': 'text/plain',
  'html': 'text/html',
  'htm': 'text/html',
  'xml': 'application/xml',
  // Source code — render as plain text in the chat preview
  'py': 'text/plain',
  'js': 'text/plain',
  'ts': 'text/plain',
  'dart': 'text/plain',
  'go': 'text/plain',
  'rs': 'text/plain',
  'c': 'text/plain',
  'cpp': 'text/plain',
  'h': 'text/plain',
  'hpp': 'text/plain',
  'java': 'text/plain',
  'kt': 'text/plain',
  'sh': 'text/plain',
  'bash': 'text/plain',
  'yaml': 'text/plain',
  'yml': 'text/plain',
  'toml': 'text/plain',
  'ini': 'text/plain',
  'env': 'text/plain',
  'tex': 'text/plain',
  'typ': 'text/plain',
  // Archives / binaries
  'zip': 'application/zip',
  'tar': 'application/x-tar',
  'gz': 'application/gzip',
  '7z': 'application/x-7z-compressed',
  // Media
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
};

String _extOf(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0 || dot == filename.length - 1) return '';
  return filename.substring(dot + 1).toLowerCase();
}

String _inferMimeFromFilename(String filename) {
  final ext = _extOf(filename);
  if (ext.isEmpty) return 'application/octet-stream';
  return _extensionMimeMap[ext] ?? 'application/octet-stream';
}

String _humanReadableBytes(int n) {
  if (n < 1024) return '$n B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = n / 1024.0;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  // Show one decimal for values under 10, none above.
  final formatted = value < 10
      ? value.toStringAsFixed(1)
      : value.round().toString();
  return '$formatted ${units[unitIndex]}';
}

String _lastSegment(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  if (idx < 0 || idx == normalized.length - 1) {
    return normalized.isEmpty ? 'file' : normalized;
  }
  return normalized.substring(idx + 1);
}

Future<ToolExecutionResult> executeSandboxSendFileToUser({
  required String? accessToken,
  required String? chatId,
  required Map<String, dynamic> args,
}) async {
  if (accessToken == null || accessToken.isEmpty) {
    return const ToolExecutionResult(
      output: 'Error: Not authenticated.',
      isError: true,
    );
  }
  if (chatId == null || chatId.isEmpty) {
    return const ToolExecutionResult(
      output: 'Error: No active chat. Start or select a chat first.',
      isError: true,
    );
  }

  final rawPath = args['path'];
  final path = rawPath is String ? rawPath.trim() : '';
  if (path.isEmpty) {
    return const ToolExecutionResult(
      output: 'Error: "path" parameter required.',
      isError: true,
    );
  }
  if (!_isUnderSandbox(path)) {
    return const ToolExecutionResult(
      output: 'Error: "path" must be under /home/sandbox.',
      isError: true,
    );
  }

  final rawDisplayName = args['display_name'];
  final displayName = rawDisplayName is String ? rawDisplayName.trim() : '';

  try {
    final sessionId = await SandboxSessionCache.ensureSession(
      accessToken: accessToken,
      chatId: chatId,
    );
    final result = await SandboxService.downloadFile(
      accessToken: accessToken,
      sessionId: sessionId,
      path: path,
    );

    final filename = displayName.isNotEmpty ? displayName : _lastSegment(path);

    // Prefer upstream content-type when it is non-empty AND specific;
    // fall back to filename extension otherwise. We treat
    // `application/octet-stream` as "unknown" so we still try to infer.
    final upstreamMime = result.contentType.trim();
    String mime;
    if (upstreamMime.isEmpty || upstreamMime == 'application/octet-stream') {
      mime = _inferMimeFromFilename(filename);
    } else {
      mime = upstreamMime;
    }

    final storagePath = await PdfAttachmentService.upload(result.bytes);

    final payload = SandboxArtifactPayload(
      storagePath: storagePath,
      filename: filename,
      mime: mime,
      sizeBytes: result.bytes.length,
    );
    final block = ContentBlock.sandboxArtifact(payload);

    final humanSize = _humanReadableBytes(result.bytes.length);
    return ToolExecutionResult(
      output:
          'Sent "$filename" ($humanSize, $mime) to the user. '
          'It is now visible in the chat as a downloadable attachment.',
      isError: false,
      producedBlocks: [block],
    );
  } on SandboxServiceException catch (e) {
    return ToolExecutionResult(output: _formatError(e), isError: true);
  } catch (e) {
    return ToolExecutionResult(
      output: 'Error: send_file_to_user failed: $e',
      isError: true,
    );
  }
}
