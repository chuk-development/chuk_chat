/// Password strength levels.
enum PasswordStrength { weak, fair, good, strong }

/// Result of password validation with detailed feedback.
class PasswordValidationResult {
  final bool isValid;
  final PasswordStrength strength;
  final String? errorMessage;
  final List<String> suggestions;
  final bool hasMinLength;
  final bool hasUppercase;
  final bool hasLowercase;
  final bool hasDigit;
  final bool hasSpecialChar;

  const PasswordValidationResult({
    required this.isValid,
    required this.strength,
    this.errorMessage,
    required this.suggestions,
    required this.hasMinLength,
    required this.hasUppercase,
    required this.hasLowercase,
    required this.hasDigit,
    required this.hasSpecialChar,
  });
}

/// Input validation and sanitization utilities for security.
///
/// This utility provides validation and sanitization functions to prevent
/// injection attacks, XSS, and DoS via malformed inputs.
class InputValidator {
  InputValidator._();

  /// Maximum message length (20 million characters).
  /// This is well above the maximum context window of any current LLM (10M).
  static const int maxMessageLength = 20000000;

  /// Maximum email length (reasonable limit for email addresses).
  static const int maxEmailLength = 320; // RFC 5321 standard

  /// Maximum file name length (reasonable limit for file names).
  static const int maxFileNameLength = 255;

  /// Minimum password length (matches Supabase auth setting: config.toml).
  static const int minPasswordLength = 8;

  /// RFC 5322 compliant email validation regex (simplified).
  /// Validates: local-part@domain with proper character restrictions.
  static final RegExp _emailRegex = RegExp(
    r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$",
  );

  /// Validates email address format and length.
  ///
  /// Returns null if valid, otherwise returns an error message.
  static String? validateEmail(String? email) {
    if (email == null || email.trim().isEmpty) {
      return 'Email address is required.';
    }

    final trimmedEmail = email.trim();

    if (trimmedEmail.length > maxEmailLength) {
      return 'Email address is too long.';
    }

    if (!_emailRegex.hasMatch(trimmedEmail)) {
      return 'Please enter a valid email address.';
    }

    return null;
  }

  /// Validates message length.
  ///
  /// Returns null if valid, otherwise returns an error message.
  static String? validateMessageLength(String message) {
    if (message.length > maxMessageLength) {
      return 'Message is too long. Maximum length is ${_formatNumber(maxMessageLength)} characters.';
    }
    return null;
  }

  /// Sanitizes a file name by removing or escaping potentially dangerous characters.
  ///
  /// This prevents path traversal attacks and injection attacks via file names.
  /// Replaces dangerous characters with underscores and limits length.
  static String sanitizeFileName(String fileName) {
    if (fileName.isEmpty) {
      return 'unnamed_file';
    }

    // Remove path separators and null bytes
    String sanitized = fileName
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll('\x00', '_')
        .replaceAll('..', '_');

    // Remove control characters (ASCII 0-31 and 127)
    sanitized = sanitized.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_');

    // Trim whitespace
    sanitized = sanitized.trim();

    // Limit length
    if (sanitized.length > maxFileNameLength) {
      final extension = _getFileExtension(sanitized);
      final nameWithoutExt = sanitized.substring(
        0,
        sanitized.length - extension.length,
      );
      sanitized =
          nameWithoutExt.substring(0, maxFileNameLength - extension.length) +
          extension;
    }

    // Ensure we have a valid file name
    if (sanitized.isEmpty) {
      return 'unnamed_file';
    }

    return sanitized;
  }

  /// Escapes special characters in file name for safe display in messages.
  ///
  /// This prevents markdown injection and other formatting issues.
  static String escapeFileNameForDisplay(String fileName) {
    // Escape markdown special characters
    return fileName
        .replaceAll('\\', '\\\\')
        .replaceAll('`', '\\`')
        .replaceAll('*', '\\*')
        .replaceAll('_', '\\_')
        .replaceAll('[', '\\[')
        .replaceAll(']', '\\]')
        .replaceAll('(', '\\(')
        .replaceAll(')', '\\)')
        .replaceAll('#', '\\#')
        .replaceAll('+', '\\+')
        .replaceAll('-', '\\-')
        .replaceAll('.', '\\.')
        .replaceAll('!', '\\!')
        .replaceAll('|', '\\|');
  }

  /// Validates and sanitizes user message input before sending to API.
  ///
  /// Returns a map with 'valid' (bool), 'sanitized' (String), and optional 'error' (String).
  static Map<String, dynamic> validateAndSanitizeMessage(String message) {
    final trimmed = message.trim();

    // Check length
    final lengthError = validateMessageLength(trimmed);
    if (lengthError != null) {
      return {'valid': false, 'error': lengthError, 'sanitized': ''};
    }

    // Message is valid, return sanitized version
    // For now, we just trim and validate length.
    // Additional sanitization can be added here if needed.
    return {'valid': true, 'sanitized': trimmed, 'error': null};
  }

  /// Gets the file extension from a file name (including the dot).
  static String _getFileExtension(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot == -1 || lastDot == fileName.length - 1) {
      return '';
    }
    return fileName.substring(lastDot);
  }

  /// Formats a large number with commas for readability.
  static String _formatNumber(int number) {
    return number.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  // ==================== Password Validation ====================

  /// Validates password strength and returns detailed feedback.
  ///
  /// Requirements:
  /// - Minimum 6 characters
  /// - At least one uppercase letter
  /// - At least one lowercase letter
  /// - At least one digit
  /// - At least one special character
  static PasswordValidationResult validatePasswordStrength(String? password) {
    if (password == null || password.isEmpty) {
      return const PasswordValidationResult(
        isValid: false,
        strength: PasswordStrength.weak,
        errorMessage: 'Password is required.',
        suggestions: ['Enter a password'],
        hasMinLength: false,
        hasUppercase: false,
        hasLowercase: false,
        hasDigit: false,
        hasSpecialChar: false,
      );
    }

    final hasMinLength = password.length >= minPasswordLength;
    final hasUppercase = password.contains(RegExp(r'[A-Z]'));
    final hasLowercase = password.contains(RegExp(r'[a-z]'));
    final hasDigit = password.contains(RegExp(r'[0-9]'));
    final hasSpecialChar = password.contains(RegExp(r'[^A-Za-z0-9]'));

    final suggestions = <String>[];
    if (!hasMinLength) {
      suggestions.add('Use at least $minPasswordLength characters');
    }
    if (!hasUppercase) {
      suggestions.add('Add uppercase letters (A-Z)');
    }
    if (!hasLowercase) {
      suggestions.add('Add lowercase letters (a-z)');
    }
    if (!hasDigit) {
      suggestions.add('Add numbers (0-9)');
    }
    if (!hasSpecialChar) {
      suggestions.add('Add special characters (!@#\$%^&*)');
    }

    // Calculate strength
    int score = 0;
    if (hasMinLength) score++;
    if (hasUppercase) score++;
    if (hasLowercase) score++;
    if (hasDigit) score++;
    if (hasSpecialChar) score++;

    // Additional scoring for extra length
    if (password.length >= 16) score++;
    if (password.length >= 20) score++;

    PasswordStrength strength;
    if (score <= 2) {
      strength = PasswordStrength.weak;
    } else if (score <= 4) {
      strength = PasswordStrength.fair;
    } else if (score <= 5) {
      strength = PasswordStrength.good;
    } else {
      strength = PasswordStrength.strong;
    }

    final isValid =
        hasMinLength &&
        hasUppercase &&
        hasLowercase &&
        hasDigit &&
        hasSpecialChar;

    String? errorMessage;
    if (!isValid) {
      errorMessage =
          'Password must be at least $minPasswordLength characters and include uppercase, lowercase, number, and special character.';
    }

    return PasswordValidationResult(
      isValid: isValid,
      strength: strength,
      errorMessage: errorMessage,
      suggestions: suggestions,
      hasMinLength: hasMinLength,
      hasUppercase: hasUppercase,
      hasLowercase: hasLowercase,
      hasDigit: hasDigit,
      hasSpecialChar: hasSpecialChar,
    );
  }

  /// Simple password validation for forms.
  ///
  /// Returns null if valid, otherwise returns an error message.
  static String? validatePassword(String? password) {
    final result = validatePasswordStrength(password);
    return result.errorMessage;
  }
}
