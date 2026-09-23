/// Keep a partial streamed URL from filling the bubble with encoded bytes.
/// Never invent a missing URL suffix or make an incomplete target clickable.
String presentIncompleteMarkdownLinks(String text, {required bool streaming}) {
  var fenced = false;
  return text
      .split('\n')
      .map((line) {
        if (line.trimLeft().startsWith('```') ||
            line.trimLeft().startsWith('~~~')) {
          fenced = !fenced;
          return line;
        }
        if (fenced || line.startsWith('    ')) return line;
        return line.replaceFirstMapped(
          RegExp(r'\[([^\]\n]+)\]\(https?://[^\s()]*$'),
          (match) => '${match[1]}${streaming ? '' : ' — Link unvollständig'}',
        );
      })
      .join('\n');
}
