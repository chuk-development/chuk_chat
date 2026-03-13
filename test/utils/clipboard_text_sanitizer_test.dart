import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/clipboard_text_sanitizer.dart';

void main() {
  group('ClipboardTextSanitizer', () {
    test('containsImageData detects base64 image data URL', () {
      const text = 'before data:image/jpeg;base64,QUJDREVGRw== after';

      final hasImageData = ClipboardTextSanitizer.containsImageData(text);

      expect(hasImageData, isTrue);
    });

    test('containsImageData is false for plain text', () {
      const text = 'hello world';

      final hasImageData = ClipboardTextSanitizer.containsImageData(text);

      expect(hasImageData, isFalse);
    });

    test('sanitize redacts plain base64 image data URLs', () {
      const text = 'prefix data:image/png;base64,SGVsbG8= suffix';

      final sanitized = ClipboardTextSanitizer.sanitize(text);

      expect(sanitized, 'prefix [image removed] suffix');
    });

    test('sanitize redacts markdown image with data URL', () {
      const text = '![alt](data:image/jpeg;base64,SGVsbG8=)';

      final sanitized = ClipboardTextSanitizer.sanitize(text);

      expect(sanitized, '[image removed]');
    });

    test('sanitize collapses repeated image placeholders', () {
      const text =
          'data:image/png;base64,QQ== data:image/jpeg;base64,Qg== done';

      final sanitized = ClipboardTextSanitizer.sanitize(text);

      expect(sanitized, '[image removed] done');
    });
  });
}
