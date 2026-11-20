// The list behind the "N sources" pill: each page once, and the domain
// never shown as title and again as subtitle.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';
import 'package:chuk_chat/widgets/agent_activity/source_list.dart';

AgentActivitySource _s(String url, String title, {String? host}) =>
    AgentActivitySource(
      url: url,
      host: host ?? Uri.parse(url).host.replaceFirst(RegExp(r'^www\.'), ''),
      title: title,
    );

void main() {
  group('dedupeSources', () {
    test('folds www, scheme, fragment and trailing slash', () {
      final List<AgentActivitySource> out = dedupeSources(<AgentActivitySource>[
        _s('https://de.wikipedia.org/wiki/Berlin', 'Berlin'),
        _s('https://de.wikipedia.org/wiki/Berlin#Geschichte', 'Berlin'),
        _s('http://www.de.wikipedia.org/wiki/Berlin/', 'Berlin'),
        _s('https://www.visitberlin.de/en', 'Visit Berlin'),
        _s('https://visitberlin.de/en/', 'visitberlin.de'),
      ]);
      expect(out.map((s) => s.url), <String>[
        'https://de.wikipedia.org/wiki/Berlin',
        'https://www.visitberlin.de/en',
      ]);
    });

    test('keeps two different pages of one domain', () {
      final List<AgentActivitySource> out = dedupeSources(<AgentActivitySource>[
        _s('https://de.wikipedia.org/wiki/Berlin', 'de.wikipedia.org'),
        _s('https://de.wikipedia.org/wiki/Brandenburger_Tor', 'x'),
      ]);
      expect(out, hasLength(2));
    });

    test('a later real title replaces a bare one', () {
      final List<AgentActivitySource> out = dedupeSources(<AgentActivitySource>[
        _s('https://example.com/a', 'example.com'),
        _s('https://example.com/a/', 'The A page'),
      ]);
      expect(out.single.title, 'The A page');
      expect(out.single.url, 'https://example.com/a');
    });
  });

  group('sourceRowLabels', () {
    test('page title above, domain below', () {
      final labels = sourceRowLabels(
        _s('https://de.wikipedia.org/wiki/Berlin', 'Berlin'),
      );
      expect(labels.title, 'Berlin');
      expect(labels.subtitle, 'de.wikipedia.org');
    });

    test('no title: a name from the path, domain below', () {
      final labels = sourceRowLabels(
        _s(
          'https://de.wikipedia.org/wiki/Brandenburger_Tor',
          'de.wikipedia.org',
        ),
      );
      expect(labels.title, 'Brandenburger Tor');
      expect(labels.subtitle, 'de.wikipedia.org');
    });

    test('no title and no path: the domain once, no subtitle', () {
      for (final String title in <String>[
        'www.berlin.de',
        'berlin.de',
        'https://www.berlin.de/',
      ]) {
        final labels = sourceRowLabels(_s('https://www.berlin.de/', title));
        expect(labels.title, 'berlin.de', reason: title);
        expect(labels.subtitle, isNull, reason: title);
      }
    });
  });
}
