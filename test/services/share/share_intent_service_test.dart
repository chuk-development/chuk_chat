import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/share/share_intent_service.dart';

void main() {
  group('SharedContent.fromMap', () {
    test('null for nothing shared', () {
      expect(SharedContent.fromMap(null), isNull);
      expect(SharedContent.fromMap(<String, Object?>{'text': '  '}), isNull);
    });

    test('reads text, target and files; skips files without a path', () {
      final SharedContent share = SharedContent.fromMap(<String, Object?>{
        'text': 'hello',
        'target': 'agent-1',
        'files': <Object?>[
          <String, Object?>{
            'path': '/c/a.png',
            'name': 'a.png',
            'mime': 'image/png',
          },
          <String, Object?>{'path': '', 'name': 'b.png'},
          <String, Object?>{'path': '/c/x', 'name': ''},
        ],
      })!;
      expect(share.agentId, 'agent-1');
      expect(share.files.map((f) => f.name), <String>['a.png', 'shared']);
      expect(share.files.first.mime, 'image/png');
    });

    test('files alone are a share', () {
      final SharedContent? share = SharedContent.fromMap(<String, Object?>{
        'files': <Object?>[
          <String, Object?>{'path': '/c/a.pdf', 'name': 'a.pdf'},
        ],
      });
      expect(share, isNotNull);
      expect(share!.agentId, isNull);
    });
  });

  group('composerText', () {
    test('subject goes first on its own line', () {
      const SharedContent s = SharedContent(
        subject: 'A page',
        text: 'https://example.com',
      );
      expect(s.composerText, 'A page\nhttps://example.com');
    });

    test('subject the text already starts with is not doubled', () {
      const SharedContent s = SharedContent(subject: 'Hi', text: 'Hi there');
      expect(s.composerText, 'Hi there');
    });

    test('subject alone', () {
      const SharedContent s = SharedContent(subject: 'Only');
      expect(s.composerText, 'Only');
    });
  });

  group('parked files', () {
    setUp(() => ShareIntentService.instance.resetForTest());

    test('taken once, only for their chat', () {
      final ShareIntentService svc = ShareIntentService.instance;
      svc.parkFiles('t1', const <SharedFile>[
        SharedFile(path: '/a', name: 'a'),
      ]);
      expect(svc.takeParkedFiles('t2'), isEmpty);
      expect(svc.takeParkedFiles('t1'), hasLength(1));
      expect(svc.takeParkedFiles('t1'), isEmpty);
    });
  });
}
