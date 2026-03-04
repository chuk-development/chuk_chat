import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

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

  String? _sandboxFolder;
  final ApprovalCallback? _approvalCallback;

  BashSandbox({ApprovalCallback? onApprovalRequired})
    : _approvalCallback = onApprovalRequired;

  String? get sandboxFolder => _sandboxFolder;
  bool get isConfigured => _sandboxFolder != null;

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

  Future<void> setSandboxFolder(String path) async {
    path = path.replaceAll(RegExp(r'/$'), '');
    final dir = io.Directory(path);
    if (!await dir.exists()) {
      throw Exception('Folder does not exist: $path');
    }
    _sandboxFolder = path;
    await _saveSandboxFolder();
  }

  Future<void> clearSandboxFolder() async {
    _sandboxFolder = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bash_sandbox_folder');
  }

  Future<void> _saveSandboxFolder() async {
    final prefs = await SharedPreferences.getInstance();
    if (_sandboxFolder != null) {
      await prefs.setString('bash_sandbox_folder', _sandboxFolder!);
    }
  }

  bool isSafeCommand(String command) {
    final trimmedCommand = command.trim();
    if (trimmedCommand.isEmpty) return false;

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

  bool isWithinSandbox(String command) {
    if (_sandboxFolder == null) return false;

    final parts = command.trim().split(RegExp(r'\s+'));

    for (final arg in parts.skip(1)) {
      if (arg.startsWith('-')) continue;
      if (!arg.contains('/') && !arg.startsWith('.')) continue;

      try {
        String resolvedPath;
        if (arg.startsWith('/')) {
          resolvedPath = arg;
        } else {
          resolvedPath = io.File('$_sandboxFolder/$arg').absolute.path;
        }

        resolvedPath = _normalizePath(resolvedPath);
        final normalizedSandbox = _normalizePath(_sandboxFolder!);

        if (!resolvedPath.startsWith(normalizedSandbox)) {
          return false;
        }
      } catch (_) {
        return false;
      }
    }

    return true;
  }

  String _normalizePath(String path) {
    final segments = <String>[];
    for (final segment in path.split('/')) {
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else if (segment != '.' && segment.isNotEmpty) {
        segments.add(segment);
      }
    }
    return '/${segments.join('/')}';
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
    try {
      final result = await io.Process.run(
        'sh',
        ['-c', command],
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
