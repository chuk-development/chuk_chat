import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/image_compression_service.dart';

void main() {
  group('detectImageFormat', () {
    test('detects JPEG', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('jpeg'));
    });

    test('detects JPEG with EXIF marker', () {
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x00]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('jpeg'));
    });

    test('detects PNG', () {
      final bytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00,
      ]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('png'));
    });

    test('detects GIF87a', () {
      // GIF87a: 47 49 46 38 37 61
      final bytes = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x37, 0x61]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('gif'));
    });

    test('detects GIF89a', () {
      // GIF89a: 47 49 46 38 39 61
      final bytes = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('gif'));
    });

    test('detects BMP', () {
      final bytes = Uint8List.fromList([0x42, 0x4D, 0x00, 0x00]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('bmp'));
    });

    test('detects WebP', () {
      // RIFF....WEBP
      final bytes = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x00, 0x00, 0x00, 0x00, // size (don't care)
        0x57, 0x45, 0x42, 0x50, // WEBP
      ]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('webp'));
    });

    test('detects TIFF little-endian', () {
      final bytes = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('tiff'));
    });

    test('detects TIFF big-endian', () {
      final bytes = Uint8List.fromList([0x4D, 0x4D, 0x00, 0x2A]);
      expect(ImageCompressionService.detectImageFormat(bytes), equals('tiff'));
    });

    test('rejects empty bytes', () {
      expect(ImageCompressionService.detectImageFormat(Uint8List(0)), isNull);
    });

    test('rejects too short bytes', () {
      expect(
        ImageCompressionService.detectImageFormat(Uint8List.fromList([0xFF])),
        isNull,
      );
    });

    test('rejects random bytes', () {
      final bytes = Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04]);
      expect(ImageCompressionService.detectImageFormat(bytes), isNull);
    });

    test('rejects text file disguised as image', () {
      // "Hello" in bytes
      final bytes = Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C, 0x6F]);
      expect(ImageCompressionService.detectImageFormat(bytes), isNull);
    });

    test('rejects PDF magic bytes', () {
      // %PDF
      final bytes = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
      expect(ImageCompressionService.detectImageFormat(bytes), isNull);
    });

    test('rejects EXE/PE magic bytes', () {
      // MZ header
      final bytes = Uint8List.fromList([0x4D, 0x5A, 0x90, 0x00]);
      expect(ImageCompressionService.detectImageFormat(bytes), isNull);
    });

    test('rejects ZIP magic bytes', () {
      // PK\x03\x04
      final bytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]);
      expect(ImageCompressionService.detectImageFormat(bytes), isNull);
    });

    test('partial PNG header rejected', () {
      // Only first 4 bytes of PNG header
      final bytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      expect(ImageCompressionService.detectImageFormat(bytes), isNull);
    });

    test('partial WebP header rejected', () {
      // Only RIFF without WEBP
      final bytes = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46,
        0x00, 0x00, 0x00, 0x00,
        0x41, 0x56, 0x49, 0x20, // AVI instead of WEBP
      ]);
      expect(ImageCompressionService.detectImageFormat(bytes), isNull);
    });
  });

  group('compressImage input validation', () {
    test('rejects file over 50MB', () async {
      // Create a >50MB buffer (just the size matters, content doesn't)
      final oversized = Uint8List(51 * 1024 * 1024);
      expect(
        () => ImageCompressionService.compressImage(oversized),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('too large'),
          ),
        ),
      );
    });

    test('rejects non-image file', () async {
      // Random bytes that don't match any image format
      final fakeFile = Uint8List.fromList(List.generate(100, (i) => i));
      expect(
        () => ImageCompressionService.compressImage(fakeFile),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Invalid image file'),
          ),
        ),
      );
    });

    test('accepts file under 50MB with valid JPEG header', () async {
      // Valid JPEG header but invalid image data — will fail at decode stage
      // This tests that the size and magic byte checks pass
      final fakeJpeg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0,
        ...List.generate(100, (i) => 0x00),
      ]);
      // Should pass size + magic byte checks, then fail at image decode
      expect(
        () => ImageCompressionService.compressImage(fakeJpeg),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('decode'),
          ),
        ),
      );
    });
  });

  group('getFileSizeMB', () {
    test('1MB file', () {
      final bytes = Uint8List(1024 * 1024);
      expect(ImageCompressionService.getFileSizeMB(bytes), equals('1.00'));
    });

    test('500KB file', () {
      final bytes = Uint8List(512 * 1024);
      expect(ImageCompressionService.getFileSizeMB(bytes), equals('0.50'));
    });

    test('empty file', () {
      final bytes = Uint8List(0);
      expect(ImageCompressionService.getFileSizeMB(bytes), equals('0.00'));
    });

    test('2.5MB file', () {
      final bytes = Uint8List((2.5 * 1024 * 1024).round());
      expect(ImageCompressionService.getFileSizeMB(bytes), equals('2.50'));
    });
  });

  group('constants', () {
    test('maxInputSizeBytes is 50MB', () {
      expect(
        ImageCompressionService.maxInputSizeBytes,
        equals(50 * 1024 * 1024),
      );
    });

    test('maxDecodedDimension is 10000', () {
      expect(ImageCompressionService.maxDecodedDimension, equals(10000));
    });

    test('targetFileSizeBytes is 2MB', () {
      expect(
        ImageCompressionService.targetFileSizeBytes,
        equals(2 * 1024 * 1024),
      );
    });

    test('maxDimension is 1920', () {
      expect(ImageCompressionService.maxDimension, equals(1920));
    });
  });
}
