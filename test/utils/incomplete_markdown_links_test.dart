import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/incomplete_markdown_links.dart';

void main() {
  test('unfinished URLs are not fabricated or exposed as broken markdown', () {
    const text =
        '- Spotify: [Suche in Spotify](https://open.spotify.com/search/A%20B';
    expect(
      presentIncompleteMarkdownLinks(text, streaming: true),
      '- Spotify: Suche in Spotify',
    );
    expect(
      presentIncompleteMarkdownLinks(text, streaming: false),
      '- Spotify: Suche in Spotify — Link unvollständig',
    );
  });
  test('complete links and fenced code remain unchanged', () {
    const complete = '[Spotify](https://open.spotify.com/search/A/tracks)';
    expect(
      presentIncompleteMarkdownLinks(complete, streaming: false),
      complete,
    );
    const code = '```md\n[Spotify](https://open.spotify.com/search/A\n```';
    expect(presentIncompleteMarkdownLinks(code, streaming: false), code);
  });
}
