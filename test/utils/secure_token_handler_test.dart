import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/secure_token_handler.dart';

void main() {
  group('maskToken', () {
    test('null returns [empty]', () {
      expect(SecureTokenHandler.maskToken(null), equals('[empty]'));
    });

    test('empty string returns [empty]', () {
      expect(SecureTokenHandler.maskToken(''), equals('[empty]'));
    });

    test('very short token (<=12) masks all but first 2', () {
      final result = SecureTokenHandler.maskToken('abcdef');
      expect(result, equals('ab****'));
      expect(result.length, equals(6));
    });

    test('exactly 12 chars masks all but first 2', () {
      final result = SecureTokenHandler.maskToken('123456789012');
      expect(result, startsWith('12'));
      expect(result.length, equals(12));
      expect(result, equals('12**********'));
    });

    test('long token shows first 8 and last 4', () {
      final token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test1234';
      final result = SecureTokenHandler.maskToken(token);
      expect(result, startsWith('eyJhbGci'));
      expect(result, endsWith('1234'));
      // Middle should be asterisks
      final middle = result.substring(8, result.length - 4);
      expect(middle, matches(RegExp(r'^\*+$')));
    });

    test('13-char token shows first 8 and last 4', () {
      final result = SecureTokenHandler.maskToken('1234567890123');
      expect(result, startsWith('12345678'));
      expect(result, endsWith('0123'));
      expect(result.length, equals(13));
    });
  });

  group('isTokenValid', () {
    test('null returns false', () {
      expect(SecureTokenHandler.isTokenValid(null), isFalse);
    });

    test('empty string returns false', () {
      expect(SecureTokenHandler.isTokenValid(''), isFalse);
    });

    test('non-empty string returns true', () {
      expect(SecureTokenHandler.isTokenValid('some-token'), isTrue);
    });

    test('whitespace returns true (not empty)', () {
      expect(SecureTokenHandler.isTokenValid(' '), isTrue);
    });
  });

  group('maskAuthHeader', () {
    test('Bearer token masked', () {
      final result = SecureTokenHandler.maskAuthHeader(
        'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature',
      );
      expect(result, startsWith('Bearer eyJhbGci'));
      expect(result, isNot(contains('payload')));
    });

    test('non-Bearer header masked as token', () {
      final result = SecureTokenHandler.maskAuthHeader('some-api-key-value');
      expect(result, isNot(equals('some-api-key-value')));
    });
  });

  group('validateTokenForRequest', () {
    test('null token returns error', () {
      final result = SecureTokenHandler.validateTokenForRequest(null);
      expect(result, isNotNull);
      expect(result, contains('missing'));
    });

    test('empty token returns error', () {
      final result = SecureTokenHandler.validateTokenForRequest('');
      expect(result, isNotNull);
      expect(result, contains('missing'));
    });

    test('valid JWT returns null (no error)', () {
      // JWT format: header.payload.signature (each part base64)
      final result = SecureTokenHandler.validateTokenForRequest(
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123',
      );
      expect(result, isNull);
    });

    test('JWT with only 2 parts returns error', () {
      final result = SecureTokenHandler.validateTokenForRequest(
        'eyJhbGci.payload',
      );
      // Short token (< 20 chars), should return error
      expect(result, isNotNull);
    });

    test('long non-JWT token returns null', () {
      // Not starting with "ey" but long enough
      final result = SecureTokenHandler.validateTokenForRequest(
        'abcdefghijklmnopqrstuvwxyz1234567890',
      );
      expect(result, isNull);
    });

    test('short non-JWT token returns error', () {
      final result = SecureTokenHandler.validateTokenForRequest('short');
      expect(result, isNotNull);
      expect(result, contains('invalid'));
    });

    test('custom context in error message', () {
      final result = SecureTokenHandler.validateTokenForRequest(
        null,
        context: 'Upload',
      );
      expect(result, contains('Upload'));
    });
  });

  group('createSafeErrorMessage', () {
    test('message without token unchanged', () {
      const msg = 'Connection failed';
      expect(
        SecureTokenHandler.createSafeErrorMessage(msg),
        equals(msg),
      );
    });

    test('message containing token gets masked', () {
      const token = 'eyJhbGciOiJIUzI1NiJ9.very.secret';
      const msg = 'Auth failed with token: eyJhbGciOiJIUzI1NiJ9.very.secret';
      final result = SecureTokenHandler.createSafeErrorMessage(
        msg,
        token: token,
      );
      expect(result, isNot(contains(token)));
    });

    test('null token returns message unchanged', () {
      const msg = 'Some error';
      expect(
        SecureTokenHandler.createSafeErrorMessage(msg, token: null),
        equals(msg),
      );
    });

    test('empty token returns message unchanged', () {
      const msg = 'Some error';
      expect(
        SecureTokenHandler.createSafeErrorMessage(msg, token: ''),
        equals(msg),
      );
    });
  });
}
