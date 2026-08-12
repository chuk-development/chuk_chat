// CoWork laptop-native tools — real implementation (native platforms only).
//
// Four tools let the agent loop act on the local machine:
//   run_command    — run a shell command, return stdout/stderr/exit code
//   read_file      — read a text file (size-capped)
//   write_file     — write/overwrite a text file
//   list_directory — list directory entries
//
// SAFETY GATE (deny by default, never fail open):
//   * Working-directory jail: every file path and the command cwd must resolve
//     under [coworkJailRoot] after normalise + symlink-resolve. A path that
//     escapes the root is rejected.
//   * Credential denylist: read_file refuses obvious secret paths (`.env`,
//     `*.pem`, `id_rsa`, `.ssh/`, `.aws/credentials`, keyrings, …).
//   * Timeout: run_command is killed after [coworkCommandTimeout]; it never
//     hangs.
//
// Privacy: no file contents or command output are ever logged — only lengths,
// counts and exit codes, and only in debug builds.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

// ─── Configuration ──────────────────────────────────────────────────────────

String? _jailRootOverride;

/// The working-directory jail root. All paths and the command cwd resolve
/// under this directory. Defaults to the user's home directory, falling back
/// to the current working directory. Settable so a host (or a test) can point
/// it at a demo workspace instead of the whole home tree.
String get coworkJailRoot => _jailRootOverride ?? _defaultJailRoot();

set coworkJailRoot(String value) {
  _jailRootOverride = value.trim().isEmpty ? null : value.trim();
}

String _defaultJailRoot() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home != null && home.trim().isNotEmpty) return home.trim();
  return Directory.current.path;
}

/// How long [executeRunCommand] waits before killing the process. Kept as a
/// mutable field so tests can shorten it.
Duration coworkCommandTimeout = const Duration(seconds: 60);

/// Cap on returned file contents / command output. Anything larger is
/// truncated and the reader is told so.
const int _readFileCap = 200 * 1024; // 200 KB
const int _streamCap = 64 * 1024; // 64 KB per stream for run_command

// ─── Jail + denylist ─────────────────────────────────────────────────────────

/// Thrown internally when a path escapes the jail. Callers convert it to a
/// clean `Error:` string for the model.
class _JailEscape implements Exception {
  const _JailEscape(this.path);
  final String path;
}

/// Canonical absolute jail root with symlinks resolved where possible.
String _canonicalRoot() {
  final root = coworkJailRoot;
  final dir = Directory(root);
  if (dir.existsSync()) {
    return dir.resolveSymbolicLinksSync();
  }
  return p.normalize(p.absolute(root));
}

/// Resolve [rawPath] against the jail and return the canonical absolute path,
/// or throw [_JailEscape] if it escapes the root. Relative paths are resolved
/// against the jail root. Symlinks are resolved for existing entries (and for
/// the parent of a not-yet-existing file) so a symlink cannot be used to point
/// outside the jail.
String _resolveInJail(String rawPath) {
  final root = _canonicalRoot();
  final abs = p.isAbsolute(rawPath) ? rawPath : p.join(root, rawPath);
  final normalized = p.normalize(abs);

  String resolved;
  if (Directory(normalized).existsSync()) {
    resolved = Directory(normalized).resolveSymbolicLinksSync();
  } else if (File(normalized).existsSync() ||
      Link(normalized).existsSync()) {
    resolved = File(normalized).resolveSymbolicLinksSync();
  } else {
    // Target does not exist yet (e.g. a fresh write). Resolve the parent so a
    // symlinked parent directory cannot smuggle the write outside the jail.
    final parent = p.dirname(normalized);
    if (Directory(parent).existsSync()) {
      final resolvedParent = Directory(parent).resolveSymbolicLinksSync();
      resolved = p.join(resolvedParent, p.basename(normalized));
    } else {
      resolved = normalized;
    }
  }

  if (p.equals(resolved, root) || p.isWithin(root, resolved)) {
    return resolved;
  }
  throw _JailEscape(rawPath);
}

/// Lowercased path segments that, if present, mark a path as a credential
/// store whose reads are refused.
const Set<String> _denySegments = {
  '.ssh',
  '.aws',
  '.gnupg',
  '.password-store',
  '.docker',
  '.kube',
};

/// Exact lowercased basenames that are refused.
const Set<String> _denyBasenames = {
  'id_rsa',
  'id_dsa',
  'id_ecdsa',
  'id_ed25519',
  'credentials',
  '.netrc',
  '.htpasswd',
  '.pgpass',
  'keyring',
  'login.keyring',
  'user.keystore',
};

/// Refuse reads of obvious secret files. Deny is the default on any doubt.
/// Operates on the already jail-resolved absolute path.
bool _isDeniedForRead(String resolvedPath) {
  final segments = p.split(resolvedPath).map((s) => s.toLowerCase()).toList();
  for (final seg in segments) {
    if (_denySegments.contains(seg)) return true;
  }
  final base = p.basename(resolvedPath).toLowerCase();
  if (_denyBasenames.contains(base)) return true;
  // `.env`, `.env.local`, `.env.production`, …
  if (base == '.env' || base.startsWith('.env.')) return true;
  final ext = p.extension(base);
  if (ext == '.pem' || ext == '.key' || ext == '.keystore' || ext == '.pfx' ||
      ext == '.p12' || ext == '.asc' || ext == '.gpg') {
    return true;
  }
  return false;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

String _capText(String s, int cap) {
  if (s.length <= cap) return s;
  final omitted = s.length - cap;
  return '${s.substring(0, cap)}\n(truncated, $omitted chars omitted)';
}

String _jailErr(String rawPath) =>
    'Error: path "$rawPath" escapes the CoWork root ($coworkJailRoot). '
    'All paths must resolve under the root.';

String _humanDuration(Duration d) {
  if (d.inSeconds >= 1) return '${d.inSeconds}s';
  return '${d.inMilliseconds}ms';
}

// ─── run_command ─────────────────────────────────────────────────────────────

Future<String> executeRunCommand(Map<String, dynamic> args) async {
  final rawCommand = args['command'];
  final command = rawCommand is String ? rawCommand.trim() : '';
  if (command.isEmpty) {
    return 'Error: "command" parameter required.';
  }

  final rawCwd = args['cwd'];
  final cwdArg = rawCwd is String ? rawCwd.trim() : '';
  String workingDir;
  try {
    workingDir = cwdArg.isEmpty ? _canonicalRoot() : _resolveInJail(cwdArg);
  } on _JailEscape {
    return _jailErr(cwdArg);
  }
  if (!Directory(workingDir).existsSync()) {
    return 'Error: working directory does not exist: $cwdArg';
  }

  final String shell;
  final List<String> shellArgs;
  if (Platform.isWindows) {
    shell = 'cmd';
    shellArgs = ['/c', command];
  } else {
    shell = '/bin/sh';
    shellArgs = ['-c', command];
  }

  if (kDebugMode) {
    debugPrint(
      '[cowork] run_command: ${command.length} chars, '
      'cwd set=${cwdArg.isNotEmpty}',
    );
  }

  Process proc;
  try {
    proc = await Process.start(
      shell,
      shellArgs,
      workingDirectory: workingDir,
    );
  } catch (e) {
    return 'Error: could not start command: $e';
  }

  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final outDone = proc.stdout.transform(utf8.decoder).forEach(outBuf.write);
  final errDone = proc.stderr.transform(utf8.decoder).forEach(errBuf.write);

  int exitCode;
  try {
    exitCode = await proc.exitCode.timeout(coworkCommandTimeout);
  } on TimeoutException {
    proc.kill(ProcessSignal.sigkill);
    // Let the streams finish draining after the kill; ignore errors.
    await Future.wait([outDone, errDone]).catchError((_) => <void>[]);
    final human = _humanDuration(coworkCommandTimeout);
    if (kDebugMode) {
      debugPrint('[cowork] run_command timed out after $human; killed.');
    }
    return 'Error: command timed out after $human and was killed.';
  }

  await Future.wait([outDone, errDone]);

  final stdout = _capText(outBuf.toString(), _streamCap);
  final stderr = _capText(errBuf.toString(), _streamCap);

  if (kDebugMode) {
    debugPrint(
      '[cowork] run_command done: exit=$exitCode, '
      'stdout=${outBuf.length}B, stderr=${errBuf.length}B',
    );
  }

  final buf = StringBuffer()..writeln('exit_code: $exitCode');
  buf.writeln('--- stdout ---');
  buf.writeln(stdout.isEmpty ? '(empty)' : stdout);
  if (stderr.isNotEmpty) {
    buf.writeln('--- stderr ---');
    buf.writeln(stderr);
  }
  return buf.toString().trimRight();
}

// ─── read_file ───────────────────────────────────────────────────────────────

Future<String> executeReadFile(Map<String, dynamic> args) async {
  final rawPath = args['path'];
  final rawPathStr = rawPath is String ? rawPath.trim() : '';
  if (rawPathStr.isEmpty) {
    return 'Error: "path" parameter required.';
  }

  String resolved;
  try {
    resolved = _resolveInJail(rawPathStr);
  } on _JailEscape {
    return _jailErr(rawPathStr);
  }

  if (_isDeniedForRead(resolved)) {
    if (kDebugMode) {
      debugPrint('[cowork] read_file denied by credential denylist.');
    }
    return 'Error: reading this path is blocked by the credential denylist '
        '(secrets, keys, .env, .ssh, .aws/credentials, keyrings).';
  }

  final file = File(resolved);
  if (!file.existsSync()) {
    return 'Error: file does not exist: $rawPathStr';
  }

  int length;
  try {
    length = file.lengthSync();
  } catch (e) {
    return 'Error: could not stat file: $e';
  }

  String contents;
  try {
    if (length > _readFileCap) {
      // Read only the cap so we never pull a huge file into memory.
      final raw = file.openSync();
      try {
        final bytes = raw.readSync(_readFileCap);
        contents = utf8.decode(bytes, allowMalformed: true);
      } finally {
        raw.closeSync();
      }
      if (kDebugMode) {
        debugPrint(
          '[cowork] read_file: ${length}B file, capped to $_readFileCap B.',
        );
      }
      final omitted = length - _readFileCap;
      return '$contents\n(truncated, $omitted of $length bytes omitted; '
          'cap is ${_readFileCap ~/ 1024} KB)';
    }
    contents = file.readAsStringSync();
  } catch (e) {
    return 'Error: could not read file (not valid UTF-8 text?): $e';
  }

  if (kDebugMode) {
    debugPrint('[cowork] read_file: ${contents.length} chars.');
  }
  return contents;
}

// ─── write_file ──────────────────────────────────────────────────────────────

Future<String> executeWriteFile(Map<String, dynamic> args) async {
  final rawPath = args['path'];
  final rawPathStr = rawPath is String ? rawPath.trim() : '';
  if (rawPathStr.isEmpty) {
    return 'Error: "path" parameter required.';
  }

  final rawContent = args['content'];
  if (rawContent is! String) {
    return 'Error: "content" parameter required (string).';
  }
  final content = rawContent;

  String resolved;
  try {
    resolved = _resolveInJail(rawPathStr);
  } on _JailEscape {
    return _jailErr(rawPathStr);
  }

  final file = File(resolved);
  try {
    final parent = Directory(p.dirname(resolved));
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    file.writeAsStringSync(content);
  } catch (e) {
    return 'Error: could not write file: $e';
  }

  final bytes = utf8.encode(content).length;
  if (kDebugMode) {
    debugPrint('[cowork] write_file: ${bytes}B written.');
  }
  return 'Wrote $rawPathStr ($bytes bytes).';
}

// ─── list_directory ──────────────────────────────────────────────────────────

Future<String> executeListDirectory(Map<String, dynamic> args) async {
  final rawPath = args['path'];
  var rawPathStr = rawPath is String ? rawPath.trim() : '';
  if (rawPathStr.isEmpty) rawPathStr = '.';

  String resolved;
  try {
    resolved = _resolveInJail(rawPathStr);
  } on _JailEscape {
    return _jailErr(rawPathStr);
  }

  final dir = Directory(resolved);
  if (!dir.existsSync()) {
    return 'Error: directory does not exist: $rawPathStr';
  }

  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (e) {
    return 'Error: could not list directory: $e';
  }

  if (entries.isEmpty) {
    return 'Empty directory: $rawPathStr';
  }

  entries.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

  final buf = StringBuffer()..writeln('Contents of $rawPathStr:');
  for (final e in entries) {
    final name = p.basename(e.path);
    if (e is Directory) {
      buf.writeln('$name/ (dir)');
    } else if (e is Link) {
      buf.writeln('$name (link)');
    } else if (e is File) {
      int size;
      try {
        size = e.lengthSync();
      } catch (_) {
        size = -1;
      }
      buf.writeln('$name (${size >= 0 ? '${size}B' : '-'}, file)');
    } else {
      buf.writeln('$name (other)');
    }
  }

  if (kDebugMode) {
    debugPrint('[cowork] list_directory: ${entries.length} entries.');
  }
  return buf.toString().trimRight();
}
