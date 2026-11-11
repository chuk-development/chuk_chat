/// The command prefix "Always allow `git push`" remembers
/// (docs/WIRE_CONTRACT.md, "Shell command rules"; research C2 item 9).
///
/// The host matches a stored prefix against a command's canonical tokens:
/// `shlex` split, the launchers `sudo` / `env VAR=` stripped, the program by
/// its basename. The app proposes the same shape so the card shows exactly
/// what will be remembered: the program, and its first word when that is a
/// subcommand (`git push`, `npm test`), never a flag, a path or a value.
///
/// Never for a shell, an interpreter or a wrapper (`bash`, `python3`,
/// `xargs`, `find`, `sudo`, ...): "always allow `bash`" would allow every
/// command there is. Those get no prefix, so the card offers no such scope.
library;

import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// Splits [command] the way a POSIX shell would for plain words: spaces
/// separate, single and double quotes group, a backslash escapes the next
/// character. Good enough for a prefix; the host does the real match.
List<String> shellWords(String command) {
  final List<String> words = <String>[];
  final StringBuffer word = StringBuffer();
  bool inWord = false;
  String? quote;
  for (int i = 0; i < command.length; i++) {
    final String c = command[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < command.length) {
        word.write(command[++i]);
      } else {
        word.write(c);
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      inWord = true;
    } else if (c == r'\' && i + 1 < command.length) {
      word.write(command[++i]);
      inWord = true;
    } else if (c == ' ' || c == '\t') {
      if (inWord) {
        words.add(word.toString());
        word.clear();
        inWord = false;
      }
    } else if (c == ';' ||
        c == '|' ||
        c == '&' ||
        c == '\n' ||
        c == '\r' ||
        c == '`' ||
        (c == r'$' && i + 1 < command.length && command[i + 1] == '(')) {
      // A second command starts (a separator, a new line, a command
      // substitution): the prefix is about the first one.
      break;
    } else {
      word.write(c);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words;
}

/// The canonical tokens of [command]: launchers stripped, program basename.
List<String> canonicalCommandTokens(String command) {
  final List<String> words = shellWords(command);
  int i = 0;
  while (i < words.length) {
    final String w = words[i];
    if (w == 'sudo' || w == 'env') {
      i++;
      // sudo's own flags (`-u root`, `-E`).
      while (i < words.length && words[i].startsWith('-')) {
        i += words[i] == '-u' ? 2 : 1;
      }
      continue;
    }
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(w)) {
      i++;
      continue;
    }
    break;
  }
  final List<String> rest = words.sublist(i.clamp(0, words.length));
  if (rest.isEmpty) return rest;
  final String program = rest.first.split('/').last;
  return <String>[program, ...rest.skip(1)];
}

/// Programs that run other commands: a remembered prefix on one of them
/// would allow anything.
const Set<String> kUnrememberablePrograms = <String>{
  'sh',
  'bash',
  'zsh',
  'fish',
  'dash',
  'ksh',
  'csh',
  'tcsh',
  'pwsh',
  'powershell',
  'cmd',
  'node',
  'deno',
  'bun',
  'perl',
  'ruby',
  'php',
  'lua',
  'env',
  'xargs',
  'eval',
  'exec',
  'find',
  'sudo',
  'doas',
  'su',
  'nohup',
  'nice',
  'timeout',
  'time',
  'watch',
  'command',
  'builtin',
  'source',
  '.',
  'ssh',
  'parallel',
};

/// Whether [program] (a basename) runs other commands, so it must never get
/// an "always allow" prefix.
bool isUnrememberableProgram(String program) {
  final String p = program.toLowerCase();
  return kUnrememberablePrograms.contains(p) ||
      RegExp(r'^python[0-9.]*$').hasMatch(p) ||
      RegExp(r'^(pypy|perl|ruby|php|node)[0-9.]*$').hasMatch(p);
}

/// The prefix to remember for [command], or null for a command with no
/// program, a launcher in front (`sudo`, `env VAR=`) or a program that runs
/// other commands ([isUnrememberableProgram]).
String? commandPrefixFor(String command) {
  final List<String> words = shellWords(command);
  if (words.isEmpty) return null;
  final String first = words.first.split('/').last;
  if (isUnrememberableProgram(first) ||
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words.first)) {
    return null;
  }
  final List<String> tokens = canonicalCommandTokens(command);
  if (tokens.isEmpty || tokens.first.isEmpty) return null;
  if (isUnrememberableProgram(tokens.first)) return null;
  if (tokens.length > 1) {
    final String sub = tokens[1];
    final bool subcommand = RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(sub);
    if (subcommand) return '${tokens.first} $sub';
  }
  return tokens.first;
}

/// The prefix a shell command approval offers to remember: the host's own
/// suggestion when it sent one (`details.prefix`), else one derived from
/// `details.command`. Null when the card does not offer the scope.
String? approvalCommandPrefix(AgentsRelayApprovalRequest request) {
  if (!request.options.contains(AgentsRelayApprovalRequest.scopeAlwaysPrefix)) {
    return null;
  }
  final Map<String, dynamic> d = request.details ?? const <String, dynamic>{};
  for (final String key in const <String>['prefix', 'command_prefix']) {
    final Object? v = d[key];
    final String? prefix = v is String
        ? v.trim()
        : v is List
        ? v.whereType<String>().join(' ').trim()
        : null;
    if (prefix != null && prefix.isNotEmpty) {
      // Even the host's own suggestion never names a shell or a wrapper.
      final List<String> words = shellWords(prefix);
      if (words.isEmpty ||
          isUnrememberableProgram(words.first.split('/').last)) {
        return null;
      }
      return prefix;
    }
  }
  final Object? command = d['command'];
  if (command is String) return commandPrefixFor(command);
  return null;
}
