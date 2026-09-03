import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/widgets/message_bubble/web_search_sources.dart';

void main() {
  test('parses numbered web_search hits with title, url, snippet, age', () {
    const raw = r'''
Search results for "Cursor pricing":

1. The Complete Guide to Cursor Pricing | Flexprice
   https://flexprice.io/blog/cursor-pricing-guide
   Cursor costs nothing on Hobby, <strong>$200 on Ultra</strong>, with Teams at $40.
   age: 3 weeks ago
   • Pro buys $20 of usage.
2. Cursor Docs
   https://www.docs.cursor.com/pricing
   Official pricing page.
''';

    final sources = parseWebSearchSources(raw);

    expect(sources.length, 2);

    expect(sources[0].title, 'The Complete Guide to Cursor Pricing | Flexprice');
    expect(sources[0].url, 'https://flexprice.io/blog/cursor-pricing-guide');
    expect(sources[0].host, 'flexprice.io');
    expect(sources[0].age, '3 weeks ago');
    // HTML tags are stripped; the snippet text survives.
    expect(sources[0].snippet, contains(r'$200 on Ultra'));
    expect(sources[0].snippet, isNot(contains('<strong>')));

    // Host drops the leading www.
    expect(sources[1].host, 'docs.cursor.com');
    expect(sources[1].snippet, 'Official pricing page.');
  });

  test('returns empty for text without numbered hits', () {
    expect(parseWebSearchSources('just some prose, no hits here'), isEmpty);
  });
}
