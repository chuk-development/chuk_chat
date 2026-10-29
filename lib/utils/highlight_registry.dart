import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/cs.dart'; // csharp
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/shell.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/cmake.dart';
import 'package:highlight/languages/makefile.dart';
import 'package:highlight/languages/nginx.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/gradle.dart';
import 'package:highlight/languages/groovy.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/less.dart';
import 'package:highlight/languages/lua.dart';
import 'package:highlight/languages/objectivec.dart';
import 'package:highlight/languages/perl.dart';
import 'package:highlight/languages/plaintext.dart';
import 'package:highlight/languages/powershell.dart';
import 'package:highlight/languages/r.dart';
import 'package:highlight/languages/scala.dart';
import 'package:highlight/languages/scss.dart';
import 'package:highlight/languages/vbnet.dart';
import 'package:highlight/languages/vim.dart';

/// Every language the chat highlights, by the name a code fence uses.
///
/// Factories, not modes: a language's [Mode] tree is a large object graph
/// built on first use, and a map of the modes themselves built all forty-odd
/// trees the first time any code block was highlighted.
final Map<String, Mode Function()> languageFactories = {
  'dart': () => dart,
  'json': () => json,
  'python': () => python,
  'py': () => python,
  'javascript': () => javascript,
  'js': () => javascript,
  'typescript': () => typescript,
  'ts': () => typescript,
  'java': () => java,
  'kotlin': () => kotlin,
  'swift': () => swift,
  'cpp': () => cpp,
  'c++': () => cpp,
  'c': () => cpp, // cpp mode often handles c too or I should import c.dart if available
  'cs': () => cs,
  'csharp': () => cs,
  'c#': () => cs,
  'go': () => go,
  'rust': () => rust,
  'sql': () => sql,
  'yaml': () => yaml,
  'yml': () => yaml,
  'xml': () => xml,
  'bash': () => bash,
  'sh': () => bash,
  'shell': () => shell,
  'markdown': () => markdown,
  'md': () => markdown,
  'css': () => css,
  'php': () => php,
  'ruby': () => ruby,
  'rb': () => ruby,
  'cmake': () => cmake,
  'makefile': () => makefile,
  'nginx': () => nginx,
  'dockerfile': () => dockerfile,
  'docker': () => dockerfile,
  'gradle': () => gradle,
  'groovy': () => groovy,
  'ini': () => ini,
  'less': () => less,
  'lua': () => lua,
  'objectivec': () => objectivec,
  'perl': () => perl,
  'plaintext': () => plaintext,
  'txt': () => plaintext,
  'powershell': () => powershell,
  'ps1': () => powershell,
  'r': () => r,
  'scala': () => scala,
  'scss': () => scss,
  'vbnet': () => vbnet,
  'vim': () => vim,
};

/// The modes themselves, keyed like [languageFactories]. Building it builds
/// every mode; prefer [isKnownLanguage] and [registerLanguageWithEmbeds].
Map<String, Mode> get allLanguages => <String, Mode>{
  for (final MapEntry<String, Mode Function()> e in languageFactories.entries)
    e.key: e.value(),
};

/// Whether [name] is a language of [languageFactories].
bool isKnownLanguage(String name) => languageFactories.containsKey(name);

/// Names already registered on this isolate's highlighter. A global, so each
/// isolate keeps its own.
final Set<String> _registered = <String>{};

/// Registers [name] with [highlighter], together with every language its
/// grammar embeds (`subLanguage`: Markdown in Dart doc comments, CSS and
/// JavaScript in XML, ...) that is in [languageFactories]. Only those modes
/// are built.
void registerLanguageWithEmbeds(Highlight highlighter, String name) {
  final List<String> pending = <String>[name];
  while (pending.isNotEmpty) {
    final String next = pending.removeLast();
    final Mode Function()? factory = languageFactories[next];
    if (factory == null || !_registered.add(next)) continue;
    final Mode mode = factory();
    highlighter.registerLanguage(next, mode);
    final Set<String> embeds = <String>{};
    _collectSubLanguages(mode, Set<Mode>.identity(), embeds);
    pending.addAll(embeds);
  }
}

void _collectSubLanguages(Mode? mode, Set<Mode> seen, Set<String> out) {
  if (mode == null || !seen.add(mode)) return;
  final List<String>? sub = mode.subLanguage;
  if (sub != null) out.addAll(sub);
  for (final Mode? child in mode.contains ?? const <Mode?>[]) {
    _collectSubLanguages(child, seen, out);
  }
  for (final Mode? variant in mode.variants ?? const <Mode?>[]) {
    _collectSubLanguages(variant, seen, out);
  }
  _collectSubLanguages(mode.starts, seen, out);
  for (final Mode ref in mode.refs?.values ?? const <Mode>[]) {
    _collectSubLanguages(ref, seen, out);
  }
}
