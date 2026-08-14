import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Callback type for approval dialogs
typedef ApprovalCallback = Future<bool> Function(String command, String reason);

/// Sandboxed Bash Command Executor
///
/// Executes bash commands within a user-selected sandbox folder.
/// Safe commands run directly, unsafe commands require user approval.
class BashSandbox {
  static const List<String> safeCommands = [
    'ls',
    'cat',
    'head',
    'tail',
    'pwd',
    'whoami',
    'ffmpeg',
    'ffprobe',
    'mkdir',
    'cp',
    'mv',
    'rm',
    'touch',
    'echo',
    'find',
    'grep',
    'wc',
    'sort',
    'uniq',
    'file',
    'stat',
    'du',
    'df',
    'date',
    'cal',
    'uname',
  ];

  static const List<String> dangerousPatterns = [
    'sudo',
    'su ',
    'chmod',
    'chown',
    'chgrp',
    'rm -rf',
    'rm -r /',
    '>',
    '>>',
    '|',
    ';',
    '&&',
    '||',
    r'$',
    '`',
    'curl',
    'wget',
    'nc ',
    'netcat',
    'ssh',
    'scp',
    'rsync',
    'eval',
    'exec',
  ];

  /// Characters that the shell interprets specially and that must never appear
  /// in a sandboxed command, even if the command is otherwise whitelisted.
  ///
  /// This catches gaps that the substring-based `dangerousPatterns` list
  /// misses — notably newlines (statement separators for `sh -c`),
  /// tilde (home-directory expansion), globs, brace expansion, and
  /// square-bracket character classes.
  static const List<String> forbiddenMetaCharacters = [
    '\n',
    '\r',
    '\t',
    '~',
    '*',
    '?',
    '{',
    '}',
    '[',
    ']',
    '\\',
    '"',
    "'",
  ];

  String? _sandboxFolder;
  final ApprovalCallback? _approvalCallback;

  BashSandbox({ApprovalCallback? onApprovalRequired})
    : _approvalCallback = onApprovalRequired;


  bool get isConfigured => _sandboxFolder != null;

  /// Folder every bash command is confined to, null until one is chosen.
  String? get sandboxFolder => _sandboxFolder;

  Future<void> loadSavedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFolder = prefs.getString('bash_sandbox_folder');
    if (savedFolder != null) {
      final dir = io.Directory(savedFolder);
      if (await dir.exists()) {
        _sandboxFolder = savedFolder;
      }
    }
  }

  /// Point the sandbox at [path] and remember it across restarts.
  Future<void> setSandboxFolder(String path) async {
    final dir = io.Directory(path);
    if (!await dir.exists()) {
      throw StateError('That folder does not exist any more: $path');
    }
    _sandboxFolder = p.canonicalize(path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bash_sandbox_folder', _sandboxFolder!);
  }

  /// Forget the folder. Commands are refused again until a new one is set.
  Future<void> clearSandboxFolder() async {
    _sandboxFolder = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bash_sandbox_folder');
  }




  bool isSafeCommand(String command) {
    final trimmedCommand = command.trim();
    if (trimmedCommand.isEmpty) return false;

    for (final meta in forbiddenMetaCharacters) {
      if (trimmedCommand.contains(meta)) return false;
    }

    for (final pattern in dangerousPatterns) {
      if (trimmedCommand.contains(pattern)) return false;
    }

    final parts = trimmedCommand.split(RegExp(r'\s+'));
    if (parts.isEmpty) return false;

    final baseCommand = parts[0].split('/').last;
    return safeCommands.contains(baseCommand);
  }

  String getUnsafeReason(String command) {
    final trimmedCommand = command.trim();

    for (final meta in forbiddenMetaCharacters) {
      if (trimmedCommand.contains(meta)) {
        final label = _metaCharLabel(meta);
        return 'Command contains forbidden shell metacharacter ($label)';
      }
    }

    for (final pattern in dangerousPatterns) {
      if (trimmedCommand.contains(pattern)) {
        if (pattern == '>' || pattern == '>>') {
          return 'Command contains file redirection ($pattern)';
        } else if (pattern == '|') {
          return 'Command contains pipe operator';
        } else if (pattern == ';' || pattern == '&&' || pattern == '||') {
          return 'Command contains command chaining ($pattern)';
        } else if (pattern == r'$' || pattern == '`') {
          return 'Command contains variable/command substitution';
        } else if (pattern.startsWith('rm')) {
          return 'Potentially destructive remove command';
        } else {
          return 'Command contains restricted pattern: $pattern';
        }
      }
    }

    final parts = trimmedCommand.split(RegExp(r'\s+'));
    if (parts.isNotEmpty) {
      final baseCommand = parts[0].split('/').last;
      if (!safeCommands.contains(baseCommand)) {
        return 'Command "$baseCommand" is not in the safe list';
      }
    }

    return 'Unknown safety concern';
  }

  String _metaCharLabel(String meta) {
    switch (meta) {
      case '\n':
        return 'newline';
      case '\r':
        return 'carriage return';
      case '\t':
        return 'tab';
      default:
        return meta;
    }
  }

  bool isWithinSandbox(String command) {
    if (_sandboxFolder == null) return false;

    // Reject anything with a shell metacharacter up front. isSafeCommand
    // enforces this too, but we also guard here because `execute()` calls
    // `isWithinSandbox` on the unsafe/approval path.
    for (final meta in forbiddenMetaCharacters) {
      if (command.contains(meta)) return false;
    }

    final parts = command.trim().split(RegExp(r'\s+'));
    final normalizedSandbox = p.canonicalize(_sandboxFolder!);

    for (final arg in parts.skip(1)) {
      // Validate every argument that could be a path — including flags that
      // bundle a path via `=` (e.g. `--output=/etc/passwd`). Plain tokens
      // without `/`, `.` or `=` are treated as sub-commands / literals and
      // skipped.
      final candidates = _extractPathCandidates(arg);
      if (candidates.isEmpty) continue;

      for (final candidate in candidates) {
        if (!_isPathInsideSandbox(candidate, normalizedSandbox)) {
          return false;
        }
      }
    }

    return true;
  }

  /// Extract the file-path portion of an argument. Handles `--flag=path`,
  /// `-f=path`, and bare paths. Returns an empty list for arguments that
  /// clearly aren't paths.
  List<String> _extractPathCandidates(String arg) {
    // `--flag=/path` or `-f=/path`
    if (arg.startsWith('-')) {
      final eq = arg.indexOf('=');
      if (eq < 0) return const [];
      final value = arg.substring(eq + 1);
      if (value.isEmpty) return const [];
      return [value];
    }
    // Bare token that looks like a path.
    if (arg.contains('/') || arg.startsWith('.')) {
      return [arg];
    }
    return const [];
  }

  /// Canonicalize [candidate] (resolving symlinks when it already exists)
  /// and verify it is contained in [normalizedSandbox]. Uses a segment-aware
  /// prefix check so `/home/user/safe_secrets` is NOT treated as living
  /// inside `/home/user/safe`.
  bool _isPathInsideSandbox(String candidate, String normalizedSandbox) {
    try {
      // 1. Resolve to an absolute path anchored at the sandbox.
      final absolute = p.isAbsolute(candidate)
          ? candidate
          : p.join(_sandboxFolder!, candidate);

      // 2. Collapse `..`, `.`, and duplicate separators.
      var canonical = p.canonicalize(absolute);

      // 3. If the path exists as a symlink (or lives inside one), follow
      //    it so we compare the real target, not the link's own location.
      final entityType = io.FileSystemEntity.typeSync(
        canonical,
        followLinks: false,
      );
      if (entityType != io.FileSystemEntityType.notFound) {
        try {
          canonical = p.canonicalize(
            io.File(canonical).resolveSymbolicLinksSync(),
          );
        } on io.FileSystemException {
          // Broken symlink or permission error — refuse it.
          return false;
        }
      }

      // 4. Segment-aware containment check. Exact match or a strict
      //    descendant only — no `startsWith` prefix confusion.
      if (canonical == normalizedSandbox) return true;
      return p.isWithin(normalizedSandbox, canonical);
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> execute(String command) async {
    if (_sandboxFolder == null) {
      return {
        'success': false,
        'error':
            'No sandbox folder configured. '
            'Please set a working folder in Settings.',
      };
    }

    final trimmedCommand = command.trim();
    if (trimmedCommand.isEmpty) {
      return {'success': false, 'error': 'Empty command'};
    }

    if (!isWithinSandbox(trimmedCommand)) {
      return {
        'success': false,
        'error':
            'Command accesses paths outside the sandbox folder: '
            '$_sandboxFolder',
      };
    }

    if (isSafeCommand(trimmedCommand)) {
      return await _executeDirectly(trimmedCommand);
    }

    final reason = getUnsafeReason(trimmedCommand);

    if (_approvalCallback != null) {
      final approved = await _approvalCallback(trimmedCommand, reason);
      if (approved) {
        return await _executeDirectly(trimmedCommand);
      } else {
        return {
          'success': false,
          'error': 'Command rejected by user',
          'command': trimmedCommand,
        };
      }
    }

    return {
      'success': false,
      'error': 'Command requires approval but no approval handler configured',
      'reason': reason,
    };
  }

  Future<Map<String, dynamic>> _executeDirectly(String command) async {
    // Re-validate: we never want to hit Process.run with a command that
    // carries shell metacharacters, even if a caller constructed it from
    // multiple sources.
    for (final meta in forbiddenMetaCharacters) {
      if (command.contains(meta)) {
        return {
          'success': false,
          'error':
              'Command contains forbidden shell metacharacter '
              '(${_metaCharLabel(meta)})',
        };
      }
    }

    final parts = command.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) {
      return {'success': false, 'error': 'Empty command'};
    }
    final executable = parts.first;
    final args = parts.sublist(1);

    try {
      // Execute argv directly — no shell interpreter. This means `~`, `$VAR`,
      // globs, and statement separators are passed verbatim as arguments
      // rather than being re-interpreted by sh. Combined with the
      // metacharacter block above, there is no shell layer to escape from.
      final result = await io.Process.run(
        executable,
        args,
        workingDirectory: _sandboxFolder,
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      final stdout = result.stdout as String;
      final stderr = result.stderr as String;

      if (result.exitCode != 0) {
        return {
          'success': false,
          'exit_code': result.exitCode,
          'error': stderr.isNotEmpty
              ? stderr
              : 'Command failed with exit code ${result.exitCode}',
          'output': stdout,
        };
      }

      return {
        'success': true,
        'exit_code': 0,
        'output': stdout.isNotEmpty ? stdout : 'Command completed successfully',
      };
    } catch (e) {
      return {'success': false, 'error': 'Execution error: $e'};
    }
  }
}
