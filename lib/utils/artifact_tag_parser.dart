/// Parser for inline `\<artifact\>` tags in AI output.
///
/// Works like `\<chart\>`, `\<map\>`, `\<email\>` blocks but routes the parsed
/// tag through [ArtifactStorageService] (via [ArtifactTagProcessor]) so the
/// artifact is persisted and gets version history, while the AI-visible text
/// has the tag stripped.
///
/// Accepted shape:
///
///     <artifact id="my-id" type="technical_drawing" title="optional">
///       {...content...}
///     </artifact>
///
/// Attributes: `id` + `type` required, `title` and `language` optional.
library;

/// A single `<artifact>` tag parsed out of assistant text.
class ParsedArtifactTag {
  ParsedArtifactTag({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    this.language,
    required this.matchStart,
    required this.matchEnd,
  });

  final String id;
  final String type;
  final String title;
  final String content;
  final String? language;
  final int matchStart;
  final int matchEnd;
}

// Matches <artifact ...>body</artifact>. The attribute capture accepts:
//   - unquoted text that is not a quote or a closing angle bracket
//   - double-quoted strings (straight " or curly “ ”)
//   - single-quoted strings (straight ' or curly ‘ ’)
// Curly quotes are accepted because LLMs (especially multilingual models)
// frequently "smart-quote" attribute values even when explicitly told not to.
final RegExp _artifactBlockPattern = RegExp(
  r'''<\s*artifact\b((?:[^>"'\u201C\u201D\u2018\u2019]|"[^"]*"|'[^']*'|\u201C[^\u201D]*\u201D|\u2018[^\u2019]*\u2019)*)>([\s\S]*?)<\s*/\s*artifact\s*>''',
  caseSensitive: false,
);

final RegExp _artifactStartPattern = RegExp(
  r'<\s*artifact\b',
  caseSensitive: false,
);

// name="value" / name='value' / name=“value” / name=‘value’
final RegExp _attrPattern = RegExp(
  r'''(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)'|\u201C([^\u201D]*)\u201D|\u2018([^\u2019]*)\u2019)''',
);

// Matches an optional leading markdown code fence the LLM sometimes
// wraps around the content ("```json\n{...}\n```").
final RegExp _leadingCodeFence = RegExp(
  r'^\s*```(?:[a-zA-Z_][\w+\-]*)?\s*\r?\n',
);
final RegExp _trailingCodeFence = RegExp(r'\r?\n\s*```\s*$');

/// Returns all complete `<artifact>` blocks found in [text]. Partial
/// (unclosed) blocks are ignored.
List<ParsedArtifactTag> parseArtifactTags(String text) {
  final results = <ParsedArtifactTag>[];
  for (final match in _artifactBlockPattern.allMatches(text)) {
    final attrsRaw = match.group(1) ?? '';
    final rawContent = (match.group(2) ?? '').trim();
    if (rawContent.isEmpty) continue;

    // LLMs sometimes wrap the inner payload in a ```json fence. Strip a
    // single pair if present so the persisted content is usable JSON /
    // source text.
    final content = _stripWrappingFence(rawContent);
    if (content.isEmpty) continue;

    final attrs = <String, String>{};
    for (final a in _attrPattern.allMatches(attrsRaw)) {
      final key = a.group(1)?.toLowerCase();
      if (key == null || key.isEmpty) continue;
      final value =
          a.group(2) ?? a.group(3) ?? a.group(4) ?? a.group(5) ?? '';
      attrs[key] = value;
    }

    final id = (attrs['id'] ?? '').trim();
    final type = (attrs['type'] ?? '').trim();
    if (id.isEmpty || type.isEmpty) continue;

    final rawTitle = attrs['title']?.trim();
    final title = (rawTitle == null || rawTitle.isEmpty) ? id : rawTitle;
    final rawLanguage = attrs['language']?.trim();
    final language = (rawLanguage == null || rawLanguage.isEmpty)
        ? null
        : rawLanguage;

    results.add(
      ParsedArtifactTag(
        id: id,
        type: type,
        title: title,
        content: content,
        language: language,
        matchStart: match.start,
        matchEnd: match.end,
      ),
    );
  }
  return results;
}

/// Strip a single surrounding "```lang\n … \n```" fence if present. Leaves
/// nested fences alone — only the outermost wrapper is removed.
String _stripWrappingFence(String content) {
  if (!_leadingCodeFence.hasMatch(content)) return content;
  var stripped = content.replaceFirst(_leadingCodeFence, '');
  stripped = stripped.replaceFirst(_trailingCodeFence, '');
  return stripped.trim();
}

/// Strips complete `<artifact>...</artifact>` blocks from [content]. When
/// [stripIncomplete] is true (default), any remaining partial opening tag is
/// also cut so the raw protocol does not flash in the UI while streaming.
String stripArtifactTagsForDisplay(
  String content, {
  bool stripIncomplete = true,
}) {
  var cleaned = content.replaceAll(_artifactBlockPattern, '');
  if (stripIncomplete) {
    final start = _artifactStartPattern.firstMatch(cleaned)?.start;
    if (start != null) {
      cleaned = cleaned.substring(0, start);
    }
  }
  return cleaned;
}
