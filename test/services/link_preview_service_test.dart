import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/link_preview_service.dart';

void main() {
  group('shortUrlLabel / linkTextIsUrl', () {
    test('host without www, path without scheme or query', () {
      expect(
        shortUrlLabel('https://www.example.com/a/b/?x=1'),
        'example.com/a/b',
      );
      expect(
        shortUrlLabel('https://arxiv.org/abs/2611.14043'),
        'arxiv.org/abs/2611.14043',
      );
      expect(shortUrlLabel('https://github.com/'), 'github.com');
    });

    test('link text that is only the address', () {
      const String u = 'https://www.example.com/a/';
      expect(linkTextIsUrl(u, u), isTrue);
      expect(linkTextIsUrl('example.com/a', u), isTrue);
      expect(linkTextIsUrl('', u), isTrue);
      expect(linkTextIsUrl('Inflect Mini v3', u), isFalse);
    });
  });

  group('LinkPreview.fromJson', () {
    test('empty answer is no card', () {
      expect(
        LinkPreview.fromJson(<String, dynamic>{
          'url': 'https://a.com',
          'empty': true,
        }),
        isNull,
      );
    });

    test('no title and no github is no card', () {
      expect(
        LinkPreview.fromJson(<String, dynamic>{
          'url': 'https://a.com',
          'host': 'a.com',
        }),
        isNull,
      );
    });

    test('drops a non-http image', () {
      final LinkPreview? p = LinkPreview.fromJson(<String, dynamic>{
        'url': 'https://a.com',
        'title': 'T',
        'image': 'javascript:x',
        'icon': 'https://a.com/i.png',
      });
      expect(p, isNotNull);
      expect(p!.imageUrl, isNull);
      expect(p.iconUrl, 'https://a.com/i.png');
      expect(p.host, 'a.com');
    });
  });

  group('LinkPreviewService', () {
    setUp(() {
      LinkPreviewService.debugReset();
      LinkPreviewService.debugSkipPersistentCache = true;
    });
    tearDown(LinkPreviewService.debugReset);

    test('fetches once and caches cards and misses', () async {
      int calls = 0;
      LinkPreviewService.debugFetchCard = (String url) async {
        calls++;
        return url.contains('good')
            ? <String, dynamic>{'url': url, 'title': 'Good'}
            : <String, dynamic>{'url': url, 'empty': true};
      };
      final List<LinkPreview?> both = await Future.wait(<Future<LinkPreview?>>[
        LinkPreviewService.get('https://good.com'),
        LinkPreviewService.get('https://good.com'),
      ]);
      expect(both[0]!.title, 'Good');
      expect(identical(both[0], both[1]), isTrue);
      expect(await LinkPreviewService.get('https://bad.com'), isNull);
      expect(await LinkPreviewService.get('https://bad.com'), isNull);
      expect(calls, 2);
      expect(LinkPreviewService.peek('https://bad.com'), (true, null));
    });

    test('a failure is quiet and backs off', () async {
      int calls = 0;
      LinkPreviewService.debugFetchCard = (String url) async {
        calls++;
        throw Exception('offline');
      };
      expect(await LinkPreviewService.get('https://x.com'), isNull);
      expect(await LinkPreviewService.get('https://x.com'), isNull);
      expect(calls, 1);
      expect(LinkPreviewService.peek('https://x.com').$1, isFalse);
    });
  });
}
