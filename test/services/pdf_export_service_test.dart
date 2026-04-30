import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/pdf_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PdfExportService.buildPdfBytes', () {
    test('produces a non-empty PDF with a %PDF header for plain text', () async {
      final Uint8List bytes = await PdfExportService.buildPdfBytes(
        'Hello world.',
      );
      expect(bytes.length, greaterThan(100));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('renders rich markdown without throwing', () async {
      const String md = '''
# Heading

Some **bold** and *italic* and `code`.

- bullet one
- bullet two with [link](https://example.com)

```dart
final x = 1;
```

> quoted

| a | b |
|---|---|
| 1 | 2 |
''';
      final Uint8List bytes = await PdfExportService.buildPdfBytes(
        md,
        title: 'Demo',
      );
      expect(bytes.length, greaterThan(500));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });
  });
}
