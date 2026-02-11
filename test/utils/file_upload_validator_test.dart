import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/file_upload_validator.dart';

void main() {
  group('FileValidationResult', () {
    test('success factory', () {
      final result = FileValidationResult.success(
        fileSizeBytes: 1024,
        mimeType: 'image/png',
      );
      expect(result.isValid, isTrue);
      expect(result.fileSizeBytes, equals(1024));
      expect(result.mimeType, equals('image/png'));
      expect(result.errorMessage, isNull);
    });

    test('error factory', () {
      final result = FileValidationResult.error('File too large');
      expect(result.isValid, isFalse);
      expect(result.errorMessage, equals('File too large'));
      expect(result.fileSizeBytes, isNull);
      expect(result.mimeType, isNull);
    });
  });

  group('constants', () {
    test('maxFileSizeBytes is 10MB', () {
      expect(FileUploadValidator.maxFileSizeBytes, equals(10 * 1024 * 1024));
    });

    test('maxArchiveEntries is 1000', () {
      expect(FileUploadValidator.maxArchiveEntries, equals(1000));
    });

    test('maxArchiveUncompressedSize is 50MB', () {
      expect(
        FileUploadValidator.maxArchiveUncompressedSize,
        equals(50 * 1024 * 1024),
      );
    });
  });

  group('formatFileSize', () {
    test('bytes', () {
      expect(FileUploadValidator.formatFileSize(500), equals('500 B'));
    });

    test('zero bytes', () {
      expect(FileUploadValidator.formatFileSize(0), equals('0 B'));
    });

    test('1 byte', () {
      expect(FileUploadValidator.formatFileSize(1), equals('1 B'));
    });

    test('kilobytes', () {
      expect(FileUploadValidator.formatFileSize(1536), equals('1.5 KB'));
    });

    test('exactly 1KB', () {
      expect(FileUploadValidator.formatFileSize(1024), equals('1.0 KB'));
    });

    test('megabytes', () {
      expect(
        FileUploadValidator.formatFileSize(2 * 1024 * 1024),
        equals('2.00 MB'),
      );
    });

    test('fractional megabytes', () {
      expect(
        FileUploadValidator.formatFileSize((1.5 * 1024 * 1024).round()),
        equals('1.50 MB'),
      );
    });

    test('just under 1KB stays as bytes', () {
      expect(FileUploadValidator.formatFileSize(1023), equals('1023 B'));
    });

    test('just under 1MB stays as KB', () {
      expect(
        FileUploadValidator.formatFileSize(1024 * 1024 - 1),
        contains('KB'),
      );
    });
  });

  group('extensionToMimeTypes', () {
    test('contains common document types', () {
      expect(FileUploadValidator.extensionToMimeTypes, contains('pdf'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('doc'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('docx'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('txt'));
    });

    test('contains image types', () {
      expect(FileUploadValidator.extensionToMimeTypes, contains('png'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('jpg'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('jpeg'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('gif'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('webp'));
    });

    test('contains code file types', () {
      expect(FileUploadValidator.extensionToMimeTypes, contains('py'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('js'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('ts'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('java'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('go'));
    });

    test('contains audio types', () {
      expect(FileUploadValidator.extensionToMimeTypes, contains('wav'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('mp3'));
      expect(FileUploadValidator.extensionToMimeTypes, contains('m4a'));
    });

    test('pdf maps to application/pdf', () {
      expect(
        FileUploadValidator.extensionToMimeTypes['pdf'],
        contains('application/pdf'),
      );
    });

    test('code files include text/plain as fallback', () {
      for (final ext in ['py', 'js', 'ts', 'java', 'go', 'rs', 'rb']) {
        expect(
          FileUploadValidator.extensionToMimeTypes[ext],
          contains('text/plain'),
          reason: '$ext should include text/plain',
        );
      }
    });

    test('no extension has empty mime list', () {
      for (final entry in FileUploadValidator.extensionToMimeTypes.entries) {
        expect(
          entry.value,
          isNotEmpty,
          reason: '${entry.key} has empty mime type list',
        );
      }
    });
  });
}
