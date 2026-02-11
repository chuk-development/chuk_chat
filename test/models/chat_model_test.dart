import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/chat_model.dart';

void main() {
  group('ModelItem', () {
    test('constructor', () {
      final item = ModelItem(name: 'GPT-4', value: 'gpt-4');
      expect(item.name, equals('GPT-4'));
      expect(item.value, equals('gpt-4'));
      expect(item.isToggle, isFalse);
      expect(item.badge, isNull);
      expect(item.iconUrl, isNull);
    });

    test('constructor with optional fields', () {
      final item = ModelItem(
        name: 'Claude',
        value: 'claude-3',
        isToggle: true,
        badge: 'NEW',
        iconUrl: 'https://example.com/icon.png',
      );
      expect(item.isToggle, isTrue);
      expect(item.badge, equals('NEW'));
      expect(item.iconUrl, equals('https://example.com/icon.png'));
    });

    test('fromJson', () {
      final item = ModelItem.fromJson({
        'name': 'Claude 3 Opus',
        'id': 'claude-3-opus',
        'icon_url': 'https://cdn.example.com/claude.svg',
      });
      expect(item.name, equals('Claude 3 Opus'));
      expect(item.value, equals('claude-3-opus'));
      expect(item.iconUrl, equals('https://cdn.example.com/claude.svg'));
      expect(item.isToggle, isFalse);
      expect(item.badge, isNull);
    });

    test('fromJson without icon_url', () {
      final item = ModelItem.fromJson({
        'name': 'Test Model',
        'id': 'test-model',
      });
      expect(item.iconUrl, isNull);
    });

    test('equality by value', () {
      final a = ModelItem(name: 'GPT-4', value: 'gpt-4');
      final b = ModelItem(name: 'GPT-4 Turbo', value: 'gpt-4');
      expect(a, equals(b)); // Same value means equal
    });

    test('inequality by value', () {
      final a = ModelItem(name: 'GPT-4', value: 'gpt-4');
      final b = ModelItem(name: 'GPT-4', value: 'gpt-4o');
      expect(a, isNot(equals(b)));
    });

    test('hashCode based on value', () {
      final a = ModelItem(name: 'A', value: 'same-id');
      final b = ModelItem(name: 'B', value: 'same-id');
      expect(a.hashCode, equals(b.hashCode));
    });

    test('can be used in Set (deduplication by value)', () {
      final set = <ModelItem>{
        ModelItem(name: 'A', value: 'model-1'),
        ModelItem(name: 'B', value: 'model-1'),
        ModelItem(name: 'C', value: 'model-2'),
      };
      expect(set, hasLength(2));
    });
  });

  group('AttachedFile', () {
    test('constructor with required fields', () {
      final file = AttachedFile(id: 'f1', fileName: 'doc.pdf');
      expect(file.id, equals('f1'));
      expect(file.fileName, equals('doc.pdf'));
      expect(file.markdownContent, isNull);
      expect(file.isUploading, isFalse);
      expect(file.localPath, isNull);
      expect(file.fileSizeBytes, isNull);
      expect(file.encryptedImagePath, isNull);
      expect(file.isImage, isFalse);
    });

    test('constructor with all fields', () {
      final file = AttachedFile(
        id: 'f2',
        fileName: 'photo.jpg',
        markdownContent: null,
        isUploading: true,
        localPath: '/tmp/photo.jpg',
        fileSizeBytes: 1024000,
        encryptedImagePath: 'user123/abc.enc',
        isImage: true,
      );
      expect(file.isUploading, isTrue);
      expect(file.localPath, equals('/tmp/photo.jpg'));
      expect(file.fileSizeBytes, equals(1024000));
      expect(file.encryptedImagePath, equals('user123/abc.enc'));
      expect(file.isImage, isTrue);
    });

    test('copyWith changes specific fields', () {
      final original = AttachedFile(
        id: 'f1',
        fileName: 'doc.pdf',
        isUploading: true,
      );
      final updated = original.copyWith(
        isUploading: false,
        markdownContent: '# Document content',
      );
      expect(updated.id, equals('f1'));
      expect(updated.fileName, equals('doc.pdf'));
      expect(updated.isUploading, isFalse);
      expect(updated.markdownContent, equals('# Document content'));
    });

    test('copyWith preserves unchanged fields', () {
      final original = AttachedFile(
        id: 'f1',
        fileName: 'photo.jpg',
        isImage: true,
        encryptedImagePath: 'user/img.enc',
      );
      final updated = original.copyWith(isUploading: false);
      expect(updated.isImage, isTrue);
      expect(updated.encryptedImagePath, equals('user/img.enc'));
    });

    test('toJson includes all fields', () {
      final file = AttachedFile(
        id: 'f1',
        fileName: 'doc.pdf',
        markdownContent: '# Content',
        isUploading: false,
        localPath: '/tmp/doc.pdf',
        fileSizeBytes: 2048,
        encryptedImagePath: null,
        isImage: false,
      );
      final json = file.toJson();
      expect(json['id'], equals('f1'));
      expect(json['fileName'], equals('doc.pdf'));
      expect(json['markdownContent'], equals('# Content'));
      expect(json['isUploading'], isFalse);
      expect(json['localPath'], equals('/tmp/doc.pdf'));
      expect(json['fileSizeBytes'], equals(2048));
      expect(json['encryptedImagePath'], isNull);
      expect(json['isImage'], isFalse);
    });

    test('fromJson creates correct instance', () {
      final file = AttachedFile.fromJson({
        'id': 'f1',
        'fileName': 'photo.jpg',
        'markdownContent': null,
        'isUploading': false,
        'localPath': '/tmp/photo.jpg',
        'fileSizeBytes': 1024,
        'encryptedImagePath': 'user/img.enc',
        'isImage': true,
      });
      expect(file.id, equals('f1'));
      expect(file.fileName, equals('photo.jpg'));
      expect(file.isImage, isTrue);
      expect(file.encryptedImagePath, equals('user/img.enc'));
    });

    test('fromJson handles missing optional fields', () {
      final file = AttachedFile.fromJson({
        'id': 'f1',
        'fileName': 'doc.txt',
      });
      expect(file.isUploading, isFalse);
      expect(file.isImage, isFalse);
      expect(file.markdownContent, isNull);
    });

    test('toJson/fromJson roundtrip', () {
      final original = AttachedFile(
        id: 'roundtrip',
        fileName: 'test.pdf',
        markdownContent: '# Test',
        isUploading: false,
        localPath: '/path/to/file',
        fileSizeBytes: 5000,
        encryptedImagePath: 'enc/path',
        isImage: false,
      );
      final restored = AttachedFile.fromJson(original.toJson());
      expect(restored.id, equals(original.id));
      expect(restored.fileName, equals(original.fileName));
      expect(restored.markdownContent, equals(original.markdownContent));
      expect(restored.isUploading, equals(original.isUploading));
      expect(restored.localPath, equals(original.localPath));
      expect(restored.fileSizeBytes, equals(original.fileSizeBytes));
      expect(restored.encryptedImagePath, equals(original.encryptedImagePath));
      expect(restored.isImage, equals(original.isImage));
    });
  });
}
