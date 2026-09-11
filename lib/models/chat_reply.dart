/// Reply context travels as ordinary quoted user text, so host history, offline
/// sends and replay retain it without a second, client-only message database.
class ChatReply {
  const ChatReply({required this.author, required this.text});
  final String author;
  final String text;

  String compose(String message) {
    final quote = text.length > 6000
        ? '${text.substring(0, 6000)}… [quote shortened]'
        : text;
    return '> Reply to $author:\n${quote.split('\n').map((line) => '> $line').join('\n')}\n\n$message';
  }

  static ({ChatReply reply, String message})? parse(String text) {
    final lines = text.split('\n');
    if (lines.length < 4) return null;
    final author = switch (lines.first) {
      '> Reply to You:' => 'You',
      '> Reply to AI:' => 'AI',
      _ => null,
    };
    if (author == null) return null;
    var i = 1;
    final quote = <String>[];
    while (i < lines.length && lines[i].startsWith('> ')) {
      quote.add(lines[i++].substring(2));
    }
    if (quote.isEmpty || i >= lines.length || lines[i] != '') return null;
    return (
      reply: ChatReply(author: author, text: quote.join('\n')),
      message: lines.skip(i + 1).join('\n'),
    );
  }
}
