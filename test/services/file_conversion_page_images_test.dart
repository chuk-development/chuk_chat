import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/file_conversion_service.dart';

/// A scanned PDF has no text layer, so the API returns its pages as image
/// data URLs instead of markdown. Those URLs go straight into a chat
/// message, so what the client accepts from the response matters.
void main() {
  group('FileConversionService.extractPageImages', () {
    test('reads the page images of a scanned PDF', () {
      final images = FileConversionService.extractPageImages({
        'markdown': 'scan.pdf is a scanned document...',
        'engine': 'pdf_pages',
        'images': [
          'data:image/jpeg;base64,AAAA',
          'data:image/jpeg;base64,BBBB',
        ],
      });
      expect(images, hasLength(2));
    });

    test('a normal conversion has none', () {
      final images = FileConversionService.extractPageImages({
        'markdown': '# Report',
        'engine': 'anydoc',
      });
      expect(images, isNull);
    });

    test('empty list is treated as none, not as an empty attachment', () {
      expect(
        FileConversionService.extractPageImages({'images': []}),
        isNull,
      );
    });

    test('drops anything that is not an image data URL', () {
      // The response decides what gets attached to a message: a remote URL
      // or a javascript: payload must never survive this.
      final images = FileConversionService.extractPageImages({
        'images': [
          'data:image/jpeg;base64,GOOD',
          'https://example.com/tracker.png',
          'javascript:alert(1)',
          'data:text/html;base64,PHNjcmlwdD4=',
          42,
          null,
        ],
      });
      expect(images, equals(['data:image/jpeg;base64,GOOD']));
    });

    test('nothing usable at all is none', () {
      expect(
        FileConversionService.extractPageImages({
          'images': ['https://example.com/a.png'],
        }),
        isNull,
      );
    });

    test('survives a malformed response body', () {
      expect(FileConversionService.extractPageImages(null), isNull);
      expect(FileConversionService.extractPageImages('boom'), isNull);
      expect(FileConversionService.extractPageImages({'images': 'nope'}), isNull);
    });
  });

  group('AttachedFile for a scanned page', () {
    test('an image attachment can carry the scan note', () {
      // The PDF is replaced by its pages; the note explaining that it is a
      // scan rides on the first page, so an image attachment has to be able
      // to hold markdown and survive a storage round-trip with it.
      final page = AttachedFile(
        id: 'p1',
        fileName: 'scan.pdf — page 1',
        encryptedImagePath: 'user/p1.enc',
        isImage: true,
        markdownContent: '**scan.pdf is a scanned document**',
      );

      final restored = AttachedFile.fromJson(page.toJson());
      expect(restored.isImage, isTrue);
      expect(restored.encryptedImagePath, equals('user/p1.enc'));
      expect(restored.markdownContent, contains('scanned document'));
    });

    test('copyWith keeps the note while clearing the uploading flag', () {
      final page = AttachedFile(
        id: 'p1',
        fileName: 'scan.pdf — page 1',
        isImage: true,
        isUploading: true,
        markdownContent: 'note',
      ).copyWith(isUploading: false, encryptedImagePath: 'user/p1.enc');

      expect(page.isUploading, isFalse);
      expect(page.markdownContent, equals('note'));
      expect(page.encryptedImagePath, equals('user/p1.enc'));
    });
  });
}
