import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/input_validator.dart';

void main() {
  group('validateEmail', () {
    test('null returns required error', () {
      expect(InputValidator.validateEmail(null), isNotNull);
    });

    test('empty string returns required error', () {
      expect(InputValidator.validateEmail(''), isNotNull);
    });

    test('whitespace only returns required error', () {
      expect(InputValidator.validateEmail('   '), isNotNull);
    });

    test('valid email returns null', () {
      expect(InputValidator.validateEmail('user@example.com'), isNull);
    });

    test('valid email with subdomain returns null', () {
      expect(InputValidator.validateEmail('user@sub.example.com'), isNull);
    });

    test('valid email with plus returns null', () {
      expect(InputValidator.validateEmail('user+tag@example.com'), isNull);
    });

    test('valid email with dots returns null', () {
      expect(InputValidator.validateEmail('first.last@example.com'), isNull);
    });

    test('email without @ is invalid', () {
      expect(InputValidator.validateEmail('userexample.com'), isNotNull);
    });

    test('email without domain is invalid', () {
      expect(InputValidator.validateEmail('user@'), isNotNull);
    });

    test('email without local part is invalid', () {
      expect(InputValidator.validateEmail('@example.com'), isNotNull);
    });

    test('email too long returns error', () {
      final longEmail = '${'a' * 310}@example.com';
      expect(InputValidator.validateEmail(longEmail), isNotNull);
    });

    test('email with spaces is invalid', () {
      expect(InputValidator.validateEmail('user @example.com'), isNotNull);
    });

    test('trims whitespace before validating', () {
      expect(InputValidator.validateEmail(' user@example.com '), isNull);
    });
  });

  group('validateMessageLength', () {
    test('normal message returns null', () {
      expect(InputValidator.validateMessageLength('Hello world'), isNull);
    });

    test('empty message returns null', () {
      expect(InputValidator.validateMessageLength(''), isNull);
    });

    test('message at max length returns null', () {
      final msg = 'a' * InputValidator.maxMessageLength;
      expect(InputValidator.validateMessageLength(msg), isNull);
    });

    test('message over max length returns error', () {
      final msg = 'a' * (InputValidator.maxMessageLength + 1);
      expect(InputValidator.validateMessageLength(msg), isNotNull);
    });
  });

  group('sanitizeFileName', () {
    test('normal filename unchanged', () {
      expect(InputValidator.sanitizeFileName('photo.jpg'), equals('photo.jpg'));
    });

    test('empty filename returns unnamed_file', () {
      expect(InputValidator.sanitizeFileName(''), equals('unnamed_file'));
    });

    test('path traversal attack sanitized', () {
      final result = InputValidator.sanitizeFileName('../../etc/passwd');
      expect(result, isNot(contains('..')));
      expect(result, isNot(contains('/')));
    });

    test('backslash path traversal sanitized', () {
      final result = InputValidator.sanitizeFileName(r'..\..\windows\system32');
      expect(result, isNot(contains('\\')));
    });

    test('null bytes removed', () {
      final result = InputValidator.sanitizeFileName('file\x00.jpg');
      expect(result, isNot(contains('\x00')));
    });

    test('control characters removed', () {
      final result = InputValidator.sanitizeFileName('file\x01\x02.jpg');
      expect(result, isNot(contains('\x01')));
      expect(result, isNot(contains('\x02')));
    });

    test('very long filename truncated preserving extension', () {
      final longName = '${'a' * 300}.pdf';
      final result = InputValidator.sanitizeFileName(longName);
      expect(
        result.length,
        lessThanOrEqualTo(InputValidator.maxFileNameLength),
      );
      expect(result, endsWith('.pdf'));
    });

    test('filename with forward slashes sanitized', () {
      final result = InputValidator.sanitizeFileName('path/to/file.txt');
      expect(result, isNot(contains('/')));
    });
  });

  group('escapeFileNameForDisplay', () {
    test('normal filename unchanged', () {
      expect(InputValidator.escapeFileNameForDisplay('photo'), equals('photo'));
    });

    test('markdown special chars escaped', () {
      final result = InputValidator.escapeFileNameForDisplay('*bold*');
      expect(result, equals('\\*bold\\*'));
    });

    test('backticks escaped', () {
      final result = InputValidator.escapeFileNameForDisplay('`code`');
      expect(result, equals('\\`code\\`'));
    });

    test('brackets escaped', () {
      final result = InputValidator.escapeFileNameForDisplay('[link](url)');
      expect(result, contains('\\['));
      expect(result, contains('\\]'));
      expect(result, contains('\\('));
      expect(result, contains('\\)'));
    });
  });

  group('validateAndSanitizeMessage', () {
    test('valid message returns valid=true', () {
      final result = InputValidator.validateAndSanitizeMessage('Hello');
      expect(result['valid'], isTrue);
      expect(result['sanitized'], equals('Hello'));
      expect(result['error'], isNull);
    });

    test('message is trimmed', () {
      final result = InputValidator.validateAndSanitizeMessage('  Hello  ');
      expect(result['sanitized'], equals('Hello'));
    });

    test('too long message returns valid=false', () {
      final msg = 'a' * (InputValidator.maxMessageLength + 1);
      final result = InputValidator.validateAndSanitizeMessage(msg);
      expect(result['valid'], isFalse);
      expect(result['error'], isNotNull);
    });
  });

  group('validatePassword', () {
    test('null returns error', () {
      expect(InputValidator.validatePassword(null), isNotNull);
    });

    test('empty string returns error', () {
      expect(InputValidator.validatePassword(''), isNotNull);
    });

    test('too short returns error', () {
      expect(InputValidator.validatePassword('Ab1!'), isNotNull);
    });

    test('valid strong password returns null', () {
      expect(InputValidator.validatePassword('MyP@ss1!'), isNull);
    });

    test('no uppercase returns error', () {
      expect(InputValidator.validatePassword('myp@ss1!'), isNotNull);
    });

    test('no lowercase returns error', () {
      expect(InputValidator.validatePassword('MYP@SS1!'), isNotNull);
    });

    test('no digit returns error', () {
      expect(InputValidator.validatePassword('MyP@sswo!'), isNotNull);
    });

    test('no special char returns error', () {
      expect(InputValidator.validatePassword('MyPassw1'), isNotNull);
    });

    test('exactly min length with all requirements passes', () {
      // 8 chars: uppercase + lowercase + digit + special
      expect(InputValidator.validatePassword('Ab1!cdef'), isNull);
    });

    test('7 chars with all requirements still too short', () {
      expect(InputValidator.validatePassword('Ab1!cde'), isNotNull);
    });
  });

  group('validatePasswordStrength', () {
    test('empty password is weak', () {
      final result = InputValidator.validatePasswordStrength('');
      expect(result.isValid, isFalse);
      expect(result.strength, equals(PasswordStrength.weak));
    });

    test('all lowercase is weak', () {
      final result = InputValidator.validatePasswordStrength('abcdefgh');
      expect(result.isValid, isFalse);
      expect(result.strength, equals(PasswordStrength.weak));
    });

    test('meeting all requirements is at least fair', () {
      final result = InputValidator.validatePasswordStrength('Ab1!cdef');
      expect(result.isValid, isTrue);
      expect(
        result.strength.index,
        greaterThanOrEqualTo(PasswordStrength.fair.index),
      );
    });

    test('long password with all requirements is strong', () {
      final result = InputValidator.validatePasswordStrength(
        'MyVeryStr0ng!Password2024',
      );
      expect(result.isValid, isTrue);
      expect(result.strength, equals(PasswordStrength.strong));
    });

    test('suggestions list is empty for valid password', () {
      final result = InputValidator.validatePasswordStrength('Ab1!cdef');
      expect(result.suggestions, isEmpty);
    });

    test('suggestions list populated for weak password', () {
      final result = InputValidator.validatePasswordStrength('abc');
      expect(result.suggestions, isNotEmpty);
    });

    test('individual flags are correct', () {
      final result = InputValidator.validatePasswordStrength('abc');
      expect(result.hasMinLength, isFalse);
      expect(result.hasUppercase, isFalse);
      expect(result.hasLowercase, isTrue);
      expect(result.hasDigit, isFalse);
      expect(result.hasSpecialChar, isFalse);
    });
  });
}
