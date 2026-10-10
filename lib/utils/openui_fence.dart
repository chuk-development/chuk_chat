// lib/utils/openui_fence.dart
//
// Finds the OpenUI Lang programs in an assistant answer. The model writes
// normal markdown and puts a UI in a ```openui-lang fence (upstream
// "inline mode", docs/OPENUI.md). The chat draws each program as native
// widgets and the text around it as markdown.
//
// Pure Dart: the voice glue and the notification code use it too.

/// One piece of an assistant answer: markdown text or one OpenUI program.
class OpenUiTextPart {
  /// Creates a markdown part.
  const OpenUiTextPart.markdown(this.text)
    : isProgram = false,
      isClosed = true,
      ordinal = -1;

  /// Creates a program part. [ordinal] counts the programs of the text,
  /// from 0.
  const OpenUiTextPart.program(
    this.text, {
    required this.ordinal,
    required this.isClosed,
  }) : isProgram = true;

  /// The markdown text, or the program source without the fence lines.
  final String text;

  /// Whether this part is an OpenUI program.
  final bool isProgram;

  /// Whether the program fence has its closing line. Always true for
  /// markdown. An open fence is a program that is still streaming, or a
  /// model that forgot the closing line.
  final bool isClosed;

  /// The index of the program in the text, or -1 for markdown.
  final int ordinal;

  @override
  String toString() => isProgram
      ? 'program#$ordinal${isClosed ? '' : '(open)'}: $text'
      : 'markdown: $text';
}

/// An opening fence line of an OpenUI program: three or more backticks,
/// then `openui-lang` or `openui`.
final RegExp _openUiOpener = RegExp(
  r'^ {0,3}(`{3,})[ \t]*(?:openui-lang|openui)[ \t\r]*$',
  caseSensitive: false,
);

/// Any fence opening line (code blocks): backticks or tildes, then an
/// optional info string.
final RegExp _anyOpener = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// The info string of the fence line that the stream writes now.
final RegExp _partialOpener = RegExp(r'^ {0,3}`{3,}([A-Za-z-]*)\r?$');

const String _openUiInfo = 'openui-lang';

/// Whether [text] can hold an OpenUI fence. A cheap check before
/// [splitOpenUiFences].
bool mayContainOpenUiFence(String text) => text.contains('```');

/// Splits [text] into markdown parts and OpenUI program parts.
///
/// - A program starts at a line ```` ```openui-lang ```` (or ```` ```openui ````)
///   and ends at a line of at least as many backticks.
/// - An OpenUI opener inside another code block is code, not a program.
/// - A program without a closing line runs to the end of the text.
/// - When [streaming] is true, a last line that can still become an
///   OpenUI opener (```` ``` ````, ```` ```open ````) is dropped, so the
///   reader never sees a half fence.
///
/// Empty markdown parts are left out. Text without a program gives one
/// markdown part (or none when it is empty).
List<OpenUiTextPart> splitOpenUiFences(String text, {bool streaming = false}) {
  final parts = <OpenUiTextPart>[];
  if (!mayContainOpenUiFence(text)) {
    if (text.trim().isNotEmpty) parts.add(OpenUiTextPart.markdown(text));
    return parts;
  }

  final lines = text.split('\n');
  final markdown = StringBuffer();
  var ordinal = 0;

  void flushMarkdown() {
    final md = markdown.toString();
    if (md.trim().isNotEmpty) parts.add(OpenUiTextPart.markdown(md));
    markdown.clear();
  }

  void addMarkdownLine(String line) {
    if (markdown.isNotEmpty) markdown.write('\n');
    markdown.write(line);
  }

  // A normal code block that is open now: its fence character and length.
  String? codeFenceChar;
  var codeFenceLength = 0;

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];

    if (codeFenceChar != null) {
      addMarkdownLine(line);
      if (_closesFence(line, codeFenceChar, codeFenceLength)) {
        codeFenceChar = null;
      }
      i++;
      continue;
    }

    final openUi = _openUiOpener.firstMatch(line);
    if (openUi != null) {
      final fenceLength = openUi.group(1)!.length;
      final body = <String>[];
      var closed = false;
      var j = i + 1;
      for (; j < lines.length; j++) {
        if (_closesFence(lines[j], '`', fenceLength)) {
          closed = true;
          break;
        }
        body.add(lines[j]);
      }
      flushMarkdown();
      parts.add(
        OpenUiTextPart.program(
          body.join('\n'),
          ordinal: ordinal++,
          isClosed: closed,
        ),
      );
      i = closed ? j + 1 : j;
      continue;
    }

    final isLast = i == lines.length - 1;
    if (streaming && isLast && _canBecomeOpenUiOpener(line)) {
      i++;
      continue;
    }

    final code = _anyOpener.firstMatch(line);
    if (code != null) {
      final fence = code.group(1)!;
      // A backtick fence cannot have a backtick in its info string; such
      // a line is inline code, not a fence.
      if (!(fence.startsWith('`') && code.group(2)!.contains('`'))) {
        codeFenceChar = fence[0];
        codeFenceLength = fence.length;
      }
    }
    addMarkdownLine(line);
    i++;
  }
  flushMarkdown();
  return parts;
}

bool _closesFence(String line, String char, int minLength) {
  final trimmed = line.trimRight();
  var start = 0;
  while (start < trimmed.length && start < 3 && trimmed[start] == ' ') {
    start++;
  }
  final rest = trimmed.substring(start);
  if (rest.length < minLength) return false;
  for (var k = 0; k < rest.length; k++) {
    if (rest[k] != char) return false;
  }
  return true;
}

bool _canBecomeOpenUiOpener(String line) {
  final m = _partialOpener.firstMatch(line);
  if (m == null) return false;
  return _openUiInfo.startsWith(m.group(1)!.toLowerCase());
}

/// Whether [text] holds an OpenUI program (closed or open).
bool hasOpenUiProgram(String text) =>
    mayContainOpenUiFence(text) &&
    splitOpenUiFences(text).any((p) => p.isProgram);

/// [text] without its OpenUI programs: only the markdown parts, joined
/// by blank lines. For previews, notifications and speech, where a
/// program is noise. Text without a program comes back unchanged.
///
/// When the answer is only a program, the result is [whenEmpty].
String stripOpenUiPrograms(String text, {String whenEmpty = ''}) {
  if (!mayContainOpenUiFence(text)) return text;
  final parts = splitOpenUiFences(text);
  if (!parts.any((p) => p.isProgram)) return text;
  final kept = parts
      .where((p) => !p.isProgram)
      .map((p) => p.text.trim())
      .where((t) => t.isNotEmpty)
      .join('\n\n');
  return kept.isEmpty ? whenEmpty : kept;
}
